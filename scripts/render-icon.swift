// Renders Eyes Driven 2me app icon concepts with CoreGraphics.
// Usage: swift scripts/render-icon.swift <concept: a|b|c> <size> <out.png>
import AppKit
import CoreGraphics

let args = CommandLine.arguments
let concept = args.count > 1 ? args[1] : "a"
let size = args.count > 2 ? CGFloat(Double(args[2]) ?? 1024) : 1024
let out = args.count > 3 ? args[3] : "icon.png"

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8,
                    bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.scaleBy(x: size / 1024, y: size / 1024)   // draw in a 1024 canvas
ctx.setShouldAntialias(true)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// macOS Big Sur+ icon grid: 824x824 rounded square centered in 1024, radius ~185.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

func linear(_ colors: [CGColor], from: CGPoint, to: CGPoint, clip: CGPath) {
    ctx.saveGState(); ctx.addPath(clip); ctx.clip()
    let g = CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}
func radial(_ colors: [CGColor], center: CGPoint, radius: CGFloat, clip: CGPath) {
    ctx.saveGState(); ctx.addPath(clip); ctx.clip()
    let g = CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: nil)!
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [.drawsAfterEndLocation])
    ctx.restoreGState()
}

// Tile shadow + background.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(tilePath); ctx.setFillColor(rgb(0x1B1F3B)); ctx.fillPath()
ctx.restoreGState()
linear([rgb(0x2A2F6B), rgb(0x12142B)], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100), clip: tilePath)
// Subtle top sheen.
radial([rgb(0x7B83FF, 0.35), rgb(0x7B83FF, 0)], center: CGPoint(x: 512, y: 860), radius: 520, clip: tilePath)

/// Almond eye shape centered at c with half-width w and half-height h.
func eyePath(center c: CGPoint, w: CGFloat, h: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: c.x - w, y: c.y))
    p.addCurve(to: CGPoint(x: c.x + w, y: c.y), control1: CGPoint(x: c.x - w * 0.45, y: c.y + h * 1.35),
               control2: CGPoint(x: c.x + w * 0.45, y: c.y + h * 1.35))
    p.addCurve(to: CGPoint(x: c.x - w, y: c.y), control1: CGPoint(x: c.x + w * 0.45, y: c.y - h * 1.35),
               control2: CGPoint(x: c.x - w * 0.45, y: c.y - h * 1.35))
    p.closeSubpath()
    return p
}

func iris(at c: CGPoint, r: CGFloat, clip: CGPath) {
    ctx.saveGState(); ctx.addPath(clip); ctx.clip()
    radial([rgb(0x9AF3FF), rgb(0x3DA8FF), rgb(0x2B3CC9)], center: c, radius: r,
           clip: CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil))
    ctx.setFillColor(rgb(0x0B0D1C))
    ctx.fillEllipse(in: CGRect(x: c.x - r * 0.42, y: c.y - r * 0.42, width: r * 0.84, height: r * 0.84))
    ctx.setFillColor(rgb(0xFFFFFF, 0.92))
    ctx.fillEllipse(in: CGRect(x: c.x + r * 0.12, y: c.y + r * 0.16, width: r * 0.28, height: r * 0.28))
    ctx.restoreGState()
}

func roundedRect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

switch concept {
case "a":
    // Concept A — "the window is the eye": a window whose content is an eye.
    let win = CGRect(x: 222, y: 270, width: 580, height: 470)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: rgb(0x000000, 0.45))
    ctx.addPath(roundedRect(win, 56)); ctx.setFillColor(rgb(0xF4F6FF)); ctx.fillPath()
    ctx.restoreGState()
    // Title bar.
    let bar = CGRect(x: win.minX, y: win.maxY - 92, width: win.width, height: 92)
    ctx.saveGState(); ctx.addPath(roundedRect(win, 56)); ctx.clip()
    ctx.setFillColor(rgb(0xDDE2F7)); ctx.fill(bar); ctx.restoreGState()
    for (i, col) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
        ctx.setFillColor(rgb(UInt32(col)))
        ctx.fillEllipse(in: CGRect(x: win.minX + 46 + CGFloat(i) * 52, y: bar.midY - 17, width: 34, height: 34))
    }
    let eyeC = CGPoint(x: 512, y: (win.minY + bar.minY) / 2)
    let eye = eyePath(center: eyeC, w: 215, h: 118)
    ctx.addPath(eye); ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillPath()
    iris(at: CGPoint(x: eyeC.x + 18, y: eyeC.y), r: 92, clip: eye)
    ctx.addPath(eye); ctx.setStrokeColor(rgb(0x1B1F3B)); ctx.setLineWidth(16); ctx.strokePath()
case "b":
    // Concept B — "gaze picks a screen": an eye above three screens, the right one lit.
    let eyeC = CGPoint(x: 512, y: 640)
    let eye = eyePath(center: eyeC, w: 250, h: 132)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 24, color: rgb(0x000000, 0.4))
    ctx.addPath(eye); ctx.setFillColor(rgb(0xF4F6FF)); ctx.fillPath(); ctx.restoreGState()
    iris(at: CGPoint(x: eyeC.x + 70, y: eyeC.y - 22), r: 100, clip: eye)
    let screens = [CGRect(x: 196, y: 238, width: 184, height: 128),
                   CGRect(x: 420, y: 238, width: 184, height: 128),
                   CGRect(x: 644, y: 238, width: 184, height: 128)]
    for (i, s) in screens.enumerated() {
        let lit = i == 2
        ctx.saveGState()
        if lit { ctx.setShadow(offset: .zero, blur: 40, color: rgb(0x5CE1FF, 0.9)) }
        ctx.addPath(roundedRect(s, 18))
        ctx.setFillColor(lit ? rgb(0x5CE1FF) : rgb(0x3A4080)); ctx.fillPath()
        ctx.restoreGState()
        ctx.setFillColor(lit ? rgb(0x5CE1FF) : rgb(0x3A4080))
        ctx.fill(CGRect(x: s.midX - 14, y: s.minY - 34, width: 28, height: 34))
        ctx.fill(CGRect(x: s.midX - 50, y: s.minY - 44, width: 100, height: 12))
    }
case "c":
    // Concept C — "focus where you look": an eye framed by camera-style focus brackets.
    let eyeC = CGPoint(x: 512, y: 512)
    let eye = eyePath(center: eyeC, w: 250, h: 140)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 26, color: rgb(0x000000, 0.4))
    ctx.addPath(eye); ctx.setFillColor(rgb(0xF4F6FF)); ctx.fillPath(); ctx.restoreGState()
    iris(at: eyeC, r: 108, clip: eye)
    let b = CGRect(x: 206, y: 236, width: 612, height: 552)
    let L: CGFloat = 120
    ctx.setStrokeColor(rgb(0x5CE1FF)); ctx.setLineWidth(30); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    for (corner, dx, dy) in [(CGPoint(x: b.minX, y: b.maxY), 1.0, -1.0), (CGPoint(x: b.maxX, y: b.maxY), -1.0, -1.0),
                             (CGPoint(x: b.minX, y: b.minY), 1.0, 1.0), (CGPoint(x: b.maxX, y: b.minY), -1.0, 1.0)] {
        ctx.move(to: CGPoint(x: corner.x, y: corner.y + dy * L))
        ctx.addLine(to: corner)
        ctx.addLine(to: CGPoint(x: corner.x + dx * L, y: corner.y))
    }
    ctx.strokePath()
default:
    break
}

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
