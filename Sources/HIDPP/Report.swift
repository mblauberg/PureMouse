/// HID++ framing. Every message is `[reportID, deviceIndex, featureIndex, fn<<4 | swID, params...]`.
public enum ReportID: UInt8, Sendable {
    case short = 0x10  // 7 bytes total; receiver-only, never over Bluetooth LE
    case long = 0x11   // 20 bytes total; works everywhere

    public var length: Int { self == .short ? 7 : 20 }
    public var paramCount: Int { length - 4 }
}

/// Device index used when talking to a device directly (Bluetooth) rather than through a receiver slot.
public let directDeviceIndex: UInt8 = 0xFF

public struct Report: Equatable, Sendable, CustomStringConvertible {
    public var reportID: ReportID
    public var deviceIndex: UInt8
    /// HID++ 2.0 feature index, or the HID++ 1.0 sub-ID (e.g. 0x41 connection, 0x8F error).
    public var featureIndex: UInt8
    public var function: UInt8   // high nibble of byte 3
    public var softwareID: UInt8 // low nibble of byte 3; 0 means an unsolicited event
    public var params: [UInt8]

    public init(reportID: ReportID = .long, deviceIndex: UInt8, featureIndex: UInt8,
                function: UInt8, softwareID: UInt8, params: [UInt8] = []) {
        precondition(function < 16 && softwareID < 16)
        self.reportID = reportID
        self.deviceIndex = deviceIndex
        self.featureIndex = featureIndex
        self.function = function
        self.softwareID = softwareID
        self.params = params
    }

    /// Parses a raw input report (first byte is the report ID). Returns nil for non-HID++ reports.
    public init?(bytes: some Collection<UInt8>) {
        let b = Array(bytes)
        guard b.count >= 4, let id = ReportID(rawValue: b[0]) else { return nil }
        reportID = id
        deviceIndex = b[1]
        featureIndex = b[2]
        function = b[3] >> 4
        softwareID = b[3] & 0x0F
        params = Array(b[4...])
    }

    /// Wire bytes, zero-padded (or truncated) to the report length.
    public var bytes: [UInt8] {
        var out = [reportID.rawValue, deviceIndex, featureIndex, function << 4 | softwareID]
        out += params.prefix(reportID.paramCount)
        out += Array(repeating: 0, count: reportID.length - out.count)
        return out
    }

    /// Whether `other` answers this request (same device, feature, function and software ID).
    func isAnswered(by other: Report) -> Bool {
        other.isFromDevice(deviceIndex) && other.featureIndex == featureIndex
            && other.function == function && other.softwareID == softwareID
    }

    /// Whether an unsolicited report is an event: a HID++ 2.0 event (software ID 0) or a short
    /// HID++ 1.0 notification (sub-ID 0x40-0x7F, such as 0x41 connection), which puts arbitrary
    /// data in byte 3. Anything else is a reply to another program (`puremouse probe`, Solaar),
    /// marked by its software ID, even a long one at a feature index in 0x40-0x7F.
    var isEvent: Bool {
        softwareID == 0 || (reportID == .short && (0x40..<0x80).contains(featureIndex))
    }

    /// The HID++ error this report carries for `request`, if any.
    func error(for request: Report) -> HIDPPError? {
        // Error layout: [id, dev, 0xFF|0x8F, failedFeatureIndex, failedFn<<4|sw, code], so the
        // failed feature index lands in this report's byte 3 (parsed as function/softwareID).
        guard isFromDevice(request.deviceIndex), params.count >= 2,
              function << 4 | softwareID == request.featureIndex,
              params[0] == request.function << 4 | request.softwareID else { return nil }
        switch featureIndex {
        case 0xFF: return .protocol20(code: params[1])
        case 0x8F: return .protocol10(code: params[1])
        default: return nil
        }
    }

    /// Bluetooth devices addressed as 0xFF may reply with index 0x00.
    private func isFromDevice(_ index: UInt8) -> Bool {
        deviceIndex == index || deviceIndex == index ^ 0xFF
    }

    public var description: String {
        let p = params.map { String(format: "%02x", $0) }.joined(separator: " ")
        return String(format: "[%02x dev=%02x feat=%02x fn=%x sw=%x] ", reportID.rawValue,
                      deviceIndex, featureIndex, function, softwareID) + p
    }
}

public enum HIDPPError: Error, Equatable, CustomStringConvertible {
    case protocol10(code: UInt8)
    case protocol20(code: UInt8)
    case timeout
    case closed
    case featureNotSupported(UInt16)
    case sendFailed(Int32)
    case malformedResponse

    public var description: String {
        switch self {
        case .protocol10(let c): return "HID++ 1.0 error 0x\(String(c, radix: 16))"
        case .protocol20(let c): return "HID++ 2.0 error 0x\(String(c, radix: 16))"
        case .timeout: return "timed out"
        case .closed: return "device closed"
        case .featureNotSupported(let f): return "feature 0x\(String(f, radix: 16)) not supported"
        case .sendFailed(let r): return "sending report failed: 0x\(String(UInt32(bitPattern: r), radix: 16))"
        case .malformedResponse: return "malformed response"
        }
    }
}
