import AppKit
import CoreGraphics

// The menu bar icon: the same closed, sealed envelope as the app icon, as an
// 18-point template. Templates are drawn in one colour and recoloured by macOS
// for light and dark menu bars, so only the shape matters. Vector, so it is
// crisp at every scale.
//
//   swift scripts/make-menubar-icon.swift Resources/MenuBarIcon.pdf

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/MenuBarIcon.pdf"
var box = CGRect(x: 0, y: 0, width: 18, height: 18)
let ctx = CGContext(URL(fileURLWithPath: path) as CFURL, mediaBox: &box, nil)!
ctx.beginPDFPage(nil)
ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
ctx.setFillColor(CGColor(gray: 0, alpha: 1))
ctx.setLineWidth(1.6)
ctx.setLineJoin(.round)
ctx.setLineCap(.round)
// Body: outline of an envelope 15 x 11 points, centred.
let body = CGRect(x: 1.5, y: 3.5, width: 15, height: 11)
ctx.addPath(CGPath(roundedRect: body, cornerWidth: 2.4, cornerHeight: 2.4, transform: nil))
ctx.strokePath()
// Flap, closing at the centre.
ctx.move(to: CGPoint(x: 2.3, y: 13.6))
ctx.addLine(to: CGPoint(x: 9, y: 8.2))
ctx.addLine(to: CGPoint(x: 15.7, y: 13.6))
ctx.strokePath()
// The seal, solid, at the centre.
ctx.addEllipse(in: CGRect(x: 6.7, y: 6.7, width: 4.6, height: 4.6))
ctx.fillPath()
ctx.endPDFPage()
ctx.closePDF()
print("wrote \(path)")
