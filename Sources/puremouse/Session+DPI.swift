import Foundation
import PureMouseKit
import HIDPP

/// The sensor resolution: which feature sets it, the list it accepts, and what it reads back.
extension Session {
    /// The feature DPI goes through: 0x2201 whenever present, else 0x2202, which carries what its
    /// writes need (separate axes, lift-off distance).
    enum DPIFeature: Equatable {
        case adjustable
        case extended(ExtendedDPI.Capabilities)
    }

    /// Which feature sets this mouse's DPI, found once; nil if it has neither. A device answer to
    /// 0x2202's capabilities (an error or a malformed reply) is logged and asked again at the
    /// next apply, so a timeout or transport failure reaches configure's retry.
    func dpiFeature() async throws -> DPIFeature? {
        if let known = state.dpiFeature { return known }
        if try await device.hasFeature(AdjustableDPI.id) {
            state.dpiFeature = .adjustable
        } else if try await device.hasFeature(ExtendedDPI.id) {
            do {
                state.dpiFeature = .extended(try await ExtendedDPI.capabilities(device))
            } catch where Self.isDeviceAnswer(error) {
                Log.error("\(name): reading extended DPI capabilities failed: \(error); DPI is left alone")
            }
        }
        return state.dpiFeature
    }

    /// Sets the DPI wanted now (`liveDPI`, else the config's, if any), snapped to the sensor's
    /// list, and reads back the one in effect. Runs on `deviceActions`.
    func applyDPI() async throws {
        guard let feature = try await dpiFeature() else { return }
        if !state.dpiRefused { try await readResolutions(feature) }
        if let target = state.liveDPI ?? config.dpi, !state.dpiRefused {
            let dpi = supportedDPI(near: target)
            try await writeDPI(dpi, feature)
            try await confirmDPI(dpi, feature)
        } else {
            try await readDPI(feature)
        }
    }

    /// Writes `dpi`, a resolution the sensor accepts. For 0x2202 the lift-off distance is read
    /// first and written back unchanged.
    func writeDPI(_ dpi: Int, _ feature: DPIFeature) async throws {
        try ensureOpen()
        switch feature {
        case .adjustable:
            try await AdjustableDPI.set(device, dpi: dpi)
        case .extended(let capabilities):
            let reading = try await ExtendedDPI.get(device)
            try ensureOpen()
            try await ExtendedDPI.set(device, dpi: dpi, capabilities: capabilities, keeping: reading)
        }
    }

    /// Reads the resolution in effect after a write of `dpi`; every axis written must show it. One
    /// that differs means the mouse did not take it, as with an onboard profile (0x8100, which is
    /// never written), or took it on one axis only: its DPI is then not controllable, said once
    /// and not retried. Judged only against a known list of supported resolutions, as `dpi` is
    /// then one the sensor accepts; without it a sensor's rounding would read as a refusal.
    func confirmDPI(_ dpi: Int, _ feature: DPIFeature) async throws {
        let current = try await readDPI(feature)
        guard !current.shows(dpi), state.resolutions != nil else { return }
        state.dpiRefused = true
        Log.info("\(name): dpi stays \(current) after setting \(dpi); its DPI cannot be set from here")
        changed()
    }

    /// What the sensor reads back: the X axis, and the Y axis where it has its own.
    struct DPIReading: CustomStringConvertible {
        let x: Int
        let y: Int?

        func shows(_ dpi: Int) -> Bool { x == dpi && (y ?? dpi) == dpi }
        var description: String { y.map { "\(x) by \($0)" } ?? "\(x)" }
    }

    /// Reads the resolution in effect, for the status and the gesture distance, which is
    /// physical and so scales with it (that of the X axis).
    @discardableResult
    func readDPI(_ feature: DPIFeature) async throws -> DPIReading {
        let current: DPIReading
        switch feature {
        case .adjustable:
            current = DPIReading(x: try await AdjustableDPI.get(device), y: nil)
        case .extended(let capabilities):
            let reading = try await ExtendedDPI.get(device)
            current = DPIReading(x: reading.x, y: capabilities.separateY ? reading.y : nil)
        }
        state.dpi = current.x
        recognizer.threshold = GestureRecognizer.counts(millimetres: config.gesture.distanceMm, dpi: current.x)
        return current
    }

    /// Reads the sensor's supported resolutions once per mouse. A device answer (error or
    /// malformed reply) is logged and retried on the next apply, and meanwhile DPI targets are
    /// sent unchanged; a timeout or transport failure fails the apply, so configure retries.
    private func readResolutions(_ feature: DPIFeature) async throws {
        guard state.resolutions == nil else { return }
        do {
            switch feature {
            case .adjustable: state.resolutions = try await AdjustableDPI.resolutions(device)
            case .extended(let capabilities): state.resolutions = try await ExtendedDPI.resolutions(device, capabilities: capabilities)
            }
        } catch ExtendedDPI.ListError.noCommonResolution {
            // Definitive, unlike a list that cannot be read: no one value suits both axes.
            state.dpiRefused = true
            Log.error("\(name): its X and Y axes share no resolution; its DPI cannot be set from here")
            changed()
        } catch where Self.isDeviceAnswer(error) {
            Log.error("\(name): reading supported DPI failed: \(error); DPI is set as configured")
        }
    }

    /// `target` snapped to a resolution the sensor accepts, or unchanged if the list is unknown.
    func supportedDPI(near target: Int) -> Int {
        let dpi = state.resolutions?.nearest(to: target) ?? target
        if dpi != target, state.snapLogged.insert(target).inserted {
            Log.info("\(name): dpi \(target) is not supported; using \(dpi)")
        }
        return dpi
    }
}
