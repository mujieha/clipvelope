import AppKit
import SwiftUI
import Carbon.HIToolbox

// MARK: - Global Hotkeys

/// Quick Slots and the open-panel key as system-wide hotkeys.
///
/// They previously used NSEvent.addLocalMonitorForEvents, which only ever sees
/// events delivered to this app -- so ⌥1-9 worked only when Clipvelope was
/// already frontmost, which is precisely when you don't need a quick slot.
///
/// Carbon's RegisterEventHotKey is used rather than an NSEvent *global* monitor
/// because a global monitor requires the user to grant Accessibility access,
/// and cannot swallow the event. RegisterEventHotKey needs no permission and
/// consumes the keystroke.
final class GlobalHotkeyCenter {
    static let shared = GlobalHotkeyCenter()

    fileprivate static let signature: OSType = 0x43565148 // 'CVEH'

    /// Key codes for the digits 1...9, in order.
    private static let digitKeyCodes: [UInt32] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    private static let openHotKeyID: UInt32 = 100

    var onSlot: ((Int) -> Void)?
    var onOpen: (() -> Void)?

    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var openRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    private init() {}

    /// Registers the open-history key, replacing whatever was registered before.
    /// Nil registers nothing, which is how the recorder gets out of the way while
    /// the user presses keys. False means another app already owns the combination.
    @discardableResult
    func setOpenHotkey(_ combo: KeyCombo?) -> Bool {
        installHandler()
        if let openRef {
            UnregisterEventHotKey(openRef)
            self.openRef = nil
        }
        guard let combo else { return true }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: Self.openHotKeyID)
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, hotKeyID,
                                         GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr else {
            NSLog("Clipvelope: could not register \(combo.displayName) to open the history (\(status))")
            return false
        }
        openRef = ref
        return true
    }

    /// Registers the Quick Slot hotkeys. Returns the slot numbers (1-9) that
    /// another app already owns, so Preferences can say which slots cannot fire
    /// rather than leaving them to fail quietly.
    @discardableResult
    func register() -> [Int] {
        installHandler()
        unregisterHotKeys()

        var unavailable: [Int] = []
        for (index, keyCode) in Self.digitKeyCodes.enumerated() {
            if !add(keyCode: keyCode, modifiers: UInt32(optionKey), id: UInt32(index + 1)) {
                // The rest still work.
                NSLog("Clipvelope: could not register ⌥\(index + 1)")
                unavailable.append(index + 1)
            }
        }
        NSLog("Clipvelope: registered \(Self.digitKeyCodes.count - unavailable.count) of \(Self.digitKeyCodes.count) quick slot hotkeys")
        return unavailable
    }

    private func add(keyCode: UInt32, modifiers: UInt32, id: UInt32) -> Bool {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr else { return false }
        hotKeyRefs.append(ref)
        return true
    }

    private func installHandler() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(event,
                                               EventParamName(kEventParamDirectObject),
                                               EventParamType(typeEventHotKeyID),
                                               nil,
                                               MemoryLayout<EventHotKeyID>.size,
                                               nil,
                                               &hotKeyID)
                guard status == noErr,
                      hotKeyID.signature == GlobalHotkeyCenter.signature
                else { return OSStatus(eventNotHandledErr) }

                let center = Unmanaged<GlobalHotkeyCenter>.fromOpaque(userData)
                    .takeUnretainedValue()
                let id = hotKeyID.id
                DispatchQueue.main.async {
                    if id == GlobalHotkeyCenter.openHotKeyID {
                        center.onOpen?()
                    } else {
                        center.onSlot?(Int(id))
                    }
                }
                return noErr
            },
            1, &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
    }

    private func unregisterHotKeys() {
        for ref in hotKeyRefs where ref != nil {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
    }

    func stop() {
        unregisterHotKeys()
        setOpenHotkey(nil)
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
    }
}

// MARK: - KeyCombo and the keyboard

extension KeyCombo {
    /// Nil for a key pressed without any modifier: recording that would turn
    /// ordinary typing into a shortcut.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= Self.command }
        if flags.contains(.shift) { modifiers |= Self.shift }
        if flags.contains(.option) { modifiers |= Self.option }
        if flags.contains(.control) { modifiers |= Self.control }
        guard modifiers != 0 else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers)
    }

    func matches(_ event: NSEvent) -> Bool {
        KeyCombo(event: event) == self
    }

    var displayName: String { displayName(keyName: keyName) }

    /// The key's name in the Latin layout the user has, so "V" stays "V" while
    /// they type in Cyrillic. The shortcut is bound to the physical key, and a
    /// name that changed with the input source would suggest it does not.
    var keyName: String {
        if let special = Self.specialKeyNames[keyCode] { return special }
        return Self.layoutKeyName(keyCode) ?? "Key \(keyCode)"
    }

    private static let specialKeyNames: [UInt32: String] = [
        36: "Return", 76: "Enter", 48: "Tab", 49: "Space", 51: "Delete",
        117: "Forward Delete", 53: "Escape", 123: "Left Arrow", 124: "Right Arrow",
        125: "Down Arrow", 126: "Up Arrow", 115: "Home", 119: "End",
        116: "Page Up", 121: "Page Down",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7",
        100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    private static func layoutKeyName(_ keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return OSStatus(paramErr) }
            return UCKeyTranslate(base.assumingMemoryBound(to: UCKeyboardLayout.self),
                                  UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                  UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysMask),
                                  &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        let name = String(utf16CodeUnits: chars, count: length)
        return name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : name.uppercased()
    }
}

// MARK: - Opening the panel

/// Whether the history panel is on screen. MenuBarExtra offers no way to ask,
/// so the panel's own NSWindow is recorded when the content view lands in it
/// and its visibility is read directly. A flag set from onAppear/onDisappear
/// was tried first and stuck at "open": the window is hidden, not closed, when
/// the panel loses focus, so onDisappear never fires and every later `--open`
/// became a no-op.
enum PanelState {
    weak static var window: NSWindow?
    static var isOpen: Bool { window?.isVisible ?? false }
}

/// The view MenuKeyHandler installs in the panel; it exists to learn the window.
final class PanelHostView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { PanelState.window = window }
    }
}

enum PanelOpener {
    /// Presses the menu bar item the way a click would, which is the only way to
    /// open a MenuBarExtra window from code. Pressing it while open closes it.
    @discardableResult
    static func toggle() -> Bool {
        for window in NSApp.windows where window.className == "NSStatusBarWindow" {
            if let button = statusButton(in: window.contentView) {
                button.performClick(nil)
                return true
            }
        }
        NSLog("Clipvelope: menu bar item not found, cannot open the history")
        return false
    }

    static func open() {
        if !PanelState.isOpen { toggle() }
    }

    private static func statusButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for subview in view.subviews {
            if let button = statusButton(in: subview) { return button }
        }
        return nil
    }
}

// MARK: - Menu Key Handler

/// The keys the history panel answers to while the search field has focus:
/// Tab accepts the autocomplete suggestion, ↑↓ move the selection, Return copies
/// it, Escape clears the search or closes the panel, and the user's Preferences
/// shortcut opens Preferences.
///
/// An NSEvent monitor rather than SwiftUI's onKeyPress because the text field
/// would otherwise consume the arrows and Return first.
struct MenuKeyHandler: NSViewRepresentable {
    @Binding var query: String
    let suggestion: String?
    let preferencesCombo: KeyCombo
    let onMove: (Int) -> Void
    let onSubmit: () -> Void
    let onEscape: () -> Void
    let onPreferences: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = PanelHostView(frame: .zero)
        context.coordinator.start(view: view)
        update(context.coordinator)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        update(context.coordinator)
    }

    private func update(_ coordinator: Coordinator) {
        coordinator.query = $query
        coordinator.suggestion = suggestion
        coordinator.preferencesCombo = preferencesCombo
        coordinator.onMove = onMove
        coordinator.onSubmit = onSubmit
        coordinator.onEscape = onEscape
        coordinator.onPreferences = onPreferences
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var monitor: Any?
        private weak var hostView: NSView?
        var query: Binding<String> = .constant("")
        var suggestion: String?
        var preferencesCombo: KeyCombo = .defaultPreferences
        var onMove: (Int) -> Void = { _ in }
        var onSubmit: () -> Void = {}
        var onEscape: () -> Void = {}
        var onPreferences: () -> Void = {}

        func start(view: NSView) {
            hostView = view
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                // A local monitor is app-wide. Without this scope check, these
                // keys would be swallowed in the Preferences window too.
                guard let window = hostView?.window, event.window === window else { return event }
                if preferencesCombo.matches(event) {
                    onPreferences()
                    return nil
                }
                switch Int(event.keyCode) {
                case 48: // Tab
                    guard let suggestion, !suggestion.isEmpty else { return event }
                    query.wrappedValue = suggestion
                    return nil
                case 126: onMove(-1); return nil
                case 125: onMove(1); return nil
                case 36, 76: onSubmit(); return nil
                case 53: onEscape(); return nil
                default: return event
                }
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
