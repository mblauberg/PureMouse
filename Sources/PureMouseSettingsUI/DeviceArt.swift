import CoreGraphics
import PureMouseAppSupport

/// Which drawing a mouse gets, which parts of it are targets and what each part opens. Pure data
/// and rules: nothing here loads an image (`DeviceArtImages` does, only for the device card) or
/// touches a setting. Docs: docs/ui-design.md, "Device card"; docs/adr/0013-silhouettes.md.
///
/// The drawings are four family templates, each in a light and a dark PDF (`assets/silhouettes`):
/// the MX Master 3 and 3S, the MX Master 4 (the same shape with its gesture button on the wing),
/// the MX Anywhere shape and the Signature M750's. A mouse is identified the
/// way the rest of Settings does, by its device key (`Status.Device.model`), never by its name. A
/// mouse of no listed model, and every other form (vertical, trackball, G series), gets no drawing
/// and no card.
enum DeviceArt {
    /// One drawing template.
    enum Family: String, CaseIterable, Sendable {
        case mx
        case mx4
        case compactAnywhere = "compact-anywhere"
        case compactM750 = "compact-m750"

        /// The PDF's name in the helper's `silhouettes` resources.
        func file(dark: Bool) -> String { rawValue + (dark ? "-dark" : "-light") }
    }

    /// Something on the drawing a pointer can find. The wheels are named for what they are; the
    /// control a part binds depends on the model (`Model.binds`). `gesture` is the small key ahead
    /// of Forward and Back on the MX Master 4 (on the 3 and 3S the gesture button is the thumb rest).
    enum Part: String, CaseIterable, Sendable {
        case middle, top, forward, back, thumbWheel, thumbRest, gesture
    }

    /// What a part stands for on one model: a button with a row on Buttons, the main wheel (its
    /// click is a button's row, and its scrolling is Scrolling › Main Wheel), or the thumb wheel
    /// (no button: Scrolling › Thumb Wheel).
    enum Bind: Equatable, Sendable {
        case button(NamedButton)
        case mainWheel(click: NamedButton)
        case thumbWheel
    }

    /// A model group: the drawing its mice share and what each of its parts binds. A part a model
    /// lacks is left out, and so is a control with no shape (`listOnly` in the art's notes: it is
    /// a row only).
    struct Model: Equatable, Sendable {
        let name: String
        let family: Family
        /// The 16-bit product IDs that name this model in a device key (Bluetooth and receiver
        /// alike).
        let productIDs: Set<UInt16>
        let binds: [Part: Bind]
    }

    /// The art is 100 x 124 points; the card draws it at that size, or scaled evenly.
    static let size = CGSize(width: 100, height: 124)

    // MARK: Models

    private static func mxBinds(thumbRest: NamedButton) -> [Part: Bind] {
        [.middle: .mainWheel(click: .middle), .top: .button(.top), .forward: .button(.forward), .back: .button(.back),
         .thumbWheel: .thumbWheel, .thumbRest: .button(thumbRest)]
    }

    /// The models that have a drawing. The IDs come from the probe fixtures (`Tests/Fixtures/probe`)
    /// and OpenLogi's captures their headers cite: the MX Master 3's are 0xB023 (Bluetooth) and
    /// 0x4082 (receiver), the 3S's 0xB034 and, on a receiver, 0x4091. The MX Master 3 for Business
    /// and for Mac, the MX Anywhere 3 and the receiver IDs of the 4 and the Anywhere 3S are not in
    /// the fixtures yet; add each with the first `puremouse probe` of it (docs/supported-mice.md).
    static let models: [Model] = [
        // The thumb rest is the gesture button.
        Model(name: "MX Master 3 and 3S", family: .mx, productIDs: [0xB023, 0x4082, 0xB034, 0x4091],
              binds: mxBinds(thumbRest: .gesture)),
        // The thumb rest is the haptic panel; the gesture button (0xC3) is the small key ahead of
        // Forward and Back.
        Model(name: "MX Master 4", family: .mx4, productIDs: [0xB042],
              binds: mxBinds(thumbRest: .thumbPanel).merging([.gesture: .button(.gesture)]) { $1 }),
        // The top button sits behind the wheel; the Anywhere has no thumb wheel or thumb rest.
        Model(name: "MX Anywhere 3S", family: .compactAnywhere, productIDs: [0xB037],
              binds: [.middle: .mainWheel(click: .middle), .top: .button(.top), .forward: .button(.forward),
                      .back: .button(.back)]),
        // No top button; its DPI button (0xFD) is a row without a shape.
        Model(name: "Signature M750", family: .compactM750, productIDs: [0xB02C],
              binds: [.middle: .mainWheel(click: .middle), .forward: .button(.forward), .back: .button(.back)]),
    ]

    /// The model a device key names, or nil when it has none, which is no drawing. A key is `m` and
    /// the 0x0003 model ID's six bytes (up to three product IDs: Bluetooth, receiver, USB, in an order
    /// that varies with how the mouse was read), or `p` and one product ID (`Config.deviceKey`). A
    /// model matches on any of its IDs; a zero word is no ID.
    static func model(forKey key: String?) -> Model? {
        guard let words = productIDs(inKey: key) else { return nil }
        return models.first { !$0.productIDs.isDisjoint(with: words) }
    }

    /// The nonzero 16-bit words of a device key, or nil if it is not one.
    static func productIDs(inKey key: String?) -> Set<UInt16>? {
        guard let key = key?.lowercased(), let kind = key.first else { return nil }
        let digits = Array(key.dropFirst())
        guard digits.allSatisfy(\.isHexDigit) else { return nil }
        guard (kind == "m" && digits.count == 12) || (kind == "p" && digits.count == 4) else { return nil }
        var words = Set<UInt16>()
        for start in stride(from: 0, to: digits.count, by: 4) {
            if let word = UInt16(String(digits[start..<start + 4]), radix: 16), word != 0 { words.insert(word) }
        }
        return words
    }

    // MARK: Geometry

    /// A closed outline in art units (x from the left, y from the top).
    struct Polygon: Equatable, Sendable {
        let points: [CGPoint]

        /// `[x0, y0, x1, y1, …]`.
        init(_ flat: [Double]) {
            points = stride(from: 0, to: flat.count - 1, by: 2).map { CGPoint(x: flat[$0], y: flat[$0 + 1]) }
        }

        var path: CGPath {
            let path = CGMutablePath()
            if let first = points.first {
                path.move(to: first)
                points.dropFirst().forEach { path.addLine(to: $0) }
                path.closeSubpath()
            }
            return path
        }

        var bounds: CGRect { path.boundingBoxOfPath }

        func contains(_ point: CGPoint) -> Bool { path.contains(point) }
    }

    /// A part's hit cell and its own outline. Cells partition the drawing, so a point is in at most
    /// one; hover and selection fill the outline, never the cell.
    struct Geometry: Equatable, Sendable {
        let hit: Polygon
        let outline: Polygon
    }

    /// The part of `family`'s drawing under `point` (art units), among `parts`: only an active part
    /// responds.
    static func part(at point: CGPoint, in family: Family, among parts: Set<Part>) -> Part? {
        parts.first { geometry[family]?[$0]?.hit.contains(point) == true }
    }
}
