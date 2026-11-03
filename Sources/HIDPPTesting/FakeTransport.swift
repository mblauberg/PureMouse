import HIDPP

/// In-memory transport; replies can arrive during send, on the next turn, or never.
@MainActor
public final class FakeTransport: HIDPPTransport {
    public enum Timing { case nextTurn, synchronous, never }
    public let product: String
    public var productID: Int
    public let isReceiver: Bool
    public var timing: Timing = .nextTurn
    public var usagePairs: [HIDUsagePair] = []
    public var sent: [Report] = []
    public var answer: ((Report) throws -> Report?)?
    private var subscribers: [UInt8: (Report) -> Void] = [:]

    public init(product: String = "Fake mouse", productID: Int = 0xB034, isReceiver: Bool = false) {
        self.product = product
        self.productID = productID
        self.isReceiver = isReceiver
    }

    public func send(_ report: Report) throws {
        sent.append(report)
        guard timing != .never, let reply = try answer?(report) else { return }
        switch timing {
        case .synchronous: deliver(reply)
        case .nextTurn: Task { self.deliver(reply) }
        case .never: break
        }
    }

    public func subscribe(_ deviceIndex: UInt8, _ handler: @escaping (Report) -> Void) {
        subscribers[deviceIndex] = handler
    }

    public func unsubscribe(_ deviceIndex: UInt8) { subscribers[deviceIndex] = nil }

    public func deliver(_ report: Report) {
        subscribers[isReceiver ? report.deviceIndex : directDeviceIndex]?(report)
    }

    public static func reply(to request: Report, params: [UInt8]) -> Report {
        var reply = request
        reply.params = params
        // Match the padding on a real input report.
        return Report(bytes: reply.bytes)!
    }

    public static func error(to request: Report, code: UInt8, legacy: Bool = false) -> Report {
        Report(reportID: legacy ? .short : .long, deviceIndex: request.deviceIndex,
               featureIndex: legacy ? 0x8F : 0xFF, function: request.featureIndex >> 4,
               softwareID: request.featureIndex & 0xF,
               params: [request.function << 4 | request.softwareID, code])
    }
}
