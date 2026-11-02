import Foundation
import PureMouseKit
import Testing
@testable import PureMouseAppSupport

// The Mouse pop-up and what the panes read and write for the mouse it chooses (#54): which mice are
// known, when the pop-up shows, which controls a scope shows, where a value lands, and which mouse
// "use configured DPI" and Find by Pressing address.

private let mx = "mb03400000000"
private let m750Key = "pb02c"
private let m750Identified = "mb02c00000000"

private func tree(_ json: String) throws -> ConfigTree { try ConfigTree(data: Data(json.utf8)) }
private func scope(_ key: String) -> ConfigScope { ConfigScope.device(key)! }

private let allCaps = Status.Device.Capabilities(dpi: true, smartShift: true, smoothScroll: true, thumbWheel: true)
private let m750Caps = Status.Device.Capabilities(dpi: true, smartShift: false, smoothScroll: true, thumbWheel: false)

private func mouse(_ name: String, key: String?, caps: Status.Device.Capabilities? = nil, online: Bool = true,
                   controls: [UInt16] = [], dpi: Int? = 1600) -> Status.Device {
    Status.Device(id: "id-\(name)", name: name, connection: .receiver, online: online, battery: nil, dpi: dpi,
                  dpiSteps: [400, 800, 1000, 1600, 3200], wheelMode: nil,
                  controls: controls.map { Status.Device.Control(cid: $0, name: nil) }, model: key, capabilities: caps)
}

private let mxMaster = mouse("MX Master 3S", key: mx, caps: allCaps)
private let m750 = mouse("Signature Plus M750", key: m750Key, caps: m750Caps, controls: [0x52, 0x53, 0x56, 0xFD], dpi: 1000)

/// A model on a sandbox holding `config`, with the daemon reporting `devices`.
@MainActor
private func makeModel(config: String = "{}", devices: [Status.Device], defaults: UserDefaults? = nil,
                   sandbox: Sandbox? = nil) throws -> (AppModel, Sandbox) {
    let sandbox = try sandbox ?? Sandbox()
    try sandbox.write(config)
    try sandbox.writeStatus(daemonStatus(pid: getpid(), devices: devices))
    let suite = defaults ?? UserDefaults(suiteName: "pm-\(UUID().uuidString)")!
    let model = AppModel(locations: sandbox.locations, defaults: suite, alert: { _, _ in })
    model.reloadStatus()
    return (model, sandbox)
}

// MARK: Which mice, and the pop-up

@MainActor @Test func twoKnownMiceShowThePopUpWithBothNames() throws {
    let (model, _) = try makeModel(devices: [mxMaster, m750])
    #expect(model.showsMouseMenu)
    #expect(model.knownMice.map(\.name) == ["MX Master 3S", "Signature Plus M750"])
    #expect(model.knownMice.map(\.key) == [mx, m750Key])
    #expect(model.knownMice.allSatisfy { $0.reported })
}

@MainActor @Test func oneMouseAndNoDevicesEntryShowsNoPopUp() throws {
    let (model, _) = try makeModel(devices: [mxMaster])
    #expect(!model.showsMouseMenu)
    #expect(model.knownMice.count == 1)
    // Even a remembered choice is ignored: the panes edit the top level, as they always did.
    model.selectMouse(mx)
    #expect(model.selectedMouse == nil && model.scope == .global)
}

@MainActor @Test func aStrayDevicesEntryShowsThePopUpEvenForOneMouse() throws {
    let (model, _) = try makeModel(config: #"{"devices": {"\#(m750Identified)": {"name": "Signature Plus M750", "dpi": 800}}}"#,
                               devices: [mxMaster])
    #expect(model.showsMouseMenu)
    #expect(model.knownMice.map(\.name) == ["MX Master 3S", "Signature Plus M750"])
    #expect(model.knownMice.map(\.reported) == [true, false])
    // A lone mouse that has an entry gets the pop-up on purpose.
    let (lone, _) = try makeModel(config: #"{"devices": {"\#(mx)": {"dpi": 800}}}"#, devices: [mxMaster])
    #expect(lone.showsMouseMenu && lone.knownMice.count == 1)
}

@Test func aMouseOnlyTheConfigNamesIsNamedFromItsEntryElseUnknown() throws {
    let config = try tree(#"{"devices": {"p046d": {"dpi": 1000}, "\#(m750Identified)": {"name": "Old Mouse", "dpi": 800}}}"#)
    let known = MouseScope.known(devices: [], config: config)
    #expect(known.map(\.key) == [m750Identified, "p046d"])
    #expect(known.map(\.name) == ["Old Mouse", "Unknown mouse p046d"])
    #expect(MouseScope.unknownName("p046d") == "Unknown mouse p046d")
    // A reported mouse is named by what it reports, once, and a mouse without a key cannot be chosen.
    let both = MouseScope.known(devices: [mouse("MX", key: mx), mouse("MX again", key: mx), mouse("No key", key: nil)],
                                config: try tree(#"{"devices": {"\#(mx)": {"name": "Stored name"}}}"#))
    #expect(both.map(\.name) == ["MX"])
}

@MainActor @Test func theChoiceIsRememberedPerUserAndDefaultsToAllMice() throws {
    let defaults = UserDefaults(suiteName: "pm-\(UUID().uuidString)")!
    let (first, sandbox) = try makeModel(devices: [mxMaster, m750], defaults: defaults)
    #expect(first.selectedMouse == nil && first.scope == .global)
    first.selectMouse(m750Key)
    #expect(first.scope == scope(m750Key))
    #expect(first.scopeTarget == ScopeTarget(scope: scope(m750Key), name: "Signature Plus M750"))
    // A new window of the same user opens on it.
    let (second, _) = try makeModel(devices: [mxMaster, m750], defaults: defaults, sandbox: sandbox)
    #expect(second.selectedMouse?.key == m750Key)
    // A mouse the list no longer has, or a word that is no key, is All Mice.
    second.selectMouse("p0000")
    #expect(second.scope == .global)
    second.selectMouse(m750Key)
    second.selectMouse("all")
    #expect(second.scope == .global && second.rememberedMouse == nil)
    second.selectMouse(m750Key.uppercased())
    #expect(second.rememberedMouse == m750Key)
}

// MARK: What shows

@Test func anOmittedCapabilityKeyShowsItsRowsAndFalseHidesThem() {
    let omitted = mouse("New", key: mx, caps: Status.Device.Capabilities(dpi: true))
    let layout = ScrollingLayout(config: ConfigTree(), devices: [omitted])
    #expect(layout.shows(.smartShift) && layout.shows(.thumbWheelAction) && layout.shows(.smoothScrolling))
    let denied = mouse("Old", key: mx, caps: Status.Device.Capabilities(dpi: true, smartShift: false, smoothScroll: false, thumbWheel: false))
    let hidden = ScrollingLayout(config: ConfigTree(), devices: [denied])
    #expect(!hidden.shows(.smartShift) && !hidden.shows(.thumbWheelAction) && !hidden.shows(.smoothScrolling))
    #expect(hidden.availability(.smartShift) == .hidden)
}

@MainActor @Test func allMiceShowsASectionWhenAnyKnownOrUnknownMouseHasTheFeature() throws {
    // The M750 has no SmartShift or thumb wheel; the MX has both: All Mice shows them.
    let (both, _) = try makeModel(devices: [mxMaster, m750])
    let all = ScrollingLayout(config: both.config, devices: both.capabilityDevices(in: .global))
    #expect(all.shows(.smartShift) && all.showsThumbWheel)
    // Only the M750 is connected: they hide, as for one mouse.
    let (only, _) = try makeModel(devices: [m750])
    #expect(!ScrollingLayout(config: only.config, devices: only.capabilityDevices(in: .global)).shows(.smartShift))
    // A mouse the daemon lists but that is asleep may have the feature: nothing is hidden.
    let asleep = mouse("MX asleep", key: mx, caps: allCaps, online: false)
    let (sleeping, _) = try makeModel(devices: [m750, asleep])
    #expect(sleeping.capabilityDevices(in: .global).isEmpty)
    #expect(ScrollingLayout(config: sleeping.config, devices: sleeping.capabilityDevices(in: .global)).shows(.smartShift))
    // A mouse only the config names might have it too.
    let (named, _) = try makeModel(config: #"{"devices": {"\#(mx)": {"dpi": 800}}}"#, devices: [m750])
    #expect(named.capabilityDevices(in: .global).isEmpty)
    // A mouse that reports nothing about a capability leaves it unknown, so it shows.
    let silent = mouse("Silent", key: "p1234", caps: Status.Device.Capabilities())
    let (unknown, _) = try makeModel(devices: [m750, silent])
    #expect(ScrollingLayout(config: unknown.config, devices: unknown.capabilityDevices(in: .global)).shows(.smartShift))
}

@MainActor @Test func aMouseScopeIsJudgedByThatMouseAlone() throws {
    let (model, _) = try makeModel(devices: [mxMaster, m750])
    let forM750 = ScrollingLayout(config: model.config, devices: model.capabilityDevices(in: scope(m750Key)), scope: scope(m750Key))
    #expect(!forM750.shows(.smartShift) && !forM750.showsThumbWheel)
    let forMX = ScrollingLayout(config: model.config, devices: model.capabilityDevices(in: scope(mx)), scope: scope(mx))
    #expect(forMX.shows(.smartShift) && forMX.showsThumbWheel)
    // A setting the mouse already has keeps a hidden row, with its caption (the top level counts).
    let (set, _) = try makeModel(config: #"{"scrollWheel": {"smartShiftThreshold": 20}}"#, devices: [mxMaster, m750])
    let kept = ScrollingLayout(config: set.config, devices: set.capabilityDevices(in: scope(m750Key)), scope: scope(m750Key))
    #expect(kept.availability(.smartShift) == .unsupportedButConfigured)
    // A mouse that is not connected decides nothing.
    let asleep = mouse("MX", key: mx, caps: m750Caps, online: false)
    let (offline, _) = try makeModel(devices: [asleep, m750])
    #expect(offline.capabilityDevices(in: scope(mx)).isEmpty)
    #expect(offline.capabilityDevices(in: scope(m750Key)).map(\.name) == ["Signature Plus M750"])
}

// MARK: Writing

@MainActor @Test func aValueChangedWithAMouseSelectedLandsOnlyUnderItsEntryWithItsName() throws {
    let (model, sandbox) = try makeModel(config: #"{"dpi": 1200, "buttons": {"back": "mute"}}"#, devices: [mxMaster, m750])
    model.selectMouse(m750Key)
    model.set(2.0, at: ["smoothScroll", "speed"], in: model.scopeTarget)
    model.setDPI(3200, in: model.scopeTarget)
    model.update(in: model.scopeTarget) { $0.bind("forward", to: .named("missionControl"), in: model.scope) }
    model.flush()
    let saved = try sandbox.tree()
    #expect(saved.string(["devices", m750Key, "name"]) == "Signature Plus M750")
    #expect(saved.double(["devices", m750Key, "smoothScroll", "speed"]) == 2)
    #expect(saved.int(["devices", m750Key, "dpi"]) == 3200)
    #expect(saved.string(["devices", m750Key, "buttons", "forward"]) == "missionControl")
    // Nothing else moved: not the top level, and not the other mouse.
    #expect(saved.int(["dpi"]) == 1200)
    #expect(saved.string(["buttons", "back"]) == "mute")
    #expect(!saved.contains(["smoothScroll"]) && !saved.contains(["buttons", "forward"]))
    #expect(!saved.contains(["devices", mx]))
}

@MainActor @Test func usingTheAllMiceSettingRemovesTheOverrideAndTheRowReadsSameAsAllMice() throws {
    let (model, sandbox) = try makeModel(config: #"{"dpi": 1600, "devices": {"\#(m750Key)": {"name": "M750", "dpi": 1000, "scrollWheel": {"inverted": true}}}}"#,
                                     devices: [mxMaster, m750])
    model.selectMouse(m750Key)
    let target = model.scopeTarget
    #expect(model.config.isOverridden(["dpi"], in: target.scope))
    #expect(model.config.resolvedInt(["dpi"], in: target.scope) == 1000)
    model.update(in: target) { $0.removeOverrides([["dpi"]], in: target.scope) }
    model.flush()
    let saved = try sandbox.tree()
    #expect(!saved.contains(["devices", m750Key, "dpi"]))
    #expect(!model.config.isOverridden(["dpi"], in: target.scope))
    #expect(model.config.resolvedInt(["dpi"], in: target.scope) == 1600)
    // The entry keeps what it still overrides, and its name.
    #expect(saved.bool(["devices", m750Key, "scrollWheel", "inverted"]) == true)
    #expect(saved.string(["devices", m750Key, "name"]) == "M750")
    // Giving back the last one removes the entry, the name included.
    model.update(in: target) { $0.removeOverrides([["scrollWheel", "inverted"]], in: target.scope) }
    model.flush()
    let emptied = try sandbox.tree()
    #expect(!emptied.contains(["devices", m750Key]))
}

@Test func restoringDefaultsOnAMouseRemovesItsKeysNeverItsNameWhileOthersRemain() throws {
    var config = try tree("""
        {"dpi": 1600, "devices": {"\(mx)": {"name": "MX", "dpi": 800, "dpiPresets": [800, 1600], "smoothScroll": {"speed": 2},
         "scrollWheel": {"inverted": true}, "thumbWheel": {"inverted": true, "action": "tabs"},
         "buttons": {"back": "mute"}, "gesture": {"distanceMm": 6}}}}
        """)
    config.restorePointerDefaults(in: scope(mx))
    #expect(!config.contains(["devices", mx, "dpi"]) && !config.contains(["devices", mx, "dpiPresets"]))
    #expect(config.string(["devices", mx, "name"]) == "MX")
    config.restoreScrollingDefaults(in: scope(mx))
    #expect(!config.contains(["devices", mx, "smoothScroll"]) && !config.contains(["devices", mx, "scrollWheel"]))
    #expect(!config.contains(["devices", mx, "thumbWheel"]))
    config.restoreButtonDefaults(in: scope(mx))
    // Nothing but the name was left, so the entry goes with it.
    #expect(!config.contains(["devices", mx]))
    #expect(config.int(["dpi"]) == 1600)
}

@Test func smoothScrollingOnAMouseIsItsOwnOrAllMicesUntilGivenBack() throws {
    var config = try tree(#"{"smoothScroll": {"enabled": false}}"#)
    #expect(config.smoothScrollOwn(in: scope(mx)) == nil)
    #expect(!config.smoothScrollEnabled(in: scope(mx)))
    config.setSmoothScroll(true, in: scope(mx))
    #expect(config.smoothScrollOwn(in: scope(mx)) == true && config.smoothScrollEnabled(in: scope(mx)))
    #expect(!config.smoothScrollEnabled(in: .global))
    config.setSmoothScroll(nil, in: scope(mx))
    #expect(config.smoothScrollOwn(in: scope(mx)) == nil && !config.smoothScrollEnabled(in: scope(mx)))
    #expect(!config.contains(["devices", mx]))
    // With All Mice off by having no smoothScroll, giving back removes a mouse's whole object,
    // whose presence would otherwise turn it on.
    var bare = try tree(#"{"devices": {"\#(mx)": {"name": "MX", "smoothScroll": {"speed": 2}, "dpi": 800}}}"#)
    #expect(bare.smoothScrollEnabled(in: scope(mx)) && bare.smoothScrollOwn(in: scope(mx)) == true)
    bare.setSmoothScroll(nil, in: scope(mx))
    #expect(!bare.smoothScrollEnabled(in: scope(mx)))
    #expect(!bare.contains(["devices", mx, "smoothScroll"]) && bare.int(["devices", mx, "dpi"]) == 800)
}

@Test func feelOnAMouseIsReadFromItsValuesOverAllMices() throws {
    var config = try tree(#"{"smoothScroll": {"acceleration": 1.2, "smoothingMs": 350}}"#)
    #expect(config.globalFeel == .gliding)
    #expect(config.ownFeel(in: scope(mx)) == nil && config.feelSelection(in: scope(mx)) == .gliding)
    config.apply(.precise, in: scope(mx))
    #expect(config.ownFeel(in: scope(mx)) == .precise)
    #expect(config.feelSelection(in: .global) == .gliding)
    config.set(100, at: ["smoothScroll", "smoothingMs"], in: scope(mx))
    #expect(config.ownFeel(in: scope(mx)) == .custom)
    config.removeOverrides([["smoothScroll", "acceleration"], ["smoothScroll", "smoothingMs"]], in: scope(mx))
    #expect(config.ownFeel(in: scope(mx)) == nil)
}

@Test func aMousesDPIPresetsReplaceAllMicesAndMayBeEmpty() throws {
    var config = try tree(#"{"dpiPresets": [800, 1600]}"#)
    #expect(config.dpiPresets(in: scope(mx)) == [800, 1600])
    config.setDPIPresets([1000], in: scope(mx))
    #expect(config.dpiPresets(in: scope(mx)) == [1000] && config.dpiPresets(in: .global) == [800, 1600])
    // An empty list on a mouse is its own: no presets for it, not All Mice's.
    config.setDPIPresets([], in: scope(mx))
    #expect(config.dpiPresets(in: scope(mx)).isEmpty && config.isOverridden(["dpiPresets"], in: scope(mx)))
    let kit = try JSONDecoder().decode(Config.self, from: config.data())
    #expect(kit.forDevice(mx).dpiPresets.isEmpty)
    config.setDPIPresets([], in: .global)
    #expect(!config.contains(["dpiPresets"]))
}



// MARK: The M750

@MainActor @Test func theM750ListsItsReportedControlsWithKitNamesWhateverItsKey() throws {
    for key in [m750Key, m750Identified] {
        let device = mouse("Signature Plus M750", key: key, caps: m750Caps, controls: [0x50, 0x51, 0x52, 0x53, 0x56, 0xFD, 0xD7])
        let (model, sandbox) = try makeModel(config: #"{"devices": {"\#(key)": {"name": "Signature Plus M750", "buttons": {"back": "missionControl"}}}}"#,
                                         devices: [device])
        #expect(model.showsMouseMenu)
        model.selectMouse(key)
        let cids = Set(model.reportedControlIDs(in: model.scope))
        #expect(model.reportedControlIDs(in: model.scope).count == 7)
        let named = ButtonRows.named(deviceCIDs: cids, configKeys: model.boundButtonKeys(in: model.scope)).map(\.rawValue)
        #expect(Set(named) == ["middle", "back", "forward"])
        let others = ButtonRows.others(deviceCIDs: model.reportedControlIDs(in: model.scope),
                                       configKeys: model.boundButtonKeys(in: model.scope))
        #expect(others.map(NamedButton.title(forKey:)).contains("DPI button"))
        #expect(others.contains("0x00fd"))
        // A write for the DPI button lands under the key the mouse has, and no other.
        model.update(in: model.scopeTarget) { $0.bind("0x00fd", to: .named("missionControl"), in: model.scope) }
        model.flush()
        let saved = try sandbox.tree()
        #expect(saved.string(["devices", key, "buttons", "0x00fd"]) == "missionControl")
        #expect(saved.string(["devices", key, "buttons", "back"]) == "missionControl")
        #expect(saved.deviceEntries.keys.sorted() == [key])
        #expect(!saved.contains(["buttons"]))
    }
}

@MainActor @Test func theKeyOfAMouseSeenOnlyByProductIdDiffersFromItsIdentifiedOne() {
    // Documented, not aliased: Bluetooth without 0x0003 gives `pb02c`, with it `m…`.
    #expect(Config.deviceKey(modelID: nil, productID: 0xB02C) == "pb02c")
    #expect(Config.deviceKey(modelID: [0xB0, 0x2C, 0, 0, 0, 0], productID: 0xB02C) == m750Identified)
    #expect(m750Key != m750Identified)
}

// MARK: Use configured DPI and Find by Pressing

@MainActor @Test func theStatusMenuStaysGlobalAndSettingTheDPIForAMouseTellsOnlyThatMouse() throws {
    let (model, sandbox) = try makeModel(config: #"{"dpi": 800}"#, devices: [mxMaster, m750])
    model.selectMouse(m750Key)
    // The status menu passes no target: the top level, whichever mouse Settings has chosen.
    model.setDPI(1200)
    model.flush()
    var saved = try sandbox.tree()
    #expect(saved.int(["dpi"]) == 1200 && !saved.contains(["devices"]))
    #expect(sandbox.control()?.device == nil && sandbox.control()?.useConfiguredDPI != nil)
    // Settings' Pointer pane passes the mouse.
    model.setDPI(3200, in: model.scopeTarget)
    model.flush()
    saved = try sandbox.tree()
    #expect(saved.int(["devices", m750Key, "dpi"]) == 3200 && saved.int(["dpi"]) == 1200)
    #expect(sandbox.control()?.device == m750Key)
}

@MainActor @Test func findByPressingNamesTheSelectedMouseAndAPressSelectsThatMousesScope() throws {
    let (model, sandbox) = try makeModel(devices: [mxMaster, m750])
    model.startCapture()
    #expect(sandbox.control()?.capture?.device == nil)
    model.cancelCapture()
    model.selectMouse(mx)
    model.startCapture()
    let token = try #require(sandbox.control()?.capture?.token)
    #expect(sandbox.control()?.capture?.device == mx)
    // The press came from the other mouse: its settings are the ones to edit.
    model.capture.handle(Status.Capture(token: token, state: .pressed, cid: 0xFD, deviceID: "id-M750", model: m750Key))
    #expect(model.scope == scope(m750Key))
    #expect(model.capture.capturedDevice == m750Key)
    #expect(model.capture.capturedButton == "0x00fd")
}

@MainActor @Test func aPressOnAMouseThePopUpDoesNotListLeavesTheScopeAlone() throws {
    let (model, sandbox) = try makeModel(devices: [mxMaster])
    model.startCapture()
    let token = try #require(sandbox.control()?.capture?.token)
    model.capture.handle(Status.Capture(token: token, state: .pressed, cid: 0x53, deviceID: "id-MX", model: mx))
    #expect(model.scope == .global && model.rememberedMouse == nil)
}

@MainActor @Test func configuredDPIRequestsCarryTheDeviceKeyOrNone() throws {
    let sandbox = try Sandbox()
    try sandbox.writeStatus(daemonStatus(pid: getpid()))
    let link = DaemonLink(locations: sandbox.locations, isAlive: { _ in true }, ring: {})
    link.reloadStatus()
    link.requestConfiguredDPI()
    #expect(sandbox.control()?.device == nil && sandbox.control()?.useConfiguredDPI != nil)
    link.requestConfiguredDPI(device: m750Key.uppercased())
    #expect(sandbox.control()?.device == m750Key)
}

// MARK: The thumb wheel on a mouse, and what keeps a row

private let swappedVolume = #"{"thumbWheel":{"action":"volume","reversed":true},"devices":{"\#(mx)":{"name":"MX","dpi":800}}}"#

private func kitWheel(_ config: ConfigTree, _ key: String) throws -> Config.ThumbWheel.Mode? {
    try JSONDecoder().decode(Config.self, from: config.data()).forDevice(key).thumbWheel?.mode
}

@Test func customOnAMouseThatInheritsAnActionKeepsWhatKitResolvedForItsDirections() throws {
    var config = try tree(swappedVolume)
    let before = try kitWheel(config, mx)
    #expect(before == .actions(left: .volumeDown, right: .volumeUp))
    let path = config.prefix(of: scope(mx)) + ["thumbWheel"]
    let base = config.thumbWheel(at: ["thumbWheel"])
    config.chooseThumbWheel(.custom, at: path, base: base)
    // Custom writes the pair the mouse already had, so nothing changes until a direction is picked.
    #expect(try kitWheel(config, mx) == before)
}

@Test func theThumbWheelGivesBackWithoutLettingAMixedCaseTwinApply() throws {
    var config = try tree(#"{"devices":{"\#(mx.uppercased())":{"thumbWheel":{"action":"zoom"}},"\#(mx)":{"thumbWheel":{"action":"volume"}}}}"#)
    let path = config.prefix(of: scope(mx)) + ["thumbWheel"]
    config.chooseThumbWheel(.inherit, at: path)
    config.setThumbWheelKey(nil, "inverted", at: path)
    // Kit keeps the last spelling whole: with its wheel given back, the zoom of the other must not apply.
    #expect(try kitWheel(config, mx).map { $0 == .scroll } ?? true)
    #expect(config.resolved(["thumbWheel"], in: scope(mx)) == nil)
    var step = try tree(#"{"devices":{"\#(mx.uppercased())":{"thumbWheel":{"step":9}},"\#(mx)":{"thumbWheel":{"step":5}}}}"#)
    step.setThumbWheelKey(nil, "step", at: step.prefix(of: scope(mx)) + ["thumbWheel"])
    #expect(step.resolvedInt(["thumbWheel", "step"], in: scope(mx)) == nil)
}

@Test func aRowStaysForAValueOnlyTheMouseItselfHolds() throws {
    // Nothing at the top level; the M750, which has no SmartShift, holds the threshold.
    let config = try tree(#"{"devices":{"\#(m750Key)":{"name":"M750","scrollWheel":{"smartShiftThreshold":20}}}}"#)
    let layout = ScrollingLayout(config: config, devices: [m750], scope: scope(m750Key))
    #expect(layout.availability(.smartShift) == .unsupportedButConfigured)
    #expect(layout.shows(.smartShift))
    // Without it the row is hidden, and the MX (which has it) is no different for another mouse's value.
    let bare = ScrollingLayout(config: ConfigTree(), devices: [m750], scope: scope(m750Key))
    #expect(bare.availability(.smartShift) == .hidden)
    let other = try tree(#"{"devices":{"\#(mx)":{"name":"MX","scrollWheel":{"smartShiftThreshold":20}}}}"#)
    #expect(ScrollingLayout(config: other, devices: [m750], scope: scope(m750Key)).availability(.smartShift) == .hidden)
}
