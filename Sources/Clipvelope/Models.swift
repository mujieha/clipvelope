import Foundation

// MARK: - Models

/// What a history entry holds.
///
/// Text lives inline in the index: it is small, and keeping it there is what
/// lets search and autocomplete run without touching the disk. Image bytes do
/// not -- they live in their own encrypted file keyed by the item's id, so
/// copying one thing never rewrites all the others. Files are references only;
/// putting file URLs back on the pasteboard needs no stored payload at all.
enum ClipboardContent: Codable, Equatable {
    case text(String)
    case richText(RichTextInfo)
    case image(ImageInfo)
    case files([FileRef])

    /// Formatted text: a styled paste kept intact rather than flattened.
    ///
    /// The plain rendering lives here in the index, because search, autocomplete
    /// and the row label all need it without touching the disk. The RTF or HTML
    /// bytes live in the item's payload file, exactly like an image.
    struct RichTextInfo: Codable, Equatable {
        /// Formatted text above this is kept as plain text instead. RTF with
        /// embedded images can be enormous for what looks like a short paste.
        static let maxBytes = 8 * 1024 * 1024

        var plainText: String
        var byteCount: Int
        /// UTI of the stored payload: "public.rtf" or "public.html".
        var typeIdentifier: String

        init(plainText: String, byteCount: Int, typeIdentifier: String) {
            self.plainText = plainText
            self.byteCount = byteCount
            self.typeIdentifier = typeIdentifier
        }

        // Decoded with the count clamped: this can arrive in a portable backup
        // from anyone, and an absurd value overflows the byte-budget arithmetic
        // or evicts the entire history on the next copy.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            plainText = try c.decode(String.self, forKey: .plainText)
            byteCount = min(max(0, try c.decode(Int.self, forKey: .byteCount)), Self.maxBytes)
            typeIdentifier = try c.decode(String.self, forKey: .typeIdentifier)
        }
    }

    struct ImageInfo: Codable, Equatable {
        /// Images larger than this are skipped rather than stored. Even with
        /// per-item files, an unbounded payload is a way to fill someone's disk.
        static let maxBytes = 32 * 1024 * 1024
        /// Decoded pixels, checked against the *declared* size before anything
        /// is decoded. A sub-megabyte compressed file can declare 50000x50000
        /// and the decoder would allocate the 10 GB raster on its word. 64 MP is
        /// three times a 6K display.
        static let maxPixels = 64_000_000

        var pixelWidth: Int
        var pixelHeight: Int
        var byteCount: Int
        /// UTI of the stored payload, e.g. "public.png".
        var typeIdentifier: String

        init(pixelWidth: Int, pixelHeight: Int, byteCount: Int, typeIdentifier: String) {
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
            self.byteCount = byteCount
            self.typeIdentifier = typeIdentifier
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            pixelWidth = max(0, try c.decode(Int.self, forKey: .pixelWidth))
            pixelHeight = max(0, try c.decode(Int.self, forKey: .pixelHeight))
            byteCount = min(max(0, try c.decode(Int.self, forKey: .byteCount)), Self.maxBytes)
            typeIdentifier = try c.decode(String.self, forKey: .typeIdentifier)
        }
    }

    struct FileRef: Codable, Equatable {
        var path: String

        /// Derived from the path, never stored.
        ///
        /// A stored label would be a second source of truth for the same fact,
        /// and an imported backup sets the two independently: a row could read
        /// "invoice.pdf" while pasting ~/.ssh/id_rsa. Deriving it removes the
        /// possibility rather than validating against it.
        var name: String { (path as NSString).lastPathComponent }

        init(path: String) {
            self.path = path
        }
    }
}

struct ClipboardItem: Codable, Identifiable, Equatable {
    let id: UUID
    /// When this was last copied. Re-copying refreshes it, so the order of the
    /// list and the time sections it is grouped into agree.
    var createdAt: Date
    var isPinned: Bool = false
    var content: ClipboardContent
    /// Bundle identifier of whichever app was frontmost when this was copied.
    /// Nil for items saved before attribution existed, and for a copy made while
    /// no application was frontmost.
    var sourceBundleID: String?

    /// Drives search, autocomplete and the row label.
    var searchText: String {
        switch content {
        case .text(let value):
            return value
        case .richText(let info):
            return info.plainText
        case .image(let info):
            return "Image \(info.pixelWidth)×\(info.pixelHeight)"
        case .files(let refs):
            return refs.map(\.name).joined(separator: ", ")
        }
    }

    /// Bytes this item costs on disk outside the index.
    var payloadByteCount: Int {
        switch content {
        case .image(let info): return info.byteCount
        case .richText(let info): return info.byteCount
        case .text, .files: return 0
        }
    }

    var hasPayloadFile: Bool { payloadByteCount > 0 }
}

extension Array where Element == ClipboardItem {
    /// Keeps the first item with each id. Views index rows by id, and the ids
    /// come out of a file, so they are unique only if something makes them so.
    func removingDuplicateIDs() -> [ClipboardItem] {
        var seen = Set<UUID>()
        return filter { seen.insert($0.id).inserted }
    }
}

extension ClipboardItem {
    enum CodingKeys: String, CodingKey {
        case id, createdAt, isPinned, content, sourceBundleID
        /// Schema 3 and earlier stored the text inline under this key.
        case text
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        // Items saved before pinning existed have no isPinned key.
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        sourceBundleID = try c.decodeIfPresent(String.self, forKey: .sourceBundleID)
        if let content = try c.decodeIfPresent(ClipboardContent.self, forKey: .content) {
            self.content = content
        } else {
            self.content = .text(try c.decode(String.self, forKey: .text))
        }
    }

    // Written explicitly because the legacy `text` key has no stored property,
    // which blocks synthesis.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(isPinned, forKey: .isPinned)
        try c.encode(content, forKey: .content)
        try c.encodeIfPresent(sourceBundleID, forKey: .sourceBundleID)
    }
}

extension ClipboardItem {
    init(id: UUID = UUID(), text: String, createdAt: Date = Date(), isPinned: Bool = false) {
        self.init(id: id, createdAt: createdAt, isPinned: isPinned,
                  content: .text(text), sourceBundleID: nil)
    }
}

struct ClipboardBinding: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var content: String
    var isShell: Bool
}

struct CommandItem: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var content: String
    var isShell: Bool
}

struct CommandFolder: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var items: [CommandItem]
}

enum BackupMode: String, Codable {
    case keychain
    case password
}

enum ThemeMode: String, Codable, CaseIterable {
    case system
    case light
    case dark
}

/// A key with modifiers, stored as Carbon's key code and modifier mask so one
/// value drives both RegisterEventHotKey and the in-panel key handler.
///
/// The modifier bits are spelled out here so this file stays free of AppKit
/// and the type can be tested without it.
struct KeyCombo: Codable, Equatable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let command: UInt32 = 0x0100
    static let shift: UInt32 = 0x0200
    static let option: UInt32 = 0x0800
    static let control: UInt32 = 0x1000
    static let allModifiers = command | shift | option | control

    /// Control + Option + V. Not Shift + Command + V: that is Paste and Match
    /// Style in most editors, and a global hotkey would take it from all of them.
    static let defaultOpen = KeyCombo(keyCode: 9, modifiers: control | option)
    /// Command + comma, as every Mac app.
    static let defaultPreferences = KeyCombo(keyCode: 43, modifiers: command)

    var hasModifier: Bool { modifiers & Self.allModifiers != 0 }

    /// "Control + Option + V" -- words rather than glyphs, in the order the
    /// keys sit on the keyboard.
    func displayName(keyName: String) -> String {
        var parts: [String] = []
        if modifiers & Self.control != 0 { parts.append("Control") }
        if modifiers & Self.option != 0 { parts.append("Option") }
        if modifiers & Self.shift != 0 { parts.append("Shift") }
        if modifiers & Self.command != 0 { parts.append("Command") }
        parts.append(keyName)
        return parts.joined(separator: " + ")
    }
}

struct AppState: Codable {
    static let currentSchemaVersion = 4

    var schemaVersion: Int = AppState.currentSchemaVersion
    var items: [ClipboardItem]
    var bindings: [ClipboardBinding]
    var folders: [CommandFolder]
    var autoBackupEnabled: Bool
    var autoBackupMode: BackupMode
    var themeMode: ThemeMode
    var skipConcealedContent: Bool = true
    var ignoredAppBundleIDs: [String] = []
    var captureSuspended: Bool = false
    var openHotkey: KeyCombo = .defaultOpen
    var preferencesHotkey: KeyCombo = .defaultPreferences

    static let empty = AppState(
        items: [], bindings: [], folders: [],
        autoBackupEnabled: false, autoBackupMode: .keychain, themeMode: .system
    )
}

// Decoded field by field with defaults, in an extension so the memberwise init
// survives. Adding or removing a field in a future version must never make an
// existing file undecodable: a decode failure is indistinguishable from real
// corruption, and the recovery path for corruption is destructive.
extension AppState {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        items = try c.decodeIfPresent([ClipboardItem].self, forKey: .items) ?? []
        bindings = try c.decodeIfPresent([ClipboardBinding].self, forKey: .bindings) ?? []
        folders = try c.decodeIfPresent([CommandFolder].self, forKey: .folders) ?? []
        autoBackupEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoBackupEnabled) ?? false
        autoBackupMode = try c.decodeIfPresent(BackupMode.self, forKey: .autoBackupMode) ?? .keychain
        themeMode = try c.decodeIfPresent(ThemeMode.self, forKey: .themeMode) ?? .system
        // Defaults chosen so an existing vault upgrades into the safer behaviour.
        skipConcealedContent = try c.decodeIfPresent(Bool.self, forKey: .skipConcealedContent) ?? true
        ignoredAppBundleIDs = try c.decodeIfPresent([String].self, forKey: .ignoredAppBundleIDs) ?? []
        captureSuspended = try c.decodeIfPresent(Bool.self, forKey: .captureSuspended) ?? false
        openHotkey = try c.decodeIfPresent(KeyCombo.self, forKey: .openHotkey) ?? .defaultOpen
        preferencesHotkey = try c.decodeIfPresent(KeyCombo.self, forKey: .preferencesHotkey)
            ?? .defaultPreferences
    }
}

/// What a `.cvb` backup carries.
///
/// Payloads live in their own files in the vault, so a backup -- which is a
/// single portable file -- has to absorb them. Backups written before payloads
/// existed were a bare `AppState`; those still import.
struct VaultSnapshot: Codable {
    var state: AppState
    /// Item id, as a UUID string, to payload bytes.
    var payloads: [String: Data]
}
