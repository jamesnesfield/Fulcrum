import AppKit
// Draws the Fulcrum icon in the "Engraved Barrel" language (DESIGN.md): anodised black metal with a
// knurled band, a depth-of-field scale whose brackets converge on a white index, and the brand mark —
// a red index triangle (never a dot) — pointing up at it.
let out = CommandLine.arguments[1]
let S: CGFloat = 1024
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: 824 pt body inset 100, continuous-looking corner.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Soft drop shadow under the body, as on other Mac app icons.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: rgb(0x000000, 0.45))
ctx.addPath(shape); ctx.setFillColor(rgb(0x0B0B0C)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape); ctx.clip()
// Anodised metal: a barely-there vertical falloff, neutral greys only.
let metal = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [rgb(0x1E1E20), rgb(0x0B0B0C)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(metal, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

// Knurled grip band across the top.
let band = CGRect(x: 100, y: 742, width: 824, height: 96)
ctx.setFillColor(rgb(0x141415)); ctx.fill(band)
ctx.setFillColor(rgb(0x2E2E31))
var x: CGFloat = 104
while x < 924 { ctx.fill(CGRect(x: x, y: band.minY + 12, width: 7, height: band.height - 24)); x += 18 }
ctx.setFillColor(rgb(0x242427)); ctx.fill(CGRect(x: 100, y: band.minY - 3, width: 824, height: 3)); ctx.fill(CGRect(x: 100, y: band.maxY, width: 824, height: 3))

// Depth-of-field brackets: drop vertically from under the band, then splay out to the scale.
let cx: CGFloat = 512, topY: CGFloat = 700, kneeY: CGFloat = 600, footY: CGFloat = 470
func bracket(_ top: CGFloat, _ foot: CGFloat, color: CGColor, width: CGFloat) {
    ctx.setStrokeColor(color); ctx.setLineWidth(width); ctx.setLineJoin(.round); ctx.setLineCap(.butt)
    for side: CGFloat in [-1, 1] {
        ctx.move(to: CGPoint(x: cx + side * top, y: topY))
        ctx.addLine(to: CGPoint(x: cx + side * top, y: kneeY))
        ctx.addLine(to: CGPoint(x: cx + side * foot, y: footY))
    }
    ctx.strokePath()
}
bracket(84, 330, color: rgb(0x4A4A4E), width: 12)
bracket(62, 250, color: rgb(0x4A4A4E), width: 12)
bracket(40, 168, color: rgb(0xF2F2F0), width: 18)   // the live pair

// The index line, and the scale's ticks either side of it.
ctx.setFillColor(rgb(0xF2F2F0)); ctx.fill(CGRect(x: cx - 8, y: 470, width: 16, height: 230))
for i in 1...4 {
    for side: CGFloat in [-1, 1] {
        let tx = cx + side * CGFloat(i) * 84
        ctx.setFillColor(i == 2 ? rgb(0xF2F2F0) : rgb(0x6A6A6E))
        ctx.fill(CGRect(x: tx - 5, y: 400, width: 10, height: i == 2 ? 44 : 30))
    }
}

// The mark: a red index triangle pointing up at the index.
ctx.setFillColor(rgb(0xD7261E))
ctx.move(to: CGPoint(x: cx, y: 448)); ctx.addLine(to: CGPoint(x: cx + 112, y: 250)); ctx.addLine(to: CGPoint(x: cx - 112, y: 250)); ctx.fillPath()

// A faint machined edge highlight.
ctx.restoreGState()
ctx.addPath(shape); ctx.setStrokeColor(rgb(0xFFFFFF, 0.08)); ctx.setLineWidth(3); ctx.strokePath()

img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
