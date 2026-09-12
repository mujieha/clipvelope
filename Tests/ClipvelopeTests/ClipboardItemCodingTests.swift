import XCTest
@testable import Clipvelope

final class ClipboardItemCodingTests: XCTestCase {
    /// Byte counts arrive in portable backups from anyone. Unclamped, two items
    /// at Int.max overflow the byte-budget sum and trap on the next copy; one
    /// item at a terabyte evicts every other entry.
    func testAbsurdByteCountsAreClampedOnDecode() throws {
        let image = #"{"pixelWidth":-5,"pixelHeight":10,"byteCount":9223372036854775807,"typeIdentifier":"public.png"}"#
        let info = try JSONDecoder().decode(ClipboardContent.ImageInfo.self, from: Data(image.utf8))
        XCTAssertEqual(info.byteCount, ClipboardContent.ImageInfo.maxBytes)
        XCTAssertEqual(info.pixelWidth, 0)

        let rich = #"{"plainText":"x","byteCount":-1,"typeIdentifier":"public.rtf"}"#
        let richInfo = try JSONDecoder().decode(ClipboardContent.RichTextInfo.self, from: Data(rich.utf8))
        XCTAssertEqual(richInfo.byteCount, 0)

        let honest = ClipboardContent.ImageInfo(pixelWidth: 2, pixelHeight: 2, byteCount: 1234, typeIdentifier: "public.png")
        let roundTrip = try JSONDecoder().decode(ClipboardContent.ImageInfo.self, from: JSONEncoder().encode(honest))
        XCTAssertEqual(roundTrip, honest)
    }

    private func decode(_ json: String) throws -> ClipboardItem {
        try JSONDecoder().decode(ClipboardItem.self, from: Data(json.utf8))
    }

    /// Schema 3 and earlier stored the text under a bare `text` key. Those items
    /// must keep decoding: the alternative is a decode failure, which the storage
    /// layer cannot distinguish from corruption.
    func testLegacyTextKeyBecomesTextContent() throws {
        let item = try decode(#"{"id":"\#(UUID().uuidString)","text":"hello","createdAt":0}"#)
        XCTAssertEqual(item.content, .text("hello"))
        XCTAssertFalse(item.isPinned)
    }

    func testLegacyItemsKeepTheirPinnedFlag() throws {
        let item = try decode(#"{"id":"\#(UUID().uuidString)","text":"x","createdAt":0,"isPinned":true}"#)
        XCTAssertTrue(item.isPinned)
    }

    func testTextItemRoundTrips() throws {
        let original = ClipboardItem(text: "round trip", isPinned: true)
        let decoded = try JSONDecoder().decode(
            ClipboardItem.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }

    func testImageItemRoundTrips() throws {
        let original = ClipboardItem(
            id: UUID(), createdAt: Date(timeIntervalSince1970: 0), isPinned: false,
            content: .image(.init(pixelWidth: 800, pixelHeight: 600,
                                  byteCount: 12_345, typeIdentifier: "public.png"))
        )
        let decoded = try JSONDecoder().decode(
            ClipboardItem.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }

    func testFilesItemRoundTrips() throws {
        let original = ClipboardItem(
            id: UUID(), createdAt: Date(timeIntervalSince1970: 0), isPinned: false,
            content: .files([.init(path: "/tmp/a.txt")])
        )
        let decoded = try JSONDecoder().decode(
            ClipboardItem.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Content hashes

    private func image(hash: String?) -> ClipboardContent.ImageInfo {
        .init(pixelWidth: 800, pixelHeight: 600, byteCount: 12_345,
              typeIdentifier: "public.png", contentHash: hash)
    }

    func testTheDigestIsLowercaseHexOfTheBytes() {
        XCTAssertEqual(ClipboardContent.digest(Data("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(ClipboardContent.digest(Data()).count, 64)
        XCTAssertNotEqual(ClipboardContent.digest(compressiblePNG(width: 4, height: 4)),
                          ClipboardContent.digest(compressiblePNG(width: 4, height: 5)))
    }

    /// Width, height, byte count and type say nothing about the pixels. Without
    /// the digest these two compared equal, and the second screenshot was
    /// silently dropped as a re-copy of the first.
    func testImagesWithTheSameMetadataButDifferentBytesAreNotEqual() {
        let one = image(hash: ClipboardContent.digest(Data("first".utf8)))
        let other = image(hash: ClipboardContent.digest(Data("second".utf8)))
        XCTAssertNotEqual(one, other)
        XCTAssertEqual(one, image(hash: one.contentHash))
    }

    /// The old-vault fallback: an entry with no hash keeps comparing on exactly
    /// the fields 0.1.0 compared, so re-copying a picture already in the vault
    /// still refreshes it instead of appending a second row for it.
    func testAnImageWithoutAHashStillMatchesOneWithAHash() {
        let hashed = image(hash: ClipboardContent.digest(Data("bytes".utf8)))
        XCTAssertEqual(hashed, image(hash: nil))
        XCTAssertEqual(image(hash: nil), hashed)
        XCTAssertEqual(image(hash: nil), image(hash: nil))
    }

    /// Metadata still has to agree; the hash only ever narrows the match.
    func testTheHashDoesNotMakeDifferentlyShapedImagesEqual() {
        let hash = ClipboardContent.digest(Data("bytes".utf8))
        let other = ClipboardContent.ImageInfo(pixelWidth: 4, pixelHeight: 600, byteCount: 12_345,
                                               typeIdentifier: "public.png", contentHash: hash)
        XCTAssertNotEqual(image(hash: hash), other)
    }

    func testFormattedTextFollowsTheSameRule() {
        func rich(_ hash: String?) -> ClipboardContent.RichTextInfo {
            .init(plainText: "hello", byteCount: 300, typeIdentifier: "public.rtf",
                  contentHash: hash)
        }
        XCTAssertNotEqual(rich(ClipboardContent.digest(Data("a".utf8))),
                          rich(ClipboardContent.digest(Data("b".utf8))))
        XCTAssertEqual(rich(ClipboardContent.digest(Data("a".utf8))), rich(nil))
        XCTAssertEqual(rich(nil), rich(nil))
    }

    /// A vault written by 0.1.0 has no `contentHash` key anywhere. Refusing to
    /// decode it would look exactly like corruption, whose recovery path is
    /// destructive.
    func testJSONWithoutAContentHashKeyDecodesAndRoundTrips() throws {
        let old = #"{"pixelWidth":800,"pixelHeight":600,"byteCount":12345,"typeIdentifier":"public.png"}"#
        let info = try JSONDecoder().decode(ClipboardContent.ImageInfo.self, from: Data(old.utf8))
        XCTAssertNil(info.contentHash)
        XCTAssertEqual(info, image(hash: nil))

        // Re-encoding an entry that has no hash must not invent one, and the
        // second round trip has to land on the same value as the first.
        let encoded = try JSONEncoder().encode(info)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("contentHash"))
        let again = try JSONDecoder().decode(ClipboardContent.ImageInfo.self, from: encoded)
        XCTAssertNil(again.contentHash)

        let oldRich = #"{"plainText":"x","byteCount":2,"typeIdentifier":"public.rtf"}"#
        let richInfo = try JSONDecoder().decode(ClipboardContent.RichTextInfo.self,
                                                from: Data(oldRich.utf8))
        XCTAssertNil(richInfo.contentHash)
    }

    func testAHashSurvivesAWholeItemRoundTrip() throws {
        let hash = ClipboardContent.digest(compressiblePNG(width: 4, height: 4))
        let original = ClipboardItem(
            id: UUID(), createdAt: Date(timeIntervalSince1970: 0), isPinned: false,
            content: .image(image(hash: hash))
        )
        let decoded = try JSONDecoder().decode(
            ClipboardItem.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
        guard case .image(let info) = decoded.content else { return XCTFail("not an image") }
        XCTAssertEqual(info.contentHash, hash)
    }

    /// An imported backup is untrusted input, and a declared hash is the
    /// strongest thing an item says about the bytes filed under its id.
    func testAnImportedPayloadMustMatchTheHashItsItemDeclares() {
        let png = compressiblePNG(width: 4, height: 4)
        let honest = ClipboardContent.image(
            .init(pixelWidth: 4, pixelHeight: 4, byteCount: png.count,
                  typeIdentifier: "public.png", contentHash: ClipboardContent.digest(png)))
        XCTAssertTrue(ClipboardStore.payloadIsAcceptable(png, for: honest))
        XCTAssertFalse(ClipboardStore.payloadIsAcceptable(compressiblePNG(width: 4, height: 5),
                                                          for: honest))

        // Uppercase hex names the same bytes; this app is not the only writer.
        let shouting = ClipboardContent.image(
            .init(pixelWidth: 4, pixelHeight: 4, byteCount: png.count, typeIdentifier: "public.png",
                  contentHash: ClipboardContent.digest(png).uppercased()))
        XCTAssertTrue(ClipboardStore.payloadIsAcceptable(png, for: shouting))

        // A backup written before the field existed declares nothing and is
        // judged exactly as it was before.
        let silent = ClipboardContent.image(
            .init(pixelWidth: 4, pixelHeight: 4, byteCount: png.count,
                  typeIdentifier: "public.png"))
        XCTAssertTrue(ClipboardStore.payloadIsAcceptable(png, for: silent))
        // The same bytes the hashed item refused: it was the hash that refused
        // them, not any of the checks that were there before.
        XCTAssertTrue(ClipboardStore.payloadIsAcceptable(compressiblePNG(width: 4, height: 5),
                                                         for: silent))

        let rtf = Data("{\\rtf1 hello}".utf8)
        let rich = ClipboardContent.richText(
            .init(plainText: "hello", byteCount: rtf.count, typeIdentifier: "public.rtf",
                  contentHash: ClipboardContent.digest(rtf)))
        XCTAssertTrue(ClipboardStore.payloadIsAcceptable(rtf, for: rich))
        XCTAssertFalse(ClipboardStore.payloadIsAcceptable(Data("{\\rtf1 other}".utf8), for: rich))
    }

    // MARK: - Derived values

    func testSearchTextForEachKind() {
        XCTAssertEqual(ClipboardItem(text: "plain").searchText, "plain")

        let image = ClipboardItem(id: UUID(), createdAt: Date(), isPinned: false,
                                  content: .image(.init(pixelWidth: 4, pixelHeight: 3,
                                                        byteCount: 1, typeIdentifier: "public.png")))
        XCTAssertEqual(image.searchText, "Image 4×3")

        let files = ClipboardItem(id: UUID(), createdAt: Date(), isPinned: false,
                                  content: .files([.init(path: "/a/b.txt"),
                                                   .init(path: "/a/c.txt")]))
        XCTAssertEqual(files.searchText, "b.txt, c.txt")
    }

    func testOnlyImagesCostPayloadBytes() {
        XCTAssertEqual(ClipboardItem(text: "x").payloadByteCount, 0)
        XCTAssertFalse(ClipboardItem(text: "x").hasPayloadFile)

        let image = ClipboardItem(id: UUID(), createdAt: Date(), isPinned: false,
                                  content: .image(.init(pixelWidth: 1, pixelHeight: 1,
                                                        byteCount: 999, typeIdentifier: "public.png")))
        XCTAssertEqual(image.payloadByteCount, 999)
        XCTAssertTrue(image.hasPayloadFile)
    }
}
