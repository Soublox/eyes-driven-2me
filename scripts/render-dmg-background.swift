// Renders the DMG window background: app slot on the left, an arrow, and the
// Applications slot on the right, with a short "drag to install" hint.
// Usage: swift scripts/render-dmg-background.swift <scale: 1|2> <out.png>
import AppKit
import CoreGraphics

let args = CommandLine.arguments
let scale = CGFloat(Double(args.count > 1 ? args[1] : "1") ?? 1)
let out = args.count > 2 ? args[2] : "dmg-background.png"

// Logical window content size (points). Keep in sync with scripts/dmg-settings.py.
let W: CGFloat = 660, H: CGFloat = 400

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(W * scale), height: Int(H * scale), bitsPerComponent: 8,
                    bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.scaleBy(x: scale, y: scale)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// Background: same palette as the app icon.
let g = CGGradient(colorsSpace: cs, colors: [rgb(0x2A2F6B), rgb(0x12142B)] as CFArray, locations: nil)!
ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: 0), options: [])
let sheen = CGGradient(colorsSpace: cs, colors: [rgb(0x7B83FF, 0.25), rgb(0x7B83FF, 0)] as CFArray, locations: nil)!
ctx.drawRadialGradient(sheen, startCenter: CGPoint(x: W / 2, y: H), startRadius: 0,
                       endCenter: CGPoint(x: W / 2, y: H), endRadius: 420, options: [])

// Icon slots (Finder draws the icons on top). Centers in bottom-left coords:
// Finder positions are (180, 190) and (480, 190) from the top-left.
let slotY = H - 190
for x in [180.0, 480.0] {
    let r = CGRect(x: x - 78, y: slotY - 78, width: 156, height: 156)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: 34, cornerHeight: 34, transform: nil))
    ctx.setFillColor(rgb(0xFFFFFF, 0.06)); ctx.fillPath()
}

// Arrow between the slots.
ctx.setStrokeColor(rgb(0x5CE1FF)); ctx.setLineWidth(8); ctx.setLineCap(.round); ctx.setLineJoin(.round)
let a0 = CGPoint(x: 285, y: slotY), a1 = CGPoint(x: 375, y: slotY)
ctx.move(to: a0); ctx.addLine(to: a1)
ctx.move(to: CGPoint(x: a1.x - 22, y: a1.y + 22)); ctx.addLine(to: a1); ctx.addLine(to: CGPoint(x: a1.x - 22, y: a1.y - 22))
ctx.strokePath()

// Text.
func draw(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, centerY: CGFloat) {
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                .foregroundColor: color]
    let str = NSAttributedString(string: s, attributes: attrs)
    let line = CTLineCreateWithAttributedString(str)
    let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
    ctx.textPosition = CGPoint(x: (W - bounds.width) / 2, y: centerY - bounds.height / 2)
    CTLineDraw(line, ctx)
}
draw("Eyes Driven 2me", size: 26, weight: .semibold, color: .white, centerY: H - 52)
draw("Drag the app to the Applications folder to install", size: 14, weight: .regular,
     color: NSColor(white: 1, alpha: 0.75), centerY: 70)
draw("Look at a window. It gets focus.", size: 12, weight: .regular,
     color: NSColor(red: 0.36, green: 0.88, blue: 1, alpha: 0.9), centerY: 42)

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
rep.size = NSSize(width: W, height: H)   // 72 dpi logical size; @2x carries 144 dpi
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
