import Foundation

// The rules that decide what is captured and what the history holds.
// Kept apart from ClipboardMonitor because these are pure functions that a
// test can call directly, where the monitor needs a real pasteboard.

// MARK: - History Policy

/// The rules for maintaining the history list. Pure, so they can be tested
/// without constructing a store (which would reach for the Keychain).
enum HistoryPolicy {
    /// Re-copying something already in history moves it back to the top rather
    /// than adding a duplicate, and stamps it with the new time: the list is in
    /// recency order, and an entry at the top dated last week would be filed
    /// under "Older" while sitting above things copied a minute ago. Dedup
    /// previously compared only against the newest entry, so copying A, B, A
    /// left three entries.
    static func inserting(_ content: ClipboardContent,
                          into items: [ClipboardItem],
                          maxItems: Int,
                          maxPayloadBytes: Int = .max,
                          id: UUID = UUID(),
                          now: Date = Date(),
                          source: String? = nil) -> [ClipboardItem] {
        var items = items
        if let existing = items.firstIndex(where: { $0.content == content }) {
            var item = items.remove(at: existing)
            item.createdAt = now
            items.insert(item, at: 0)
            return items
        }
        items.insert(ClipboardItem(id: id, createdAt: now, isPinned: false,
                                   content: content, sourceBundleID: source),
                     at: 0)
        // `keeping:` is the whole reason a copy cannot be lost to a full vault.
        // See `trimmed`.
        return trimmed(items, maxItems: maxItems, maxPayloadBytes: maxPayloadBytes, keeping: id)
    }

    static func inserting(_ text: String,
                          into items: [ClipboardItem],
                          maxItems: Int,
                          maxPayloadBytes: Int = .max,
                          id: UUID = UUID(),
                          now: Date = Date()) -> [ClipboardItem] {
        inserting(.text(text), into: items, maxItems: maxItems,
                  maxPayloadBytes: maxPayloadBytes, id: id, now: now)
    }

    /// Pinned items are exempt from both caps -- pinning is a promise to keep it.
    ///
    /// The byte budget exists because image payloads are unbounded in a way text
    /// never was: a count-based cap alone would happily hold 200 screenshots.
    ///
    /// `keeping` names one entry that may not be evicted, and `inserting` passes
    /// the entry it has just added. Without it the pin exemption eats the newest
    /// copy: in a vault already at the cap with every other row pinned, the entry
    /// that went in at index 0 is the only eviction candidate there is, so it is
    /// removed, the array comes back exactly as it went in, and `add` returns
    /// having recorded nothing -- for that copy and every copy after it, silently.
    /// A backup of 201 pinned entries was enough to arrange that; so was pinning
    /// 200 rows by hand.
    ///
    /// Keeping it cannot make the history grow without bound. At most one
    /// unevictable non-pinned row exists at a time: the next copy protects
    /// *itself* instead, which makes its predecessor an ordinary candidate
    /// again. So a vault whose pinned rows already fill the cap settles at one
    /// row above it rather than climbing.
    static func trimmed(_ items: [ClipboardItem],
                        maxItems: Int,
                        maxPayloadBytes: Int = .max,
                        keeping protected: UUID? = nil) -> [ClipboardItem] {
        var items = items
        var payloadBytes = items.reduce(0) { $0 + $1.payloadByteCount }

        while items.count > maxItems || payloadBytes > maxPayloadBytes {
            guard let index = items.lastIndex(where: { !$0.isPinned && $0.id != protected })
            else { break }
            payloadBytes -= items[index].payloadByteCount
            items.remove(at: index)
        }
        return items
    }

    /// Display order: pinned first, each group keeping its recency order.
    static func displayOrder(_ items: [ClipboardItem]) -> [ClipboardItem] {
        items.filter(\.isPinned) + items.filter { !$0.isPinned }
    }
}

// MARK: - Capture Policy

/// Decides whether a pasteboard change should be recorded. Kept pure -- no
/// NSPasteboard, no app state -- so the rules can be tested directly.
enum CapturePolicy {
    /// Markers from the nspasteboard.org convention that apps set to say
    /// "do not record this". Password managers set ConcealedType when you copy
    /// a credential; without honouring it, a clipboard manager quietly becomes
    /// a plaintext-ish log of every password the user copies.
    static let concealedMarkers: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
        // Older marker still set by some password managers.
        "com.agilebits.onepassword"
    ]

    static func shouldCapture(
        types: [String],
        sourceBundleID: String?,
        ignoredBundleIDs: Set<String>,
        skipConcealed: Bool
    ) -> Bool {
        if skipConcealed, types.contains(where: { concealedMarkers.contains($0) }) {
            return false
        }
        if let sourceBundleID, ignoredBundleIDs.contains(sourceBundleID) {
            return false
        }
        return true
    }

    /// How many pasteboard writes happened between two observations of
    /// `NSPasteboard.changeCount` that the poll never got to read.
    ///
    /// The counter advances once per write, so a poll that finds it three higher
    /// than it left it knows two items came and went. Their content is gone --
    /// the pasteboard holds only the last of them -- so this cannot recover
    /// anything; it exists so the condition is countable rather than invisible.
    ///
    /// A delta of one is the ordinary case and means nothing was missed, which
    /// is the off-by-one this function exists to hold still. A delta of zero or
    /// less is not a miss either: the counter is per boot and resets when the
    /// pasteboard server restarts, and a reset tells us nothing about how many
    /// writes preceded it, so the honest answer is zero rather than a negative
    /// number.
    static func missedChanges(previousCount: Int, currentCount: Int) -> Int {
        let (delta, overflow) = currentCount.subtractingReportingOverflow(previousCount)
        guard !overflow, delta > 1 else { return 0 }
        return delta - 1
    }
}

// MARK: - Polling Policy

/// How often the pasteboard is polled. macOS has no notification for pasteboard
/// changes, so polling is the only mechanism; what this decides is the rate.
///
/// **Read this before widening an interval to save wakeups.** The interval
/// is not only a latency; it is the width of a window in which a copied item is
/// lost outright. `NSPasteboard.changeCount` says only *that* the pasteboard
/// changed, never what it held in between, and the poll is the only thing that
/// reads it. So if the user copies A and then copies B before the next poll
/// fires, that poll finds the counter two higher and the pasteboard holding B.
/// A is gone, permanently and with no trace. Whatever number stands in `idle`
/// is exactly how long that window is.
///
/// Two rates, not a ramp. A ramp would be more code and more test surface for
/// nothing the user can perceive: the whole span it would interpolate across is
/// already under the time it takes a person to copy something and reach for the
/// panel.
enum PollingPolicy {
    /// The rate while the user is plainly copying things. This is what the
    /// monitor did at every moment before back-off existed, and nobody has
    /// reported a missed or late capture at it, so it is left alone.
    static let active: TimeInterval = 0.6

    /// The rate at rest, and therefore the width of the loss window described
    /// above. One second, and `idleCeiling` holds it there.
    ///
    /// This was 2.5 s, chosen as the largest delay that is still invisible --
    /// which was the wrong question. A delay nobody can see is not the same as a
    /// delay nobody is harmed by: at 2.5 s, two copies 1.5 s apart from an idle
    /// Mac lost the first one outright for 40 per cent of the poll phases, and
    /// measuring it that way found 3 losses in 11 trials. The first copy after
    /// sitting down at the machine is exactly the one most at risk, because that
    /// is when the poll is guaranteed to be at its slowest.
    ///
    /// One second is under the gap in a real two-copy burst -- select, copy,
    /// move, select, copy is well over a second even by keyboard -- so the two
    /// cannot collide. 1.2 s would also clear the 1.5 s burst measured here, but
    /// only by 0.3 s, and the burst is a human rhythm rather than a constant.
    /// The wakeup saving is what is traded away and it is still most of the
    /// prize: 100 a minute at `active`, 60 at this rate, 24 at the old 2.5 s. A
    /// 40 per cent cut in idle wakeups is worth having; it is not worth silently
    /// dropping what somebody copied.
    static let idle: TimeInterval = 1.0

    /// The highest `idle` may ever be, pinned by a test.
    ///
    /// The ceiling is here because the pressure on this number only ever points
    /// one way: every future look at the poll will be someone counting wakeups,
    /// and raising `idle` is the cheapest way to reduce them. What that person
    /// will not see in a wakeup graph is the item the app threw away. Raising
    /// this constant widens the window in which a copied item is lost with no
    /// trace, in an app whose entire promise is that it does not lose what you
    /// copied. If a future change genuinely needs a slower rate at rest, it
    /// needs a mechanism that closes the window -- reading the pasteboard on
    /// some signal other than the poll -- not a larger number here.
    static let idleCeiling: TimeInterval = 1.2

    /// How long after the last change the poll stays at its quickest. Fifteen
    /// seconds covers a normal copy-paste-copy rhythm without holding the fast
    /// rate open on a Mac whose owner has walked away.
    static let activeWindow: TimeInterval = 15

    /// The polling interval for a pasteboard last changed `sinceLastChange`
    /// seconds ago.
    ///
    /// The boundary falls on the idle side: exactly at `activeWindow` the
    /// window has elapsed. A negative argument -- the wall clock moving
    /// backwards under an NTP correction or a timezone change -- reads as
    /// "changed even more recently than now" and yields the active rate, which
    /// is the safe direction: the worst case is a few seconds of quick polling,
    /// where treating it as idle could delay a capture the user is waiting for.
    /// The result is always one of the two constants, so it can never fall
    /// outside `active...idle`.
    static func interval(sinceLastChange: TimeInterval) -> TimeInterval {
        sinceLastChange < activeWindow ? active : idle
    }
}
