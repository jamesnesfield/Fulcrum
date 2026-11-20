import Foundation

/// Which pixels a local adjustment touches.
public struct MaskSpec: Codable, Equatable, Hashable {
    public enum Kind: String, Codable, CaseIterable, Identifiable {
        case sky, subject, linearGradient, luminanceRange, everything
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .sky: return "Sky (auto)"
            case .subject: return "Subject (auto)"
            case .linearGradient: return "Linear Gradient"
            case .luminanceRange: return "Luminance Range"
            case .everything: return "Whole Image"
            }
        }
        public var symbol: String {
            switch self {
            case .sky: return "cloud.sun"
            case .subject: return "person.crop.rectangle"
            case .linearGradient: return "square.bottomhalf.filled"
            case .luminanceRange: return "circle.lefthalf.filled"
            case .everything: return "rectangle.fill"
            }
        }
    }

    public var kind: Kind
    /// Gradient: fraction from the top of the frame where the effect is 100%.
    public var gradientFrom: Double = 0.0
    /// Gradient: fraction from the top where the effect fades to 0%.
    public var gradientTo: Double = 0.5
    /// Luminance range in 0–255 (sRGB) units.
    public var lumaLow: Double = 128
    public var lumaHigh: Double = 255
    public var lumaFeather: Double = 24
    public var invert: Bool = false

    public init(kind: Kind) { self.kind = kind }

    enum CodingKeys: String, CodingKey { case kind, gradientFrom, gradientTo, lumaLow, lumaHigh, lumaFeather, invert }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        gradientFrom = try c.decodeIfPresent(Double.self, forKey: .gradientFrom) ?? 0
        gradientTo = try c.decodeIfPresent(Double.self, forKey: .gradientTo) ?? 0.5
        lumaLow = try c.decodeIfPresent(Double.self, forKey: .lumaLow) ?? 128
        lumaHigh = try c.decodeIfPresent(Double.self, forKey: .lumaHigh) ?? 255
        lumaFeather = try c.decodeIfPresent(Double.self, forKey: .lumaFeather) ?? 24
        invert = try c.decodeIfPresent(Bool.self, forKey: .invert) ?? false
    }
}

/// A masked, median-pivoted contrast adjustment (the "select sky, then curve around 177" move).
public struct LocalAdjustment: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var enabled = true
    public var mask: MaskSpec
    public var contrast: Double = 25        // -100...100
    public var pivotOffset: Double = 0      // added to the masked median, 0–255 units
    public var exposure: Double = 0         // EV
    public var saturation: Double = 0       // -100...100

    public init(kind: MaskSpec.Kind) {
        mask = MaskSpec(kind: kind)
        switch kind {
        case .linearGradient: mask.gradientFrom = 0; mask.gradientTo = 0.45
        case .luminanceRange: mask.lumaLow = 150; mask.lumaHigh = 255
        default: break
        }
    }

    public var name: String { mask.kind.label + (mask.invert ? " (inverted)" : "") }

    enum CodingKeys: String, CodingKey { case id, enabled, mask, contrast, pivotOffset, exposure, saturation }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        mask = try c.decode(MaskSpec.self, forKey: .mask)
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        pivotOffset = try c.decodeIfPresent(Double.self, forKey: .pivotOffset) ?? 0
        exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
    }
}

/// Crop rectangle, normalised to the (oriented) photo with a top-left origin.
public struct CropRect: Codable, Equatable {
    public var x = 0.0, y = 0.0, w = 1.0, h = 1.0
    public init(x: Double = 0, y: Double = 0, w: Double = 1, h: Double = 1) { self.x = x; self.y = y; self.w = w; self.h = h }
    public var isFull: Bool { x <= 0.0001 && y <= 0.0001 && w >= 0.9999 && h >= 0.9999 }

    /// Pixel rect in Core Image coordinates (bottom-left origin) for an image of the given extent.
    public func pixelRect(in e: CGRect) -> CGRect {
        guard !isFull else { return e }
        let r = CGRect(x: e.minX + x * e.width, y: e.minY + (1 - y - h) * e.height, width: w * e.width, height: h * e.height)
        return r.integral.intersection(e)
    }
}

public struct EditSettings: Codable, Equatable {
    // Light
    public var exposure: Double = 0             // EV, -4...4
    public var brilliance: Double = 0           // -100...100 lift shadows, hold highlights, add local punch
    public var highlights: Double = 0           // 0...100 recovery
    public var shadows: Double = 0              // -100...100

    // Median-anchored contrast
    public var contrast: Double = 0             // -100...100
    public var pivotAuto: Bool = true           // pivot = measured median + offset
    public var pivotOffset: Double = 0          // 0–255 units
    public var manualPivot: Double = 128        // used when pivotAuto == false
    public var contrastLuminosityOnly: Bool = false

    // Colour
    public var temperature: Double = 0          // -100...100 (≈ ±2500 K)
    public var tint: Double = 0                 // -100...100
    public var clarity: Double = 0              // -100...100
    public var vibrance: Double = 0             // -100...100
    public var saturation: Double = 0           // -100...100

    // RAW decode
    public var rawBaseCurve: Double = 1         // CIRAWFilter boost (0 = flat, 1 = Apple default)
    public var rawSharpening: Double? = nil     // nil = camera default
    public var rawNoiseReduction: Double? = nil // nil = camera default

    public var localAdjustments: [LocalAdjustment] = []

    // Colour grading (adds colour into tonal ranges) and mixer (edits existing colours)
    public var grade = ColorGrade()
    public var mixer = ColorMixer()

    public var bw = BlackWhite()
    public var grain = Grain()
    public var vignette = Vignette()

    public var crop = CropRect()
    public var cropAspect = "free"      // remembered ratio for the crop tool, e.g. "4:5"

    public init() {}

    public var isDefault: Bool { self == EditSettings() }

    /// Same edit without the crop (for looks, paste, and the crop tool's uncropped view).
    public var withoutCrop: EditSettings { var s = self; s.crop = CropRect(); return s }

    enum CodingKeys: String, CodingKey {
        case exposure, highlights, shadows, contrast, pivotAuto, pivotOffset, manualPivot,
             contrastLuminosityOnly, temperature, tint, clarity, vibrance, saturation,
             rawBaseCurve, rawSharpening, rawNoiseReduction, localAdjustments, grade, mixer, bw, grain, vignette, brilliance, crop, cropAspect
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func d<T: Decodable>(_ k: CodingKeys, _ def: T) throws -> T { try c.decodeIfPresent(T.self, forKey: k) ?? def }
        exposure = try d(.exposure, 0)
        highlights = try d(.highlights, 0)
        shadows = try d(.shadows, 0)
        contrast = try d(.contrast, 0)
        pivotAuto = try d(.pivotAuto, true)
        pivotOffset = try d(.pivotOffset, 0)
        manualPivot = try d(.manualPivot, 128)
        contrastLuminosityOnly = try d(.contrastLuminosityOnly, false)
        temperature = try d(.temperature, 0)
        tint = try d(.tint, 0)
        clarity = try d(.clarity, 0)
        vibrance = try d(.vibrance, 0)
        saturation = try d(.saturation, 0)
        rawBaseCurve = try d(.rawBaseCurve, 1)
        rawSharpening = try c.decodeIfPresent(Double.self, forKey: .rawSharpening)
        rawNoiseReduction = try c.decodeIfPresent(Double.self, forKey: .rawNoiseReduction)
        localAdjustments = try d(.localAdjustments, [])
        grade = (try? c.decodeIfPresent(ColorGrade.self, forKey: .grade)) ?? ColorGrade()
        mixer = (try? c.decodeIfPresent(ColorMixer.self, forKey: .mixer)) ?? ColorMixer()
        bw = (try? c.decodeIfPresent(BlackWhite.self, forKey: .bw)) ?? BlackWhite()
        grain = (try? c.decodeIfPresent(Grain.self, forKey: .grain)) ?? Grain()
        vignette = (try? c.decodeIfPresent(Vignette.self, forKey: .vignette)) ?? Vignette()
        brilliance = try d(.brilliance, 0)
        crop = (try? c.decodeIfPresent(CropRect.self, forKey: .crop)) ?? CropRect()
        cropAspect = try d(.cropAspect, "free")
    }

    /// Settings that require re-decoding the RAW file when they change.
    struct DecodeKey: Equatable {
        var temperature, tint, baseCurve: Double
        var sharpening, noiseReduction: Double?
        /// Same colour and brightness — differs at most in sharpening / noise reduction (fine detail only).
        func sameTone(as o: DecodeKey) -> Bool { temperature == o.temperature && tint == o.tint && baseCurve == o.baseCurve }
    }
    /// Everything that affects the image before the global contrast median is measured.
    struct LightKey: Equatable {
        var decode: DecodeKey
        var exposure, highlights, shadows, brilliance, temperature, tint: Double
        var crop: CropRect
    }
    func lightKey(isRAW: Bool) -> LightKey {
        LightKey(decode: decodeKey(isRAW: isRAW), exposure: exposure, highlights: highlights, shadows: shadows,
                 brilliance: brilliance, temperature: temperature, tint: tint, crop: crop)
    }

    func decodeKey(isRAW: Bool) -> DecodeKey {
        guard isRAW else { return DecodeKey(temperature: 0, tint: 0, baseCurve: 1, sharpening: nil, noiseReduction: nil) }
        return DecodeKey(temperature: temperature, tint: tint, baseCurve: rawBaseCurve,
                         sharpening: rawSharpening, noiseReduction: rawNoiseReduction)
    }
}
