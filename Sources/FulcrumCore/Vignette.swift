import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

/// A post-crop vignette: an exposure falloff on an ellipse fitted to the cropped frame. Its centre can
/// be the frame's centre, a point you place, or the middle of the detected subject.
public struct Vignette: Codable, Equatable {
    public enum Centre: String, Codable, CaseIterable, Identifiable {
        case frame, manual, subject
        public var id: String { rawValue }
        public var label: String {
            switch self { case .frame: "Centre"; case .manual: "Manual"; case .subject: "Subject" }
        }
    }

    public var amount: Double = 0       // −100…100: negative darkens the edges, positive lightens them
    public var size: Double = 50        // 0…100: how far out the falloff starts
    public var roundness: Double = 0    // −100 (fits the frame's shape) … 100 (a circle)
    public var feather: Double = 50     // 0…100: hard edge … very soft
    public var centre: Centre = .frame
    public var x: Double = 0.5          // manual centre, 0–1 across the cropped frame from the left
    public var y: Double = 0.5          // manual centre, 0–1 down the cropped frame from the top

    public init() {}

    public var isActive: Bool { abs(amount) >= 0.5 }

    enum CodingKeys: String, CodingKey { case amount, size, roundness, feather, centre, x, y }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 0
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? 50
        roundness = try c.decodeIfPresent(Double.self, forKey: .roundness) ?? 0
        feather = try c.decodeIfPresent(Double.self, forKey: .feather) ?? 50
        centre = (try? c.decodeIfPresent(Centre.self, forKey: .centre)) ?? .frame
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0.5
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0.5
    }

    /// Where the vignette is centred, as 0–1 of the cropped frame from the top-left.
    /// `subject` is the subject's centre in the same space, or nil when no subject was found.
    public func resolvedCentre(subject: CGPoint?) -> CGPoint {
        switch centre {
        case .frame: return CGPoint(x: 0.5, y: 0.5)
        case .manual: return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
        case .subject: return subject ?? CGPoint(x: 0.5, y: 0.5)
        }
    }

    /// The ellipse that touches the frame's edges (semi-axes, in the frame's units), and the falloff
    /// in multiples of it: where the effect starts, is half strength, and is full strength.
    private func geometry(_ size: CGSize) -> (unit: CGSize, start: Double, mid: Double, full: Double) {
        let w = Double(size.width), h = Double(size.height)
        let t = (roundness + 100) / 200                      // 0 = frame-shaped ellipse, 1 = circle
        let r = (w * h).squareRoot() / 2
        let unit = CGSize(width: (w / 2) * (1 - t) + r * t, height: (h / 2) * (1 - t) + r * t)
        let mid = 0.35 + self.size / 100 * 0.9
        let spread = mid * (0.08 + feather / 100 * 0.85)
        return (unit, max(mid - spread, 0), mid, mid + spread)
    }

    /// Semi-axes of where the effect starts, is half strength, and reaches full strength, for a frame
    /// of `size`. Used to draw the boundary on the photo.
    public func boundaries(in size: CGSize) -> (start: CGSize, mid: CGSize, full: CGSize) {
        let g = geometry(size)
        func s(_ k: Double) -> CGSize { CGSize(width: g.unit.width * k, height: g.unit.height * k) }
        return (s(g.start), s(g.mid), s(g.full))
    }

    /// 0 inside the vignette, rising to 1 where it is at full strength.
    func mask(for extent: CGRect, centre c: CGPoint) -> CIImage {
        let w = extent.width, h = extent.height
        let geo = geometry(extent.size)
        let rx = geo.unit.width, ry = geo.unit.height
        // Distances are measured in "ellipse units": 1 = the ellipse that touches the frame's edges.
        let g = CIFilter.radialGradient()
        g.center = .zero
        g.radius0 = Float(geo.start)
        g.radius1 = Float(geo.full)
        g.color0 = CIColor(red: 0, green: 0, blue: 0)
        g.color1 = CIColor(red: 1, green: 1, blue: 1)
        let cx = extent.minX + c.x * w, cy = extent.minY + (1 - c.y) * h   // CI's origin is bottom-left
        return g.outputImage!
            .transformed(by: CGAffineTransform(scaleX: rx, y: ry).concatenating(CGAffineTransform(translationX: cx, y: cy)))
            .cropped(to: extent)
    }

    /// Applies the vignette as an exposure change, so colours and black-and-white tones stay true.
    func apply(to img: CIImage, centre c: CGPoint) -> CIImage {
        guard isActive else { return img }
        let ev = amount < 0 ? amount / 100 * 2.0 : amount / 100 * 1.2
        let e = CIFilter.exposureAdjust()
        e.inputImage = img
        e.ev = Float(ev)
        let b = CIFilter.blendWithMask()
        b.inputImage = (e.outputImage ?? img).cropped(to: img.extent)
        b.backgroundImage = img
        b.maskImage = mask(for: img.extent, centre: c)
        return (b.outputImage ?? img).cropped(to: img.extent)
    }
}

extension MaskCache {
    /// Where a subject-centred vignette should sit, as 0–1 of the full frame from the top-left, or nil.
    /// Faces win: the largest face, or the middle of the main faces when several are about as big
    /// (a couple, a small group). Without a face it falls back to the centre of the subject mask.
    func subjectCentre() -> CGPoint? {
        if let c = cachedSubjectCentre { return c }
        let found = faceCentre() ?? measureSubjectCentre()
        cachedSubjectCentre = .some(found)
        return found
    }

    private func faceCentre() -> CGPoint? {
        guard let cg = context.createCGImage(analysisBase, from: analysisBase.extent, format: .RGBA8,
                                             colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { return nil }
        let req = VNDetectFaceRectanglesRequest()
        guard (try? VNImageRequestHandler(cgImage: cg).perform([req])) != nil,
              let faces = req.results, !faces.isEmpty else { return nil }
        // Vision's boxes are 0–1 with the origin at the bottom-left.
        let areas = faces.map { $0.boundingBox.width * $0.boundingBox.height }
        let largest = areas.max() ?? 0
        guard largest > 0.0004 else { return nil }   // ignore faces too small to be the subject
        var sx = 0.0, sy = 0.0, sw = 0.0
        for (f, a) in zip(faces, areas) where a >= largest * 0.5 {
            sx += f.boundingBox.midX * a; sy += (1 - f.boundingBox.midY) * a; sw += a
        }
        return CGPoint(x: sx / sw, y: sy / sw)
    }

    private func measureSubjectCentre() -> CGPoint? {
        let m = subjectMask()
        let bmp = Raster.render(m, context: context, colorSpace: nil)
        var sx = 0.0, sy = 0.0, sw = 0.0
        for row in 0..<bmp.height {
            for col in 0..<bmp.width {
                let v = Double(bmp.bytes[(row * bmp.width + col) * 4])
                if v > 8 { sx += Double(col) * v; sy += Double(row) * v; sw += v }
            }
        }
        // Ignore a "subject" that is a few stray pixels.
        guard sw > 255 * Double(bmp.count) * 0.002 else { return nil }
        return CGPoint(x: (sx / sw + 0.5) / Double(bmp.width), y: (sy / sw + 0.5) / Double(bmp.height))
    }
}
