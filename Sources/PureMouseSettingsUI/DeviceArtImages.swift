import AppKit

/// The device art PDFs, loaded the first time a drawing is asked for in an appearance, and kept.
/// Only the device card asks, so Settings on General, Apps, About or All Mice never reads one. The
/// loader is a seam: the app's is `bundled`, a test passes its own (through the card's
/// `deviceArtImages` environment value) and counts the calls.
@MainActor
final class DeviceArtImages {
    typealias Load = @MainActor (DeviceArt.Family, _ dark: Bool) -> NSImage?

    /// The app's, for the device card.
    static let shared = DeviceArtImages(load: { DeviceArtImages.bundled($0, dark: $1) })

    private struct Key: Hashable {
        let family: DeviceArt.Family
        let dark: Bool
    }

    private let load: Load
    private var images: [Key: NSImage] = [:]
    private var missing: Set<Key> = []

    init(load: @escaping Load) { self.load = load }

    /// The family's drawing in the light or dark appearance's colours, or nil when the PDF is
    /// missing or unreadable. Asked once per drawing and appearance: a miss is remembered too.
    func image(for family: DeviceArt.Family, dark: Bool) -> NSImage? {
        let key = Key(family: family, dark: dark)
        if let image = images[key] { return image }
        if missing.contains(key) { return nil }
        guard let image = load(family, dark) else {
            missing.insert(key)
            return nil
        }
        images[key] = image
        return image
    }

    /// `silhouettes/<family>-light.pdf` (or `-dark`) in the Settings helper's Resources
    /// (build-app.sh puts them there).
    static func bundled(_ family: DeviceArt.Family, dark: Bool, in bundle: Bundle = .main) -> NSImage? {
        bundle.url(forResource: family.file(dark: dark), withExtension: "pdf", subdirectory: "silhouettes")
            .flatMap(image(contentsOf:))
    }

    /// A PDF as an image, drawn in its own colours.
    static func image(contentsOf url: URL) -> NSImage? {
        guard let image = NSImage(contentsOf: url), image.isValid else { return nil }
        return image
    }
}
