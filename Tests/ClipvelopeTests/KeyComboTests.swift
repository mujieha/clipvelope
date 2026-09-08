import XCTest
@testable import Clipvelope

final class KeyComboTests: XCTestCase {
    func testDisplayNameSpellsModifiersOutInKeyboardOrder() {
        let all = KeyCombo(keyCode: 9, modifiers: KeyCombo.allModifiers)
        XCTAssertEqual(all.displayName(keyName: "V"), "Control + Option + Shift + Command + V")
        XCTAssertEqual(KeyCombo.defaultOpen.displayName(keyName: "V"), "Control + Option + V")
        XCTAssertEqual(KeyCombo.defaultPreferences.displayName(keyName: ","), "Command + ,")
    }

    func testAKeyWithoutModifiersIsNotAShortcut() {
        XCTAssertFalse(KeyCombo(keyCode: 9, modifiers: 0).hasModifier)
        XCTAssertTrue(KeyCombo.defaultOpen.hasModifier)
    }

    func testAnOlderVaultGetsTheDefaultShortcuts() throws {
        let json = #"{"items":[],"bindings":[],"folders":[],"autoBackupEnabled":false,"autoBackupMode":"keychain","themeMode":"system"}"#
        let state = try JSONDecoder().decode(AppState.self, from: Data(json.utf8))
        XCTAssertEqual(state.openHotkey, .defaultOpen)
        XCTAssertEqual(state.preferencesHotkey, .defaultPreferences)
    }

    func testChosenShortcutsRoundTrip() throws {
        var state = AppState.empty
        state.openHotkey = KeyCombo(keyCode: 49, modifiers: KeyCombo.command | KeyCombo.shift)
        state.preferencesHotkey = KeyCombo(keyCode: 44, modifiers: KeyCombo.control)
        let decoded = try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.openHotkey, state.openHotkey)
        XCTAssertEqual(decoded.preferencesHotkey, state.preferencesHotkey)
    }
}
