import AppKit

/// What actually taps the trackpad.
///
/// A protocol only so a test can watch: `NSHapticFeedbackManager` reports
/// nothing back, produces no observable state, and on a machine without a Force
/// Touch trackpad does nothing at all -- so without a seam here the only way to
/// check that pinning asks for the right pattern is to feel it.
protocol HapticFeedbackPerforming {
    func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern)
}

/// The real one.
///
/// `drawCompleted` rather than `now`: it holds the tap until the next drawing
/// pass, so the feel and the row changing land together instead of a frame
/// apart. That synchronisation is the whole reason the platform offers a
/// performance time at all.
struct SystemHaptics: HapticFeedbackPerforming {
    func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .drawCompleted)
    }
}

/// A tap on the trackpad when a row changes under the pointer.
///
/// **Where this may and may not be used.** AppKit's own header says a Force
/// Touch trackpad "will not perform the feedback if the user isn't currently
/// touching the trackpad". So every keyboard path in this app -- Control +
/// Option + V, the arrows, Return, the Command and Option numbers -- would feel
/// nothing, and a call there would be dead code that reads like a feature. Only
/// paths that the pointer drives can carry it.
///
/// That is also why these calls live at the buttons in `Views.swift` rather
/// than in `ClipboardStore`. Pinning and deleting happen from places with no
/// pointer anywhere near them as well -- an import, an eviction when the history
/// reaches its cap, Delete Everything, and the removal of a row whose image
/// payload turned out to be missing. A tap on those would be unfelt at best and
/// wrong at worst. The two buttons exist only while the pointer is over a row,
/// which is exactly the condition the hardware requires.
///
/// **What the platform already decides, so this does not.** `defaultPerformer`
/// accounts for the input device, the accessibility settings and the user's own
/// trackpad preferences, and does nothing on hardware with no haptic actuator.
/// There is therefore no capability check here and no setting in Preferences:
/// either would be a second, staler source of truth for something the system
/// owns. It needs no entitlement and raises no prompt, so it costs the app
/// nothing of its "needs nothing from macOS" position.
enum Haptics {
    /// Swapped in tests. Not a setting: nothing in the app writes to it.
    static var performer: HapticFeedbackPerforming = SystemHaptics()

    /// Pinning moves a row between two discrete states, which is what
    /// `levelChange` describes.
    static func rowPinned() {
        performer.perform(.levelChange)
    }

    /// Deleting is neither an alignment nor a step on a scale, so it takes
    /// `generic` -- the pattern for "none of the others apply" rather than a
    /// default reached for out of habit.
    static func rowDeleted() {
        performer.perform(.generic)
    }
}
