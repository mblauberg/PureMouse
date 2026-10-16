import Foundation

/// A HID++ endpoint: one receiver slot, the receiver itself (index 0xFF on a receiver), or a
/// Bluetooth device (index 0xFF). Requests are serialised; one is in flight at a time.
@MainActor
public final class HIDPPDevice {
    public nonisolated let interface: HIDInterface
    public nonisolated let index: UInt8
    /// Unsolicited reports: HID++ 2.0 events and HID++ 1.0 notifications (`Report.isEvent`).
    public var onEvent: ((Report) -> Void)?

    /// Software IDs mark replies as ours (0 is reserved for events). They rotate per request so
    /// that a reply arriving after its request timed out cannot satisfy a later request, and
    /// programs sharing a device (the daemon and `puremouse probe`) use disjoint ranges.
    public nonisolated let softwareIDs: ClosedRange<UInt8>
    public static let defaultSoftwareIDs: ClosedRange<UInt8> = 0x8...0xF
    public var timeout: Duration = .milliseconds(1500)

    private var featureIndices: [UInt16: UInt8] = [0x0000: 0]
    private var pending: Pending?
    private var nextSoftwareID: UInt8
    private var closed = false
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var nextToken = 0

    private struct Pending {
        let token: Int
        let request: Report
        let continuation: CheckedContinuation<[UInt8], Error>
        /// Fails the request with `.timeout`; cancelled once the request ends any other way.
        var deadline: Task<Void, Never>?
    }

    public init(interface: HIDInterface, index: UInt8, softwareIDs: ClosedRange<UInt8> = defaultSoftwareIDs) {
        precondition(softwareIDs.lowerBound > 0 && softwareIDs.upperBound <= 0xF)
        self.interface = interface
        self.index = index
        self.softwareIDs = softwareIDs
        nextSoftwareID = softwareIDs.lowerBound
        interface.subscribe(index) { [weak self] in self?.handle($0) }
    }

    /// Stops receiving reports. The request in flight and any queued behind it fail with `.closed`.
    public func close() {
        closed = true
        interface.unsubscribe(index)
        failPending(HIDPPError.closed)
        let queued = waiters
        waiters = []
        queued.forEach { $0.resume() }  // each wakes, sees `closed` and throws
    }

    // MARK: Requests

    /// Sends a HID++ 2.0 request and returns the response parameters.
    public func request(_ reportID: ReportID = .long, featureIndex: UInt8, function: UInt8,
                        params: [UInt8] = []) async throws -> [UInt8] {
        try await send(Report(reportID: reportID, deviceIndex: index, featureIndex: featureIndex,
                              function: function, softwareID: softwareIDs.lowerBound, params: params),
                       rotatingSoftwareID: true)
    }

    /// Sends a HID++ 1.0 register request (`subID` 0x80 set / 0x81 get short register), where
    /// byte 3 is the register address rather than function and software ID.
    public func registerRequest(subID: UInt8, register: UInt8, params: [UInt8] = []) async throws -> [UInt8] {
        try await send(Report(reportID: .short, deviceIndex: index, featureIndex: subID,
                              function: register >> 4, softwareID: register & 0x0F, params: params))
    }

    private func send(_ request: Report, rotatingSoftwareID: Bool = false) async throws -> [UInt8] {
        guard !closed else { throw HIDPPError.closed }
        await acquire()
        defer { release() }
        // A request queued behind others must not go out once its caller has given up.
        guard !closed else { throw HIDPPError.closed }
        try Task.checkCancellation()
        // Allocated only for requests that really go out, so abandoned ones cannot use up the
        // rotation and bring a timed-out request's ID straight back.
        var request = request
        if rotatingSoftwareID { request.softwareID = takeSoftwareID() }
        nextToken += 1
        let token = nextToken
        // A caller that gives up (say a session closing) fails its request at once rather than
        // holding the endpoint until the timeout, so whatever is queued behind it goes out sooner.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = Pending(token: token, request: request, continuation: continuation)
                do {
                    try interface.send(request)
                } catch {
                    failPending(error)
                    return
                }
                guard pending?.token == token else { return }  // answered or failed during send
                pending?.deadline = Task { [weak self, timeout] in
                    do { try await Task.sleep(for: timeout) } catch { return }  // cancelled: ended already
                    guard let self, self.pending?.token == token else { return }
                    self.failPending(HIDPPError.timeout)
                }
            }
        } onCancel: {
            // Runs wherever the canceller is, perhaps before the request is pending: hop and look.
            Task { @MainActor [weak self] in
                guard let self, self.pending?.token == token else { return }
                self.failPending(CancellationError())
            }
        }
    }

    /// Calls `function` of HID++ 2.0 feature `feature`, resolving and caching its index.
    public func call(_ feature: UInt16, _ function: UInt8, _ params: [UInt8] = []) async throws -> [UInt8] {
        let featureIndex = try await featureIndex(of: feature)
        return try await request(featureIndex: featureIndex, function: function, params: params)
    }

    public func featureIndex(of feature: UInt16) async throws -> UInt8 {
        if let cached = featureIndices[feature] { return cached }
        let response = try await request(featureIndex: 0, function: 0, params: feature.bigEndianBytes)
        guard let featureIndex = response.first, featureIndex != 0 else {
            throw HIDPPError.featureNotSupported(feature)
        }
        featureIndices[feature] = featureIndex
        return featureIndex
    }

    /// The cached feature ID at `featureIndex`, for routing events. Only features already
    /// resolved through `featureIndex(of:)` are known.
    public func feature(at featureIndex: UInt8) -> UInt16? {
        featureIndices.first { $0.value == featureIndex }?.key
    }

    /// Whether the device has `feature`: false if it says not, throws if it does not answer.
    public func hasFeature(_ feature: UInt16) async throws -> Bool {
        do {
            _ = try await featureIndex(of: feature)
            return true
        } catch HIDPPError.featureNotSupported {
            return false
        }
    }

    /// HID++ protocol version, or nil if the slot is empty or the device is asleep.
    public func protocolVersion() async -> (major: UInt8, minor: UInt8)? {
        guard let r = try? await request(featureIndex: 0, function: 1, params: [0, 0, 0x5A]),
              r.count >= 2 else { return nil }
        return (r[0], r[1])
    }

    // MARK: Plumbing

    private func handle(_ report: Report) {
        if let p = pending {
            if p.request.isAnswered(by: report) {
                pending = nil
                p.deadline?.cancel()
                p.continuation.resume(returning: report.params)
                return
            }
            if let error = report.error(for: p.request) {
                failPending(error)
                return
            }
        }
        if report.isEvent { onEvent?(report) }
    }

    private func failPending(_ error: Error) {
        guard let p = pending else { return }
        pending = nil
        p.deadline?.cancel()
        p.continuation.resume(throwing: error)
    }

    private func takeSoftwareID() -> UInt8 {
        let id = nextSoftwareID
        nextSoftwareID = id == softwareIDs.upperBound ? softwareIDs.lowerBound : id + 1
        return id
    }

    private func acquire() async {
        guard busy else { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}

extension UInt16 {
    var bigEndianBytes: [UInt8] { [UInt8(self >> 8), UInt8(self & 0xFF)] }
    init(bigEndian hi: UInt8, _ lo: UInt8) { self = UInt16(hi) << 8 | UInt16(lo) }
}
