import Foundation
import AppKit

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
    static let maxRichTextBytes = ClipboardContent.RichTextInfo.maxBytes

    /// Plain text above this is not recorded. Text lives inline in the index,
    /// which is re-encrypted and rewritten on every copy, so one pasted log file
    /// would tax every copy after it until 200 more pushed it out.
    static let maxTextBytes = 2 * 1024 * 1024

    private var timer: Timer?
    private var lastChangeCount: Int = NSPasteboard.general.changeCount
    var onNewContent: ((CapturedItem) -> Void)?

    var isPaused = false
    var skipConcealed = true
    var ignoredBundleIDs: Set<String> = []

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            self?.checkPasteboard()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func checkPasteboard() {
        let pb = NSPasteboard.general
        // Always advance the change count, even when skipping, so a skipped item
        // is not re-examined on the next tick.
        if pb.changeCount == lastChangeCount { return }
        lastChangeCount = pb.changeCount

        if isPaused { return }

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
                NSLog("Clipvelope: skipped a \(string.utf8.count)-byte text, over the \(maxTextBytes)-byte limit")
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

        let candidates: [(NSPasteboard.PasteboardType, String)] = [
            (.rtf, "public.rtf"),
            (.html, "public.html"),
        ]
        for (type, identifier) in candidates {
            guard let data = pb.data(forType: type), !data.isEmpty else { continue }
            guard data.count <= maxRichTextBytes else {
                NSLog("Clipvelope: \(data.count)-byte \(identifier) is over the limit, keeping plain text")
                return nil
            }
            return .richText(data: data, plainText: plain, typeIdentifier: identifier)
        }
        return nil
    }

    private static func readImage(from pb: NSPasteboard) -> CapturedPayload? {
        // Prefer PNG. TIFF off the pasteboard is uncompressed and routinely an
        // order of magnitude larger for the same picture.
        let data: Data
        if let png = pb.data(forType: .png) {
            data = png
        } else if let tiff = pb.data(forType: .tiff),
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) {
            data = png
        } else {
            return nil
        }

        guard data.count <= maxImageBytes else {
            NSLog("Clipvelope: skipped a \(data.count)-byte image, over the \(maxImageBytes)-byte limit")
            return nil
        }
        guard let rep = NSBitmapImageRep(data: data) else { return nil }

        return .image(data: data,
                      typeIdentifier: "public.png",
                      pixelWidth: rep.pixelsWide,
                      pixelHeight: rep.pixelsHigh)
    }
}
