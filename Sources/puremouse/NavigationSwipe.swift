import CoreGraphics

/// Synthesises the trackpad "swipe between pages" gesture, which Safari, Finder and most
/// document-based apps treat as back/forward. Recipe from Mac Mouse Fix
/// (Helper/Core/Touch/TouchSimulator.m, `postNavigationSwipeEventWithDirection:`).
enum NavigationSwipe {
    private static let typeField = CGEventField(rawValue: 55)!       // CGS event type
    private static let subtypeField = CGEventField(rawValue: 110)!   // IOHID event type
    private static let directionField = CGEventField(rawValue: 115)! // IOHIDSwipeMask
    private static let phaseField = CGEventField(rawValue: 132)!     // IOHIDEventPhaseBits

    private static let gestureType: Int64 = 29       // NSEventTypeGesture
    private static let navigationSwipe: Int64 = 16   // kIOHIDEventTypeNavigationSwipe
    private static let swipeLeft: Int64 = 4, swipeRight: Int64 = 8
    private static let phaseBegan: Int64 = 1, phaseEnded: Int64 = 4

    static func post(back: Bool) {
        guard let event = CGEvent(source: nil) else { return }
        event.setIntegerValueField(typeField, value: gestureType)
        event.setIntegerValueField(subtypeField, value: navigationSwipe)
        event.setIntegerValueField(phaseField, value: phaseBegan)
        event.setIntegerValueField(directionField, value: back ? swipeLeft : swipeRight)
        event.post(tap: .cghidEventTap)
        event.setIntegerValueField(directionField, value: 0)
        event.setIntegerValueField(phaseField, value: phaseEnded)
        event.post(tap: .cghidEventTap)
    }
}
