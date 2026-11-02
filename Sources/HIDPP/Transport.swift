/// A HID++ report transport. Endpoint subscriptions and all I/O belong to the main actor.
@MainActor
public protocol HIDPPTransport: AnyObject, Sendable {
    var product: String { get }
    var productID: Int { get }
    var isReceiver: Bool { get }
    func send(_ report: Report) throws
    func subscribe(_ deviceIndex: UInt8, _ handler: @escaping (Report) -> Void)
    func unsubscribe(_ deviceIndex: UInt8)
}
