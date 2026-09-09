import AppKit

// Renders an app's layered icon the way macOS itself draws it -- Liquid Glass,
// shadows, specular -- and writes a complete .icns from it.
//
// actool's own .icns stops at 256 px, and nothing but the system can flatten an
// Icon Composer document. So: point NSWorkspace at a copy of the bundle under a
// throwaway identifier (IconServices caches by identifier, and a stale cache
// would silently ship last build's icon), draw at each size, hand the set to
// iconutil.
//
//   swift scripts/render-app-icon.swift dist/Clipvelope.app out.icns [social.png]

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: render-app-icon.swift <app> <out.icns> [social-preview.png]\n".data(using: .utf8)!)
    exit(2)
}
let appPath = args[1], icnsPath = args[2]
let fm = FileManager.default
let scratch = fm.temporaryDirectory.appendingPathComponent("clipvelope-icon-\(UUID().uuidString)")
try! fm.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: scratch) }

// A copy with a unique bundle identifier defeats the icon cache.
let copy = scratch.appendingPathComponent("Render.app")
try! fm.copyItem(atPath: appPath, toPath: copy.path)
let plistURL = copy.appendingPathComponent("Contents/Info.plist")
var plist = try! PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as! [String: Any]
plist["CFBundleIdentifier"] = "render.\(UUID().uuidString)"
try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: plistURL)

let icon = NSWorkspace.shared.icon(forFile: copy.path)

func render(_ size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    icon.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = scratch.appendingPathComponent("AppIcon.iconset")
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
let variants: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32), ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256), ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, size) in variants {
    try! render(size).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icnsPath]
try! iconutil.run(); iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(1) }
print("wrote \(icnsPath) with \(variants.count) sizes")

// Optional: the GitHub social preview, 1280 x 640, from the same rendering.
if args.count >= 4 {
    let W = 1280, H = 640
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let gradient = NSGradient(starting: NSColor(srgbRed: 0.043, green: 0.145, blue: 0.169, alpha: 1),
                              ending: NSColor(srgbRed: 0.118, green: 0.333, blue: 0.376, alpha: 1))!
    gradient.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: 20)
    icon.draw(in: NSRect(x: 96, y: 96, width: 448, height: 448), from: .zero, operation: .sourceOver, fraction: 1)
    let cream = NSColor(srgbRed: 0.973, green: 0.949, blue: 0.902, alpha: 1)
    NSAttributedString(string: "Clipvelope", attributes: [
        .font: NSFont.systemFont(ofSize: 104, weight: .semibold), .foregroundColor: cream, .kern: -2,
    ]).draw(at: NSPoint(x: 600, y: 330))
    NSAttributedString(string: "Your clipboard, sealed.", attributes: [
        .font: NSFont.systemFont(ofSize: 44, weight: .medium),
        .foregroundColor: NSColor(srgbRed: 0.910, green: 0.631, blue: 0.384, alpha: 1),
    ]).draw(at: NSPoint(x: 606, y: 268))
    NSAttributedString(string: "Encrypted, local-only clipboard history for macOS.\nOpen source, MIT licensed.",
                       attributes: [.font: NSFont.systemFont(ofSize: 27), .foregroundColor: cream.withAlphaComponent(0.72)])
        .draw(at: NSPoint(x: 606, y: 172))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[3]))
    print("wrote \(args[3])")
}
