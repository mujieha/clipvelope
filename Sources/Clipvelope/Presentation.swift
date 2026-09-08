import Foundation

// How the history is shown, as opposed to what it holds. Pure functions, so
// the layout rules can be tested without a view.

// MARK: - Preview text

/// The one-glance rendering of a copied string.
///
/// Copied code arrives with its indentation and blank lines, and a row that
/// honours them is as tall as the source made it. Collapsing whitespace lets the
/// panel decide the row height; the line count keeps the shape of the original
/// visible.
enum PreviewText {
    struct Summary: Equatable {
        let text: String
        /// Lines with something on them. Blank lines are not information.
        let lineCount: Int
    }

    static func summary(of raw: String, maxCharacters: Int = 240) -> Summary {
        let lineCount = raw.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
            .filter { $0.contains(where: { !$0.isWhitespace }) }
            .count
        let collapsed = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let text = collapsed.count > maxCharacters
            ? String(collapsed.prefix(maxCharacters)) + "…"
            : collapsed
        return Summary(text: text, lineCount: lineCount)
    }
}

// MARK: - Time sections

/// Where an entry sits in the ledger. The history is a sequence in time, and
/// a user looking for "the thing from this morning" navigates by that, not by
/// position.
enum HistorySection: CaseIterable, Hashable {
    case pinned
    case lastHour
    case today
    case yesterday
    case thisWeek
    case older

    var title: String {
        switch self {
        case .pinned: return "Pinned"
        case .lastHour: return "Last hour"
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .thisWeek: return "This week"
        case .older: return "Older"
        }
    }

    struct Group: Equatable {
        let section: HistorySection
        let items: [ClipboardItem]
    }

    static func section(for item: ClipboardItem, now: Date, calendar: Calendar) -> HistorySection {
        if item.isPinned { return .pinned }
        if now.timeIntervalSince(item.createdAt) < 3600 { return .lastHour }
        if calendar.isDate(item.createdAt, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(item.createdAt, inSameDayAs: yesterday) {
            return .yesterday
        }
        if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now),
           item.createdAt > weekAgo {
            return .thisWeek
        }
        return .older
    }

    /// Groups in display order, each keeping the order it was given, empty
    /// groups omitted. Pinned entries come first however old they are.
    static func grouped(_ items: [ClipboardItem],
                        now: Date = Date(),
                        calendar: Calendar = .current) -> [Group] {
        var buckets: [HistorySection: [ClipboardItem]] = [:]
        for item in items {
            buckets[section(for: item, now: now, calendar: calendar), default: []].append(item)
        }
        return HistorySection.allCases.compactMap { section in
            guard let members = buckets[section], !members.isEmpty else { return nil }
            return Group(section: section, items: members)
        }
    }
}

// MARK: - Panel behaviour

/// What the history panel does with the search field and the keys, kept out of
/// the view so it can be tested. The view holds one of these as its state.
struct PanelModel: Equatable {
    /// The panel is a menu, not a browser; past this the search field is the tool.
    static let maxVisibleRows = 50

    var query = ""
    /// Index into `visibleItems`. Return copies this row.
    var selection = 0

    enum EscapeOutcome: Equatable {
        case clearedSearch
        case close
    }

    func matches(in items: [ClipboardItem]) -> [ClipboardItem] {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return items }
        let q = query.lowercased()
        return items.filter { $0.searchText.lowercased().contains(q) }
    }

    /// Rows in the order they are drawn: pinned first, then by time section.
    /// Everything positional -- ⌘-numbers, the selection -- derives from this.
    func groups(in items: [ClipboardItem],
                now: Date = Date(),
                calendar: Calendar = .current) -> [HistorySection.Group] {
        let shown = Array(HistoryPolicy.displayOrder(matches(in: items)).prefix(Self.maxVisibleRows))
        return HistorySection.grouped(shown, now: now, calendar: calendar)
    }

    func visibleItems(in items: [ClipboardItem],
                      now: Date = Date(),
                      calendar: Calendar = .current) -> [ClipboardItem] {
        groups(in: items, now: now, calendar: calendar).flatMap(\.items)
    }

    func selectedItem(in items: [ClipboardItem],
                      now: Date = Date(),
                      calendar: Calendar = .current) -> ClipboardItem? {
        let visible = visibleItems(in: items, now: now, calendar: calendar)
        return visible.indices.contains(selection) ? visible[selection] : nil
    }

    /// Completes the search from the newest text entry that starts with it.
    /// Only text entries: an image cannot be typed into a search field.
    func suggestion(in items: [ClipboardItem]) -> String? {
        guard !query.isEmpty else { return nil }
        let q = query.lowercased()
        return items.first { item in
            guard case .text(let value) = item.content else { return false }
            return value.lowercased().hasPrefix(q)
        }?.searchText
    }

    /// A new search starts from the top: the old selection pointed at a row
    /// that may no longer be shown.
    mutating func setQuery(_ newQuery: String) {
        query = newQuery
        selection = 0
    }

    mutating func move(_ delta: Int, rowCount: Int) {
        guard rowCount > 0 else { selection = 0; return }
        selection = min(max(selection + delta, 0), rowCount - 1)
    }

    /// Escape backs out one level: first the search, then the panel.
    mutating func escape() -> EscapeOutcome {
        if query.isEmpty { return .close }
        setQuery("")
        return .clearedSearch
    }
}

// MARK: - State strip

/// The one line under the list that says what the vault is doing. Degraded
/// states are the ones the user chose or suffered and might have forgotten.
struct StripContent: Equatable {
    let symbol: String
    let text: String
    let degraded: Bool

    static func describe(isLoading: Bool,
                         savingPaused: Bool,
                         capturePaused: Bool,
                         recordingPasswords: Bool,
                         itemCount: Int,
                         notice: String?) -> StripContent {
        if isLoading {
            return StripContent(symbol: "lock.fill", text: "Opening vault…", degraded: false)
        }
        if let notice {
            return StripContent(symbol: "exclamationmark.circle.fill", text: notice, degraded: true)
        }
        if savingPaused {
            return StripContent(symbol: "exclamationmark.triangle.fill",
                                text: "Saving paused.", degraded: true)
        }
        var parts: [String] = []
        if capturePaused { parts.append("Capture paused.") }
        if recordingPasswords { parts.append("Recording passwords.") }
        if !parts.isEmpty {
            return StripContent(symbol: capturePaused ? "pause.circle.fill" : "exclamationmark.shield.fill",
                                text: parts.joined(separator: " "), degraded: true)
        }
        let text: String
        switch itemCount {
        case 0: text = "Empty vault, encrypted on this Mac."
        case 1: text = "1 item, encrypted on this Mac."
        default: text = "\(itemCount) items, encrypted on this Mac."
        }
        return StripContent(symbol: "lock.fill", text: text, degraded: false)
    }
}
