import AppKit
import PureMouseAppSupport
import SwiftUI
import Testing
@testable import PureMouseSettingsUI

// The device card on Mouse › Buttons (docs/ui-design.md, "Device card"; docs/adr/0013-silhouettes.md):
// which mice get a drawing, where each part is, what each part opens and how a selection and the
// row it marks are kept.

private let mx3s = "mb03440910000"
private let mx3 = "m4082b0230000"
private let mx4 = "pb042"
private let anywhere3s = "pb037"
private let m750 = "pb02c"

private let allButtons = Set(NamedButton.allCases)

// MARK: Which mice have a drawing

@MainActor @Suite struct DeviceArtModelTests {
    @Test func theKeysOfTheProbedMiceNameTheirModels() {
        #expect(DeviceArt.model(forKey: mx3s)?.family == .mx)
        #expect(DeviceArt.model(forKey: mx3)?.family == .mx)
        #expect(DeviceArt.model(forKey: mx4)?.family == .mx)
        #expect(DeviceArt.model(forKey: anywhere3s)?.family == .compactAnywhere)
        #expect(DeviceArt.model(forKey: m750)?.family == .compactM750)
    }

    @Test func aMouseIsKnownByAnyOfItsProductIDsInAnyOrderAndCase() {
        // Bluetooth, receiver and a zero word, in the orders a read can give them.
        for key in ["mb03440910000", "m4091b0340000", "m0000b0344091", "MB03440910000", "p4091", "pB034"] {
            #expect(DeviceArt.model(forKey: key)?.name == DeviceArt.model(forKey: mx3s)?.name, "\(key)")
        }
        #expect(DeviceArt.model(forKey: mx3s) == DeviceArt.model(forKey: mx3), "the 3 and the 3S share one drawing and binds")
    }

    @Test func theMX4BindsItsThumbRestToTheHapticPanelAndTheOthersToTheGestureButton() {
        #expect(DeviceArt.model(forKey: mx4)?.binds[.thumbRest] == .button(.thumbPanel))
        #expect(DeviceArt.model(forKey: mx3s)?.binds[.thumbRest] == .button(.gesture))
        // The gesture button (0xC3) on the 4 is a row only: nothing on the drawing binds it.
        let four = DeviceArt.model(forKey: mx4)!
        #expect(!four.binds.values.contains(.button(.gesture)))
    }

    @Test func eachFamilyHasOnlyTheButtonsItsMouseHas() {
        let anywhere = DeviceArt.model(forKey: anywhere3s)!
        #expect(Set(anywhere.binds.keys) == [.middle, .top, .forward, .back])
        let signature = DeviceArt.model(forKey: m750)!
        #expect(Set(signature.binds.keys) == [.middle, .forward, .back], "the M750 has no top button; its DPI button is a row only")
        let master = DeviceArt.model(forKey: mx3s)!
        #expect(Set(master.binds.keys) == Set(DeviceArt.Part.allCases))
        #expect(master.binds[.middle] == .mainWheel(click: .middle))
        #expect(master.binds[.thumbWheel] == .thumbWheel)
    }

    @Test func mostMiceGetNoDrawing() {
        // No key; not a key; a key of no ID; the MX Master 2S, MX Vertical, Lift, MX Ergo, a G series
        // mouse and a mouse nobody has listed.
        let keys: [String?] = [nil, "", "x", "pzzzz", "p", "p123", "m", "m000000000000", "p0000", "pb019", "pb020", "pb031",
                               "pb01d", "pc09d", "pffff", "m1234567890ab", "mb03440910000a"]
        for key in keys { #expect(DeviceArt.model(forKey: key) == nil, "\(key ?? "nil")") }
    }

    @Test func productIDsAreReadFromTheKeyOnly() {
        #expect(DeviceArt.productIDs(inKey: "mb03440910000") == [0xB034, 0x4091])
        #expect(DeviceArt.productIDs(inKey: "pb042") == [0xB042])
        #expect(DeviceArt.productIDs(inKey: "MX Master 3S") == nil)
    }

    @Test func everyFamilyHasAPDFInEachAppearance() throws {
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "assets/silhouettes")
        for family in DeviceArt.Family.allCases {
            for dark in [false, true] {
                let file = folder.appending(path: family.file(dark: dark) + ".pdf")
                let image = DeviceArtImages.image(contentsOf: file)
                #expect(image != nil, "\(file.lastPathComponent)")
                #expect(image?.size == DeviceArt.size, "\(file.lastPathComponent) is a 100 x 124 pt page")
            }
        }
    }
}

// MARK: Geometry

@Suite struct DeviceArtGeometryTests {
    private static let page = CGRect(origin: .zero, size: DeviceArt.size)

    private func parts(of family: DeviceArt.Family) -> Set<DeviceArt.Part> {
        Set(DeviceArt.models.filter { $0.family == family }.flatMap { $0.binds.keys })
    }

    @Test func everyBoundPartHasAShapeAndNoOtherDoes() {
        for family in DeviceArt.Family.allCases {
            #expect(Set(DeviceArt.geometry[family]?.keys.map { $0 } ?? []) == parts(of: family), "\(family)")
        }
    }

    @Test func everyTargetIsAtLeast20By20PointsAndOnThePage() {
        for family in DeviceArt.Family.allCases {
            for (part, geometry) in DeviceArt.geometry[family] ?? [:] {
                let bounds = geometry.hit.bounds
                #expect(bounds.width >= 20 && bounds.height >= 20, "\(family) \(part) \(bounds)")
                #expect(Self.page.insetBy(dx: -0.01, dy: -0.01).contains(bounds), "\(family) \(part)")
            }
        }
    }

    @Test func eachOutlineLiesInsideItsOwnTarget() {
        for family in DeviceArt.Family.allCases {
            for (part, geometry) in DeviceArt.geometry[family] ?? [:] {
                #expect(geometry.hit.bounds.insetBy(dx: -0.01, dy: -0.01).contains(geometry.outline.bounds), "\(family) \(part)")
                // The outline's centre is in the cell, so the part is where its shape is.
                let box = geometry.outline.bounds
                #expect(geometry.hit.contains(CGPoint(x: box.midX, y: box.midY)), "\(family) \(part)")
            }
        }
    }

    @Test func targetsOfOneDrawingDoNotOverlap() {
        for family in DeviceArt.Family.allCases {
            let cells = DeviceArt.geometry[family] ?? [:]
            var point = CGPoint.zero
            for y in stride(from: 0.25, to: DeviceArt.size.height, by: 0.5) {
                for x in stride(from: 0.25, to: DeviceArt.size.width, by: 0.5) {
                    point = CGPoint(x: x, y: y)
                    let inside = cells.filter { $0.value.hit.contains(point) }.map(\.key)
                    #expect(inside.count <= 1, "\(family) \(point) is in \(inside)")
                    if inside.count > 1 { return }
                }
            }
        }
    }

    @Test func aPointFindsOnlyAnActivePart() {
        let centre = { (part: DeviceArt.Part) -> CGPoint in
            let box = DeviceArt.geometry[.mx]![part]!.hit.bounds
            return CGPoint(x: box.midX, y: box.midY)
        }
        for part in DeviceArt.Part.allCases {
            #expect(DeviceArt.part(at: centre(part), in: .mx, among: [part]) == part)
            #expect(DeviceArt.part(at: centre(part), in: .mx, among: Set(DeviceArt.Part.allCases).subtracting([part])) == nil)
        }
        #expect(DeviceArt.part(at: CGPoint(x: -5, y: -5), in: .mx, among: Set(DeviceArt.Part.allCases)) == nil)
    }
}

// MARK: Plan and routing

@Suite struct DeviceCardPlanTests {
    private func plan(_ key: String, listed: Set<NamedButton> = allButtons.subtracting([.thumbPanel]),
                      mainWheel: Bool = true, thumbWheel: Bool = true) -> DeviceCardPlan {
        DeviceCardPlan(model: DeviceArt.model(forKey: key)!, listed: listed, mainWheelSettings: mainWheel, thumbWheelSettings: thumbWheel)
    }

    @Test func eachPartOpensItsRowOrItsScrollingSettings() {
        let plan = plan(mx3s)
        #expect(plan.target(.back)?.destinations == [.row(.back)])
        #expect(plan.target(.forward)?.destinations == [.row(.forward)])
        #expect(plan.target(.top)?.destinations == [.row(.top)])
        #expect(plan.target(.thumbRest)?.destinations == [.row(.gesture)])
        #expect(plan.target(.thumbWheel)?.destinations == [.scrolling(.thumbWheel)])
    }

    @Test func theMainWheelOffersWheelClickAndScrollingSettings() {
        let wheel = plan(mx3s).target(.middle)
        #expect(wheel?.destinations == [.row(.middle), .scrolling(.mainWheel)])
        #expect(wheel?.destinations.map(\.menuTitle) == ["Wheel Click", "Scrolling Settings"])
    }

    @Test func aWheelWithOneWayInGoesThereDirectly() {
        #expect(plan(mx3s, mainWheel: false).target(.middle)?.destinations == [.row(.middle)])
        #expect(plan(mx3s, listed: [.back]).target(.middle)?.destinations == [.scrolling(.mainWheel)])
    }

    @Test func thePartsAMouseLacksHaveNoTarget() {
        // The thumb wheel is gone from Scrolling; the haptic panel row is not listed (no report, not bound).
        let plan = plan(mx4, thumbWheel: false)
        #expect(plan.target(.thumbWheel) == nil)
        #expect(plan.target(.thumbRest) == nil)
        #expect(Set(plan.targets.map(\.part)) == [.middle, .top, .forward, .back])
        // Listed, the MX 4's thumb rest is the haptic panel.
        let listed = self.plan(mx4, listed: allButtons)
        #expect(listed.target(.thumbRest)?.destinations == [.row(.thumbPanel)])
    }

    @Test func aRowThatIsNotListedLeavesItsPartInert() {
        let plan = plan(m750, listed: [.middle, .back])
        #expect(plan.target(.forward) == nil)
        #expect(plan.target(.back)?.destinations == [.row(.back)])
    }

    @Test func theCompactMiceHaveNoThumbPartsWhateverScrollingShows() {
        for key in [anywhere3s, m750] {
            let plan = plan(key)
            #expect(plan.target(.thumbWheel) == nil, Comment(rawValue: key))
            #expect(plan.target(.thumbRest) == nil, Comment(rawValue: key))
        }
        #expect(plan(anywhere3s).target(.top)?.destinations == [.row(.top)])
        #expect(plan(m750).target(.top) == nil)
    }

    @Test func aPointOnADrawnPartFindsItsTargetInDrawingUnits() {
        let plan = plan(mx3s)
        for target in plan.targets {
            let box = DeviceArt.geometry[.mx]![target.part]!.hit.bounds
            #expect(plan.part(at: CGPoint(x: box.midX, y: box.midY)) == target.part)
        }
        #expect(plan.part(at: CGPoint(x: 1, y: 1)) == nil)
    }

    @Test func aSelectedRowFindsItsPart() {
        let plan = plan(mx3s)
        #expect(plan.part(for: .middle) == .middle)
        #expect(plan.part(for: .gesture) == .thumbRest)
        #expect(plan.part(for: .thumbPanel) == nil)
        #expect(self.plan(mx4, listed: allButtons).part(for: .thumbPanel) == .thumbRest)
    }

    // MARK: Which mouse

    @Test func theCardIsForTheChosenMouseOrALoneOne() {
        let a = KnownMouse(key: mx3s, name: "MX Master 3S", reported: true)
        let b = KnownMouse(key: m750, name: "Signature M750", reported: true)
        #expect(DeviceCardPlan.mouse(selected: a, known: [a, b], offersChoice: true) == a)
        #expect(DeviceCardPlan.mouse(selected: nil, known: [a, b], offersChoice: true) == nil, "All Mice has no card")
        #expect(DeviceCardPlan.mouse(selected: nil, known: [a], offersChoice: false) == a, "one mouse, no pop-up")
        #expect(DeviceCardPlan.mouse(selected: nil, known: [a], offersChoice: true) == nil, "All Mice, chosen on purpose")
        #expect(DeviceCardPlan.mouse(selected: nil, known: [], offersChoice: false) == nil)
    }

    // MARK: Words

    private let actions: [NamedButton: DeviceCardPlan.ActionText] = [
        .back: .init(shown: "Back", spoken: "Back"), .middle: .init(shown: "Mouse Default", spoken: "Mouse Default"),
        .gesture: .init(shown: "Gesture", spoken: "Gesture"),
    ]

    @Test func eachPartIsOneButtonWithItsOwnName() {
        let plan = plan(mx3s)
        let names = plan.targets.map { plan.name(of: $0) }
        #expect(names == ["Main wheel", "Top button", "Forward button", "Back button", "Thumb wheel", "Gesture button"])
        #expect(Set(names).count == names.count)
        #expect(plan.accessibilityLabel(of: plan.target(.back)!, actions: actions) == "Back button, set to Back")
        #expect(plan.accessibilityLabel(of: plan.target(.thumbWheel)!, actions: actions) == "Thumb wheel")
        #expect(plan.accessibilityLabel(of: plan.target(.middle)!, actions: actions) == "Main wheel")
    }

    @Test func theCaptionNamesThePartAndItsAction() {
        let plan = plan(mx3s)
        func caption(_ hovered: DeviceArt.Part?, _ selected: NamedButton? = nil) -> String {
            plan.caption(hovered: hovered, selected: selected, actions: actions)
        }
        #expect(caption(.back) == "Back button: Back")
        #expect(caption(.thumbWheel) == "Thumb wheel: scrolling settings")
        #expect(caption(.middle) == "Main wheel: wheel click or scrolling settings")
        #expect(caption(nil) == DeviceCardPlan.hint)
        #expect(caption(nil, .gesture) == "Gesture button: Gesture", "no hover: the selected part")
        #expect(caption(.back, .gesture) == "Back button: Back", "the part under the pointer wins")
    }
}

// MARK: Selection and the row it marks

@Suite struct RowMarkTests {
    @Test func theFoundRowShowsMoreThanTheSelectedOne() {
        #expect(RowMark.of("back", selected: nil, found: nil) == .none)
        #expect(RowMark.of("back", selected: .back, found: nil) == .selected)
        #expect(RowMark.of("back", selected: nil, found: "back") == .found)
        #expect(RowMark.of("back", selected: .back, found: "back") == .found)
        #expect(RowMark.of("forward", selected: .back, found: "back") == .none)
        #expect(RowMark.of("0x00fd", selected: .back, found: "0x00fd") == .found, "a row without a name is found too")
    }

    @Test func aMarkedRowIsDrawnInTheAccentColourNotJustFilled() {
        #expect(RowMark.none.fillOpacity == 0)
        #expect(RowMark.selected.fillOpacity > 0)
        #expect(RowMark.found.fillOpacity > RowMark.selected.fillOpacity)
        #expect(RowMark.none.tintsTitle == false)
        #expect(RowMark.selected.tintsTitle && RowMark.found.tintsTitle)
    }

    @Test func buttonsPaneDoesNotRelyOnARowBackground() throws {
        // A grouped form on macOS draws no `listRowBackground` (#133), so a row is marked in its content.
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/PureMouseSettingsUI/ButtonsPane.swift"), encoding: .utf8)
        #expect(!source.contains("listRowBackground"))
        #expect(source.contains(".rowMark("))
    }
}

@MainActor @Suite struct CardSelectionTests {
    @Test func selectingAButtonKeepsItUntilCleared() {
        let card = CardSelection()
        #expect(card.button == nil)
        card.select(.back)
        #expect(card.button == .back)
        card.select(.forward)
        #expect(card.button == .forward)
        card.select(nil)
        #expect(card.button == nil)
    }

    @Test func changingTheMouseClearsTheSelectionButSeeingItAgainDoesNot() {
        let card = CardSelection()
        card.follow(mouse: mx3s)
        card.select(.back)
        card.follow(mouse: mx3s)
        #expect(card.button == .back)
        card.follow(mouse: m750)
        #expect(card.button == nil)
        card.select(.back)
        card.follow(mouse: nil)
        #expect(card.button == nil, "All Mice")
    }
}

// MARK: Going to Scrolling

@MainActor @Suite struct CardNavigationTests {
    private func mouseTab() -> MouseTab {
        MouseTab(segment: .buttons, header: { _ in NSView() }, make: { _ in
            let pane = NSViewController()
            pane.view = NSView()
            return pane
        })
    }

    /// The context holds its tabs weakly, so the tabs are kept here for the test's length.
    private let tabs = SettingsTabs()

    private func context(_ tab: MouseTab) -> (SettingsContext, SettingsTabs) {
        tabs.mouse = tab
        let context = SettingsContext()
        context.tabs = tabs
        return (context, tabs)
    }

    @Test func theThumbWheelGoesThroughTheStripsPath() {
        let tab = mouseTab()
        var ended = 0, told: [MouseSegment] = []
        tab.willLeaveButtons = { ended += 1 }
        tab.didSelect = { told.append($0) }
        _ = tab.view
        let (context, _) = context(tab)
        context.card.select(.back)

        context.activate(.scrolling(.thumbWheel))

        #expect(tab.selection.segment == .scrolling)
        #expect(ended == 1, "Find by Pressing ends")
        #expect(told == [.scrolling], "the window refits once")
        #expect(context.arrival == .thumbWheel)
    }

    @Test func theMainWheelsScrollingSettingsArriveAtMainWheel() {
        let tab = mouseTab()
        _ = tab.view
        let (context, _) = context(tab)
        context.activate(.scrolling(.mainWheel))
        #expect(tab.selection.segment == .scrolling)
        #expect(context.arrival == .mainWheel)
    }

    @Test func aRowDestinationSelectsItOnTheSamePage() {
        let tab = mouseTab()
        var told = 0
        tab.didSelect = { _ in told += 1 }
        _ = tab.view
        let (context, _) = context(tab)
        context.activate(.row(.forward))
        #expect(context.card.button == .forward)
        #expect(tab.selection.segment == .buttons)
        #expect(context.arrival == nil)
        #expect(told == 0)
    }

    @Test func leavingButtonsFromTheStripClearsTheSelection() {
        let tab = mouseTab()
        _ = tab.view
        let (context, _) = context(tab)
        tab.willLeaveButtons = { [weak context] in context?.card.select(nil) }
        context.card.select(.top)
        tab.selection.select(.pointer)
        #expect(context.card.button == nil)
    }

    @Test func activatingARegionWritesNoSettings() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "pm-card-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let config = folder.appending(path: "config.json")
        let text = #"{"buttons":{"back":"forward"}}"#
        try Data(text.utf8).write(to: config)
        let locations = Locations(config: config, log: folder.appending(path: "log"), daemon: nil, companion: folder)
        let model = AppModel(locations: locations, defaults: UserDefaults(suiteName: "pm-\(UUID().uuidString)")!, alert: { _, _ in })
        let before = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()

        let tab = mouseTab()
        _ = tab.view
        let (context, _) = context(tab)
        for destination in [CardDestination.row(.back), .row(.middle), .scrolling(.mainWheel), .scrolling(.thumbWheel)] {
            context.activate(destination)
        }
        model.flush()

        #expect(try String(contentsOf: config, encoding: .utf8) == text)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == before, "no lock, backup or temp file appears")
    }
}

// MARK: Loading the art

@MainActor @Suite struct DeviceArtImagesTests {
    @Test func nothingLoadsUntilAFormIsAsked() {
        var loads: [String] = []
        let images = DeviceArtImages(load: { family, dark in
            loads.append(family.file(dark: dark))
            return NSImage(size: DeviceArt.size)
        })
        #expect(loads.isEmpty)
        _ = images.image(for: .mx, dark: false)
        _ = images.image(for: .mx, dark: false)
        _ = images.image(for: .mx, dark: true)
        #expect(loads == ["mx-light", "mx-dark"], "once per drawing and appearance")
    }

    @Test func aMissingFileIsAskedOnceAndDrawsNothing() {
        var asked = 0
        let images = DeviceArtImages(load: { _, _ in asked += 1; return nil })
        #expect(images.image(for: .compactM750, dark: false) == nil)
        #expect(images.image(for: .compactM750, dark: false) == nil)
        #expect(asked == 1)
    }

    @Test func theCardLoadsItsDrawingOnceAndOnlyWhenItIsBuilt() {
        var loads = 0
        let images = DeviceArtImages(load: { _, _ in loads += 1; return NSImage(size: DeviceArt.size) })
        let plan = DeviceCardPlan(model: DeviceArt.model(forKey: mx3s)!, listed: allButtons, mainWheelSettings: true, thumbWheelSettings: true)
        #expect(loads == 0, "a plan is data")
        let card = DeviceCard(plan: plan, name: "MX Master 3S", actions: [:], selected: nil, activate: { _ in })
            .environment(\.deviceArtImages, images)
        let host = NSHostingView(rootView: card)
        _ = host.fittingSize
        #expect(loads == 1)
    }
}
