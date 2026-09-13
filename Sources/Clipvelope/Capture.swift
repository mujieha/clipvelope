import Foundation
import AppKit
import ImageIO

enum AppNameResolver {
    private static var nameCache: [String: String] = [:]
    private static var iconCache: [String: NSImage?] = [:]

    static func displayName(forBundleID id: String) -> String {
        if let cached = nameCache[id] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
            nameCache[id] = id
            return id
        }
        let name = FileManager.default.displayName(atPath: url.path)
        nameCache[id] = name
        return name
    }

    /// Small icon for a history row. Cached because the list re-renders on every
    /// keystroke in the search field and this hits the filesystem.
    static func icon(forBundleID id: String) -> NSImage? {
        if let cached = iconCache[id] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        icon?.size = NSSize(width: 16, height: 16)
        iconCache[id] = icon
        return icon
    }
}

// MARK: - Clipboard Monitor

/// What was read off the pasteboard, before it becomes a history item.
enum CapturedPayload {
    case text(String)
    case richText(data: Data, plainText: String, typeIdentifier: String)
    case image(data: Data, typeIdentifier: String, pixelWidth: Int, pixelHeight: Int)
    case files([URL])
}

/// A pasteboard change, with the app that was frontmost when it happened.
struct CapturedItem {
    let payload: CapturedPayload
    let sourceBundleID: String?
}

final class ClipboardMonitor {
    static let maxImageBytes = ClipboardContent.ImageInfo.maxBytes
    static let maxImagePixels = ClipboardContent.ImageInfo.maxPixels
    static let maxRichTextBytes = ClipboardContent.RichTextInfo.maxBytes
    static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// Plain text above this is not recorded. Text lives inline in the index,
    /// which is re-encrypted and rewritten on every copy, so one pasted log file
    /// would tax every copy after it until 200 more pushed it out.
    static let maxTextBytes = 2 * 1024 * 1024

    private var timer: Timer?
    /// The interval the installed timer was built with, so a tick can tell
    /// whether the rate the policy now asks for is a different one.
    private var scheduledInterval: TimeInterval?
    private var lastChangeCount: Int = NSPasteboard.general.changeCount
    /// When the pasteboard last actually changed, which is what the back-off
    /// schedule is a function of.
    private var lastChangeAt = Date()
    var onNewContent: ((CapturedItem) -> Void)?

    /// Pausing keeps polling and keeps advancing `lastChangeCount`, so that
    /// resuming does not capture whatever was copied while paused.
    ///
    /// It deliberately gets no third, slower rate of its own. The poll is the
    /// only thing that advances `lastChangeCount`, so the interval is exactly
    /// the width of the window in which something copied just before the user
    /// resumes is still unseen -- and therefore captured on resume, which is
    /// the one thing pausing promises not to do. Backing off further while
    /// paused would widen that window to buy wakeups back only while the
    /// feature is switched off.
    var isPaused = false
    var skipConcealed = true
    var ignoredBundleIDs: Set<String> = []

    func start() {
        guard timer == nil else { return }
        // Start in the active window: the app has just launched, the user is at
        // the machine, and the first seconds are when a capture is most likely
        // to be waited on.
        lastChangeAt = Date()
        schedule(interval: PollingPolicy.interval(sinceLastChange: 0))
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        scheduledInterval = nil
    }

    /// Installs the repeating poll at `interval`, replacing whatever was there.
    /// The one place a timer is created, so `start()` and the back-off path
    /// cannot disagree or leave two of them running.
    private func schedule(interval: TimeInterval) {
        timer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // .common so the poll keeps firing while a menu is tracking; in the
        // default mode alone, opening the menu bar item would stop capture.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        scheduledInterval = interval
    }

    /// Poll, then re-rate. Rescheduling rather than deciding to do nothing on
    /// each tick is the whole point: a 0.6 s timer that wakes up to skip its own
    /// body is exactly the wakeup the back-off is meant to remove.
    private func tick() {
        checkPasteboard()
        // checkPasteboard can reach the app through onNewContent, which may have
        // stopped the monitor; do not resurrect a timer it just invalidated.
        guard timer != nil else { return }

        let wanted = PollingPolicy.interval(sinceLastChange: Date().timeIntervalSince(lastChangeAt))
        if wanted != scheduledInterval {
            schedule(interval: wanted)
        }
    }

    private func checkPasteboard() {
        let pb = NSPasteboard.general
        // Always advance the change count, even when skipping, so a skipped item
        // is not re-examined on the next tick.
        if pb.changeCount == lastChangeCount { return }
        // Counted before lastChangeCount moves. The counter advances once per
        // write, so a jump of more than one says the pasteboard was overwritten
        // between polls and those items are unrecoverable -- they are not on the
        // pasteboard any more. Logged rather than shown: telling someone they
        // lost a copy they cannot get back is noise, not truth-telling, but
        // leaving the condition entirely invisible is how a 2.5 s idle rate
        // survived a release.
        let missed = CapturePolicy.missedChanges(previousCount: lastChangeCount,
                                                 currentCount: pb.changeCount)
        lastChangeCount = pb.changeCount
        // Stamped before the pause check, and before any policy or size rule can
        // refuse the item: the schedule is a function of pasteboard activity,
        // not of what was kept. Somebody copying passwords is at the keyboard.
        //
        // This is also the whole of the monitor's response to `missed`, and it
        // is why no extra one is needed: any observed change already drops the
        // rate back to `active`, so a burst is polled quickly from its second
        // item on whether or not the first was missed.
        lastChangeAt = Date()

        if isPaused { return }

        if missed > 0 {
            NSLog("%@", "Clipvelope: the pasteboard changed \(missed + 1) times between two polls; \(missed) item(s) were overwritten before they could be read. Idle poll is \(PollingPolicy.idle)s.")
        }

        let types = (pb.types ?? []).map(\.rawValue)
        // The pasteboard does not record who wrote to it; the frontmost app at
        // the moment of the change is the standard approximation.
        let source = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        guard CapturePolicy.shouldCapture(
            types: types,
            sourceBundleID: source,
            ignoredBundleIDs: ignoredBundleIDs,
            skipConcealed: skipConcealed
        ) else { return }

        if let payload = Self.readPayload(from: pb) {
            onNewContent?(CapturedItem(payload: payload, sourceBundleID: source))
        }
    }

    static func readPayload(from pb: NSPasteboard) -> CapturedPayload? {
        // Files first: copying a file in Finder also puts its name on as text,
        // so checking text first would record the name and lose the file.
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return .files(urls)
        }
        if let image = readImage(from: pb) {
            return image
        }
        // Rich text before plain: a styled paste offers both, and taking the
        // plain one throws the formatting away for good.
        if let rich = readRichText(from: pb) {
            return rich
        }
        if let string = pb.string(forType: .string), !string.isEmpty {
            guard string.utf8.count <= maxTextBytes else {
                NSLog("%@", "Clipvelope: skipped a \(string.utf8.count)-byte text, over the \(maxTextBytes)-byte limit")
                return nil
            }
            return .text(string)
        }
        return nil
    }

    private static func readRichText(from pb: NSPasteboard) -> CapturedPayload? {
        // Without a plain rendering there is nothing to search, display or paste
        // into a plain-text field, so plain text is a precondition, not a
        // fallback.
        guard let plain = pb.string(forType: .string), !plain.isEmpty else { return nil }
        // The plain rendering is stored inline in the index, exactly like plain
        // text, so it is subject to the same cap. Returning nil here falls
        // through to the plain-text branch, which refuses it for the same reason.
        guard plain.utf8.count <= maxTextBytes else {
            NSLog("%@", "Clipvelope: skipped a rich text whose \(plain.utf8.count)-byte plain rendering is over the \(maxTextBytes)-byte limit")
            return nil
        }

        let candidates: [(NSPasteboard.PasteboardType, String)] = [
            (.rtf, "public.rtf"),
            (.html, "public.html"),
        ]
        for (type, identifier) in candidates {
            guard let data = pb.data(forType: type), !data.isEmpty else { continue }
            guard data.count <= maxRichTextBytes else {
                NSLog("%@", "Clipvelope: \(data.count)-byte \(identifier) is over the limit, keeping plain text")
                return nil
            }
            return .richText(data: data, plainText: plain, typeIdentifier: identifier)
        }
        return nil
    }

    private static func readImage(from pb: NSPasteboard) -> CapturedPayload? {
        // Prefer PNG. TIFF off the pasteboard is uncompressed and routinely an
        // order of magnitude larger for the same picture.
        let raw: Data
        let isPNG: Bool
        if let png = pb.data(forType: .png) {
            (raw, isPNG) = (png, true)
        } else if let tiff = pb.data(forType: .tiff) {
            (raw, isPNG) = (tiff, false)
        } else {
            return nil
        }

        // Both limits are checked before a single pixel is decoded. The
        // pasteboard is writable by every process on the machine, and a decoder
        // allocates whatever raster the file's header declares.
        guard raw.count <= maxImageBytes else {
            NSLog("%@", "Clipvelope: skipped a \(raw.count)-byte image, over the \(maxImageBytes)-byte limit")
            return nil
        }
        guard let (width, height) = declaredPixelSize(of: raw) else { return nil }
        guard acceptsImage(pixelWidth: width, pixelHeight: height) else {
            NSLog("%@", "Clipvelope: skipped a \(width)x\(height) image, over the \(maxImagePixels)-pixel limit")
            return nil
        }

        let data: Data
        if isPNG {
            data = raw
        } else {
            guard let rep = NSBitmapImageRep(data: raw),
                  let png = rep.representation(using: .png, properties: [:]) else { return nil }
            guard png.count <= maxImageBytes else {
                NSLog("%@", "Clipvelope: skipped a \(png.count)-byte image, over the \(maxImageBytes)-byte limit")
                return nil
            }
            data = png
        }

        return .image(data: data,
                      typeIdentifier: "public.png",
                      pixelWidth: width,
                      pixelHeight: height)
    }

    /// Pure, so the ceiling can be tested without building a hostile file.
    static func acceptsImage(pixelWidth: Int, pixelHeight: Int) -> Bool {
        guard pixelWidth > 0, pixelHeight > 0 else { return false }
        let (pixels, overflow) = pixelWidth.multipliedReportingOverflow(by: pixelHeight)
        return !overflow && pixels <= maxImagePixels
    }

    /// The dimensions the file header claims, read without decoding the raster.
    static func declaredPixelSize(of data: Data) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }
}
