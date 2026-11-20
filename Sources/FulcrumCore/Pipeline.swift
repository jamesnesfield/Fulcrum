import CoreImage
import CoreImage.CIFilterBuiltins

/// What the analysis pass measured, and the pivots it decided on (all tones in 0–255 sRGB luminosity).
public struct AnalysisResult: Equatable {
    public var globalMedian: Double = 128         // median before contrast — the transcript's "53"
    public var globalPivot: Double = 128          // where the global curve is locked
    public var outputMedian: Double = 128
    public var localMedians: [UUID: Double] = [:] // median of the masked region — the sky's "177"
    public var localPivots: [UUID: Double] = [:]
    public var localCoverage: [UUID: Double] = [:] // mean mask weight 0...1
    public var bwMedian: Double = 128             // median grey of the B&W conversion — Tone pivots here
    public var vignetteCentre: CGPoint?           // 0–1 of the cropped frame from the top-left, when a vignette is on
    public var vignetteSubjectFound = true        // false when Subject mode found no subject and fell back to the centre
    public var vignetteHandle = false             // show the movable centre handle (Manual or Subject mode)
    public var vignette: Vignette?                // the vignette as rendered, to draw its boundary on the photo
    public var preContrastHistogram: [Float] = Histogram.empty.luma
    public var histogram: Histogram = .empty
    public init() {}
}

/// Builds the Core Image graph. Order:
/// decode/WB → exposure → highlights/shadows → [measure median] → median-pivot contrast →
/// local adjustments (each measures its own masked median) → clarity → vibrance/saturation.
public final class Pipeline: @unchecked Sendable {
    public let context: CIContext
    public init(context: CIContext) { self.context = context }

    /// The pre-contrast median only depends on the light stage — skip re-measuring it while
    /// contrast, colour, B&W or grain sliders move.
    private var globalCache: (key: EditSettings.LightKey, median: Double, hist: [Float])?

    private func pixelScale(_ img: CIImage) -> CGFloat { max(img.extent.width, img.extent.height) / 1000 }

    func light(_ base: CIImage, _ s: EditSettings, isRAW: Bool) -> CIImage {
        var img = base
        let e = base.extent
        if !isRAW, s.temperature != 0 || s.tint != 0 {
            let f = CIFilter.temperatureAndTint()
            f.inputImage = img
            f.neutral = CIVector(x: 6500, y: 0)
            f.targetNeutral = CIVector(x: CGFloat(WhiteBalance.kelvin(base: 6500, slider: -s.temperature)), y: CGFloat(-s.tint))
            img = f.outputImage ?? img
        }
        if s.exposure != 0 { img = exposure(img, s.exposure) }
        let b = s.brilliance / 100
        if s.highlights > 0 || s.shadows != 0 || b != 0 {
            let f = CIFilter.highlightShadowAdjust()
            f.inputImage = img
            f.highlightAmount = Float(max(0.1, 1 - s.highlights / 100 * 0.9 - max(b, 0) * 0.45))
            f.shadowAmount = Float(min(max(s.shadows / 100 + b * 0.6, -1), 1))
            f.radius = Float(max(1, 8 * pixelScale(base)))
            img = f.outputImage ?? img
        }
        if b != 0 {
            // Brilliance also adds a little local contrast (or removes it when negative).
            let u = CIFilter.unsharpMask()
            u.inputImage = img.clampedToExtent()
            u.radius = Float(12 * pixelScale(base))
            u.intensity = Float(b * 0.3)
            img = u.outputImage ?? img
        }
        return img.cropped(to: e)
    }

    func exposure(_ img: CIImage, _ ev: Double) -> CIImage {
        let f = CIFilter.exposureAdjust()
        f.inputImage = img
        f.ev = Float(ev)
        return f.outputImage ?? img
    }

    /// The core move: a curve locked at `pivot` (0–255) on both input and output.
    public func contrast(_ img: CIImage, pivot: Double, amount: Double, luminosityOnly: Bool) -> CIImage {
        guard amount != 0 else { return img }
        let a = ContrastCurve.exponent(forAmount: amount)
        let lut = ContrastCurve.lut(pivot: pivot / 255, exponent: a)
        var table = [Float]()
        table.reserveCapacity(lut.count * 3)
        for v in lut { table += [v, v, v] }
        let f = CIFilter.colorCurves()
        f.inputImage = img
        f.curvesData = table.withUnsafeBufferPointer { Data(buffer: $0) }
        f.curvesDomain = CIVector(x: 0, y: 1)
        f.colorSpace = Raster.sRGB      // curve operates on gamma-encoded tones, like Photoshop/Lightroom
        guard var out = f.outputImage else { return img }
        if luminosityOnly {
            let l = CIFilter.luminosityBlendMode()
            l.inputImage = out
            l.backgroundImage = img
            out = l.outputImage ?? out
        }
        return out.cropped(to: img.extent)
    }

    func saturate(_ img: CIImage, _ amount: Double) -> CIImage {
        guard amount != 0 else { return img }
        let f = CIFilter.colorControls()
        f.inputImage = img
        f.saturation = Float(1 + amount / 100)
        f.brightness = 0
        f.contrast = 1
        return f.outputImage ?? img
    }

    func presence(_ input: CIImage, _ s: EditSettings) -> CIImage {
        var img = input
        let e = input.extent
        if s.clarity != 0 {
            let f = CIFilter.unsharpMask()
            f.inputImage = img.clampedToExtent()
            f.radius = Float(20 * pixelScale(input))
            f.intensity = Float(s.clarity / 100 * 0.8)
            img = (f.outputImage ?? img).cropped(to: e)
        }
        if s.vibrance != 0 {
            let f = CIFilter.vibrance()
            f.inputImage = img
            f.amount = Float(s.vibrance / 100)
            img = f.outputImage ?? img
        }
        img = saturate(img, s.saturation)
        return img.cropped(to: e)
    }

    private var lutKey: (ColorGrade, ColorMixer, BlackWhite, Double)?
    private var lutData: Data?
    private let lutLock = NSLock()

    /// Colour mixer + colour grade, baked into a 3D LUT (rebuilt only when those settings change).
    func colorLUT(_ img: CIImage, _ s: EditSettings, bwPivot: Double) -> CIImage {
        guard !(s.grade.isNeutral && s.mixer.isNeutral && !s.bw.enabled) else { return img }
        lutLock.lock()
        let key = (s.grade, s.mixer, s.bw, bwPivot)
        if lutKey == nil || lutKey! != key {
            lutData = ColorLUT.cube { ColorLUT.apply($0, grade: s.grade, mixer: s.mixer, bw: s.bw, bwPivot: bwPivot) }
            lutKey = key
        }
        let data = lutData!
        lutLock.unlock()
        return applyCube(img, data)
    }

    func applyCube(_ img: CIImage, _ data: Data) -> CIImage {
        let f = CIFilter.colorCubeWithColorSpace()
        f.inputImage = img
        f.cubeDimension = Float(ColorLUT.size)
        f.cubeData = data
        f.colorSpace = Raster.sRGB
        return f.outputImage ?? img
    }

    /// Shared graph builder. The hooks either measure (analysis) or look up (render) the pivots,
    /// so preview, analysis and export are guaranteed to use identical maths.
    func build(base: CIImage, settings s: EditSettings, isRAW: Bool, masks: MaskCache?,
               globalPivot: (CIImage) -> Double,
               localPivot: (LocalAdjustment, CIImage, CIImage) -> Double,
               bwPivot: (CIImage) -> Double = { _ in 128 },
               maskSink: ((UUID, CIImage) -> Void)? = nil,
               vignetteSink: ((CGPoint, Bool) -> Void)? = nil) -> (preContrast: CIImage, output: CIImage) {
        let full = base.extent
        let r = s.crop.pixelRect(in: full)
        let frame = Masks.Frame(full: CGRect(origin: .zero, size: full.size),
                                crop: r.offsetBy(dx: -full.minX, dy: -full.minY))
        let cropped = r == full ? base
            : base.cropped(to: r).transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))
        let pre = light(cropped, s, isRAW: isRAW)
        var img = contrast(pre, pivot: globalPivot(pre), amount: s.contrast, luminosityOnly: s.contrastLuminosityOnly)
        for adj in s.localAdjustments where adj.enabled {
            let mask = Masks.build(adj.mask, for: img, cache: masks, frame: frame)
            maskSink?(adj.id, mask)
            let exposed = adj.exposure != 0 ? exposure(img, adj.exposure).cropped(to: img.extent) : img
            let pivot = localPivot(adj, exposed, mask)
            var adjusted = contrast(exposed, pivot: pivot, amount: adj.contrast, luminosityOnly: s.contrastLuminosityOnly)
            adjusted = saturate(adjusted, adj.saturation)
            let b = CIFilter.blendWithMask()
            b.inputImage = adjusted
            b.backgroundImage = img
            b.maskImage = mask
            img = (b.outputImage ?? img).cropped(to: img.extent)
        }
        var out = presence(img, s)
        let pivot = s.bw.enabled ? bwPivot(out) : 128
        out = colorLUT(out, s, bwPivot: pivot).cropped(to: out.extent)
        if s.vignette.isActive {
            var subject: CGPoint?
            if s.vignette.centre == .subject, let p = masks?.subjectCentre() {
                // Full-frame (top-left) → cropped frame (top-left).
                let X = p.x * frame.full.width, Y = (1 - p.y) * frame.full.height
                subject = CGPoint(x: min(max((X - frame.crop.minX) / frame.crop.width, 0), 1),
                                  y: min(max(1 - (Y - frame.crop.minY) / frame.crop.height, 0), 1))
            }
            let c = s.vignette.resolvedCentre(subject: subject)
            vignetteSink?(c, s.vignette.centre != .subject || subject != nil)
            out = s.vignette.apply(to: out, centre: c)
        }
        out = s.grain.apply(to: out)
        return (pre, out)
    }

    static func clampPivot(_ v: Double) -> Double { min(max(v, 5), 250) }

    /// Runs the graph on a small image, measuring medians as it goes.
    /// `reuse`: while a slider is moving, take local-mask medians, the B&W median and the histogram from the
    /// previous frame instead of re-measuring them (they're refreshed exactly once the slider settles).
    public func analyze(base: CIImage, settings s: EditSettings, isRAW: Bool, masks: MaskCache?,
                        reuse previous: AnalysisResult? = nil) -> AnalysisResult {
        var r = AnalysisResult()
        let lightKey = s.lightKey(isRAW: isRAW)
        let (_, out) = build(base: base, settings: s, isRAW: isRAW, masks: masks, globalPivot: { pre in
            if let g = self.globalCache, g.key == lightKey {
                r.globalMedian = g.median
                r.preContrastHistogram = g.hist
            } else {
                let c = Measure.counts(Raster.render(pre, context: self.context))
                r.globalMedian = Measure.median(c.luma)
                r.preContrastHistogram = Measure.normalized(c.luma)
                self.globalCache = (lightKey, r.globalMedian, r.preContrastHistogram)
            }
            r.globalPivot = Self.clampPivot(s.pivotAuto ? r.globalMedian + s.pivotOffset : s.manualPivot)
            return r.globalPivot
        }, localPivot: { adj, exposed, mask in
            if let p = previous, let med = p.localMedians[adj.id] {
                r.localMedians[adj.id] = med
                r.localCoverage[adj.id] = p.localCoverage[adj.id] ?? 0
                let piv = Self.clampPivot(med + adj.pivotOffset)
                r.localPivots[adj.id] = piv
                return piv
            }
            let weights = Raster.render(mask, context: self.context, colorSpace: nil)
            let c = Measure.counts(Raster.render(exposed, context: self.context), weights: weights)
            let med = Measure.median(c.luma)
            r.localMedians[adj.id] = med
            r.localCoverage[adj.id] = c.total / Double(max(weights.count, 1))
            let p = Self.clampPivot(med + adj.pivotOffset)
            r.localPivots[adj.id] = p
            return p
        }, bwPivot: { img in
            if let p = previous, s.bw.enabled { r.bwMedian = p.bwMedian; return p.bwMedian }
            // Median of the B&W conversion (mixer → filter → neutrals), measured before Tone.
            let bmp = Raster.render(img, context: self.context)
            var h = [Double](repeating: 0, count: 256)
            // Every other pixel in each direction is plenty for a median.
            for i in stride(from: 0, to: bmp.count, by: 1) where (i % bmp.width) % 2 == 0 && (i / bmp.width) % 2 == 0 {
                let o = i * 4
                var c = SIMD3(Double(bmp.bytes[o]), Double(bmp.bytes[o + 1]), Double(bmp.bytes[o + 2])) / 255
                if !s.mixer.isNeutral { c = ColorLUT.mix(c, s.mixer) }
                h[Int((s.bw.gray(c) * 255).rounded())] += 1
            }
            r.bwMedian = Measure.median(h)
            return r.bwMedian
        }, vignetteSink: { c, found in
            r.vignetteCentre = c
            r.vignetteSubjectFound = found
            r.vignetteHandle = s.vignette.centre != .frame
            r.vignette = s.vignette
        })
        if let p = previous {
            r.histogram = p.histogram
            r.outputMedian = p.outputMedian
            return r
        }
        let c = Measure.counts(Raster.render(out, context: context))
        r.histogram = Measure.histogram(c)
        r.outputMedian = Measure.median(c.luma)
        return r
    }

    /// Builds the final graph at any resolution using pivots from `analysis`.
    public func render(base: CIImage, settings s: EditSettings, isRAW: Bool, masks: MaskCache?,
                       analysis a: AnalysisResult, overlayMask: UUID? = nil, showRanges: Bool = false) -> CIImage {
        var overlay: CIImage?
        var (_, out) = build(base: base, settings: s, isRAW: isRAW, masks: masks,
                             globalPivot: { _ in a.globalPivot },
                             localPivot: { adj, _, _ in a.localPivots[adj.id] ?? 128 },
                             bwPivot: { _ in a.bwMedian },
                             maskSink: { id, m in if id == overlayMask { overlay = m } })
        if showRanges {
            out = applyCube(out, ColorLUT.rangeCube(s.grade)).cropped(to: out.extent)
        }
        if let overlay {
            let tint = CIImage(color: CIColor(red: 1, green: 0.15, blue: 0.1)).cropped(to: out.extent)
            let half = overlay.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.55, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0.55, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0.55, w: 0),
            ])
            out = tint.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: out, kCIInputMaskImageKey: half])
                .cropped(to: out.extent)
        }
        return out
    }
}
