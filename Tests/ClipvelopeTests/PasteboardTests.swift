import XCTest
import AppKit
import CryptoKit
import zlib
@testable import Clipvelope

/// The core loop of the product, both directions, on a private pasteboard so
/// the test never touches the one every other app shares.
private struct TestKeyStore: KeyProviding {
    let key = SymmetricKey(data: Data(repeating: 7, count: 32))
    func getOrCreateKey() throws -> SymmetricKey { key }
}

/// A real, valid PNG: `width` x `height` grayscale black. Solid colour deflates
/// at roughly a thousand to one, so a file well under a megabyte can declare
/// far more pixels than the decoder should ever be asked to allocate.
private func compressiblePNG(width: Int, height: Int) -> Data {
    func be(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.bigEndian, Array.init) }
    func chunk(_ type: String, _ body: Data) -> Data {
        let typeBytes = Data(type.utf8)
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in typeBytes + body {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xEDB8_8320 : 0) }
        }
        return Data(be(UInt32(body.count))) + typeBytes + body + Data(be(crc ^ 0xFFFF_FFFF))
    }
    // One filter byte per row, then the samples; all zero.
    let raw = Data(count: (width + 1) * height)
    var destinationLength = compressBound(uLong(raw.count))
    var compressed = Data(count: Int(destinationLength))
    let status = raw.withUnsafeBytes { source in
        compressed.withUnsafeMutableBytes { destination in
            compress2(destination.bindMemory(to: Bytef.self).baseAddress, &destinationLength,
                      source.bindMemory(to: Bytef.self).baseAddress, uLong(raw.count), Z_BEST_SPEED)
        }
    }
    precondition(status == Z_OK)
    compressed.count = Int(destinationLength)

    let ihdr = Data(be(UInt32(width)) + be(UInt32(height)) + [8, 0, 0, 0, 0])
    return Data(ClipboardMonitor.pngSignature) + chunk("IHDR", ihdr) + chunk("IDAT", compressed) + chunk("IEND", Data())
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

    func testOversizedPlainTextIsNotCaptured() {
        pb.setString(String(repeating: "a", count: ClipboardMonitor.maxTextBytes + 1), forType: .string)
        XCTAssertNil(ClipboardMonitor.readPayload(from: pb))
        pb.clearContents()
        pb.setString(String(repeating: "a", count: ClipboardMonitor.maxTextBytes), forType: .string)
        XCTAssertNotNil(ClipboardMonitor.readPayload(from: pb))
    }

    func testOversizedRichTextFallsBackToPlainText() {
        pb.setData(Data(count: ClipboardMonitor.maxRichTextBytes + 1), forType: .rtf)
        pb.setString("plain", forType: .string)
        guard case .text(let s)? = ClipboardMonitor.readPayload(from: pb) else { return XCTFail() }
        XCTAssertEqual(s, "plain")
    }

    /// The plain rendering of a rich paste lives inline in the index, like plain
    /// text does, so it gets the same cap; otherwise a small RTF could carry an
    /// unbounded string past the plain-text limit.
    func testRichTextWithAnOversizedPlainRenderingIsSkipped() {
        let huge = String(repeating: "x", count: ClipboardMonitor.maxTextBytes + 1)
        pb.setString(huge, forType: .string)
        pb.setData(Data("{\\rtf1 small}".utf8), forType: .rtf)
        XCTAssertNil(ClipboardMonitor.readPayload(from: pb))
    }

    /// A valid PNG well under a megabyte that declares 81 million pixels. Decoding it
    /// would allocate the whole raster, so the declared size is checked first,
    /// on both the PNG and the TIFF path (ImageIO sniffs the real format).
    func testAnImageDeclaringMorePixelsThanTheCeilingIsSkippedWithoutDecoding() {
        let hostile = compressiblePNG(width: 9000, height: 9000)
        XCTAssertLessThan(hostile.count, 1_000_000, "the point is that the file is small")
        XCTAssertEqual(ClipboardMonitor.declaredPixelSize(of: hostile).map { [$0.0, $0.1] },
                       [9000, 9000], "the fixture must be a readable PNG")
        XCTAssertGreaterThan(9000 * 9000, ClipboardMonitor.maxImagePixels)

        pb.setData(hostile, forType: .png)
        XCTAssertNil(ClipboardMonitor.readPayload(from: pb))

        pb.clearContents()
        pb.setData(hostile, forType: .tiff)
        XCTAssertNil(ClipboardMonitor.readPayload(from: pb))
    }

    /// The same construction at a sane size still captures, so the ceiling is
    /// the only thing the previous test exercises.
    func testACompressibleImageUnderTheCeilingIsCaptured() {
        pb.setData(compressiblePNG(width: 300, height: 200), forType: .png)
        guard case .image(_, _, let w, let h)? = ClipboardMonitor.readPayload(from: pb) else { return XCTFail() }
        XCTAssertEqual([w, h], [300, 200])
    }

    func testTheImageCeilingAdmitsScreensAndRefusesTheAbsurd() {
        XCTAssertTrue(ClipboardMonitor.acceptsImage(pixelWidth: 6016, pixelHeight: 3384), "a 6K display")
        XCTAssertFalse(ClipboardMonitor.acceptsImage(pixelWidth: 50_000, pixelHeight: 50_000))
        XCTAssertFalse(ClipboardMonitor.acceptsImage(pixelWidth: 0, pixelHeight: 10))
        XCTAssertFalse(ClipboardMonitor.acceptsImage(pixelWidth: .max, pixelHeight: 2), "overflow")
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

    /// The shell runs on a global queue; wait for either outcome.
    private func waitForShell(_ store: ClipboardStore, until done: () -> Bool) {
        for _ in 0..<150 where !done() {
            store.drainPendingWork()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    func testAQuickSlotCommandCopiesItsOutput() {
        let store = makeStore()
        store.runShellAndCopy("printf 'from the shell'")
        waitForShell(store) { pb.string(forType: .string) != nil }
        XCTAssertEqual(pb.string(forType: .string), "from the shell")
        XCTAssertNil(store.notice)
    }

    func testAFailingQuickSlotCommandLeavesTheClipboardAloneAndSaysSo() {
        let store = makeStore()
        pb.setString("keep me", forType: .string)
        store.runShellAndCopy("echo lost >/dev/null; exit 3")
        waitForShell(store) { store.notice != nil }
        XCTAssertEqual(pb.string(forType: .string), "keep me",
                       "a failed command used to clear the clipboard and paste nothing")
        XCTAssertEqual(store.notice?.contains("exit 3"), true)
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
