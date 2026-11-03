/// A HID++ report transport. Endpoint subscriptions and all I/O belong to the main actor.
@MainActor
public protocol HIDPPTransport: AnyObject, Sendable {
    var product: String { get }
    var productID: Int { get }
    var isReceiver: Bool { get }
    /// The (usage page, usage) pairs the device's HID descriptor declares, empty when unknown.
    var usagePairs: [HIDUsagePair] { get }
    func send(_ report: Report) throws
    func subscribe(_ deviceIndex: UInt8, _ handler: @escaping (Report) -> Void)
    func unsubscribe(_ deviceIndex: UInt8)
}

/// One top-level collection a HID device declares: Generic Desktop (0x01) Mouse is (0x01, 0x02).
public struct HIDUsagePair: Equatable, Sendable {
    public let page: Int
    public let usage: Int
    public init(page: Int, usage: Int) { self.page = page; self.usage = usage }

    public static let genericDesktop = 0x01
    /// Generic Desktop usages: Mouse, Pointer, Keyboard, Keypad.
    public var isPointing: Bool { page == Self.genericDesktop && (usage == 0x02 || usage == 0x01) }
    public var isTyping: Bool { page == Self.genericDesktop && (usage == 0x06 || usage == 0x07) }
}

extension HIDPPTransport {
    public var usagePairs: [HIDUsagePair] { [] }
}
