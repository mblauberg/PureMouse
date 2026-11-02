import Foundation
import HIDPP
import PureMouseKit

/// Who a newly found mouse is, read once when it is adopted: its device key (`Config.deviceKey`:
/// the config's `devices` key and `Status.Device.model`), its unit ID and its kind. A read that
/// fails leaves its field nil and never fails the adoption.
struct Identification: Equatable, Sendable {
    /// `m` plus the 0x0003 model ID, else `p` plus the product ID. Nil when 0x0003 did not answer
    /// (a timeout), so a mouse is never taken for another model it might not be, and nil while
    /// the product ID a key needs is not known yet (`keyedByProduct`).
    var deviceKey: String?
    /// 0x0003 answered without a usable model ID (absent, or a placeholder), so the key is the
    /// product ID's: for a receiver slot adopted before its first connection announcement, the
    /// daemon completes it with `keyed(byProduct:)` once the announcement names the product.
    var keyedByProduct = false
    /// The 0x0003 unit ID in 8 lowercase hex digits; nil when absent or a placeholder.
    var unit: String?
    var kind: DeviceName.Kind?

    /// `productID` is the one the daemon knows for the endpoint (the interface's, or the
    /// receiver slot's), the key's fallback when the mouse has no usable model ID.
    static func read(_ device: HIDPPDevice, productID: UInt16?) async -> Identification {
        var result = Identification()
        result.kind = try? await DeviceName.kind(device)
        do {
            let info = try await DeviceIdentity.info(device)
            result.keyedByProduct = Config.deviceKey(modelID: info.modelID, productID: nil) == nil
            result.deviceKey = Config.deviceKey(modelID: info.modelID, productID: productID)
            result.unit = Config.identityHex(info.unitID)
        } catch where Session.isDeviceAnswer(error) {
            result.keyedByProduct = true
            result.deviceKey = Config.deviceKey(modelID: nil, productID: productID)
        } catch {}
        return result
    }

    /// The identity with the key `productID` gives, when the key is the product ID's.
    func keyed(byProduct productID: UInt16) -> Identification {
        guard keyedByProduct else { return self }
        var result = self
        result.deviceKey = Config.deviceKey(modelID: nil, productID: productID)
        return result
    }
}
