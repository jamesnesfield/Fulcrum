import CoreImage
import CoreVideo
import IOSurface
import ImageIO
import UniformTypeIdentifiers

public struct ExportOptions: Codable, Equatable {
    public enum Format: String, Codable, CaseIterable, Identifiable {
        case jpeg, heic, tiff16, png
        public var id: String { rawValue }
        public var label: String {
            switch self { case .jpeg: "JPEG"; case .heic: "HEIC"; case .tiff16: "TIFF (16-bit)"; case .png: "PNG" }
        }
        public var ext: String {
            switch self { case .jpeg: "jpg"; case .heic: "heic"; case .tiff16: "tif"; case .png: "png" }
        }
        var type: UTType {
            switch self { case .jpeg: .jpeg; case .heic: .heic; case .tiff16: .tiff; case .png: .png }
        }
    }
    public enum Space: String, Codable, CaseIterable, Identifiable {
        case sRGB, displayP3
        public var id: String { rawValue }
        public var label: String { self == .sRGB ? "sRGB" : "Display P3" }
        var cg: CGColorSpace { CGColorSpace(name: self == .sRGB ? CGColorSpace.sRGB : CGColorSpace.displayP3)! }
    }
    public var format: Format = .jpeg
    public var quality: Double = 0.92
    public var maxLongEdge: Int = 0          // 0 = full resolution
    public var colorSpace: Space = .sRGB
    public var suffix: String = ""
    public init() {}
}

/// Owns one photo: caches the decoded preview/analysis images and runs the pipeline.
/// Not thread-safe — use from a single serial queue.
public final class Renderer: @unchecked Sendable {
    public let source: ImageSource
    public let previewMax: CGFloat
    public let analysisMax: CGFloat = 640
    let context: CIContext
    let pipeline: Pipeline

    private var decodeKey: EditSettings.DecodeKey?
    private var previewBase: CIImage?
    private var draftBase: CIImage?
    private var surfacePool: [IOSurfaceRef] = []
    private var surfaceIndex = 0
    private var analysisBase: CIImage?
    private var masks: MaskCache?
    private var beforeCache: (CropRect, CGImage)?
    private var fullBase: (EditSettings.DecodeKey, CIImage)?

    static let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!

    public static let sharedContext = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .workingFormat: CIFormat.RGBAh,
        .name: "Fulcrum",
    ])

    public init(url: URL, previewMax: CGFloat = 2400, context: CIContext = Renderer.sharedContext) throws {
        source = try ImageSource(url: url)
        self.previewMax = previewMax
        self.context = context
        pipeline = Pipeline(context: context)
    }

    /// Bake a decoded image into a float bitmap so slider moves don't re-run the RAW demosaic.
    private func bake(_ img: CIImage) -> CIImage {
        guard let cg = context.createCGImage(img, from: img.extent, format: .RGBAh, colorSpace: Self.linear) else { return img }
        return CIImage(cgImage: cg)
    }

    private var draftKey: EditSettings.DecodeKey?
    private var analysisKey: EditSettings.DecodeKey?

    private func downscale(_ img: CIImage, to maxDim: CGFloat) -> CIImage {
        let scale = min(1, maxDim / max(img.extent.width, img.extent.height))
        guard scale < 1 else { return img }
        let d = img.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
        return bake(d.cropped(to: CGRect(x: 0, y: 0, width: floor(d.extent.width), height: floor(d.extent.height))))
    }

    /// Drafts are half the preview's size.
    private func draftMax(_ preview: CIImage) -> CGFloat { floor(max(preview.extent.width, preview.extent.height) * 0.5) }

    /// Half-size and analysis-size copies of a decoded image.
    private func deriveSmallBases(from img: CIImage, key: EditSettings.DecodeKey, includeDraft: Bool) {
        if includeDraft { draftBase = downscale(img, to: draftMax(img)); draftKey = key }
        let a = downscale(img, to: analysisMax)
        analysisBase = a; analysisKey = key
        if masks == nil { masks = MaskCache(analysisBase: a, context: context) }
    }

    /// Full-quality bases (preview, draft, analysis) for these settings.
    private func ensureBases(_ s: EditSettings) throws {
        let key = s.decodeKey(isRAW: source.isRAW)
        if key != decodeKey || previewBase == nil {
            guard let p = source.makeBase(s, maxDimension: previewMax) else { throw FulcrumError.renderFailed }
            previewBase = bake(p)
            decodeKey = key
        }
        if draftKey != key || analysisKey != key { deriveSmallBases(from: previewBase!, key: key, includeDraft: true) }
    }

    /// Bases for a draft frame while a slider moves. When a RAW decode setting (white balance,
    /// base curve, sharpening, noise reduction) has changed, render straight from open half-size and
    /// analysis-size RAW decoders (a few ms each) without copying anything off the GPU. The full
    /// preview decode happens once, when the slider settles.
    private func ensureDraftBases(_ s: EditSettings) throws {
        let key = s.decodeKey(isRAW: source.isRAW)
        if previewBase == nil { try ensureBases(s); return }
        if draftKey == key, let ak = analysisKey, ak.sameTone(as: key) { return }
        if key == decodeKey { deriveSmallBases(from: previewBase!, key: key, includeDraft: true); return }
        guard let d = source.makeBase(s, maxDimension: draftMax(previewBase!)) else { throw FulcrumError.renderFailed }
        draftBase = d; draftKey = key
        // Sharpening / noise reduction don't move the measured medians, so skip a second (slow) decode for them.
        if let ak = analysisKey, ak.sameTone(as: key) { return }
        guard let a = source.makeBase(s, maxDimension: analysisMax) else { throw FulcrumError.renderFailed }
        analysisBase = a; analysisKey = key
    }

    /// RAW only: open and warm the draft-size decoder so the first white-balance drag is fluid.
    /// Safe to call from any queue (it only touches the source's locked decoders and the thread-safe context).
    public func prewarmDraftDecode(_ s: EditSettings) {
        guard source.isRAW else { return }
        let maxDim = floor(min(previewMax, source.longEdge) * 0.5)
        var x = s
        for dt in [0.0, 1.0] {
            x.temperature = s.temperature + dt
            for m in [maxDim, analysisMax] {
                if let img = source.makeBase(x, maxDimension: m) {
                    _ = context.createCGImage(img, from: img.extent, format: .RGBA8, colorSpace: Self.linear)
                }
            }
        }
    }

    public func analyze(_ s: EditSettings, reuse: AnalysisResult? = nil) throws -> AnalysisResult {
        try ensureBases(s)
        return pipeline.analyze(base: analysisBase!, settings: s, isRAW: source.isRAW, masks: masks, reuse: reuse)
    }

    public struct Preview {
        public let image: CGImage
        public let analysis: AnalysisResult
    }

    /// A frame for the on-screen canvas: GPU-shared memory the display layer can show without copying.
    public struct Display: @unchecked Sendable {
        public let surface: IOSurfaceRef
        public let analysis: AnalysisResult
        /// Size of the full-quality preview this frame stands for (draft frames are smaller but fill the same space).
        public let logicalSize: CGSize
        public let isDraft: Bool
    }

    public func renderDisplay(_ s: EditSettings, overlayMask: UUID? = nil, showRanges: Bool = false, draft: Bool = false,
                              previous: AnalysisResult? = nil) throws -> Display {
        let a: AnalysisResult
        if draft {
            try ensureDraftBases(s)
            a = pipeline.analyze(base: analysisBase!, settings: s, isRAW: source.isRAW, masks: masks, reuse: previous)
        } else {
            a = try analyze(s)
        }
        let base = draft ? draftBase! : previewBase!
        let out = pipeline.render(base: base, settings: s, isRAW: source.isRAW, masks: masks, analysis: a,
                                  overlayMask: overlayMask, showRanges: showRanges)
        let full = s.crop.pixelRect(in: previewBase!.extent).size
        let w = Int(out.extent.width), h = Int(out.extent.height)
        let surface = try nextSurface(width: w, height: h)
        context.render(out, to: surface, bounds: out.extent, colorSpace: Self.displayP3)
        return Display(surface: surface, analysis: a, logicalSize: full, isDraft: draft)
    }

    /// Small round-robin pool so we never draw into the surface currently on screen.
    private func nextSurface(width: Int, height: Int) throws -> IOSurfaceRef {
        if surfacePool.first.map({ IOSurfaceGetWidth($0) != width || IOSurfaceGetHeight($0) != height }) ?? true {
            surfacePool = []
            for _ in 0..<3 {
                let props: [CFString: Any] = [
                    kIOSurfaceWidth: width, kIOSurfaceHeight: height, kIOSurfaceBytesPerElement: 4,
                    kIOSurfacePixelFormat: kCVPixelFormatType_32BGRA,
                    kIOSurfaceBytesPerRow: IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, width * 4),
                ]
                guard let sfc = IOSurfaceCreate(props as CFDictionary) else { throw FulcrumError.renderFailed }
                if let icc = Self.displayP3.copyICCData() { IOSurfaceSetValue(sfc, kIOSurfaceColorSpace, icc) }
                surfacePool.append(sfc)
            }
            surfaceIndex = 0
        }
        surfaceIndex = (surfaceIndex + 1) % surfacePool.count
        return surfacePool[surfaceIndex]
    }

    public func renderPreview(_ s: EditSettings, overlayMask: UUID? = nil, showRanges: Bool = false) throws -> Preview {
        let a = try analyze(s)
        let out = pipeline.render(base: previewBase!, settings: s, isRAW: source.isRAW, masks: masks, analysis: a,
                                  overlayMask: overlayMask, showRanges: showRanges)
        guard let cg = context.createCGImage(out, from: out.extent, format: .RGBA8, colorSpace: Self.displayP3) else {
            throw FulcrumError.renderFailed
        }
        return Preview(image: cg, analysis: a)
    }

    /// Grey-world auto white balance: finds the Temperature/Tint slider values that make the
    /// average of the mid-tone pixels neutral. Solved numerically, so it works for RAW and JPEG alike.
    public func autoWhiteBalance(_ s: EditSettings) -> (temperature: Double, tint: Double) {
        func cast(_ t: Double, _ n: Double) -> SIMD2<Double> {
            var x = EditSettings()
            x.temperature = t; x.tint = n; x.exposure = s.exposure; x.rawBaseCurve = s.rawBaseCurve
            guard let base = source.makeBase(x, maxDimension: 256) else { return .zero }
            let bmp = Raster.render(pipeline.light(base, x, isRAW: source.isRAW), context: context)
            var sum = SIMD3<Double>(repeating: 0), n = 0.0
            for i in 0..<bmp.count {
                let o = i * 4
                let c = SIMD3(Double(bmp.bytes[o]), Double(bmp.bytes[o + 1]), Double(bmp.bytes[o + 2])) / 255
                let l = 0.299 * c.x + 0.587 * c.y + 0.114 * c.z
                if l < 0.06 || l > 0.94 || c.max() > 0.98 { continue }   // ignore black and clipped pixels
                sum += c; n += 1
            }
            guard n > 0 else { return .zero }
            let m = sum / n
            return SIMD2(m.x - m.z, m.y - (m.x + m.z) / 2)   // (warm–cool, green–magenta)
        }
        var p = SIMD2(s.temperature, s.tint)
        for _ in 0..<3 {
            let f = cast(p.x, p.y)
            if abs(f.x) < 0.002 && abs(f.y) < 0.002 { break }
            let d = 15.0
            let fx = cast(p.x + d, p.y), fy = cast(p.x, p.y + d)
            let a = (fx.x - f.x) / d, b = (fy.x - f.x) / d, c = (fx.y - f.y) / d, e = (fy.y - f.y) / d
            let det = a * e - b * c
            guard abs(det) > 1e-9 else { break }
            let step = SIMD2((e * f.x - b * f.y) / det, (-c * f.x + a * f.y) / det)
            p -= step
            p = SIMD2(min(max(p.x, -100), 100), min(max(p.y, -100), 100))
        }
        return (p.x.rounded(), p.y.rounded())
    }

    /// The untouched photo (camera-default decode), cropped like the edit, for before/after.
    public func renderBefore(crop: CropRect = CropRect()) -> CGImage? {
        if let b = beforeCache, b.0 == crop { return b.1 }
        guard var b = source.makeBase(EditSettings(), maxDimension: previewMax) else { return nil }
        let r = crop.pixelRect(in: b.extent)
        b = b.cropped(to: r).transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))
        guard let cg = context.createCGImage(b, from: b.extent, format: .RGBA8, colorSpace: Self.displayP3) else { return nil }
        beforeCache = (crop, cg)
        return cg
    }

    /// Size of the edited output at full resolution (after crop).
    public func outputPixelSize(_ s: EditSettings) -> CGSize {
        s.crop.pixelRect(in: CGRect(origin: .zero, size: source.pixelSize)).size
    }

    /// Renders part of the edited photo from the full-resolution original — used when zoomed in past
    /// the preview's resolution. `region` is normalised (top-left origin) within the cropped output.
    public func renderDetail(_ s: EditSettings, analysis a: AnalysisResult, region: CGRect, maxPixels: CGSize) throws -> CGImage {
        try ensureBases(s)
        let key = s.decodeKey(isRAW: source.isRAW)
        let base: CIImage
        if let f = fullBase, f.0 == key { base = f.1 } else {
            guard let b = source.makeBase(s, maxDimension: nil) else { throw FulcrumError.renderFailed }
            fullBase = (key, b); base = b
        }
        let out = pipeline.render(base: base, settings: s, isRAW: source.isRAW, masks: masks, analysis: a)
        let E = out.extent
        let R = CGRect(x: E.minX + region.minX * E.width, y: E.minY + (1 - region.maxY) * E.height,
                       width: region.width * E.width, height: region.height * E.height).integral.intersection(E)
        let scale = min(1, maxPixels.width / R.width, maxPixels.height / R.height)
        var img = out.cropped(to: R).transformed(by: CGAffineTransform(translationX: -R.minX, y: -R.minY))
        if scale < 1 { img = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        let rect = CGRect(origin: .zero, size: CGSize(width: floor(R.width * scale), height: floor(R.height * scale)))
        guard let cg = context.createCGImage(img, from: rect, format: .RGBA8, colorSpace: Self.displayP3) else {
            throw FulcrumError.renderFailed
        }
        return cg
    }

    public func export(_ s: EditSettings, to url: URL, options o: ExportOptions) throws {
        let a = try analyze(s)
        guard let base = source.makeBase(s, maxDimension: o.maxLongEdge > 0 ? CGFloat(o.maxLongEdge) : nil) else {
            throw FulcrumError.renderFailed
        }
        let out = pipeline.render(base: base, settings: s, isRAW: source.isRAW, masks: masks, analysis: a)
        let sixteen = o.format == .tiff16
        guard let rendered = context.createCGImage(out, from: out.extent, format: sixteen ? .RGBA16 : .RGBA8,
                                                   colorSpace: o.colorSpace.cg),
              let opaque = Self.dropAlpha(rendered, bits: sixteen ? 16 : 8, space: o.colorSpace.cg) else {
            throw FulcrumError.renderFailed
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, o.format.type.identifier as CFString, 1, nil) else {
            throw FulcrumError.writeFailed(url)
        }
        CGImageDestinationAddImage(dest, opaque, exportProperties(o) as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw FulcrumError.writeFailed(url) }
    }

    private func exportProperties(_ o: ExportOptions) -> [String: Any] {
        var p: [String: Any] = [:]
        let m = source.metadata
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary,
                    kCGImagePropertyExifAuxDictionary] {
            if let d = m[key as String] { p[key as String] = d }
        }
        var tiff = (m[kCGImagePropertyTIFFDictionary as String] as? [String: Any]) ?? [:]
        tiff[kCGImagePropertyTIFFOrientation as String] = 1
        tiff[kCGImagePropertyTIFFSoftware as String] = "Fulcrum"
        p[kCGImagePropertyTIFFDictionary as String] = tiff
        p[kCGImagePropertyOrientation as String] = 1
        if var exif = p[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension as String)
            exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension as String)
            p[kCGImagePropertyExifDictionary as String] = exif
        }
        if o.format == .jpeg || o.format == .heic {
            p[kCGImageDestinationLossyCompressionQuality as String] = o.quality
        }
        return p
    }

    static func dropAlpha(_ img: CGImage, bits: Int, space: CGColorSpace) -> CGImage? {
        let info: UInt32 = CGImageAlphaInfo.noneSkipLast.rawValue |
            (bits == 16 ? CGBitmapInfo.byteOrder16Little.rawValue : 0)
        guard let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: bits,
                                  bytesPerRow: 0, space: space, bitmapInfo: info) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return ctx.makeImage()
    }
}
