import XCTest
import CryptoKit
@testable import Clipvelope

/// Drives the code paths behind the buttons: the Folders tab, Quick Slots,
/// pinning and deleting rows, and Export/Import in the Backup tab. The UI layer
/// on top is a file picker and some SwiftUI bindings; everything that can
/// actually go wrong lives here.
private struct FixedKeyStore: KeyProviding {
    let key: SymmetricKey
    init(seed: UInt8 = 1) { key = SymmetricKey(data: Data(repeating: seed, count: 32)) }
    func getOrCreateKey() throws -> SymmetricKey { key }
}

final class StoreIntegrationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clipvelope-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore(_ name: String = "vault", seed: UInt8 = 1) -> ClipboardStore {
        let storage = EncryptedStorage(directory: root.appendingPathComponent(name),
                                       keyStore: FixedKeyStore(seed: seed))
        let store = ClipboardStore(storage: storage, enableSystemIntegration: false)
        settle(store)
        return store
    }

    /// Loads and saves hop between a serial I/O queue and the main queue, so a
    /// test has to drain both before asserting.
    private func settle(_ store: ClipboardStore, rounds: Int = 4) {
        for _ in 0..<rounds {
            store.drainPendingWork()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    // MARK: - Folders tab

    func testAddingAFolderPersistsAcrossRelaunch() {
        let store = makeStore()
        store.addFolder()
        store.folders[0].name = "Deploy"
        store.persistState()
        settle(store)

        let reopened = makeStore()
        XCTAssertEqual(reopened.folders.map(\.name), ["Deploy"])
    }

    func testAddingCommandsToAFolderPersists() {
        let store = makeStore()
        store.addFolder()
        store.folders[0].name = "Deploy"
        store.addCommand(to: store.folders[0])
        store.folders[0].items[0].title = "Ship it"
        store.folders[0].items[0].content = "echo deploying"
        store.folders[0].items[0].isShell = true
        store.persistState()
        settle(store)

        let reopened = makeStore()
        XCTAssertEqual(reopened.folders.count, 1)
        XCTAssertEqual(reopened.folders[0].items.map(\.title), ["Ship it"])
        XCTAssertTrue(reopened.folders[0].items[0].isShell)
    }

    func testRemovingAFolderPersists() {
        let store = makeStore()
        store.addFolder()
        store.addFolder()
        store.folders[0].name = "Keep"
        store.folders[1].name = "Drop"
        store.persistState()
        settle(store)

        store.removeFolder(store.folders[1])
        settle(store)

        XCTAssertEqual(makeStore().folders.map(\.name), ["Keep"])
    }

    func testRemovingACommandLeavesTheFolder() {
        let store = makeStore()
        store.addFolder()
        store.addCommand(to: store.folders[0])
        store.addCommand(to: store.folders[0])
        store.folders[0].items[0].title = "first"
        store.folders[0].items[1].title = "second"
        store.persistState()
        settle(store)

        store.removeCommand(folder: store.folders[0], item: store.folders[0].items[0])
        settle(store)

        let reopened = makeStore()
        XCTAssertEqual(reopened.folders.count, 1)
        XCTAssertEqual(reopened.folders[0].items.map(\.title), ["second"])
    }

    // MARK: - Quick Slots

    func testQuickSlotCopiesItsTextToThePasteboard() {
        let store = makeStore()
        store.addBinding()
        store.bindings[0].title = "Signature"
        store.bindings[0].content = "sent from a test"
        store.persistState()
        settle(store)

        NSPasteboard.general.clearContents()
        store.triggerBinding(slot: 1)

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "sent from a test")
    }

    func testTriggeringAnEmptySlotDoesNothingRatherThanCrashing() {
        let store = makeStore()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("untouched", forType: .string)

        store.triggerBinding(slot: 7)

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "untouched")
    }

    // MARK: - History rows

    func testPinDeleteAndReopen() {
        let store = makeStore()
        store.add(text: "one")
        store.add(text: "two")
        store.add(text: "three")
        settle(store)

        store.togglePin(store.items.first { $0.searchText == "one" }!)
        store.remove(store.items.first { $0.searchText == "two" }!)
        settle(store)

        let reopened = makeStore()
        XCTAssertEqual(Set(reopened.items.map(\.searchText)), ["one", "three"])
        XCTAssertTrue(reopened.items.first { $0.searchText == "one" }!.isPinned)
    }

    func testClearAllEmptiesTheVaultButKeepsSettings() {
        let store = makeStore()
        store.add(text: "secret")
        store.addFolder()
        store.themeMode = .dark
        store.persistState()
        settle(store)

        store.clearAll()
        settle(store)

        let reopened = makeStore()
        XCTAssertTrue(reopened.items.isEmpty)
        XCTAssertTrue(reopened.folders.isEmpty)
        XCTAssertEqual(reopened.themeMode, .dark)
    }

    // MARK: - Backup tab

    func testKeychainBackupRoundTripsIntoAFreshVault() {
        let source = makeStore("source")
        source.add(text: "remember me")
        source.addFolder()
        source.folders[0].name = "Snippets"
        source.persistState()
        settle(source)

        let backup = root.appendingPathComponent("keychain.cvb")
        source.exportBackup(to: backup, password: nil)
        settle(source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))

        // Same key, empty vault: what Import does on a reinstalled Mac.
        let destination = makeStore("destination")
        XCTAssertTrue(destination.items.isEmpty)

        destination.importBackup(from: backup, password: nil)
        settle(destination)

        XCTAssertEqual(destination.items.map(\.searchText), ["remember me"])
        XCTAssertEqual(destination.folders.map(\.name), ["Snippets"])
    }

    func testPasswordBackupRoundTripsOntoADifferentKey() {
        let source = makeStore("source", seed: 1)
        source.add(text: "portable entry")
        source.persistState()
        settle(source)

        let backup = root.appendingPathComponent("portable.cvb")
        source.exportBackup(to: backup, password: "correct horse")
        settle(source)

        // seed 2: a different Keychain key, i.e. a different Mac.
        let destination = makeStore("destination", seed: 2)
        destination.importBackup(from: backup, password: "correct horse")
        settle(destination)

        XCTAssertEqual(destination.items.map(\.searchText), ["portable entry"])
    }

    func testImportingWithTheWrongPasswordFailsVisiblyAndChangesNothing() {
        let source = makeStore("source")
        source.add(text: "original")
        source.persistState()
        settle(source)

        let backup = root.appendingPathComponent("portable.cvb")
        source.exportBackup(to: backup, password: "right")
        settle(source)

        let destination = makeStore("destination", seed: 2)
        destination.add(text: "existing entry")
        settle(destination)

        destination.importBackup(from: backup, password: "wrong")
        settle(destination)

        XCTAssertEqual(destination.items.map(\.searchText), ["existing entry"],
                       "a failed import must not wipe what was already there")
        XCTAssertNotNil(destination.storageFailure,
                        "a failed import must say so rather than fail silently")
    }

    func testAKeychainBackupCannotBeOpenedOnAnotherMachine() {
        let source = makeStore("source", seed: 1)
        source.add(text: "device bound")
        source.persistState()
        settle(source)

        let backup = root.appendingPathComponent("keychain.cvb")
        source.exportBackup(to: backup, password: nil)
        settle(source)

        let elsewhere = makeStore("elsewhere", seed: 2)
        elsewhere.importBackup(from: backup, password: nil)
        settle(elsewhere)

        XCTAssertTrue(elsewhere.items.isEmpty)
        XCTAssertNotNil(elsewhere.storageFailure)
    }

    // MARK: - Privacy tab

    func testPausingCaptureSurvivesRelaunch() {
        let store = makeStore()
        store.setCaptureSuspended(true)
        settle(store)

        XCTAssertTrue(makeStore().captureSuspended)
    }

    /// Capturing passwords is opt-in and must stay that way: a fresh vault, and
    /// one whose file predates the setting, both start with it off.
    func testSensitiveCaptureIsOffByDefaultAndPersistsWhenTurnedOn() {
        let store = makeStore()
        XCTAssertTrue(store.skipConcealedContent,
                      "a fresh vault must not capture passwords")

        store.setSkipConcealedContent(false)
        settle(store)
        XCTAssertFalse(makeStore().skipConcealedContent,
                       "the opt-in must survive a relaunch")

        store.setSkipConcealedContent(true)
        settle(store)
        XCTAssertTrue(makeStore().skipConcealedContent)
    }

    /// Whatever the answer is on this machine, the store must report the same
    /// thing the key store actually does - a Preferences panel that disagreed
    /// with reality would be worse than showing nothing.
    func testKeyIsolationIsReportedHonestly() {
        XCTAssertEqual(makeStore().isKeyIsolated,
                       KeychainKeyStore.usesDataProtectionKeychain)
    }

    func testIgnoredAppsPersistAndDeduplicate() {
        let store = makeStore()
        store.ignoreApp(bundleID: "com.1password.1password")
        store.ignoreApp(bundleID: "com.1password.1password")
        settle(store)

        XCTAssertEqual(makeStore().ignoredAppBundleIDs, ["com.1password.1password"])

        store.stopIgnoringApp(bundleID: "com.1password.1password")
        settle(store)
        XCTAssertTrue(makeStore().ignoredAppBundleIDs.isEmpty)
    }
}
