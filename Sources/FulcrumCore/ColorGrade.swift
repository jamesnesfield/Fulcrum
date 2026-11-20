import Foundation

/// One colour wheel: hue in degrees, saturation 0...100 (distance from centre), luminance -100...100.
public struct Wheel: Codable, Equatable {
    public var hue: Double = 0
    public var sat: Double = 0
    public var lum: Double = 0
    public init(hue: Double = 0, sat: Double = 0, lum: Double = 0) { self.hue = hue; self.sat = sat; self.lum = lum }
    public var isNeutral: Bool { sat == 0 && lum == 0 }
}

public enum Harmony: String, Codable, CaseIterable, Identifiable {
    case free, complementary, analogous, monochromatic
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .free: "Free"
        case .complementary: "Complementary"
        case .analogous: "Analogous"
        case .monochromatic: "Mono"
        }
    }
    public var help: String {
        switch self {
        case .free: "Wheels move independently — experiment."
        case .complementary: "Shadows sit opposite the highlights (blue ↔ orange, green ↔ pink). Midtones follow the highlights."
        case .analogous: "Shadows, midtones and highlights stay 30° apart — one colour family."
        case .monochromatic: "All three ranges share one hue."
        }
    }
}

public enum WheelID: String, CaseIterable, Identifiable {
    case shadows, midtones, highlights, global
    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
}

/// Lightroom-style colour grading: adds colour into tonal ranges (rather than editing colours already there).
public struct ColorGrade: Codable, Equatable {
    public var enabled = true
    public var shadows = Wheel()
    public var midtones = Wheel()
    public var highlights = Wheel()
    public var global = Wheel()
    public var blending: Double = 50     // 0...100, smoothness of the transitions between ranges
    public var balance: Double = 0       // -100 (favour shadows) ... 100 (favour highlights)
    public var harmony: Harmony = .free

    public init() {}

    public var isNeutral: Bool {
        !enabled || (shadows.isNeutral && midtones.isNeutral && highlights.isNeutral && global.isNeutral)
    }

    public subscript(id: WheelID) -> Wheel {
        get {
            switch id { case .shadows: shadows; case .midtones: midtones; case .highlights: highlights; case .global: global }
        }
        set {
            switch id {
            case .shadows: shadows = newValue
            case .midtones: midtones = newValue
            case .highlights: highlights = newValue
            case .global: global = newValue
            }
        }
    }

    static func wrap(_ h: Double) -> Double { let x = h.truncatingRemainder(dividingBy: 360); return x < 0 ? x + 360 : x }

    /// After `changed`'s hue moves, re-derive the other range hues from the harmony rule.
    public mutating func applyHarmony(changed: WheelID) {
        guard changed != .global else { return }
        let h = self[changed].hue
        switch harmony {
        case .free:
            return
        case .complementary:
            let warm = changed == .shadows ? Self.wrap(h + 180) : h
            shadows.hue = Self.wrap(warm + 180)
            midtones.hue = warm
            highlights.hue = warm
        case .analogous:
            let mid = changed == .shadows ? h + 30 : changed == .highlights ? h - 30 : h
            shadows.hue = Self.wrap(mid - 30)
            midtones.hue = Self.wrap(mid)
            highlights.hue = Self.wrap(mid + 30)
        case .monochromatic:
            shadows.hue = h; midtones.hue = h; highlights.hue = h
        }
    }

    /// Random grade that respects the current harmony — "just experiment and see what looks cool".
    public static func surprise(harmony: Harmony, subtle: Bool) -> ColorGrade {
        var g = ColorGrade()
        g.harmony = harmony
        let k = subtle ? 0.5 : 1.0
        func sat() -> Double { (Double.random(in: 12...40) * k).rounded() }
        let base = Double.random(in: 0..<360).rounded()
        g.shadows = Wheel(hue: base, sat: sat(), lum: Double.random(in: -4...8).rounded())
        g.midtones = Wheel(hue: Double.random(in: 0..<360).rounded(), sat: (sat() * 0.5).rounded())
        g.highlights = Wheel(hue: Double.random(in: 0..<360).rounded(), sat: sat(), lum: Double.random(in: -6...2).rounded())
        if harmony != .free { g.applyHarmony(changed: .shadows) }
        g.blending = Double.random(in: 35...75).rounded()
        g.balance = Double.random(in: -30...30).rounded()
        return g
    }

    /// Starting points based on the combinations in the tutorial.
    public static let starters: [(name: String, grade: ColorGrade)] = {
        func make(_ h: Harmony, _ s: Wheel, _ m: Wheel, _ hi: Wheel, global: Wheel = Wheel(), blend: Double = 50, bal: Double = 0) -> ColorGrade {
            var g = ColorGrade(); g.harmony = h; g.shadows = s; g.midtones = m; g.highlights = hi
            g.global = global; g.blending = blend; g.balance = bal; return g
        }
        return [
            ("Blue & Orange", make(.complementary, Wheel(hue: 212, sat: 30), Wheel(hue: 32, sat: 12), Wheel(hue: 32, sat: 26), blend: 65, bal: 15)),
            ("Night Blue & Orange", make(.complementary, Wheel(hue: 218, sat: 50, lum: 6), Wheel(hue: 30, sat: 18), Wheel(hue: 30, sat: 40), blend: 50, bal: -5)),
            ("Green & Pink (film)", make(.complementary, Wheel(hue: 140, sat: 20, lum: 3), Wheel(), Wheel(hue: 335, sat: 16, lum: -3), blend: 55)),
            ("Autumn Warmth", make(.analogous, Wheel(hue: 15, sat: 18), Wheel(hue: 38, sat: 16), Wheel(hue: 50, sat: 22), global: Wheel(hue: 35, sat: 6), blend: 60, bal: 10)),
            ("Moody Winter Blue", make(.monochromatic, Wheel(hue: 210), Wheel(hue: 210, sat: 18), Wheel(hue: 210, sat: 22), blend: 55, bal: 10)),
            ("90s Night Film", make(.free, Wheel(hue: 175, sat: 30, lum: 6), Wheel(hue: 315, sat: 14), Wheel(hue: 18, sat: 24, lum: -5), blend: 40)),
        ]
    }()
}

/// HSL / colour mixer — edits colours that already exist in the photo (8 bands).
public struct ColorMixer: Codable, Equatable {
    public static let bandNames = ["Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta"]
    public static let bandHues: [Double] = [0, 30, 60, 120, 180, 240, 275, 315]
    public var hue = [Double](repeating: 0, count: 8)   // -100...100 → ±30°
    public var sat = [Double](repeating: 0, count: 8)   // -100...100
    public var lum = [Double](repeating: 0, count: 8)   // -100...100
    public init() {}
    public var isNeutral: Bool { hue.allSatisfy { $0 == 0 } && sat.allSatisfy { $0 == 0 } && lum.allSatisfy { $0 == 0 } }
}

/// Bakes mixer + grade into a 3D LUT over gamma-encoded sRGB (applied with CIColorCubeWithColorSpace).
public enum ColorLUT {
    public static let size = 40

    @inline(__always) static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(max((x - a) / (b - a), 0), 1); return t * t * (3 - 2 * t)
    }
    @inline(__always) public static func luma(_ c: SIMD3<Double>) -> Double { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }

    static func hsv2rgb(_ h: Double, _ s: Double, _ v: Double) -> SIMD3<Double> {
        let hh = ColorGrade.wrap(h) / 60, i = Int(hh) % 6, f = hh - floor(hh)
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch i {
        case 0: return [v, t, p]; case 1: return [q, v, p]; case 2: return [p, v, t]
        case 3: return [p, q, v]; case 4: return [t, p, v]; default: return [v, p, q]
        }
    }
    static func rgb2hsv(_ c: SIMD3<Double>) -> (h: Double, s: Double, v: Double) {
        let mx = max(c.x, c.y, c.z), mn = min(c.x, c.y, c.z), d = mx - mn
        var h = 0.0
        if d > 1e-9 {
            if mx == c.x { h = 60 * ((c.y - c.z) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == c.y { h = 60 * ((c.z - c.x) / d + 2) }
            else { h = 60 * ((c.x - c.y) / d + 4) }
        }
        return (ColorGrade.wrap(h), mx > 0 ? d / mx : 0, mx)
    }

    /// Zero-luminance chroma direction for a hue (adds colour without changing brightness).
    public static func chroma(_ hue: Double) -> SIMD3<Double> {
        let c = hsv2rgb(hue, 1, 1); return c - SIMD3(repeating: luma(c))
    }

    /// Tonal-range weights (shadows, midtones, highlights) for a luminance 0...1.
    public static func rangeWeights(_ L: Double, blending: Double, balance: Double) -> (s: Double, m: Double, h: Double) {
        let c = 0.5 - balance / 100 * 0.25
        let w = 0.04 + 0.26 * blending / 100
        let ws = 1 - smooth(c - 0.17 - w, c - 0.17 + w, L)
        let wh = smooth(c + 0.17 - w, c + 0.17 + w, L)
        return (ws, max(0, 1 - ws - wh), wh)
    }

    /// Band weights for a hue (tent functions between neighbouring band centres; they sum to 1).
    static func bandWeights(_ hue: Double) -> [(Int, Double)] {
        let c = ColorMixer.bandHues
        for i in 0..<c.count {
            let a = c[i], b = i + 1 < c.count ? c[i + 1] : 360
            if hue >= a && hue < b {
                let t = (hue - a) / (b - a)
                return [(i, 1 - t), ((i + 1) % c.count, t)]
            }
        }
        return [(0, 1)]
    }

    public static func mix(_ c: SIMD3<Double>, _ m: ColorMixer) -> SIMD3<Double> {
        var (h, s, v) = rgb2hsv(c)
        guard s > 0.0001 else { return c }
        var dh = 0.0, ds = 0.0, dl = 0.0
        for (i, w) in bandWeights(h) { dh += w * m.hue[i]; ds += w * m.sat[i]; dl += w * m.lum[i] }
        h += dh / 100 * 30
        s = min(max(s * (1 + ds / 100), 0), 1)
        var out = hsv2rgb(h, s, v)
        // Luminance: scale towards/away from black, weighted by saturation so greys are untouched.
        out *= 1 + dl / 100 * 0.5 * s
        return out
    }

    public static func applyGrade(_ input: SIMD3<Double>, _ g: ColorGrade) -> SIMD3<Double> {
        var c = input
        let L0 = luma(c)
        let r = rangeWeights(L0, blending: g.blending, balance: g.balance)
        // Luminance first: lifting the shadows puts grey into black, which can then take the shadow colour.
        let lift = (r.s * g.shadows.lum + r.m * g.midtones.lum + r.h * g.highlights.lum + g.global.lum) / 100 * 0.2
        c += SIMD3(repeating: lift)
        let L = min(max(luma(c), 0), 1)
        // Pure black and pure white have no room for colour.
        let room = min(1, 6 * L * (1 - L))
        var add = SIMD3<Double>(repeating: 0)
        for (wheel, weight) in [(g.shadows, r.s), (g.midtones, r.m), (g.highlights, r.h), (g.global, 1.0)] where wheel.sat > 0 {
            add += chroma(wheel.hue) * (wheel.sat / 100 * 0.32 * weight)
        }
        c += add * room
        return c
    }

    public static func apply(_ c: SIMD3<Double>, grade: ColorGrade, mixer: ColorMixer,
                             bw: BlackWhite = BlackWhite(), bwPivot: Double = 128) -> SIMD3<Double> {
        var x = c
        if !mixer.isNeutral { x = mix(x, mixer) }
        // B&W sits between the mixer (which then acts as a B&W colour mixer) and the grade (which then tones it).
        if bw.enabled { x = bw.apply(x, pivot: bwPivot) }
        if !grade.isNeutral { x = applyGrade(x, grade) }
        return SIMD3(min(max(x.x, 0), 1), min(max(x.y, 0), 1), min(max(x.z, 0), 1))
    }

    /// RGBA float32 cube data, red varying fastest.
    public static func cube(_ f: (SIMD3<Double>) -> SIMD3<Double>) -> Data {
        let n = size
        var data = [Float](repeating: 1, count: n * n * n * 4)
        data.withUnsafeMutableBufferPointer { buf in
            let base = buf.baseAddress!
            // One blue slice per task, spread across all cores.
            DispatchQueue.concurrentPerform(iterations: n) { b in
                var o = b * n * n * 4
                for g in 0..<n { for r in 0..<n {
                    let v = f(SIMD3(Double(r), Double(g), Double(b)) / Double(n - 1))
                    base[o] = Float(v.x); base[o + 1] = Float(v.y); base[o + 2] = Float(v.z)
                    o += 4
                } }
            }
        }
        return data.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// False-colour view of the tonal ranges: shadows blue, midtones grey, highlights orange.
    public static func rangeCube(_ g: ColorGrade) -> Data {
        cube { c in
            let w = rangeWeights(luma(c), blending: g.blending, balance: g.balance)
            return SIMD3(0.15, 0.35, 0.95) * w.s + SIMD3(0.55, 0.55, 0.55) * w.m + SIMD3(1.0, 0.6, 0.15) * w.h
        }
    }
}
