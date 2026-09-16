import CryptoKit
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

    /// SHA-256 of a payload, hex-encoded lowercase.
    ///
    /// The index describes payloads it does not contain, and the description --
    /// size, byte count, type -- is not the picture. Two different screenshots of
    /// the same window compare equal on those fields alone, and the second one is
    /// then silently discarded as a re-copy of the first. This digest is what
    /// makes the difference representable, so it is computed once where the bytes
    /// are already in hand and stored alongside them.
    ///
    /// Not a security boundary and not a secret: a digest of the payload is no
    /// more revealing than the payload, which sits next to it in the same vault.
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

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
        /// SHA-256 of the RTF or HTML bytes. Nil for entries written before this
        /// field existed; see `==` for what that means.
        var contentHash: String?

        init(plainText: String, byteCount: Int, typeIdentifier: String,
             contentHash: String? = nil) {
            self.plainText = plainText
            self.byteCount = byteCount
            self.typeIdentifier = typeIdentifier
            self.contentHash = contentHash
        }

        // Decoded with the count clamped: this can arrive in a portable backup
        // from anyone, and an absurd value overflows the byte-budget arithmetic
        // or evicts the entire history on the next copy.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            plainText = try c.decode(String.self, forKey: .plainText)
            byteCount = min(max(0, try c.decode(Int.self, forKey: .byteCount)), Self.maxBytes)
            typeIdentifier = try c.decode(String.self, forKey: .typeIdentifier)
            // A vault written by 0.1.0 has no such key, and failing to decode it
            // would be indistinguishable from corruption.
            contentHash = try c.decodeIfPresent(String.self, forKey: .contentHash)
        }

        /// Two formatted pastes are the same paste only if their bytes are.
        ///
        /// See `ImageInfo.==` for the whole argument; it applies here verbatim,
        /// weakened only by `plainText` already carrying some of the payload.
        static func == (lhs: Self, rhs: Self) -> Bool {
            guard lhs.plainText == rhs.plainText,
                  lhs.byteCount == rhs.byteCount,
                  lhs.typeIdentifier == rhs.typeIdentifier
            else { return false }
            guard let left = lhs.contentHash, let right = rhs.contentHash else { return true }
            return left == right
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
        /// SHA-256 of the image bytes. Nil for entries written before this field
        /// existed; see `==` for what that means.
        var contentHash: String?

        init(pixelWidth: Int, pixelHeight: Int, byteCount: Int, typeIdentifier: String,
             contentHash: String? = nil) {
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
            self.byteCount = byteCount
            self.typeIdentifier = typeIdentifier
            self.contentHash = contentHash
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            pixelWidth = max(0, try c.decode(Int.self, forKey: .pixelWidth))
            pixelHeight = max(0, try c.decode(Int.self, forKey: .pixelHeight))
            byteCount = min(max(0, try c.decode(Int.self, forKey: .byteCount)), Self.maxBytes)
            typeIdentifier = try c.decode(String.self, forKey: .typeIdentifier)
            // A vault written by 0.1.0 has no such key. Every field added after
            // release is optional with a default, because a decode failure is
            // indistinguishable from corruption and the recovery path for
            // corruption is destructive.
            contentHash = try c.decodeIfPresent(String.self, forKey: .contentHash)
        }

        /// Two pictures are the same picture only if their bytes are.
        ///
        /// Written by hand rather than synthesised, because the rule is
        /// deliberately asymmetric in the hash:
        ///
        /// - both sides carry a hash: equal only if the hashes agree. Width,
        ///   height, byte count and type say nothing about the pixels, so two
        ///   different screenshots of the same window used to compare equal and
        ///   the newer one was silently dropped as a re-copy of the older.
        /// - either side is missing a hash: compare exactly the fields 0.1.0
        ///   compared, and nothing more. Entries already in a vault have no hash
        ///   and are never given one -- doing that would mean decrypting every
        ///   payload file at launch, which is the cost the per-item payload
        ///   layout exists to avoid. Without this fallback, re-copying a picture
        ///   that is already in the history would append a second entry for it
        ///   after the upgrade, for every image the user had.
        ///
        /// The fallback makes `==` intransitive between a hashless entry and two
        /// differently-hashed ones. That is accepted knowingly: the only caller
        /// is the linear "have we already got this?" scan in `HistoryPolicy`,
        /// which asks the question pairwise and never relies on transitivity, and
        /// neither this type nor its containers are `Hashable` or used as a set
        /// element or dictionary key.
        static func == (lhs: Self, rhs: Self) -> Bool {
            guard lhs.pixelWidth == rhs.pixelWidth,
                  lhs.pixelHeight == rhs.pixelHeight,
                  lhs.byteCount == rhs.byteCount,
                  lhs.typeIdentifier == rhs.typeIdentifier
            else { return false }
            guard let left = lhs.contentHash, let right = rhs.contentHash else { return true }
            return left == right
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

extension Array where Element: Identifiable {
    /// Keeps the first element with each id. Views index rows by id, and the
    /// ids come out of a file, so they are unique only if something makes them
    /// so: `ForEach` renders undefined output on a repeat, and the row map in
    /// the history panel used to trap outright.
    func removingDuplicateIDs() -> [Element] {
        var seen = Set<Element.ID>()
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
    /// Whether choosing an entry also presses Command + V for the user. Off
    /// until they say otherwise: it is the one feature that needs Accessibility
    /// access, and granting that to a clipboard manager is a decision the user
    /// makes, never one a default or a file makes for them.
    var pasteDirectly: Bool = false

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
        // A vault written by 0.1.0 has no such key, and its absence has to mean
        // off -- anything else would turn on keystroke synthesis for everyone
        // who upgrades, which is the opposite of a choice.
        pasteDirectly = try c.decodeIfPresent(Bool.self, forKey: .pasteDirectly) ?? false
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
