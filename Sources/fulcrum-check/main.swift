import IOSurface
import CoreImage
import Foundation
import FulcrumCore
import ImageIO
import UniformTypeIdentifiers

// Engine checks: synthesises test photos, runs the pipeline, asserts the behaviour from the transcript.
var failures = 0
func check(_ ok: Bool, _ msg: String) {
    print(ok ? "  ✓ \(msg)" : "  ✗ \(msg)")
    if !ok { failures += 1 }
}

let tmp = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory())
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

/// Writes a w×h sRGB PNG from a per-pixel closure (x, y from top) returning 0...255 RGB.
func makePNG(_ name: String, w: Int = 600, h: Int = 400, _ f: (Int, Int) -> (UInt8, UInt8, UInt8)) -> URL {
    var px = [UInt8](repeating: 255, count: w * h * 4)
    for y in 0..<h { for x in 0..<w {
        let (r, g, b) = f(x, y); let o = (y * w + x) * 4
        px[o] = r; px[o + 1] = g; px[o + 2] = b
    } }
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let url = tmp.appendingPathComponent(name)
    let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(d)
    return url
}

func meanLuma(_ cg: CGImage) -> Double {
    let w = cg.width, h = cg.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    var s = 0.0
    for i in 0..<(w * h) { s += 0.299 * Double(px[i*4]) + 0.587 * Double(px[i*4+1]) + 0.114 * Double(px[i*4+2]) }
    return s / Double(w * h)
}

print("Curve maths")
check(abs(ContrastCurve.value(53.0/255, pivot: 53.0/255, exponent: 2) - 53.0/255) < 1e-9, "pivot is a fixed point")
check(ContrastCurve.value(0, pivot: 0.3, exponent: 2) == 0 && ContrastCurve.value(1, pivot: 0.3, exponent: 2) == 1, "black/white points fixed")
check(ContrastCurve.value(0.6, pivot: 0.3, exponent: 2) > 0.6 && ContrastCurve.value(0.15, pivot: 0.3, exponent: 2) < 0.15, "brights up, darks down")
check(abs(ContrastCurve.exponent(forAmount: 0) - 1) < 1e-12, "amount 0 = identity")

// A low-key "evening" photo: sky band at top (~180), dark land below (~35-70) — median well below 128.
let lowKey = makePNG("lowkey.png") { x, y in
    if y < 110 { let v = UInt8(165 + (x % 30)); return (v - 25, v - 5, v + 10) }   // bluish sky
    let v = UInt8(30 + (x * 7 + y * 3) % 45)
    return (v + 6, v + 2, v)
}

print("Low-key image, global contrast")
let r = try Renderer(url: lowKey, previewMax: 1200)
let flat = try r.renderPreview(EditSettings())
print("    median before contrast: \(Int(flat.analysis.globalMedian.rounded()))")
check(flat.analysis.globalMedian < 90, "median detected as low-key (< 90)")

var fixed128 = EditSettings(); fixed128.contrast = 60; fixed128.pivotAuto = false; fixed128.manualPivot = 128
var median = EditSettings(); median.contrast = 60
let a = try r.renderPreview(fixed128), b = try r.renderPreview(median)
let base = meanLuma(flat.image), dark128 = meanLuma(a.image), darkMedian = meanLuma(b.image)
print(String(format: "    mean luma: original %.1f | pivot 128 %.1f | pivot median %.1f", base, dark128, darkMedian))
check(dark128 < base - 5, "fixed 128 pivot darkens the low-key image (the problem in the video)")
check(abs(b.analysis.outputMedian - flat.analysis.globalMedian) < 3, "median pivot keeps the median where it was")
check(abs(darkMedian - base) < abs(dark128 - base), "median pivot changes overall brightness less")

print("Local sky contrast")
var sky = EditSettings(); var adj = LocalAdjustment(kind: .sky); adj.contrast = 50; sky.localAdjustments = [adj]
let s = try r.renderPreview(sky)
let skyMed = s.analysis.localMedians[adj.id] ?? -1, cov = s.analysis.localCoverage[adj.id] ?? 0
print(String(format: "    sky median %.0f, coverage %.0f%%", skyMed, cov * 100))
check(skyMed > 140, "sky mask median is the sky's tones (> 140)")
check(cov > 0.2 && cov < 0.4, "sky mask covers the top band (~27%)")

var grad = EditSettings(); var g = LocalAdjustment(kind: .linearGradient); g.mask.gradientFrom = 0; g.mask.gradientTo = 0.25
grad.localAdjustments = [g]
let ga = try r.renderPreview(grad).analysis
check((ga.localMedians[g.id] ?? 0) > 140, "top gradient measures sky tones (orientation correct)")

var lum = EditSettings(); var l = LocalAdjustment(kind: .luminanceRange); l.mask.lumaLow = 0; l.mask.lumaHigh = 90; l.mask.lumaFeather = 5
lum.localAdjustments = [l]
let la = try r.renderPreview(lum).analysis
check((la.localMedians[l.id] ?? 255) < 90, "shadow luminance mask measures dark tones")

print("White balance direction (non-RAW)")
let gray = makePNG("gray.png", w: 64, h: 64) { _, _ in (128, 128, 128) }
let gr = try Renderer(url: gray, previewMax: 64)
var warm = EditSettings(); warm.temperature = 60
let wimg = try gr.renderPreview(warm).image
var px = [UInt8](repeating: 0, count: 64 * 64 * 4)
let wctx = CGContext(data: &px, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                     space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
wctx.draw(wimg, in: CGRect(x: 0, y: 0, width: 64, height: 64))
print("    warm gray → R \(px[0]) G \(px[1]) B \(px[2])")
check(px[0] > px[2], "positive temperature warms the image")
var mag = EditSettings(); mag.tint = 60
let mimg = try gr.renderPreview(mag).image
wctx.draw(mimg, in: CGRect(x: 0, y: 0, width: 64, height: 64))
print("    +tint gray → R \(px[0]) G \(px[1]) B \(px[2])")
check(Int(px[1]) < (Int(px[0]) + Int(px[2])) / 2, "positive tint goes magenta (like Lightroom)")

print("Export")
var opts = ExportOptions(); opts.maxLongEdge = 450
let outURL = tmp.appendingPathComponent("out.jpg")
try r.export(median, to: outURL, options: opts)
let src = CGImageSourceCreateWithURL(outURL as CFURL, nil)
let props = src.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] }
check((props?[kCGImagePropertyPixelWidth as String] as? Int) == 450, "JPEG export at 450 px long edge")
var t16 = ExportOptions(); t16.format = .tiff16; t16.maxLongEdge = 300
try r.export(median, to: tmp.appendingPathComponent("out.tif"), options: t16)
let tprops = CGImageSourceCreateWithURL(tmp.appendingPathComponent("out.tif") as CFURL, nil)
    .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] }
check((tprops?[kCGImagePropertyDepth as String] as? Int) == 16, "16-bit TIFF export")

print("Draft frames")
let full0 = try r.renderDisplay(median)
let d0 = try r.renderDisplay(sky, draft: true, previous: full0.analysis)
check(d0.isDraft && IOSurfaceGetWidth(d0.surface) < IOSurfaceGetWidth(full0.surface) && d0.logicalSize == full0.logicalSize,
      "draft is smaller but stands in for the full preview size")
let full1 = try r.renderDisplay(sky)
check(!full1.isDraft && IOSurfaceGetWidth(full1.surface) == IOSurfaceGetWidth(full0.surface), "settled frame back at full size")

if CommandLine.arguments.count > 2, !CommandLine.arguments[2].isEmpty {
    let rawURL = URL(fileURLWithPath: CommandLine.arguments[2])
    print("RAW: \(rawURL.lastPathComponent)")
    let t0 = Date()
    let rr = try Renderer(url: rawURL)
    let p = try rr.renderPreview(median)
    print(String(format: "    isRAW %@, %.0fx%.0f, as-shot %.0fK, median %.0f, first preview %.2fs",
                 rr.source.isRAW ? "yes" : "no", rr.source.pixelSize.width, rr.source.pixelSize.height,
                 rr.source.asShotTemperature, p.analysis.globalMedian, Date().timeIntervalSince(t0)))
    let t1 = Date(); _ = try rr.renderPreview(sky)
    print(String(format: "    slider re-render (cached decode) %.2fs", Date().timeIntervalSince(t1)))
    var w = median; w.temperature = 60
    let warmMean = try rr.renderPreview(w).analysis.histogram
    let cool = try rr.renderPreview(median).analysis.histogram
    func centroid(_ h: [Float]) -> Double { let s = h.reduce(0, +); return s > 0 ? zip(h.indices, h).reduce(0.0) { $0 + Double($1.0) * Double($1.1) } / Double(s) : 0 }
    check(centroid(warmMean.red) - centroid(warmMean.blue) > centroid(cool.red) - centroid(cool.blue), "RAW: positive temperature warms")
    // Dragging Temperature: draft frames decode the RAW at half size, then settle at full size.
    _ = try rr.renderDisplay(median)
    rr.prewarmDraftDecode(median)   // the app does this in the background after opening a RAW
    var dragTimes: [Double] = []
    var lastDraft: Renderer.Display?
    for t in stride(from: 0.0, through: 50, by: 10) {
        var x = median; x.temperature = t
        let t2 = Date()
        lastDraft = try rr.renderDisplay(x, draft: true, previous: lastDraft?.analysis ?? p.analysis)
        dragTimes.append(Date().timeIntervalSince(t2))
    }
    var settled = median; settled.temperature = 50
    let t3 = Date(); let fullW = try rr.renderDisplay(settled)
    print(String(format: "    temperature drag: draft frames %@ ms · settle %.0f ms",
                 dragTimes.map { String(format: "%.0f", $0 * 1000) }.joined(separator: "/"), Date().timeIntervalSince(t3) * 1000))
    check(lastDraft!.isDraft && IOSurfaceGetWidth(lastDraft!.surface) < IOSurfaceGetWidth(fullW.surface), "RAW: white-balance drafts decode small")
    check((lastDraft!.analysis.globalMedian - fullW.analysis.globalMedian).magnitude < 4, "RAW: draft and settled medians agree")
    let t4 = Date(); let awb = rr.autoWhiteBalance(median)
    print(String(format: "    auto white balance → temp %+.0f tint %+.0f in %.0f ms", awb.temperature, awb.tint, Date().timeIntervalSince(t4) * 1000))
    try rr.export(sky, to: tmp.appendingPathComponent("raw-out.jpg"), options: ExportOptions())
    check(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("raw-out.jpg").path), "RAW full-res export")
}

print("Colour grading")
var blueShadows = ColorGrade(); blueShadows.shadows = Wheel(hue: 220, sat: 50)
let black = ColorLUT.apply(.zero, grade: blueShadows, mixer: ColorMixer())
check(black == .zero, "shadow colour leaves pure black untouched (no light to colour)")
let dark = ColorLUT.apply(SIMD3(repeating: 0.2), grade: blueShadows, mixer: ColorMixer())
check(dark.z > dark.x + 0.03, "shadow colour tints dark greys blue")
var lifted = blueShadows; lifted.shadows.lum = 40
let liftedBlack = ColorLUT.apply(.zero, grade: lifted, mixer: ColorMixer())
check(liftedBlack.z > liftedBlack.x && liftedBlack.z > 0.02, "raising shadow luminance lets black take the colour")
var pinkHi = ColorGrade(); pinkHi.highlights = Wheel(hue: 330, sat: 50)
check(ColorLUT.apply(SIMD3(repeating: 1), grade: pinkHi, mixer: ColorMixer()) == SIMD3(repeating: 1), "highlight colour leaves pure white untouched")
pinkHi.highlights.lum = -40
let pinkWhite = ColorLUT.apply(SIMD3(repeating: 1), grade: pinkHi, mixer: ColorMixer())
check(pinkWhite.x > pinkWhite.y + 0.02, "lowering highlight luminance lets white take the colour")
let w0 = ColorLUT.rangeWeights(0.5, blending: 50, balance: 0), w1 = ColorLUT.rangeWeights(0.5, blending: 50, balance: 80)
check(w1.h > w0.h, "balance → right favours the highlights")
let sharp = ColorLUT.rangeWeights(0.3, blending: 0, balance: 0), soft = ColorLUT.rangeWeights(0.3, blending: 100, balance: 0)
check(soft.s > 0.05 && soft.m > 0.05 && min(sharp.s, sharp.m) < min(soft.s, soft.m), "blending smooths the shadow/midtone transition")
var comp = ColorGrade(); comp.harmony = .complementary; comp.shadows.hue = 210; comp.applyHarmony(changed: .shadows)
check(comp.highlights.hue == 30 && comp.midtones.hue == 30, "complementary: blue shadows → orange highlights & mids")
var ana = ColorGrade(); ana.harmony = .analogous; ana.midtones.hue = 40; ana.applyHarmony(changed: .midtones)
check(ana.shadows.hue == 10 && ana.highlights.hue == 70, "analogous keeps hues 30° apart")

print("Colour mixer")
var mix = ColorMixer(); mix.sat[0] = 100
check(ColorLUT.apply(SIMD3(repeating: 0.5), grade: ColorGrade(), mixer: mix) == SIMD3(repeating: 0.5), "red saturation does nothing to grey (can't add colour)")
let red = ColorLUT.apply(SIMD3(0.6, 0.4, 0.4), grade: ColorGrade(), mixer: mix)
check(red.x - red.y > 0.2 + 0.05, "red saturation boosts existing reds")

print("Auto white balance")
let warmCast = makePNG("cast.png", w: 200, h: 150) { x, y in
    let v = Double(60 + (x + y) % 140); return (UInt8(min(255, v * 1.18)), UInt8(v), UInt8(v * 0.80))
}
let wr = try Renderer(url: warmCast, previewMax: 400)
let (at, an) = wr.autoWhiteBalance(EditSettings())
var wb = EditSettings(); wb.temperature = at; wb.tint = an
let castH = try wr.renderPreview(EditSettings()).analysis.histogram, fixH = try wr.renderPreview(wb).analysis.histogram
func centroid(_ h: [Float]) -> Double { let s = h.reduce(0, +); return s > 0 ? zip(h.indices, h).reduce(0.0) { $0 + Double($1.0) * Double($1.1) } / Double(s) : 0 }
let before = centroid(castH.red) - centroid(castH.blue), after = centroid(fixH.red) - centroid(fixH.blue)
print(String(format: "    auto → temperature %.0f, tint %.0f; red–blue gap %.1f → %.1f", at, an, before, after))
check(at < 0 && abs(after) < abs(before) * 0.3, "auto WB cools a warm cast to near-neutral")

print("Grade through the pipeline")
var bo = EditSettings(); bo.grade = ColorGrade.starters[0].grade
let boImg = try r.renderPreview(bo).analysis.histogram, plain = try r.renderPreview(EditSettings()).analysis.histogram
check(centroid(boImg.blue) > centroid(plain.blue) - 0.5 && boImg != plain, "Blue & Orange starter changes the render")
let ranges = try r.renderPreview(bo, showRanges: true)
check(ranges.image.width > 0, "tonal-range view renders")

print("Black & white")
var bwOn = BlackWhite(); bwOn.enabled = true
let gOut = ColorLUT.apply(SIMD3(0.7, 0.3, 0.2), grade: ColorGrade(), mixer: ColorMixer(), bw: bwOn)
check(gOut.x == gOut.y && gOut.y == gOut.z, "converts to neutral grey")
var redF = bwOn; redF.filter = .red; redF.intensity = 100
let redPx = SIMD3(0.7, 0.25, 0.2), bluePx = SIMD3(0.2, 0.35, 0.75)
check(redF.gray(redPx) > bwOn.gray(redPx) && redF.gray(bluePx) < bwOn.gray(bluePx), "red filter + intensity: reds lighter, blue skies darker")
var noInt = redF; noInt.intensity = 0
check(abs(noInt.gray(redPx) - ColorLUT.luma(redPx)) < 1e-9, "intensity 0 = plain luminance")
var neu = bwOn; neu.intensity = 0; neu.neutrals = 80
check(neu.gray(SIMD3(repeating: 0.5)) > 0.55 && neu.gray(.zero) == 0 && neu.gray(SIMD3(repeating: 1)) == 1, "neutrals lightens greys, black/white anchored")
var toned = EditSettings(); toned.bw.enabled = true; toned.bw.tone = 60
let tA = try r.renderPreview(toned).analysis
var flatBW = EditSettings(); flatBW.bw.enabled = true
let fA = try r.renderPreview(flatBW).analysis
print(String(format: "    B&W median %.0f; output median flat %.0f → toned %.0f", tA.bwMedian, fA.outputMedian, tA.outputMedian))
check(abs(tA.outputMedian - fA.outputMedian) < 4, "Tone pivots on the B&W median (brightness held)")
var sepia = toned; sepia.grade.highlights = Wheel(hue: 35, sat: 40)
let sh = try r.renderPreview(sepia).analysis.histogram
check(centroid(sh.red) > centroid(sh.blue) + 1, "colour grade tones the B&W image")

print("Grain")
let midGray = makePNG("mid.png", w: 300, h: 200) { x, _ in x < 150 ? (0, 0, 0) : (128, 128, 128) }
let mr = try Renderer(url: midGray, previewMax: 300)
var gr0 = EditSettings(); gr0.grain.amount = 60
let gImg = try mr.renderPreview(gr0).image
var gpx = [UInt8](repeating: 0, count: 300 * 200 * 4)
let gctx = CGContext(data: &gpx, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 1200,
                     space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
gctx.draw(gImg, in: CGRect(x: 0, y: 0, width: 300, height: 200))
func stats(_ x0: Int, _ x1: Int) -> (Double, Double) {
    var v = [Double](); for y in 20..<180 { for x in x0..<x1 { v.append(Double(gpx[(y * 300 + x) * 4 + 1])) } }
    let m = v.reduce(0, +) / Double(v.count); let sd = (v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(v.count)).squareRoot()
    return (m, sd)
}
let (bm, bsd) = stats(10, 140), (gm, gsd) = stats(160, 290)
print(String(format: "    black: mean %.1f sd %.2f | mid grey: mean %.1f sd %.2f", bm, bsd, gm, gsd))
check(bsd < 1 && bm < 2, "grain leaves pure black clean")
check(gsd > 4 && abs(gm - 128) < 4, "grain adds texture to midtones without shifting brightness")
let gImg2 = try mr.renderPreview(gr0).image
check((gImg2.dataProvider?.data as Data?) == (gImg.dataProvider?.data as Data?), "grain pattern is stable between renders (no shimmer while editing)")

print("Brilliance")
var bril = EditSettings(); bril.brilliance = 60
let brA = try r.renderPreview(bril).analysis
check(brA.outputMedian > flat.analysis.outputMedian + 3, "brilliance lifts a dark image")

print("Crop")
var topCrop = EditSettings(); topCrop.crop = CropRect(x: 0, y: 0, w: 1, h: 0.25)
let tc = try r.renderPreview(topCrop)
check(tc.analysis.globalMedian > 140, "cropping to the sky re-measures the median on the crop (\(Int(tc.analysis.globalMedian)))")
check(abs(Double(tc.image.width) / Double(tc.image.height) - 4.0 * 1.5) < 0.1, "crop has the right shape")
var bottomSky = EditSettings(); bottomSky.crop = CropRect(x: 0.2, y: 0.5, w: 0.6, h: 0.5)
var sk = LocalAdjustment(kind: .sky); sk.contrast = 30; bottomSky.localAdjustments = [sk]
let bsA = try r.renderPreview(bottomSky).analysis
check((bsA.localCoverage[sk.id] ?? 1) < 0.02, "sky mask stays aligned to the full frame when cropped (no sky in a ground crop)")
var topSky = topCrop; var sk2 = LocalAdjustment(kind: .sky); topSky.localAdjustments = [sk2]
check((try r.renderPreview(topSky).analysis.localCoverage[sk2.id] ?? 0) > 0.9, "sky mask fills a sky-only crop")
var cropOpts = ExportOptions(); cropOpts.format = .png
try r.export(bottomSky, to: tmp.appendingPathComponent("crop.png"), options: cropOpts)
let cp = CGImageSourceCreateWithURL(tmp.appendingPathComponent("crop.png") as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] }
check((cp?[kCGImagePropertyPixelWidth as String] as? Int) == 360 && (cp?[kCGImagePropertyPixelHeight as String] as? Int) == 200, "export honours the crop (360×200)")
let beforeCrop = r.renderBefore(crop: bottomSky.crop)
check(beforeCrop?.width == 360, "before view is cropped the same way")
let det = try r.renderDetail(EditSettings(), analysis: flat.analysis, region: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), maxPixels: CGSize(width: 4000, height: 4000))
check(det.width == 300 && det.height == 200, "detail render returns the requested region at full resolution")

print("Edit log & style patterns")
var l1 = EditSettings(); l1.contrast = 30; l1.mixer.sat[5] = -20; l1.grade.shadows = Wheel(hue: 210, sat: 25)
let flat1 = EditLogFormat.flatten(l1)
check((flat1["contrast"] as? Double) == 30 && (flat1["mixer.sat.Blue"] as? Double) == -20, "settings flatten to readable keys (mixer.sat.Blue)")
let e1 = EditLogFormat.entry(event: "edit", file: URL(fileURLWithPath: "/p/a.cr3"), settings: l1, previous: nil, median: 64,
                             imageSize: CGSize(width: 6000, height: 4000))
let s1 = e1["settings"] as! [String: Any]
check(s1.count == 4 && s1["exposure"] == nil, "entry stores only non-default settings")
var l2 = l1; l2.contrast = 45
let e2 = EditLogFormat.entry(event: "edit", file: URL(fileURLWithPath: "/p/a.cr3"), settings: l2, previous: EditLogFormat.flatten(l1))
check((e2["changed"] as! [String: Any]).keys.sorted() == ["contrast"], "entry records what changed since last time")
var b1 = EditSettings(); b1.bw.enabled = true; b1.bw.filter = .red; b1.grain.amount = 40; b1.contrast = 20
b1.crop = CropRect(x: 0.1, y: 0, w: 0.6, h: 1); b1.cropAspect = "5:4-p"
var b2 = b1; b2.grain.amount = 20; b2.bw.filter = .orange
let logLines = [e1, e2,
    EditLogFormat.entry(event: "edit", file: URL(fileURLWithPath: "/p/b.cr3"), settings: b1, previous: nil),
    EditLogFormat.entry(event: "export", file: URL(fileURLWithPath: "/p/c.jpg"), settings: b2, previous: nil)]
// round-trip through JSON like the real log file
let parsed = logLines.map { try! JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: $0)) as! [String: Any] }
let sum = StyleSummary(parsed)
print("    " + sum.text.split(separator: "\n").prefix(2).joined(separator: " | "))
check(sum.photos == 3, "summary counts each photo once (3)")
check(abs(sum.bwShare - 2.0 / 3) < 0.01 && abs(sum.grainShare - 2.0 / 3) < 0.01 && abs(sum.grainAverage - 30) < 0.01, "B&W 67%, grain 67% avg 30")
check(abs((sum.usage.first { $0.id == "contrast" }?.average ?? 0) - (45 + 20 + 20) / 3.0) < 0.01, "contrast average uses each photo's latest state")
check(sum.aspects.first?.0 == "5:4-p" && abs(sum.cropShare - 2.0 / 3) < 0.01, "crop ratio habits")
check(abs((StyleSummary.circularMean([350, 10]) ?? 99) - 0) < 0.01 || abs((StyleSummary.circularMean([350, 10]) ?? 0) - 360) < 0.01, "hue averages wrap around red")

print("Vignette")
func regionLuma(_ cg: CGImage, _ fx: Double, _ fy: Double, _ fs: Double = 0.06) -> Double {
    let w = Int(Double(cg.width) * fs), h = Int(Double(cg.height) * fs)
    let x = Int(Double(cg.width - w) * fx), y = Int(Double(cg.height - h) * fy)
    return meanLuma(cg.cropping(to: CGRect(x: x, y: y, width: w, height: h))!)
}
let grey = makePNG("grey.png") { _, _ in (128, 128, 128) }
let vr = try Renderer(url: grey, previewMax: 1200)
let vPlain = try vr.renderPreview(EditSettings()).image
var vs = EditSettings(); vs.vignette.amount = -100
let vDark = try vr.renderPreview(vs)
check(regionLuma(vDark.image, 0, 0) < regionLuma(vPlain, 0, 0) - 40, "negative amount darkens the corners")
check(abs(regionLuma(vDark.image, 0.5, 0.5) - regionLuma(vPlain, 0.5, 0.5)) < 3, "…and leaves the centre alone")
check(vDark.analysis.vignetteCentre == CGPoint(x: 0.5, y: 0.5), "Centre mode reports the frame centre")
vs.vignette.amount = 60
check(regionLuma(try vr.renderPreview(vs).image, 1, 1) > regionLuma(vPlain, 1, 1) + 15, "positive amount lightens the corners")
vs.vignette.amount = -100; vs.vignette.centre = .manual; vs.vignette.x = 0.15; vs.vignette.y = 0.3
let moved = try vr.renderPreview(vs)
check(regionLuma(moved.image, 0, 0.5) > regionLuma(moved.image, 1, 0.5) + 20, "a manual centre on the left keeps the left bright")
check(regionLuma(moved.image, 0.15, 0.3) > regionLuma(moved.image, 0.15, 0.95) + 10, "…and y runs down from the top")
vs.vignette.centre = .subject
let noSubject = try vr.renderPreview(vs)
check(noSubject.analysis.vignetteCentre == CGPoint(x: 0.5, y: 0.5) && !noSubject.analysis.vignetteSubjectFound,
      "Subject mode with no subject falls back to the centre and says so")
var crop = EditSettings(); crop.vignette.amount = -100; crop.crop = CropRect(x: 0.5, y: 0, w: 0.5, h: 1)
let cropped = try vr.renderPreview(crop).image
check(regionLuma(cropped, 0.5, 0.5) > regionLuma(cropped, 0, 0) + 40, "the vignette follows the crop, not the full frame")

print("Shot sidecars")
do {
    var sc = ShotSidecar()
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    sc.created = t0; sc.modified = t0
    sc.files = [.init(name: "A.ARW", role: .source, bytes: 10), .init(name: "A.JPG", role: .companion, bytes: 5)]
    var e = EditSettings(); e.exposure = 0.4; e.contrast = 20
    sc.edit = e
    sc.variations = [.init(number: 1, date: t0, settings: EditSettings())]
    sc.tags = .init(favourite: true, labels: ["coast"])
    sc.uploads.apple = .init(date: t0, version: "v1")
    let back = try ShotSidecar.decode(try ShotSidecar.encode(sc))
    check(back == sc, "a sidecar survives encode → decode unchanged")
    check(back.sourceName == "A.ARW", "the source file is the one marked source")

    let sparse = try ShotSidecar.decode(Data(#"{"edit":{"exposure":0.5},"tags":{"labels":["x"]}}"#.utf8))
    check(sparse.edit?.exposure == 0.5 && sparse.edit?.contrast == 0, "a sidecar missing keys still loads, with defaults")
    check(sparse.variations.isEmpty && !sparse.tags.favourite && sparse.version == ShotSidecar.currentVersion,
          "…including missing collections and version")
    let newer = try ShotSidecar.decode(Data(#"{"version":2,"future":"field"}"#.utf8))
    check(newer.version > ShotSidecar.currentVersion, "a newer sidecar reports its version, so the app can open it read-only")
    check(ShotSidecar().isEmpty && !sc.isEmpty, "isEmpty is true only when there's nothing to keep")
    var onlyUpload = ShotSidecar(); onlyUpload.uploads.google = .init(date: t0, version: nil)
    check(!onlyUpload.isEmpty, "upload state alone is worth keeping")
} catch { check(false, "sidecar round-trip threw \(error)") }

print("Shot grouping")
do {
    let dir = tmp.appendingPathComponent("shots-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for n in ["DSC_1.ARW", "dsc_1.jpg", "DSC_2.JPG", "IMG_3.HEIC", "IMG_3.png", "notes.txt", "DSC_1.fulcrum"] {
        FileManager.default.createFile(atPath: dir.appendingPathComponent(n).path, contents: Data())
    }
    let jpg = dir.appendingPathComponent("dsc_1.jpg")
    let pair = ShotGrouping.shotFiles(containing: jpg).map(\.lastPathComponent)
    check(pair == ["DSC_1.ARW", "dsc_1.jpg"], "RAW+JPEG pair groups across case, RAW first (got \(pair))")
    check(ShotGrouping.sidecarURL(forSource: dir.appendingPathComponent("DSC_1.ARW")).lastPathComponent == "DSC_1.fulcrum",
          "the sidecar is named after the source")
    let all = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
    let groups = ShotGrouping.group(all).map { $0.map(\.lastPathComponent) }.sorted { $0[0] < $1[0] }
    check(groups == [["DSC_1.ARW", "dsc_1.jpg"], ["DSC_2.JPG"], ["IMG_3.HEIC", "IMG_3.png"]],
          "a folder groups into three shots, ignoring non-photos (got \(groups))")
} catch { check(false, "grouping threw \(error)") }

print("Migration from path-keyed stores")
do {
    let raw = URL(fileURLWithPath: "/shoot/DSC_9.ARW"), jpg = URL(fileURLWithPath: "/shoot/DSC_9.JPG")
    let lone = URL(fileURLWithPath: "/shoot/IMG_1.HEIC"), gone = "/elsewhere/old.jpg"
    var a = EditSettings(); a.exposure = 1
    var b = EditSettings(); b.contrast = 40
    let d1 = Date(timeIntervalSince1970: 1_700_000_000), d2 = d1.addingTimeInterval(3600)
    var tRaw = LegacyPhotoTags(); tRaw.labels = ["sea", "Dusk"]; tRaw.uploadedApple = d1; tRaw.uploadedAppleVersion = "old"
    var tJpg = LegacyPhotoTags(); tJpg.favorite = true; tJpg.labels = ["dusk", "rocks"]; tJpg.uploadedApple = d2; tJpg.uploadedAppleVersion = "new"
    let legacy = ShotMigration.Legacy(
        edits: [raw.path: a, jpg.path: b, lone.path: b, gone: a],
        snapshots: [jpg.path: [.init(number: 3, date: d1, settings: a)]],
        tags: [raw.path: tRaw, jpg.path: tJpg])
    let files: [String: [URL]] = [raw.path: [raw, jpg], jpg.path: [raw, jpg], lone.path: [lone]]
    let plan = ShotMigration.plan(legacy, exists: { files[$0] != nil }, shotFiles: { files[$0.path]! }, now: d2)
    check(plan.shots.count == 2, "three existing paths become two shots (got \(plan.shots.count))")
    if let pairShot = plan.shots.first(where: { $0.sidecar.sourceName == "DSC_9.ARW" })?.sidecar {
        check(pairShot.edit == a, "the RAW's edit wins")
        check(pairShot.variations.map(\.settings) == [a, b] && pairShot.variations.map(\.number) == [1, 2],
              "the snapshot comes first, then the JPEG's differing edit as a variation, renumbered")
        check(pairShot.tags.favourite && pairShot.tags.labels == ["sea", "Dusk", "rocks"],
              "favourite if either was; labels merged ignoring case (got \(pairShot.tags.labels))")
        check(pairShot.uploads.apple == .init(date: d2, version: "new"), "the latest upload is kept with its version")
    } else { check(false, "the pair produced a sidecar") }
    check(plan.shots.first { $0.sidecar.sourceName == "IMG_1.HEIC" }?.sidecarURL.path == "/shoot/IMG_1.fulcrum",
          "a lone photo gets its own sidecar beside it")
    check(plan.unmatched.edits.keys.sorted() == [gone], "a missing photo's entry is kept as unmatched, not dropped")
    var same = legacy; same.edits[jpg.path] = a
    let samePlan = ShotMigration.plan(same, exists: { files[$0] != nil }, shotFiles: { files[$0.path]! }, now: d2)
    check(samePlan.shots.first { $0.sidecar.sourceName == "DSC_9.ARW" }?.sidecar.variations.count == 1,
          "identical RAW and JPEG edits don't add a variation")
}

print("Library index")
do {
    let fm = FileManager.default
    let base = tmp.appendingPathComponent("library-\(UUID().uuidString)", isDirectory: true)
    let root = base.appendingPathComponent("Fulcrum", isDirectory: true)
    let dayA = root.appendingPathComponent("2026-11-01", isDirectory: true)
    let dayB = root.appendingPathComponent("2026-11-14", isDirectory: true)
    let pkg = root.appendingPathComponent("Old.photoslibrary/originals", isDirectory: true)
    for d in [dayA, dayB, pkg] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
    func touch(_ u: URL, _ date: Date) {
        fm.createFile(atPath: u.path, contents: Data())
        try? fm.setAttributes([.modificationDate: date], ofItemAtPath: u.path)
    }
    let t = Date(timeIntervalSince1970: 1_790_000_000)
    for n in ["DSC_1.ARW", "DSC_1.JPG", "DSC_2.ARW"] { touch(dayA.appendingPathComponent(n), t) }
    for n in ["IMG_5.HEIC", "IMG_6.HEIC"] { touch(dayB.appendingPathComponent(n), t.addingTimeInterval(86_400 * 13)) }
    touch(pkg.appendingPathComponent("inside.jpg"), t)
    var sc = ShotSidecar(); sc.edit = EditSettings(); sc.tags.favourite = true
    sc.files = ShotGrouping.makeFiles([dayA.appendingPathComponent("DSC_1.ARW"), dayA.appendingPathComponent("DSC_1.JPG")])
    try ShotSidecar.encode(sc).write(to: dayA.appendingPathComponent("DSC_1.fulcrum"))

    let dbURL = base.appendingPathComponent("library.sqlite")
    var idx: LibraryIndex? = try LibraryIndex(url: dbURL)
    let first = try idx!.refresh(root: root)
    let shoots = try idx!.shoots()
    check(shoots.map(\.name) == ["2026-11-14", "2026-11-01"], "two shoots, newest first, package contents skipped (got \(shoots.map(\.name)))")
    check(shoots.last?.shots == 2 && shoots.last?.edited == 1 && shoots.last?.favourites == 1,
          "a RAW+JPEG pair counts as one shot, with its sidecar's edit and favourite")
    let pair = try idx!.shots(.shoot(dayA.standardizedFileURL.path)).first
    check(pair?.source == "DSC_1.ARW" && pair?.kinds == "ARW+JPG" && pair?.id == sc.id.uuidString,
          "a shot row names its source, kinds and sidecar id")
    check(try idx!.count(.favourites) == 1 && idx!.count(.readyToUpload) == 1, "Favourites and To Upload count from sidecars")
    check(first.foldersScanned == 3, "the first refresh reads the root and both shoots, not the package (got \(first.foldersScanned))")
    check(try idx!.refresh(root: root).foldersScanned == 0, "a second refresh with nothing changed reads nothing")

    sc.uploads.apple = .init(date: t, version: "v")
    try ShotSidecar.encode(sc).write(to: dayA.appendingPathComponent("DSC_1.fulcrum.tmp"))
    _ = try fm.replaceItemAt(dayA.appendingPathComponent("DSC_1.fulcrum"), withItemAt: dayA.appendingPathComponent("DSC_1.fulcrum.tmp"))
    let r = try idx!.refresh(root: root)
    check(r.foldersScanned == 1 && r.shotsChanged == 1, "saving a sidecar rescans only its folder (got \(r))")
    check(try idx!.count(.readyToUpload) == 0, "an uploaded shot leaves To Upload")

    try fm.removeItem(at: dayB)
    _ = try idx!.refresh(root: root)
    check(try idx!.shoots().map(\.name) == ["2026-11-01"], "a deleted folder's shoot disappears")

    idx = nil
    idx = try LibraryIndex(url: dbURL)
    check(try idx!.refresh(root: root).foldersScanned == 0 && idx!.shoots().count == 1, "the index persists between launches")
    let other = base.appendingPathComponent("Elsewhere", isDirectory: true)
    try fm.createDirectory(at: other, withIntermediateDirectories: true)
    _ = try idx!.refresh(root: other)
    check(try idx!.shoots().isEmpty, "changing the library folder starts the index again")
    try fm.removeItem(at: dbURL)
    idx = try LibraryIndex(url: dbURL)
    _ = try idx!.refresh(root: root)
    check(try idx!.shoots().count == 1 && idx!.count(.favourites) == 1, "a deleted index rebuilds from the sidecars")
} catch { check(false, "library index threw \(error)") }

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
