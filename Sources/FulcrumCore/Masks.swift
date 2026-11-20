import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

/// Per-photo cache of the expensive, content-aware masks (sky and subject), computed once at analysis size.
public final class MaskCache: @unchecked Sendable {
    let analysisBase: CIImage
    let context: CIContext
    private var sky: CIImage?
    private var subject: CIImage?
    private var subjectTried = false
    var cachedSubjectCentre: CGPoint??          // nil = not measured yet; .some(nil) = no subject

    init(analysisBase: CIImage, context: CIContext) {
        self.analysisBase = analysisBase
        self.context = context
    }

    func skyMask() -> CIImage {
        if let sky { return sky }
        let bmp = Raster.render(analysisBase, context: context)
        let bytes = Masks.skyDetect(bmp)
        let m = Raster.grayImage(bytes, width: bmp.width, height: bmp.height)
        let blurred = m.clampedToExtent()
            .applyingGaussianBlur(sigma: Double(bmp.width) * 0.004)
            .cropped(to: m.extent)
        sky = blurred
        return blurred
    }

    func subjectMask() -> CIImage {
        if let subject { return subject }
        if !subjectTried {
            subjectTried = true
            if let cg = context.createCGImage(analysisBase, from: analysisBase.extent, format: .RGBA8,
                                              colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) {
                let req = VNGenerateForegroundInstanceMaskRequest()
                let handler = VNImageRequestHandler(cgImage: cg)
                if (try? handler.perform([req])) != nil, let r = req.results?.first,
                   let pb = try? r.generateScaledMaskForImage(forInstances: r.allInstances, from: handler) {
                    subject = CIImage(cvPixelBuffer: pb)
                }
            }
        }
        if let subject { return subject }
        return CIImage(color: .black).cropped(to: analysisBase.extent)
    }
}

enum Raster {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Renders to 8-bit RGBA. colorSpace nil = no colour matching (literal working-space values, used for masks).
    static func render(_ image: CIImage, context: CIContext, colorSpace: CGColorSpace? = Raster.sRGB) -> Bitmap {
        let e = image.extent.integral
        let w = max(Int(e.width), 1), h = max(Int(e.height), 1)
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        buf.withUnsafeMutableBytes { p in
            context.render(image, toBitmap: p.baseAddress!, rowBytes: w * 4, bounds: e, format: .RGBA8, colorSpace: colorSpace)
        }
        return Bitmap(bytes: buf, width: w, height: h)
    }

    static func grayImage(_ bytes: [UInt8], width: Int, height: Int) -> CIImage {
        CIImage(bitmapData: Data(bytes), bytesPerRow: width, size: CGSize(width: width, height: height), format: .L8, colorSpace: nil)
    }
}

enum Masks {
    /// Stretch an analysis-size mask over any extent.
    static func fit(_ m: CIImage, to e: CGRect) -> CIImage {
        let me = m.extent
        guard me.width > 0, me.height > 0 else { return CIImage(color: .black).cropped(to: e) }
        return m.clampedToExtent()
            .transformed(by: CGAffineTransform(translationX: -me.minX, y: -me.minY))
            .transformed(by: CGAffineTransform(scaleX: e.width / me.width, y: e.height / me.height))
            .transformed(by: CGAffineTransform(translationX: e.minX, y: e.minY))
            .cropped(to: e)
    }

    /// Where the current (possibly cropped) image sits inside the full frame the cached masks describe.
    struct Frame {
        var full: CGRect      // full-frame extent at this resolution
        var crop: CGRect      // crop rect within `full` (CI coordinates)
        func place(_ m: CIImage) -> CIImage {
            fit(m, to: full)
                .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
                .cropped(to: CGRect(origin: .zero, size: crop.size))
        }
    }

    static func build(_ spec: MaskSpec, for image: CIImage, cache: MaskCache?, frame: Frame? = nil) -> CIImage {
        let e = image.extent
        func content(_ m: CIImage) -> CIImage { frame?.place(m) ?? fit(m, to: e) }
        var m: CIImage
        switch spec.kind {
        case .everything:
            m = CIImage(color: .white).cropped(to: e)
        case .linearGradient:
            let g = CIFilter.linearGradient()
            let y0 = e.maxY - CGFloat(spec.gradientFrom) * e.height
            var y1 = e.maxY - CGFloat(spec.gradientTo) * e.height
            if abs(y1 - y0) < 1 { y1 = y0 - 1 }
            g.point0 = CGPoint(x: e.midX, y: y0)
            g.point1 = CGPoint(x: e.midX, y: y1)
            g.color0 = .white
            g.color1 = .black
            m = g.outputImage!.cropped(to: e)
        case .luminanceRange:
            m = luminanceMask(image, low: spec.lumaLow / 255, high: spec.lumaHigh / 255, feather: spec.lumaFeather / 255)
        case .sky:
            m = cache.map { content($0.skyMask()) } ?? CIImage(color: .black).cropped(to: e)
        case .subject:
            m = cache.map { content($0.subjectMask()) } ?? CIImage(color: .black).cropped(to: e)
        }
        if spec.invert { m = m.applyingFilter("CIColorInvert") }
        return m
    }

    static func luminanceMask(_ image: CIImage, low: Double, high: Double, feather: Double) -> CIImage {
        let y = CIFilter.colorMatrix()
        y.inputImage = image
        let v = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        y.rVector = v; y.gVector = v; y.bVector = v
        y.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        y.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        let f = max(feather, 0.001)
        func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
            let t = min(max((x - a) / (b - a), 0), 1); return t * t * (3 - 2 * t)
        }
        let n = 256
        var table = [Float]()
        table.reserveCapacity(n * 3)
        for i in 0..<n {
            let x = Double(i) / Double(n - 1)
            let w = smooth(low - f, low, x) * (1 - smooth(high, high + f, x))
            table += [Float(w), Float(w), Float(w)]
        }
        let c = CIFilter.colorCurves()
        c.inputImage = y.outputImage
        c.curvesData = table.withUnsafeBufferPointer { Data(buffer: $0) }
        c.curvesDomain = CIVector(x: 0, y: 1)
        c.colorSpace = Raster.sRGB
        // Curves outputs sRGB-encoded weights converted back to linear; undo that so weights are literal.
        return c.outputImage!.applyingFilter("CILinearToSRGBToneCurve").cropped(to: image.extent)
    }

    /// Heuristic sky finder: bright/blue-ish pixels flood-filled from the top edge, plus similar-coloured
    /// disconnected patches (sky through trees) in the upper part of the frame.
    static func skyDetect(_ bmp: Bitmap) -> [UInt8] {
        let w = bmp.width, h = bmp.height, n = w * h
        var cand = [Bool](repeating: false, count: n)
        var rgb = [SIMD3<Float>](repeating: .zero, count: n)
        for i in 0..<n {
            let o = i * 4
            let r = Float(bmp.bytes[o]) / 255, g = Float(bmp.bytes[o + 1]) / 255, b = Float(bmp.bytes[o + 2]) / 255
            rgb[i] = SIMD3(r, g, b)
            let l = 0.299 * r + 0.587 * g + 0.114 * b
            let spread = max(r, g, b) - min(r, g, b)
            let blueish = b > r + 0.02 && b > g - 0.06 && l > 0.22
            let brightNeutral = l > 0.62 && spread < 0.22          // overcast / clouds
            let warmGlow = l > 0.45 && r > g && g > b && spread < 0.45 && l > 0.55 // sunset sky
            cand[i] = blueish || brightNeutral || warmGlow
        }
        var mask = [UInt8](repeating: 0, count: n)
        var stack = [Int]()
        for x in 0..<w where cand[x] { stack.append(x); mask[x] = 255 }
        var sum = SIMD3<Float>.zero, count: Float = 0
        while let i = stack.popLast() {
            sum += rgb[i]; count += 1
            let x = i % w, y = i / w
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < w && ny < h {
                let j = ny * w + nx
                if mask[j] == 0, cand[j] {
                    let d = abs(rgb[j] - rgb[i])
                    if max(d.x, d.y, d.z) < 0.09 { mask[j] = 255; stack.append(j) }
                }
            }
        }
        if count > Float(n) * 0.005 {
            let mean = sum / count
            let limit = Int(Double(h) * 0.7)
            for y in 0..<limit {
                for x in 0..<w {
                    let i = y * w + x
                    if mask[i] == 0, cand[i] {
                        let d = abs(rgb[i] - mean)
                        if max(d.x, d.y, d.z) < 0.12 { mask[i] = 255 }
                    }
                }
            }
        }
        return mask
    }
}
