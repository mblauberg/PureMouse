import Foundation
import HIDPP
import PureMouseKit

/// Who a newly found mouse is, read once when it is adopted: the name it reports, its device key
/// (`Config.deviceKey`: the config's `devices` key and `Status.Device.model`), its unit ID and its
/// kind. A read that fails leaves its field nil and never fails the adoption.
struct Identification: Equatable, Sendable {
    var name: String?
    /// `m` plus the 0x0003 model ID, else `p` plus the product ID. Nil when 0x0003 did not answer
    /// (a timeout), so a mouse is never taken for another model it might not be.
    var model: String?
    /// The 0x0003 unit ID in 8 lowercase hex digits; nil when absent or all zeros or all 0xFF.
    var unit: String?
    var kind: DeviceName.Kind?

    /// `productID` is the one the daemon knows for the endpoint (the interface's, or the
    /// receiver slot's), the key's fallback when the mouse has no usable model ID.
    static func read(_ device: HIDPPDevice, productID: UInt16?) async -> Identification {
        var result = Identification()
        result.name = try? await DeviceName.get(device)
        result.kind = (try? await DeviceName.kind(device)) ?? nil
        do {
            let info = try await DeviceIdentity.info(device)
            result.model = Config.deviceKey(modelID: info.modelID, productID: productID)
            result.unit = unit(info.unitID)
        } catch where (error as? HIDPPError)?.isDeviceAnswer == true {
            result.model = Config.deviceKey(modelID: nil, productID: productID)
        } catch {}
        return result
    }

    static func unit(_ bytes: [UInt8]) -> String? {
        guard !bytes.allSatisfy({ $0 == 0 }), !bytes.allSatisfy({ $0 == 0xFF }) else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
