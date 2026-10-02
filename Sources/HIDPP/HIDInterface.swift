import Foundation
import IOKit.hid

/// One Logitech HID++ collection seen by macOS: a Bolt/Unifying receiver (usage page 0xFF00)
/// or a directly connected Bluetooth device (usage page 0xFF43).
@MainActor
public final class HIDInterface {
    public let device: IOHIDDevice
    public let product: String
    public let productID: Int
    public let usagePage: Int
    public let transport: String

    /// A receiver multiplexes up to six devices by slot index; a Bluetooth device is index 0xFF.
    public var isReceiver: Bool { usagePage == 0xFF00 }

    private var subscribers: [UInt8: (Report) -> Void] = [:]

    init(device: IOHIDDevice) {
        self.device = device
        product = device.property(kIOHIDProductKey) ?? "?"
        productID = device.property(kIOHIDProductIDKey) ?? 0
        usagePage = device.property(kIOHIDPrimaryUsagePageKey) ?? 0
        transport = device.property(kIOHIDTransportKey) ?? "?"
    }

    public func send(_ report: Report) throws {
        let bytes = report.bytes
        let result: IOReturn
        if let element = longOutputElement, !isReceiver {
            // Over Bluetooth LE, IOHIDDeviceSetReport reports success but sends nothing; the
            // output element must be set directly, without the report ID byte.
            let body = Array(bytes.dropFirst())
            guard let value = IOHIDValueCreateWithBytes(kCFAllocatorDefault, element, mach_absolute_time(),
                                                        body, body.count)
            else { throw HIDPPError.sendFailed(kIOReturnNoMemory) }
            result = IOHIDDeviceSetValue(device, element, value)
        } else {
            result = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(bytes[0]), bytes, bytes.count)
        }
        guard result == kIOReturnSuccess else { throw HIDPPError.sendFailed(result) }
    }

    /// The vendor-page output element carrying long (0x11) HID++ reports, if the device has one.
    /// Its presence is what makes a Bluetooth device a HID++ device.
    public private(set) lazy var longOutputElement: IOHIDElement? = {
        let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone))
            as? [IOHIDElement] ?? []
        return elements.first {
            IOHIDElementGetType($0) == kIOHIDElementTypeOutput && IOHIDElementGetUsagePage($0) >= 0xFF00
                && IOHIDElementGetReportID($0) == UInt32(ReportID.long.rawValue)
                && IOHIDElementGetReportCount($0) == UInt32(ReportID.long.length - 1)
        }
    }()

    /// Routes reports for `deviceIndex` to `handler`; one subscriber per index.
    public func subscribe(_ deviceIndex: UInt8, _ handler: @escaping (Report) -> Void) {
        subscribers[deviceIndex] = handler
    }

    public func unsubscribe(_ deviceIndex: UInt8) {
        subscribers[deviceIndex] = nil
    }

    func deliver(_ report: Report) {
        // A direct device is always index 0xFF, though over Bluetooth it may answer as 0x00.
        subscribers[isReceiver ? report.deviceIndex : directDeviceIndex]?(report)
    }
}

/// Watches for Logitech HID++ interfaces appearing and disappearing, and delivers their input
/// reports. Everything runs on the main queue.
@MainActor
public final class HIDMonitor {
    public var onAttach: ((HIDInterface) -> Void)?
    public var onDetach: ((HIDInterface) -> Void)?
    public private(set) var interfaces: [HIDInterface] = []

    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

    public static let logitechVendorID = 0x046D

    public init() {}

    /// Starts matching. Returns the IOKit status of opening the manager; `kIOReturnNotPermitted`
    /// means the process lacks Input Monitoring permission.
    @discardableResult
    public func start() -> IOReturn {
        // Receivers expose HID++ as their own vendor-page interface. Bluetooth devices hide it
        // inside the main interface, so match them by transport and filter on attach.
        let matching = [
            [kIOHIDVendorIDKey: Self.logitechVendorID, kIOHIDPrimaryUsagePageKey: 0xFF00],
            [kIOHIDVendorIDKey: Self.logitechVendorID, kIOHIDTransportKey: "Bluetooth Low Energy"],
        ] as [CFDictionary]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
            MainActor.assumeIsolated { HIDMonitor.from(ctx).attached(device) }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, device in
            MainActor.assumeIsolated { HIDMonitor.from(ctx).detached(device) }
        }, context)
        IOHIDManagerRegisterInputReportCallback(manager, { ctx, _, sender, _, _, bytes, length in
            guard let sender, let report = Report(bytes: UnsafeBufferPointer(start: bytes, count: length))
            else { return }
            let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
            MainActor.assumeIsolated { HIDMonitor.from(ctx).received(report, from: device) }
        }, context)

        // Open before activating: opening after activation on the main queue deadlocks.
        let status = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDispatchQueue(manager, .main)
        IOHIDManagerActivate(manager)
        return status
    }

    private static func from(_ ctx: UnsafeMutableRawPointer?) -> HIDMonitor {
        Unmanaged<HIDMonitor>.fromOpaque(ctx!).takeUnretainedValue()
    }

    private func attached(_ device: IOHIDDevice) {
        guard !interfaces.contains(where: { $0.device == device }) else { return }
        let interface = HIDInterface(device: device)
        guard interface.isReceiver || interface.longOutputElement != nil else { return }
        interfaces.append(interface)
        onAttach?(interface)
    }

    private func detached(_ device: IOHIDDevice) {
        guard let i = interfaces.firstIndex(where: { $0.device == device }) else { return }
        let interface = interfaces.remove(at: i)
        onDetach?(interface)
    }

    private func received(_ report: Report, from device: IOHIDDevice) {
        interfaces.first { $0.device == device }?.deliver(report)
    }
}

extension IOHIDDevice {
    func property<T>(_ key: String) -> T? {
        IOHIDDeviceGetProperty(self, key as CFString) as? T
    }
}
