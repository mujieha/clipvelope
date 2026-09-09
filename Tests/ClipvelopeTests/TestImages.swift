import Foundation
import zlib
@testable import Clipvelope

/// A real, valid PNG: `width` x `height` grayscale black. Solid colour deflates
/// at roughly a thousand to one, so a file well under a megabyte can declare far
/// more pixels than any decoder should be asked to allocate. Shared, because
/// both the capture path and the import path have to refuse one.
func compressiblePNG(width: Int, height: Int) -> Data {
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
