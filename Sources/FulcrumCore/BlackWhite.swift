import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Classic coloured-filter B&W: colours near the filter's hue get lighter, their complements darker.
public enum BWFilter: String, Codable, CaseIterable, Identifiable {
    case red, orange, yellow, green, blue
    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
    public var hue: Double {
        switch self { case .red: 0; case .orange: 30; case .yellow: 55; case .green: 120; case .blue: 220 }
    }
    public var help: String {
        switch self {
        case .red: "Dramatic: dark skies, light skin and foliage reds"
        case .orange: "Darker skies, smooth skin"
        case .yellow: "Classic, gentle sky separation"
        case .green: "Lighter foliage, ruddier skin"
        case .blue: "Light skies, haze and moodier warm tones"
        }
    }
}

public struct BlackWhite: Codable, Equatable {
    public var enabled = false
    public var filter: BWFilter = .yellow
    public var intensity: Double = 50     // 0...100 — how strongly colours separate into different greys
    public var neutrals: Double = 0       // -100...100 — lighten/darken the grey midtones
    public var tone: Double = 0           // -100...100 — contrast, pivoted on the B&W image's own median
    public init() {}

    enum CodingKeys: String, CodingKey { case enabled, filter, intensity, neutrals, tone }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        filter = (try? c.decodeIfPresent(BWFilter.self, forKey: .filter)) ?? .yellow
        intensity = try c.decodeIfPresent(Double.self, forKey: .intensity) ?? 50
        neutrals = try c.decodeIfPresent(Double.self, forKey: .neutrals) ?? 0
        tone = try c.decodeIfPresent(Double.self, forKey: .tone) ?? 0
    }

    /// Grey value (0...1, gamma-encoded) before Tone is applied.
    public func gray(_ c: SIMD3<Double>) -> Double {
        let L = ColorLUT.luma(c)
        let dir = ColorLUT.chroma(filter.hue)
        let norm = (dir * dir).sum().squareRoot()
        var g = L + intensity / 100 * 0.9 * ((c - SIMD3(repeating: L)) * dir).sum() / norm
        g = min(max(g, 0), 1)
        // Neutrals: a midtone bump that leaves black and white anchored.
        g += neutrals / 100 * 0.3 * g * (1 - g) * 4 * 0.5
        return min(max(g, 0), 1)
    }

    public func apply(_ c: SIMD3<Double>, pivot: Double) -> SIMD3<Double> {
        var g = gray(c)
        if tone != 0 { g = ContrastCurve.value(g, pivot: pivot / 255, exponent: ContrastCurve.exponent(forAmount: tone)) }
        return SIMD3(repeating: g)
    }
}

/// Film-style monochrome grain. Strongest in the midtones, absent in pure black and white.
public struct Grain: Codable, Equatable {
    public var amount: Double = 0       // 0...100
    public var size: Double = 25        // 0...100
    public var roughness: Double = 50   // 0...100 — mix of fine and clumpy grain
    public init() {}

    enum CodingKeys: String, CodingKey { case amount, size, roughness }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 0
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? 25
        roughness = try c.decodeIfPresent(Double.self, forKey: .roughness) ?? 50
    }

    /// Deterministic noise tiles (values centred exactly on 0.5, no colour conversion).
    static let tileA = makeTile(seed: 0x9E3779B97F4A7C15)
    static let tileB = makeTile(seed: 0xD1B54A32D192ED03)

    static func makeTile(seed: UInt64, size: Int = 512) -> CIImage {
        var state = seed
        func next() -> Float {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Float(state >> 40) / Float(1 << 24)
        }
        var px = [Float](repeating: 1, count: size * size * 4)
        for i in 0..<(size * size) {
            let v = (next() + next() + next()) / 3      // ≈ gaussian, mean 0.5
            px[i * 4] = v; px[i * 4 + 1] = v; px[i * 4 + 2] = v
        }
        let data = px.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: size * 16, size: CGSize(width: size, height: size),
                       format: .RGBAf, colorSpace: nil)
    }

    /// Grain is sized relative to the photo (per 1000 px of long edge) so preview and export match.
    func apply(to img: CIImage) -> CIImage {
        guard amount > 0 else { return img }
        let e = img.extent
        let ps = max(e.width, e.height) / 1000
        let cell = ps * (0.25 + size / 100 * 1.1)

        func layer(scale: CGFloat, tile: CIImage) -> CIImage {
            let t = CIFilter.affineTile()
            t.inputImage = tile
            t.transform = .identity
            let noise = t.outputImage!
                .transformed(by: CGAffineTransform(scaleX: max(scale, 1), y: max(scale, 1)))  // never minify: averaging would erase it
            return noise.applyingGaussianBlur(sigma: Double(max(scale, 1)) * 0.5).cropped(to: e)
        }
        let coarse = layer(scale: cell, tile: Self.tileA)
        let fine = layer(scale: cell * 0.53, tile: Self.tileB)
        let r = roughness / 100
        let mixed = coarse.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: fine, kCIInputTimeKey: r * 0.6,
        ])
        // Stretch the blurred noise into a 0...1 mask centred on 0.5.
        let k = 2.6
        let mask = mixed.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0.5 - 0.5 * k, y: 0.5 - 0.5 * k, z: 0.5 - 0.5 * k, w: 0),
        ]).applyingFilter("CIColorClamp").cropped(to: e)
        // In gamma space: out = b ± A·4b(1−b). The 4b(1−b) envelope peaks in the midtones and is
        // zero at pure black and white (like grain in film). Each side is a simple polynomial.
        let A = amount / 100 * 0.2
        let gamma = img.applyingFilter("CILinearToSRGBToneCurve")
        func poly(_ a1: Double, _ a2: Double) -> CIImage {
            let c = CIVector(x: 0, y: a1, z: a2, w: 0)
            return gamma.applyingFilter("CIColorPolynomial", parameters: [
                "inputRedCoefficients": c, "inputGreenCoefficients": c, "inputBlueCoefficients": c,
                "inputAlphaCoefficients": CIVector(x: 0, y: 1, z: 0, w: 0),
            ])
        }
        let lighter = poly(1 + 4 * A, -4 * A), darker = poly(1 - 4 * A, 4 * A)
        let blended = lighter.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: darker, kCIInputMaskImageKey: mask,
        ])
        return blended.applyingFilter("CISRGBToneCurveToLinear").cropped(to: e)
    }
}
