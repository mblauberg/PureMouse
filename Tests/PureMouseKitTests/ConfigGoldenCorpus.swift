// Inputs for ConfigGoldenTests: valid configs (ok-) and ones the decoder must reject (err-).
// Each runs through the decoder and `ConfigCheck`; the results are in ConfigGoldenExpected.swift.
enum ConfigGoldenCorpus {
    static let inputs: [(name: String, json: String)] = [
        ("err-apps-button-unknown-action", #"""
{"apps": {"com.apple.Safari": {"buttons": {"back": "explode"}}}}
"""#),
        ("err-apps-buttons-type", #"""
{"apps": {"a": {"buttons": 5}}}
"""#),
        ("err-apps-entry-type", #"""
{"apps": {"a": "nope"}}
"""#),
        ("err-apps-list", #"""
{"apps": []}
"""#),
        ("err-apps-smooth-speed", #"""
{"apps": {"com.apple.Safari": {"smoothScroll": {"speed": 0}}}}
"""#),
        ("err-apps-thumb-step", #"""
{"apps": {"a": {"thumbWheel": {"step": 99}}}}
"""#),
        ("err-buttons-gesture-bad", #"""
{"buttons": {"gesture": {"up": "explode"}}}
"""#),
        ("err-buttons-haptic-number", #"""
{"buttons": {"top": {"haptic": 27}}}
"""#),
        ("err-buttons-haptic-unknown", #"""
{"buttons": {"top": {"haptic": "unknown"}}}
"""#),
        ("err-buttons-null-binding", #"""
{"buttons": {"back": null}}
"""#),
        ("err-buttons-type", #"""
{"buttons": []}
"""#),
        ("err-buttons-unknown-action", #"""
{"buttons": {"top": "explode"}}
"""#),
        ("err-dpi-float", #"""
{"dpi": 1600.5}
"""#),
        ("err-dpi-huge", #"""
{"dpi": 100000}
"""#),
        ("err-dpi-null", #"""
{"dpi": null}
"""#),
        ("err-dpi-string", #"""
{"dpi": "high"}
"""#),
        ("err-dpi-syntax", #"""
{"dpi": 1600
"""#),
        ("err-dpi-zero", #"""
{"dpi": 0}
"""#),
        ("err-gesture-interval-max", #"""
{"gesture": {"repeatIntervalMs": 9223372036854775807}}
"""#),
        ("err-gesture-interval-neg", #"""
{"gesture": {"repeatIntervalMs": -1}}
"""#),
        ("err-gesture-mm-huge", #"""
{"gesture": {"distanceMm": 1e20}}
"""#),
        ("err-gesture-mm-zero", #"""
{"gesture": {"distanceMm": 0}}
"""#),
        ("err-gesture-type", #"""
{"gesture": []}
"""#),
        ("err-presets-high", #"""
{"dpiPresets": [100000]}
"""#),
        ("err-presets-low", #"""
{"dpiPresets": [800, 10]}
"""#),
        ("err-presets-not-list", #"""
{"dpiPresets": 800}
"""#),
        ("err-presets-too-many", #"""
{"dpiPresets": [400, 800, 1200, 1600, 2000, 2400, 2800, 3200, 3600]}
"""#),
        ("err-presets-type", #"""
{"dpiPresets": [800, "x"]}
"""#),
        ("err-scroll-inverted-type", #"""
{"scrollWheel": {"inverted": 1}}
"""#),
        ("err-scroll-mode-bad", #"""
{"scrollWheel": {"mode": "fast"}}
"""#),
        ("err-scroll-not-object", #"""
{"scrollWheel": 5}
"""#),
        ("err-scroll-threshold-256", #"""
{"scrollWheel": {"smartShiftThreshold": 256}}
"""#),
        ("err-scroll-threshold-zero", #"""
{"scrollWheel": {"smartShiftThreshold": 0}}
"""#),
        ("err-smooth-accel-neg", #"""
{"smoothScroll": {"acceleration": -1}}
"""#),
        ("err-smooth-enabled-type", #"""
{"smoothScroll": {"enabled": "yes"}}
"""#),
        ("err-smooth-hspeed-neg", #"""
{"smoothScroll": {"horizontalSpeed": -1}}
"""#),
        ("err-smooth-ms-huge", #"""
{"smoothScroll": {"smoothingMs": 1e300}}
"""#),
        ("err-smooth-ms-neg", #"""
{"smoothScroll": {"smoothingMs": -5}}
"""#),
        ("err-smooth-speed-huge", #"""
{"smoothScroll": {"speed": 1e300}}
"""#),
        ("err-smooth-speed-zero", #"""
{"smoothScroll": {"speed": 0}}
"""#),
        ("err-thumb-action-actionname", #"""
{"thumbWheel": {"action": "missionControl"}}
"""#),
        ("err-thumb-action-unknown", #"""
{"thumbWheel": {"action": "explode"}}
"""#),
        ("err-thumb-inverted-type", #"""
{"thumbWheel": {"inverted": "x"}}
"""#),
        ("err-thumb-left-unknown", #"""
{"thumbWheel": {"left": "explode"}}
"""#),
        ("err-thumb-reversed-type", #"""
{"thumbWheel": {"reversed": 1}}
"""#),
        ("err-thumb-step-37", #"""
{"thumbWheel": {"step": 37}}
"""#),
        ("err-thumb-step-zero", #"""
{"thumbWheel": {"step": 0}}
"""#),
        ("err-top-level-empty-file", ""),
        ("err-top-level-list", #"""
[]
"""#),
        ("err-universal-type", #"""
{"universalControl": {"handOff": 1}}
"""#),
        ("ok-apps-case-and-repeat", #"""
{"apps": {"com.Apple.Safari": {"buttons": {"back": "none"}}, "COM.APPLE.SAFARI": {"buttons": {"forward": "none"}}}}
"""#),
        ("ok-apps-empty-entry", #"""
{"apps": {"a": {}}}
"""#),
        ("ok-apps-empty", #"""
{"apps": {}}
"""#),
        ("ok-apps-gesture-over-action", #"""
{"buttons": {"gesture": "launchpad"}, "apps": {"x": {"buttons": {"gesture": {"up": "appExpose"}}}}}
"""#),
        ("ok-apps-merge", #"""
{"buttons": {"back": "navigateBack", "middle": "missionControl", "gesture": {"click": "missionControl", "left": "spaceLeft", "right": "spaceRight"}}, "thumbWheel": {"inverted": true, "action": "volume", "step": 4}, "smoothScroll": {"speed": 2, "smoothingMs": 300}, "apps": {"com.apple.Safari": {"buttons": {"back": {"keys": "cmd+["}, "top": "showDesktop", "gesture": {"left": "navigateBack"}}}, "com.google.Chrome": {"thumbWheel": {"action": "tabs"}, "smoothScroll": {"speed": 3}}, "com.apple.Music": {"thumbWheel": {"step": 1}}, "com.apple.Preview": {"thumbWheel": {"action": "scroll"}, "smoothScroll": {"enabled": false}}}}
"""#),
        ("ok-apps-partial-thumb", #"""
{"thumbWheel": {"left": "volumeDown", "right": "volumeUp", "step": 8}, "apps": {"a": {"thumbWheel": {"left": "mute"}}, "b": {"thumbWheel": {"action": "volume"}}, "c": {"thumbWheel": {"action": "zoom"}}, "d": {"thumbWheel": {"action": "zoom", "right": "mute", "step": 5}}}}
"""#),
        ("ok-apps-reversed-inherit", #"""
{"thumbWheel": {"inverted": true, "action": "volume", "reversed": true}, "apps": {"a": {"thumbWheel": {"action": "tabs"}}, "b": {"thumbWheel": {"action": "tabs", "reversed": false}}, "c": {"buttons": {"back": "none"}}}}
"""#),
        ("ok-apps-smooth-no-global", #"""
{"apps": {"com.apple.Safari": {"smoothScroll": {}}}}
"""#),
        ("ok-apps-warnings", #"""
{"apps": {"com.apple.Safari": {"dpi": 800, "thumbWheel": {"inverted": true}, "buttons": {"zz": "none", "qq": "none"}, "gesture": {"distanceMm": 9}}, "b.app": {"scrollWheel": {}}}}
"""#),
        ("ok-boundaries-high", #"""
{"dpi": 25600, "scrollWheel": {"smartShiftThreshold": 255}, "smoothScroll": {"speed": 10, "horizontalSpeed": 10, "acceleration": 10, "smoothingMs": 2000}, "gesture": {"distanceMm": 50, "repeatIntervalMs": 5000}}
"""#),
        ("ok-boundaries-low", #"""
{"dpi": 50, "scrollWheel": {"smartShiftThreshold": 1}, "smoothScroll": {"speed": 0.1, "horizontalSpeed": 0.1, "acceleration": 0, "smoothingMs": 0}, "gesture": {"distanceMm": 0.5, "repeatIntervalMs": 0}}
"""#),
        ("ok-buttons-duplicate-cid", #"""
{"buttons": {"back": "none", "0x53": "none", "53": "none", "forward": {"click": "none"}}}
"""#),
        ("ok-buttons-duplicate-unknown", #"""
{"buttons": {"qq": "none", "qq ": "none", "zz": "mute"}}
"""#),
        ("ok-buttons-empty", #"""
{"buttons": {}}
"""#),
        ("ok-buttons-gesture-full", #"""
{"buttons": {"gesture": {"click": "missionControl", "up": "missionControl", "down": "appExpose", "left": "spaceLeft", "right": "spaceRight"}}}
"""#),
        ("ok-buttons-gesture-partial", #"""
{"buttons": {"gesture": {"up": "missionControl"}, "top": {"click": {"haptic": "completed"}}}}
"""#),
        ("ok-buttons-hex", #"""
{"buttons": {"0x00c4": {"keys": "cmd+shift+4"}, "back": {"run": "true"}, "00fd": "mute", "0X01A0": "none"}}
"""#),
        ("ok-buttons-named", #"""
{"buttons": {"middle": "none", "back": "navigateBack", "forward": "navigateForward", "gesture": "launchpad", "top": "showDesktop", "thumbPanel": {"haptic": "sharpStateChange"}}}
"""#),
        ("ok-buttons-unknown", #"""
{"buttons": {"zz": "none", "back": "none", "qq": "mute", "0xzz": "none"}}
"""#),
        ("ok-dpi-and-presets", #"""
{"dpi": 1600, "dpiPresets": [800, 1600, 3200], "buttons": {"top": "cycleDPI"}}
"""#),
        ("ok-dpi-presets-empty", #"""
{"dpiPresets": []}
"""#),
        ("ok-dpi-presets-max", #"""
{"dpiPresets": [50, 400, 800, 1200, 1600, 2000, 2400, 25600]}
"""#),
        ("ok-empty", #"""
{}
"""#),
        ("ok-everything", #"""
{"dpi": 1650, "dpiPresets": [800, 1600], "scrollWheel": {"inverted": true, "mode": "freespin", "smartShiftThreshold": 255}, "thumbWheel": {"inverted": true, "action": "tabs", "reversed": true, "step": 5}, "smoothScroll": {"speed": 0.7, "horizontalSpeed": 1.0, "acceleration": 1.0, "smoothingMs": 350}, "buttons": {"gesture": {"click": "missionControl"}, "back": "navigateBack", "zz": "none", "0x00fd": "cycleDPI"}, "gesture": {"distanceMm": 4, "repeatIntervalMs": 400}, "universalControl": {"handOff": false}, "apps": {"com.apple.Safari": {"buttons": {"back": "none", "gesture": {"up": "appExpose"}}, "thumbWheel": {"step": 2}, "smoothScroll": {"speed": 1}}}}
"""#),
        ("ok-gesture-settings-empty", #"""
{"gesture": {}}
"""#),
        ("ok-gesture-settings", #"""
{"gesture": {"distanceMm": 12.5, "repeatIntervalMs": 250}}
"""#),
        ("ok-scroll-wheel-all", #"""
{"scrollWheel": {"inverted": true, "mode": "freespin", "smartShiftThreshold": 20}}
"""#),
        ("ok-scroll-wheel-empty", #"""
{"scrollWheel": {}}
"""#),
        ("ok-scroll-wheel-ratchet", #"""
{"scrollWheel": {"mode": "ratchet"}}
"""#),
        ("ok-smooth-all", #"""
{"smoothScroll": {"enabled": true, "speed": 1.5, "horizontalSpeed": 2.5, "acceleration": 3, "smoothingMs": 200, "shiftScrollsHorizontally": false}}
"""#),
        ("ok-smooth-disabled", #"""
{"smoothScroll": {"enabled": false, "speed": 2}}
"""#),
        ("ok-smooth-empty", #"""
{"smoothScroll": {}}
"""#),
        ("ok-thumb-empty", #"""
{"thumbWheel": {}}
"""#),
        ("ok-thumb-inverted", #"""
{"thumbWheel": {"inverted": true}}
"""#),
        ("ok-thumb-right-only", #"""
{"thumbWheel": {"right": "mute", "step": 36}}
"""#),
        ("ok-thumb-scroll", #"""
{"thumbWheel": {"action": "scroll"}}
"""#),
        ("ok-thumb-spaces-step", #"""
{"thumbWheel": {"action": "spaces", "step": 6}}
"""#),
        ("ok-thumb-tabs-reversed", #"""
{"thumbWheel": {"action": "tabs", "reversed": true, "inverted": false}}
"""#),
        ("ok-thumb-volume-left", #"""
{"thumbWheel": {"action": "volume", "left": {"keys": "cmd+["}, "right": "missionControl"}}
"""#),
        ("ok-thumb-zoom", #"""
{"thumbWheel": {"action": "zoom"}}
"""#),
        ("ok-universal-control-empty", #"""
{"universalControl": {}}
"""#),
        ("ok-universal-control-off", #"""
{"universalControl": {"handOff": false}}
"""#),
    ]
}
