import Foundation

/// An S-curve that is locked at (pivot, pivot) — the "set input and output to the median" node —
/// with black and white points fixed. Slope at the pivot equals the exponent, and the two halves
/// meet smoothly, so values above the pivot are pushed up exactly as much as values below are pushed down.
public enum ContrastCurve {
    /// Maps the -100...100 slider to the curve exponent (0.4 ... 2.5, 1 = identity).
    public static func exponent(forAmount amount: Double) -> Double {
        exp(amount / 100.0 * log(2.5))
    }

    /// x and pivot in 0...1.
    public static func value(_ x: Double, pivot p0: Double, exponent a: Double) -> Double {
        let p = min(max(p0, 0.02), 0.98)
        let x = min(max(x, 0), 1)
        if x <= p { return p * pow(x / p, a) }
        return 1 - (1 - p) * pow((1 - x) / (1 - p), a)
    }

    public static func lut(pivot: Double, exponent: Double, count: Int = 1024) -> [Float] {
        (0..<count).map { Float(value(Double($0) / Double(count - 1), pivot: pivot, exponent: exponent)) }
    }
}

/// 8-bit RGBA pixels (top row first).
public struct Bitmap {
    public var bytes: [UInt8]
    public var width: Int
    public var height: Int
    public var count: Int { width * height }
}

public struct Histogram: Equatable {
    /// 256 bins each, normalised to 0...1 for display.
    public var luma: [Float]
    public var red: [Float]
    public var green: [Float]
    public var blue: [Float]
    public static let empty = Histogram(luma: .init(repeating: 0, count: 256), red: .init(repeating: 0, count: 256),
                                        green: .init(repeating: 0, count: 256), blue: .init(repeating: 0, count: 256))
}

public enum Measure {
    /// Photoshop-style luminosity (Rec.601 weights on gamma-encoded values), 0...255.
    @inline(__always) static func luma(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Int {
        (Int(r) * 299 + Int(g) * 587 + Int(b) * 114 + 500) / 1000
    }

    /// Raw (weighted) counts. `weights` is an RGBA mask bitmap of the same size; its red channel is used.
    public static func counts(_ bmp: Bitmap, weights: Bitmap? = nil) -> (luma: [Double], r: [Double], g: [Double], b: [Double], total: Double) {
        var l = [Double](repeating: 0, count: 256), r = l, g = l, b = l
        var total = 0.0
        bmp.bytes.withUnsafeBufferPointer { p in
            let w = weights?.bytes
            for i in 0..<bmp.count {
                let o = i * 4
                let weight: Double = w.map { Double($0[o]) / 255.0 } ?? 1
                if weight <= 0 { continue }
                let R = p[o], G = p[o + 1], B = p[o + 2]
                l[luma(R, G, B)] += weight
                r[Int(R)] += weight; g[Int(G)] += weight; b[Int(B)] += weight
                total += weight
            }
        }
        return (l, r, g, b, total)
    }

    /// Median of a 256-bin histogram (interpolated within the bin). 128 if empty.
    public static func median(_ h: [Double]) -> Double {
        let total = h.reduce(0, +)
        guard total > 0 else { return 128 }
        let half = total / 2
        var c = 0.0
        for i in 0..<h.count {
            let next = c + h[i]
            if next >= half {
                let frac = h[i] > 0 ? (half - c) / h[i] : 0
                return min(max(Double(i) - 0.5 + frac, 0), 255)
            }
            c = next
        }
        return 255
    }

    public static func normalized(_ h: [Double]) -> [Float] {
        // Ignore clipped end bins when scaling so a spike at 0/255 doesn't flatten the rest.
        let peak = max(h[1..<255].max() ?? 0, 1e-9)
        return h.map { Float(min($0 / peak, 1)) }
    }

    public static func histogram(_ c: (luma: [Double], r: [Double], g: [Double], b: [Double], total: Double)) -> Histogram {
        Histogram(luma: normalized(c.luma), red: normalized(c.r), green: normalized(c.g), blue: normalized(c.b))
    }
}
