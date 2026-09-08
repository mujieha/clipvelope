import XCTest
import AppKit
import CryptoKit
@testable import Clipvelope

/// The core loop of the product, both directions, on a private pasteboard so
/// the test never touches the one every other app shares.
private struct TestKeyStore: KeyProviding {
    let key = SymmetricKey(data: Data(repeating: 7, count: 32))
    func getOrCreateKey() throws -> SymmetricKey { key }
}

private func pngData(width: Int, height: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    return rep.representation(using: .png, properties: [:])!
}

final class CaptureReadingTests: XCTestCase {
    private var pb: NSPasteboard!

    override func setUp() {
        pb = NSPasteboard(name: NSPasteboard.Name("clipvelope-test-\(UUID().uuidString)"))
        pb.clearContents()
    }

    override func tearDown() {
        pb.releaseGlobally()
    }

    func testPlainStringIsText() {
        pb.setString("hello", forType: .string)
        guard case .text(let s)? = ClipboardMonitor.readPayload(from: pb) else { return XCTFail() }
        XCTAssertEqual(s, "hello")
    }

    func testEmptyStringAndEmptyPasteboardAreNothing() {
        XCTAssertNil(ClipboardMonitor.readPayload(from: pb))
        pb.setString("", forType: .string)
        XCTAssertNil(ClipboardMonitor.readPayload(from: pb))
    }

    func testRTFWinsOverPlainTextAndKeepsThePlainRendering() {
        let rtf = Data("{\\rtf1 bold}".utf8)
        pb.setData(rtf, forType: .rtf)
        pb.setString("bold", forType: .string)
        guard case .richText(let data, let plain, let type)? = ClipboardMonitor.readPayload(from: pb)
        else { return XCTFail() }
        XCTAssertEqual(data, rtf)
        XCTAssertEqual(plain, "bold")
        XCTAssertEqual(type, "public.rtf")
    }

    func testHTMLIsRichTextWhenThereIsNoRTF() {
        pb.setData(Data("<b>x</b>".utf8), forType: .html)
        pb.setString("x", forType: .string)
        guard case .richText(_, _, let type)? = ClipboardMonitor.readPayload(from: pb) else { return XCTFail() }
        XCTAssertEqual(type, "public.html")
    }

    /// The pasteboard server derives a plain string from RTF on its own, so RTF
    /// alone still arrives with a plain rendering. The guard in readRichText is
    /// for a pasteboard that offers none, which a real one does not produce.
    func testRTFAloneStillComesWithAPlainRenderingFromThePasteboard() {
        pb.setData(Data("{\\rtf1 x}".utf8), forType: .rtf)
        guard case .richText(_, let plain, _)? = ClipboardMonitor.readPayload(from: pb) else { return XCTFail() }
        XCTAssertEqual(plain, "x")
    }

    func testOversizedRichTextFallsBackToPlainText() {
        pb.setData(Data(count: ClipboardMonitor.maxRichTextBytes + 1), forType: .rtf)
        pb.setString("plain", forType: .string)
        guard case .text(let s)? = ClipboardMonitor.readPayload(from: pb) else { return XCTFail() }
        XCTAssertEqual(s, "plain")
    }

    func testPNGIsAnImageWithItsDimensions() {
        pb.setData(pngData(width: 3, height: 2), forType: .png)
        guard case .image(_, let type, let w, let h)? = ClipboardMonitor.readPayload(from: pb)
        else { return XCTFail() }
        XCTAssertEqual([type, "\(w)x\(h)"], ["public.png", "3x2"])
    }

    func testTIFFIsConvertedToPNG() {
        let tiff = NSBitmapImageRep(data: pngData(width: 2, height: 2))!.tiffRepresentation!
        pb.setData(tiff, forType: .tiff)
        guard case .image(let data, let type, _, _)? = ClipboardMonitor.readPayload(from: pb)
        else { return XCTFail() }
        XCTAssertEqual(type, "public.png")
        XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "PNG signature")
    }

    func testImageWinsOverTextAndFilesWinOverBoth() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cv-\(UUID().uuidString).txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        pb.setData(pngData(width: 1, height: 1), forType: .png)
        pb.setString("caption", forType: .string)
        guard case .image? = ClipboardMonitor.readPayload(from: pb) else { return XCTFail("image first") }

        pb.clearContents()
        pb.writeObjects([file as NSURL])
        pb.setString(file.lastPathComponent, forType: .string)
        guard case .files(let urls)? = ClipboardMonitor.readPayload(from: pb) else { return XCTFail("files first") }
        XCTAssertEqual(urls.map(\.lastPathComponent), [file.lastPathComponent])
    }
}

final class StoreCopyingTests: XCTestCase {
    private var root: URL!
    private var pb: NSPasteboard!
    private var storage: EncryptedStorage!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("clipvelope-copy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        pb = NSPasteboard(name: NSPasteboard.Name("clipvelope-copy-\(UUID().uuidString)"))
        pb.clearContents()
        storage = EncryptedStorage(directory: root, keyStore: TestKeyStore())
    }

    override func tearDownWithError() throws {
        pb.releaseGlobally()
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore() -> ClipboardStore {
        let store = ClipboardStore(storage: storage, enableSystemIntegration: false, pasteboard: pb)
        settle(store)
        return store
    }

    private func settle(_ store: ClipboardStore, rounds: Int = 4) {
        for _ in 0..<rounds {
            store.drainPendingWork()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    func testCopyingTextPutsItOnThePasteboard() {
        let store = makeStore()
        store.add(text: "kubectl get pods")
        store.copyToPasteboard(store.items[0])
        settle(store)
        XCTAssertEqual(pb.string(forType: .string), "kubectl get pods")
    }

    func testCopyingRichTextRestoresBothRenderings() {
        let store = makeStore()
        let rtf = Data("{\\rtf1 hello}".utf8)
        store.add(.richText(data: rtf, plainText: "hello", typeIdentifier: "public.rtf"))
        settle(store)
        store.copyToPasteboard(store.items[0])
        settle(store)
        XCTAssertEqual(pb.data(forType: .rtf), rtf)
        XCTAssertEqual(pb.string(forType: .string), "hello")
        XCTAssertNil(store.notice)
    }

    func testRichTextWithAMissingPayloadFallsBackToPlainTextAndSaysSo() {
        let store = makeStore()
        store.add(.richText(data: Data("{\\rtf1 hi}".utf8), plainText: "hi", typeIdentifier: "public.rtf"))
        settle(store)
        storage.deletePayload(for: store.items[0].id)
        store.copyToPasteboard(store.items[0])
        settle(store)
        XCTAssertEqual(pb.string(forType: .string), "hi")
        XCTAssertNil(pb.data(forType: .rtf))
        XCTAssertNotNil(store.notice)
    }

    func testCopyingAnImageWritesPNG() {
        let store = makeStore()
        let png = pngData(width: 2, height: 2)
        store.add(.image(data: png, typeIdentifier: "public.png", pixelWidth: 2, pixelHeight: 2))
        settle(store)
        store.copyToPasteboard(store.items[0])
        settle(store)
        XCTAssertEqual(pb.data(forType: .png), png)
    }

    func testAnImageWhosePayloadIsMissingIsRemovedWithANotice() {
        let store = makeStore()
        store.add(.image(data: pngData(width: 2, height: 2), typeIdentifier: "public.png",
                         pixelWidth: 2, pixelHeight: 2))
        store.add(text: "keep me")
        settle(store)
        let image = store.items[1]
        storage.deletePayload(for: image.id)

        store.copyToPasteboard(image)
        settle(store)

        XCTAssertEqual(store.items.map(\.searchText), ["keep me"], "the dead row is gone")
        XCTAssertNil(pb.data(forType: .png), "nothing was copied")
        XCTAssertEqual(store.notice, "That image's file was missing, so the entry was removed.")

        let reopened = makeStore()
        XCTAssertEqual(reopened.items.map(\.searchText), ["keep me"], "and it stays gone")
    }

    func testCopyingFilesPutsTheirURLsBack() throws {
        let file = root.appendingPathComponent("report.pdf")
        try Data([1, 2, 3]).write(to: file)
        let store = makeStore()
        store.add(.files([file]))
        settle(store)
        store.copyToPasteboard(store.items[0])
        settle(store)
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        XCTAssertEqual(urls?.map(\.lastPathComponent), ["report.pdf"])
    }
}
