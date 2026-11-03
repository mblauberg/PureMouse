import Observation
import PureMouseAppSupport
import SwiftUI

extension EnvironmentValues {
    /// The loader the device card draws with; nil is the app's (`DeviceArtImages.shared`). A test
    /// sets its own to count what loads.
    @Entry var deviceArtImages: DeviceArtImages? = nil
}

/// A section of Mouse › Scrolling the device card can send the person to.
enum ScrollingSection: String, Hashable, Sendable {
    case mainWheel, thumbWheel

    var title: String {
        switch self {
        case .mainWheel: "Main Wheel"
        case .thumbWheel: "Thumb Wheel"
        }
    }
}

/// Where a part of the card leads: a row on Buttons (the same page) or a section of Scrolling.
enum CardDestination: Hashable, Sendable {
    case row(NamedButton)
    case scrolling(ScrollingSection)

    /// The main wheel's menu item.
    var menuTitle: String {
        switch self {
        case .row(.middle): "Wheel Click"
        case .row(let button): button.label
        case .scrolling: "Scrolling Settings"
        }
    }
}

/// What the card offers for one mouse: the parts that respond and where each leads. Pure data
/// (`DeviceCardTests`). A part exists only when the model has it, the art can place it and its
/// destination exists on this mouse: a button whose row is listed, the thumb wheel when Scrolling
/// shows it, the main wheel when it has a way in (its click row, Scrolling's Main Wheel section).
struct DeviceCardPlan: Equatable {
    struct Target: Equatable, Identifiable {
        let part: DeviceArt.Part
        /// One: pressing goes there. Two or more: pressing offers them as a menu.
        let destinations: [CardDestination]
        var id: DeviceArt.Part { part }
    }

    /// How a row's action reads: as shown, and as VoiceOver says it (a shortcut in words).
    struct ActionText: Equatable {
        let shown: String
        let spoken: String
    }

    static let hint = "Click a part of the mouse to find its setting."

    let model: DeviceArt.Model
    let targets: [Target]

    var family: DeviceArt.Family { model.family }

    /// `listed`: the named buttons Buttons has rows for. `mainWheelSettings`, `thumbWheelSettings`:
    /// Scrolling shows a Main Wheel / Thumb Wheel section for this mouse.
    init(model: DeviceArt.Model, listed: Set<NamedButton>, mainWheelSettings: Bool, thumbWheelSettings: Bool) {
        self.model = model
        let placed = DeviceArt.geometry[model.family] ?? [:]
        targets = DeviceArt.Part.allCases.compactMap { part in
            guard placed[part] != nil, let bind = model.binds[part] else { return nil }
            var destinations: [CardDestination] = []
            switch bind {
            case .button(let button):
                if listed.contains(button) { destinations = [.row(button)] }
            case .mainWheel(let click):
                if listed.contains(click) { destinations.append(.row(click)) }
                if mainWheelSettings { destinations.append(.scrolling(.mainWheel)) }
            case .thumbWheel:
                if thumbWheelSettings { destinations = [.scrolling(.thumbWheel)] }
            }
            return destinations.isEmpty ? nil : Target(part: part, destinations: destinations)
        }
    }

    func target(_ part: DeviceArt.Part) -> Target? { targets.first { $0.part == part } }

    /// The part a row belongs to, if the card has it.
    func part(for button: NamedButton) -> DeviceArt.Part? {
        targets.first { $0.destinations.contains(.row(button)) }?.part
    }

    /// The part under a point in drawing units.
    func part(at point: CGPoint) -> DeviceArt.Part? {
        DeviceArt.part(at: point, in: family, among: Set(targets.map(\.part)))
    }

    /// The mouse the card shows: the one chosen, else the only one known when there is no pop-up.
    /// With two or more mice and All Mice, no one drawing is right.
    static func mouse(selected: KnownMouse?, known: [KnownMouse], offersChoice: Bool) -> KnownMouse? {
        if let selected { return selected }
        return !offersChoice && known.count == 1 ? known.first : nil
    }

    // MARK: Words

    /// "Back button", "Top button", "Thumb wheel": what VoiceOver calls the part.
    func name(of target: Target) -> String {
        switch model.binds[target.part] {
        case .button(let button): Self.buttonName(button)
        case .mainWheel: "Main wheel"
        case .thumbWheel: "Thumb wheel"
        case nil: target.part.rawValue
        }
    }

    static func buttonName(_ button: NamedButton) -> String {
        button.label.lowercased().hasSuffix("button") ? button.label : button.label + " button"
    }

    /// "Back button, set to Back"; a wheel is named alone and its actions carry the rest.
    func accessibilityLabel(of target: Target, actions: [NamedButton: ActionText]) -> String {
        if case .button(let button) = model.binds[target.part], let action = actions[button] {
            return "\(name(of: target)), set to \(action.spoken)"
        }
        return name(of: target)
    }

    func accessibilityHint(of target: Target) -> String {
        switch (target.destinations.count, target.destinations.first) {
        case (2..., _): "Opens a menu"
        case (_, .scrolling(let section)?): "Opens \(section.title) in Scrolling"
        default: "Shows its setting"
        }
    }

    /// What the caption slot says: the part under the pointer, else the selected button's, else how
    /// to use the card.
    func caption(hovered: DeviceArt.Part?, selected: NamedButton?, actions: [NamedButton: ActionText]) -> String {
        let part = hovered ?? selected.flatMap { part(for: $0) }
        guard let part, let target = target(part) else { return Self.hint }
        switch (model.binds[part], target.destinations) {
        case (.button(let button)?, _):
            return "\(Self.buttonName(button)): \(actions[button]?.shown ?? button.label)"
        case (.mainWheel?, let destinations) where destinations.count > 1:
            return "Main wheel: wheel click or scrolling settings"
        case (.mainWheel(let click)?, let destinations) where destinations == [.row(click)]:
            return "Wheel click: \(actions[click]?.shown ?? click.label)"
        case (.mainWheel?, _):
            return "Main wheel: scrolling settings"
        default:
            return "Thumb wheel: scrolling settings"
        }
    }
}

/// The part of the card chosen on Buttons: a button, whose shape is filled and whose row is
/// marked. It clears on leaving Buttons (`SettingsContext`, `MouseTab.willLeaveButtons`) and when
/// the mouse changes.
@MainActor @Observable
final class CardSelection {
    private(set) var button: NamedButton?
    @ObservationIgnored private var mouse: String?

    func select(_ button: NamedButton?) { self.button = button }

    /// Notes which mouse the card shows; another one clears the selection.
    func follow(mouse key: String?) {
        guard key != mouse else { return }
        mouse = key
        button = nil
    }
}

/// How a Buttons row is marked. A grouped form draws no `listRowBackground` (#133), so the mark is
/// drawn in the row's own content: a fill in the accent colour, and the title in it too.
enum RowMark: Equatable {
    case none
    /// The row of the card's selected button.
    case selected
    /// The row Find by Pressing matched: stronger, for a few seconds.
    case found

    static func of(_ key: String, selected: NamedButton?, found: String?) -> RowMark {
        if found == key { return .found }
        return selected?.rawValue == key ? .selected : .none
    }

    var fillOpacity: Double {
        switch self {
        case .none: 0
        case .selected: 0.14
        case .found: 0.28
        }
    }

    var tintsTitle: Bool { self != .none }
}

extension View {
    /// Marks a Buttons row (see `RowMark`).
    func rowMark(_ mark: RowMark) -> some View { modifier(MarkedRow(mark: mark)) }
}

private struct MarkedRow: ViewModifier {
    let mark: RowMark
    /// How far the fill reaches past the row's content, to the form's edge.
    private static let bleed: CGFloat = 8

    func body(content: Content) -> some View {
        content.overlay {
            if mark != .none {
                Capsule()
                    .fill(.tint.opacity(mark.fillOpacity))
                    .padding(.horizontal, -Self.bleed)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// A part's hit cell as a shape: the polygon, in drawing units, mapped onto the frame that holds its
/// bounds.
private struct PolygonShape: Shape {
    let polygon: DeviceArt.Polygon

    func path(in rect: CGRect) -> Path {
        let bounds = polygon.bounds
        guard bounds.width > 0, bounds.height > 0 else { return Path() }
        let transform = CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)
            .concatenating(CGAffineTransform(scaleX: rect.width / bounds.width, y: rect.height / bounds.height))
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY))
        return Path(polygon.path).applying(transform)
    }
}

/// The mouse at the top of Mouse › Buttons: its drawing, each part a button on it, beside its name
/// and a caption slot (docs/ui-design.md, "Device card"; docs/adr/0013-silhouettes.md). At rest it
/// is the drawing alone. Hovering a part tints its own shape and names it and its action in the
/// caption, whose room is always reserved, so nothing moves. A button selects its row; the thumb
/// wheel opens Scrolling › Thumb Wheel; the main wheel offers a menu of Wheel Click and Scrolling
/// Settings. Nothing here changes a setting.
struct DeviceCard: View {
    let plan: DeviceCardPlan
    let name: String
    let actions: [NamedButton: DeviceCardPlan.ActionText]
    let selected: NamedButton?
    let activate: (CardDestination) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.deviceArtImages) private var images
    @State private var hovered: DeviceArt.Part?

    /// The drawing's size on the card, as a multiple of its 100 x 124 pt page.
    static let scale: CGFloat = 1.5

    private var size: CGSize { CGSize(width: DeviceArt.size.width * Self.scale, height: DeviceArt.size.height * Self.scale) }
    private var fit: CGAffineTransform { CGAffineTransform(scaleX: Self.scale, y: Self.scale) }
    private var geometry: [DeviceArt.Part: DeviceArt.Geometry] { DeviceArt.geometry[plan.family] ?? [:] }

    var body: some View {
        HStack(spacing: 20) {
            art
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.headline)
                Text(plan.caption(hovered: hovered, selected: selected, actions: actions))
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        #if DEBUG
        .onAppear {
            if let part = ProcessInfo.processInfo.environment["PUREMOUSE_DEV_HOVER"].flatMap(DeviceArt.Part.init(rawValue:)) {
                hovered = part
            }
        }
        #endif
    }

    private var art: some View {
        ZStack(alignment: .topLeading) {
            if let image = (images ?? .shared).image(for: plan.family, dark: colorScheme == .dark) {
                Image(nsImage: image)
                    .resizable()
                    .accessibilityHidden(true)
            }
            shape(of: hovered.flatMap { plan.target($0) }, opacity: 0.6)
            shape(of: selected.flatMap { plan.part(for: $0) }.flatMap { plan.target($0) }, opacity: 1)
            ForEach(plan.targets) { target in control(target) }
        }
        .frame(width: size.width, height: size.height)
    }

    /// The part's own outline filled with the accent colour (the system's tint).
    @ViewBuilder
    private func shape(of target: DeviceCardPlan.Target?, opacity: Double) -> some View {
        if let target, let outline = geometry[target.part]?.outline {
            Path(outline.path).applying(fit)
                .fill(.tint.opacity(opacity))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func control(_ target: DeviceCardPlan.Target) -> some View {
        if let cell = geometry[target.part]?.hit {
            let frame = cell.bounds.applying(fit)
            let area = Color.clear
                .frame(width: frame.width, height: frame.height)
                .contentShape(PolygonShape(polygon: cell))
            Group {
                if target.destinations.count > 1 {
                    Menu {
                        ForEach(target.destinations, id: \.self) { destination in
                            Button(destination.menuTitle) { activate(destination) }
                        }
                    } label: { area }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                } else if let destination = target.destinations.first {
                    Button { activate(destination) } label: { area }
                        .buttonStyle(.plain)
                }
            }
            .onHover { inside in
                if inside {
                    hovered = target.part
                } else if hovered == target.part {
                    hovered = nil
                }
            }
            .position(x: frame.midX, y: frame.midY)
            .accessibilityLabel(plan.accessibilityLabel(of: target, actions: actions))
            .accessibilityHint(plan.accessibilityHint(of: target))
            .accessibilityAddTraits(isSelected(target) ? .isSelected : [])
            .modifier(DestinationActions(destinations: target.destinations.count > 1 ? target.destinations : [], activate: activate))
        }
    }

    private func isSelected(_ target: DeviceCardPlan.Target) -> Bool {
        selected.map { target.destinations.contains(.row($0)) } ?? false
    }
}

/// A part with several destinations offers each as a VoiceOver action as well as in its menu.
private struct DestinationActions: ViewModifier {
    let destinations: [CardDestination]
    let activate: (CardDestination) -> Void

    func body(content: Content) -> some View {
        destinations.reduce(AnyView(content)) { view, destination in
            AnyView(view.accessibilityAction(named: destination.menuTitle) { activate(destination) })
        }
    }
}
