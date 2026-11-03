import AppKit
import PureMouseAppSupport
import SwiftUI
import Testing
@testable import PureMouseSettingsUI

// The device card on Mouse › Buttons (docs/ui-design.md, "Device card"; docs/adr/0013-silhouettes.md):
// which mice get a drawing, where each part is, what each part opens and how a selection and the
// row it marks are kept.

private let mx3s = "mb03400000000"  // the development mouse's own key
private let mx3sReceiver = "mb03440910000"
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
        #expect(DeviceArt.model(forKey: mx4)?.family == .mx4)
        #expect(DeviceArt.model(forKey: anywhere3s)?.family == .compactAnywhere)
        #expect(DeviceArt.model(forKey: m750)?.family == .compactM750)
    }

    @Test func aMouseIsKnownByAnyOfItsProductIDsInAnyOrderAndCase() {
        // Bluetooth, receiver and a zero word, in the orders a read can give them.
        for key in ["mb03400000000", "mb03440910000", "m4091b0340000", "m0000b0344091", "MB03440910000", "p4091", "pB034"] {
            #expect(DeviceArt.model(forKey: key)?.name == DeviceArt.model(forKey: mx3s)?.name, "\(key)")
        }
        #expect(DeviceArt.model(forKey: mx3s) == DeviceArt.model(forKey: mx3), "the 3 and the 3S share one drawing and binds")
        #expect(DeviceArt.model(forKey: mx4)?.family != DeviceArt.model(forKey: mx3s)?.family, "the 4 has its own drawing")
    }

    @Test func theMX4BindsItsThumbRestToTheHapticPanelAndItsOwnGestureKey() {
        let four = DeviceArt.model(forKey: mx4)!
        #expect(four.binds[.thumbRest] == .button(.thumbPanel))
        #expect(four.binds[.gesture] == .button(.gesture), "0x00C3 is the small key ahead of Forward and Back")
        // The 3 and 3S have the gesture button on the thumb rest and no key of its own.
        let three = DeviceArt.model(forKey: mx3s)!
        #expect(three.binds[.thumbRest] == .button(.gesture))
        #expect(three.binds[.gesture] == nil)
        #expect(four.binds.values.filter { $0 == .button(.gesture) }.count == 1)
    }

    @Test func theGestureButtonIsANamedRowInTheOrderOfThe3S() {
        // The MX Master 4's reported controls (Tests/Fixtures/probe/mx-master-4.txt).
        let reported: Set<UInt16> = [0x50, 0x51, 0x52, 0x53, 0x56, 0xC3, 0xC4, 0x1A0, 0xD7]
        let rows = ButtonRows.named(deviceCIDs: reported, configKeys: [])
        #expect(rows == [.back, .forward, .middle, .top, .gesture, .thumbPanel])
        #expect(ButtonRows.others(deviceCIDs: [0xC3, 0x1A0], configKeys: []).isEmpty, "0xC3 is no Other control")
    }

    @Test func eachFamilyHasOnlyTheButtonsItsMouseHas() {
        let anywhere = DeviceArt.model(forKey: anywhere3s)!
        #expect(Set(anywhere.binds.keys) == [.middle, .top, .forward, .back])
        let signature = DeviceArt.model(forKey: m750)!
        #expect(Set(signature.binds.keys) == [.middle, .forward, .back], "the M750 has no top button; its DPI button is a row only")
        let master = DeviceArt.model(forKey: mx3s)!
        #expect(Set(master.binds.keys) == Set(DeviceArt.Part.allCases).subtracting([.gesture]))
        #expect(Set(DeviceArt.model(forKey: mx4)!.binds.keys) == Set(DeviceArt.Part.allCases))
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

    @Test func aTrackballAVerticalAndAnUnknownMouseGetNoCardAndKeepTheirRows() {
        // #56: no card is shown for them, and their controls stay in the list.
        let ergo = "p406f", vertical = "pb020", lift = "pb031", g305 = "p4074", unknown = "m999900000000"
        for key in [ergo, vertical, lift, g305, unknown] {
            #expect(DeviceArt.model(forKey: key) == nil, Comment(rawValue: key))
            let mouse = KnownMouse(key: key, name: "Any", reported: true)
            #expect(DeviceCardPlan.mouse(selected: mouse, known: [mouse]) == mouse, "the mouse is still the one chosen")
        }
        // Whatever the card does, the list is the mouse's own controls.
        let reported: Set<UInt16> = [0x52, 0x53, 0x56, 0xC3]
        #expect(ButtonRows.named(deviceCIDs: reported, configKeys: []) == [.back, .forward, .middle, .gesture])
    }

    @Test func productIDsAreReadFromTheKeyOnly() {
        #expect(DeviceArt.productIDs(inKey: mx3sReceiver) == [0xB034, 0x4091])
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

    @Test func everyTargetIsAtLeast20By20PointsAsDrawnAndOnThePage() {
        // The card draws the art at DeviceCard.scale, and a target is at least 20 x 20 pt there (ADR 13).
        for family in DeviceArt.Family.allCases {
            for (part, geometry) in DeviceArt.geometry[family] ?? [:] {
                let bounds = geometry.hit.bounds
                #expect(bounds.width * DeviceCard.scale >= 20 && bounds.height * DeviceCard.scale >= 20, "\(family) \(part) \(bounds)")
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
        for part in DeviceArt.Part.allCases where DeviceArt.geometry[.mx]![part] != nil {
            #expect(DeviceArt.part(at: centre(part), in: .mx, among: [part]) == part)
            #expect(DeviceArt.part(at: centre(part), in: .mx, among: Set(DeviceArt.Part.allCases).subtracting([part])) == nil)
        }
        // On the MX Master 4 the gesture key is found where it is drawn, not as Forward or Back.
        let key = DeviceArt.geometry[.mx4]![.gesture]!.outline.bounds
        #expect(DeviceArt.part(at: CGPoint(x: key.midX, y: key.midY), in: .mx4, among: Set(DeviceArt.Part.allCases)) == .gesture)
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
        #expect(Set(plan.targets.map(\.part)) == [.middle, .top, .forward, .back, .gesture])
        #expect(plan.target(.gesture)?.destinations == [.row(.gesture)])
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
        #expect(self.plan(mx4, listed: allButtons).part(for: .gesture) == .gesture)
    }

    // MARK: Which mouse

    @Test func theCardIsForTheChosenMouseOrForAllMiceOfOneModel() {
        let a = KnownMouse(key: mx3s, name: "MX Master 3S", reported: true)
        let a2 = KnownMouse(key: "pb034", name: "MX Master 3S", reported: false)
        let b = KnownMouse(key: m750, name: "Signature M750", reported: true)
        let unknown = KnownMouse(key: "m999900000000", name: "Mystery", reported: true)
        #expect(DeviceCardPlan.mouse(selected: a, known: [a, b]) == a, "a chosen mouse shows its own card")
        #expect(DeviceCardPlan.mouse(selected: nil, known: [a, b]) == nil, "All Mice with two models has no card")
        #expect(DeviceCardPlan.mouse(selected: nil, known: [a, unknown]) == nil, "a known and an unknown mouse have no card")
        #expect(DeviceCardPlan.mouse(selected: nil, known: [unknown]) == nil, "an unknown mouse alone has no card")
        #expect(DeviceCardPlan.mouse(selected: nil, known: [a]) == a, "All Mice with one mouse shows it")
        #expect(DeviceCardPlan.mouse(selected: nil, known: [a, a2]) == a, "two mice of one model show the card")
        #expect(DeviceCardPlan.mouse(selected: nil, known: []) == nil)
    }

    @Test func anUnidentifiedSecondMouseDoesNotShowOneModelsCardUnderAllMice() {
        let a = KnownMouse(key: mx3s, name: "MX Master 3S", reported: true)
        #expect(DeviceCardPlan.mouse(selected: nil, known: [a], unidentified: false) == a)
        #expect(DeviceCardPlan.mouse(selected: nil, known: [a], unidentified: true) == nil,
                "one identified mouse and another with no model are not one drawing")
        #expect(DeviceCardPlan.mouse(selected: a, known: [a], unidentified: true) == a, "a chosen mouse still shows its own card")
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

    @Test func theCaptionIsASentenceAboutThePartAndItsAction() {
        let plan = plan(mx3s)
        func caption(_ hovered: DeviceArt.Part?, _ selected: NamedButton? = nil) -> String {
            plan.caption(hovered: hovered, selected: selected, actions: actions)
        }
        #expect(caption(.back) == "The Back button is set to Back.")
        #expect(caption(.thumbWheel) == "Click to open the thumb wheel's scrolling settings.")
        #expect(caption(.middle) == "Choose the wheel click or the main wheel's scrolling settings.")
        #expect(caption(nil) == DeviceCardPlan.hint)
        #expect(caption(nil, .gesture) == "The gesture button is set to Gesture.", "no hover: the selected part")
        #expect(caption(.back, .gesture) == "The Back button is set to Back.", "the part under the pointer wins")
        let wheelOnly = DeviceCardPlan(model: DeviceArt.model(forKey: mx3s)!, listed: allButtons,
                                       mainWheelSettings: false, thumbWheelSettings: true)
        #expect(wheelOnly.caption(hovered: .middle, selected: nil, actions: actions) == "The wheel click is set to Mouse Default.")
    }

    @Test func theThumbRestIsAPanelNotAButtonAndOnlyBackAndForwardKeepTheirCapitals() {
        let plan = plan(mx4, listed: allButtons)
        let thumb = plan.caption(hovered: .thumbRest, selected: nil, actions: [:])
        #expect(thumb == "The thumb panel is set to Thumb panel.", "no action known: its label")
        let shown: [NamedButton: DeviceCardPlan.ActionText] = [.thumbPanel: .init(shown: "Mouse Default", spoken: "Mouse Default")]
        #expect(plan.caption(hovered: .thumbRest, selected: nil, actions: shown) == "The thumb panel is set to Mouse Default.")
        #expect(DeviceCardPlan.sentenceName(.back) == "Back button" && DeviceCardPlan.sentenceName(.forward) == "Forward button")
        #expect(DeviceCardPlan.sentenceName(.gesture) == "gesture button" && DeviceCardPlan.sentenceName(.top) == "top button")
        #expect(DeviceCardPlan.buttonName(.thumbPanel) == "Thumb panel", "VoiceOver says the part, not a button")
    }

    @Test func everyCaptionIsAFullSentenceThatFitsTwoLines() {
        for key in [mx3s, mx4, anywhere3s, m750] {
            let plan = plan(key, listed: allButtons)
            var captions = [DeviceCardPlan.hint]
            for target in plan.targets {
                captions.append(plan.caption(hovered: target.part, selected: nil, actions: [:]))
            }
            for caption in captions {
                #expect(caption.first?.isUppercase == true, Comment(rawValue: caption))
                #expect(caption.hasSuffix("."), Comment(rawValue: caption))
                #expect(caption.count <= 64, Comment(rawValue: caption))
            }
        }
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

    @Test func aMarkedRowIsATintedBandAndOnlyTheFoundOneIsOutlined() {
        #expect(RowMark.none.fillOpacity == 0)
        #expect(RowMark.selected.fillOpacity == 0.18)
        #expect(RowMark.found.fillOpacity == 0.30)
        #expect(RowMark.none.outlined == false && RowMark.selected.outlined == false)
        #expect(RowMark.found.outlined)
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

    @Test func aPressFoundOnTheMouseLightsItsPartAndAControlWithNoPartClearsIt() {
        let card = CardSelection()
        card.found("forward")
        #expect(card.button == .forward, "the part's drawing takes the state a click gives it")
        card.found("0x00c5")
        #expect(card.button == nil, "a control the drawing has no part for")
        card.found("thumbPanel")
        #expect(card.button == .thumbPanel)
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

    @Test func choosingThePartAgainIsANewRequestToScroll() {
        let tab = mouseTab()
        _ = tab.view
        let (context, _) = context(tab)
        #expect(context.rowRequest == nil)
        context.activate(.row(.forward))
        let first = context.rowRequest
        #expect(first?.button == .forward)
        // The highlight stays as it was, but the request is a new one, which a pane scrolls for.
        context.activate(.row(.forward))
        #expect(context.card.button == .forward)
        #expect(context.rowRequest?.button == .forward)
        #expect(context.rowRequest != first)
        // A scroll to Scrolling is no row request.
        let before = context.rowRequest
        context.activate(.scrolling(.mainWheel))
        #expect(context.rowRequest == before)
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

// MARK: The arrival outline

@Suite struct ArrivalOutlineTests {
    @Test func anOutlineEndsWithItsOwnTimeout() {
        var outline = ArrivalOutlineState()
        let first = outline.begin(.thumbWheel)
        #expect(outline.section == .thumbWheel)
        outline.expire(first)
        #expect(outline.section == nil)
    }

    @Test func anEarlierTimeoutDoesNotClearALaterArrival() {
        var outline = ArrivalOutlineState()
        let first = outline.begin(.thumbWheel)
        let second = outline.begin(.mainWheel)
        outline.expire(first)
        #expect(outline.section == .mainWheel, "the first arrival's timeout fires during the second's outline")
        outline.expire(second)
        #expect(outline.section == nil)
    }

    @Test func theSameSectionArrivedAtAgainKeepsItsOutlineForAFullTime() {
        var outline = ArrivalOutlineState()
        let first = outline.begin(.mainWheel)
        let second = outline.begin(.mainWheel)
        outline.expire(first)
        #expect(outline.section == .mainWheel)
        outline.expire(second)
        #expect(outline.section == nil)
    }
}
