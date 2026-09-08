import AppKit
import CoreGraphics

// Clipvelope's icon: a padlock and a clipboard drawn as the same object.
// The board is the lock body, the clip is the shackle, and the keyhole sits
// where a clipboard's content would start. One shape, read two ways, and it
// still reads at 16pt where a more literal drawing turns to mush.
//
// Rendered from code rather than checked in as art so it can be adjusted and
// regenerated: `swift scripts/make-icon.swift`.

let canvas: CGFloat = 1024

func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: alpha)
}

// Graphite ground with a brass shackle: brass reads as "lock" without the
// blue every other clipboard utility uses.
let groundTop = hex(0x3A4048)
let groundBottom = hex(0x171A1F)
let board = hex(0xF4F1E8)
let boardShade = hex(0xD9D4C6)
let brass = hex(0xF0A93B)
let brassShade = hex(0xC8801F)
let ink = hex(0x3A4048)

/// macOS icons are a squircle inset in the canvas, not a full-bleed square.
func squirclePath(in rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func draw(into ctx: CGContext, size: CGFloat) {
    let scale = size / canvas
    ctx.scaleBy(x: scale, y: scale)
    // Work in a y-down space so the layout reads top to bottom.
    ctx.translateBy(x: 0, y: canvas)
    ctx.scaleBy(x: 1, y: -1)

    // Ground
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    ctx.saveGState()
    ctx.addPath(squirclePath(in: body, radius: 185))
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [groundTop, groundBottom] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 512, y: 100),
                           end: CGPoint(x: 512, y: 924),
                           options: [])
    ctx.restoreGState()

    // Shackle: a thick arch whose legs run down behind the board.
    let shackleWidth: CGFloat = 62
    let shackleCentre = CGPoint(x: 512, y: 432)
    let shackleRadius: CGFloat = 118
    let legBottom: CGFloat = 560

    ctx.saveGState()
    ctx.setLineWidth(shackleWidth)
    ctx.setLineCap(.butt)
    ctx.setStrokeColor(brassShade)
    let shackle = CGMutablePath()
    shackle.move(to: CGPoint(x: shackleCentre.x - shackleRadius, y: legBottom))
    shackle.addLine(to: CGPoint(x: shackleCentre.x - shackleRadius, y: shackleCentre.y))
    shackle.addArc(center: shackleCentre, radius: shackleRadius,
                   startAngle: .pi, endAngle: 0, clockwise: false)
    shackle.addLine(to: CGPoint(x: shackleCentre.x + shackleRadius, y: legBottom))
    ctx.addPath(shackle)
    ctx.strokePath()

    // A lighter face on the arch so it does not read as a flat hoop.
    ctx.setLineWidth(shackleWidth - 22)
    ctx.setStrokeColor(brass)
    ctx.addPath(shackle)
    ctx.strokePath()
    ctx.restoreGState()

    // Board / lock body, drawn over the shackle legs. Taller than a padlock
    // body would be, to lean towards clipboard proportions.
    let boardRect = CGRect(x: 276, y: 468, width: 472, height: 412)
    ctx.saveGState()
    ctx.addPath(squirclePath(in: boardRect, radius: 64))
    ctx.clip()
    let boardGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                   colors: [board, boardShade] as CFArray,
                                   locations: [0, 1])!
    ctx.drawLinearGradient(boardGradient,
                           start: CGPoint(x: 512, y: 468),
                           end: CGPoint(x: 512, y: 880),
                           options: [])
    ctx.restoreGState()

    // Lines of copied text inside the lock body. This is the whole idea: the
    // silhouette says padlock, the contents say clipboard. A keyhole here read
    // as a plain padlock and nothing else.
    ctx.setFillColor(ink)
    let lineHeight: CGFloat = 40
    let lineLeft: CGFloat = 356
    let lineWidths: [CGFloat] = [312, 312, 208]
    for (index, width) in lineWidths.enumerated() {
        let y = 560 + CGFloat(index) * 84
        ctx.addPath(CGPath(roundedRect: CGRect(x: lineLeft, y: y, width: width,
                                               height: lineHeight),
                           cornerWidth: lineHeight / 2, cornerHeight: lineHeight / 2,
                           transform: nil))
    }
    ctx.fillPath()
}

func render(size: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                  pixelsWide: size, pixelsHigh: size,
                                  bitsPerSample: 8, samplesPerPixel: 4,
                                  hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    ctx.cgContext.setShouldAntialias(true)
    ctx.cgContext.interpolationQuality = .high
    draw(into: ctx.cgContext, size: CGFloat(size))
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

// The set iconutil expects.
let variants: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
for (name, size) in variants {
    try! render(size: size).write(to: URL(fileURLWithPath: "\(outputDir)/\(name)"))
}
print("wrote \(variants.count) images to \(outputDir)")
