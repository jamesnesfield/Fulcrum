import CoreImage
import ImageIO
import UniformTypeIdentifiers

public enum FulcrumError: LocalizedError {
    case cannotOpen(URL)
    case renderFailed
    case writeFailed(URL)
    public var errorDescription: String? {
        switch self {
        case .cannotOpen(let u): return "Couldn't open \(u.lastPathComponent)."
        case .renderFailed: return "Rendering failed."
        case .writeFailed(let u): return "Couldn't write \(u.lastPathComponent)."
        }
    }
}

/// A photo on disk: either a camera RAW (decoded with CIRAWFilter) or an already-rendered image (JPEG/HEIC/PNG/TIFF).
public final class ImageSource: @unchecked Sendable {
    public let url: URL
    public let isRAW: Bool
    public let pixelSize: CGSize
    public let metadata: [String: Any]
    public let asShotTemperature: Float
    public let asShotTint: Float
    public let rawDefaultSharpening: Double
    public let rawDefaultNoiseReduction: Double

    public static let rawExtensions: Set<String> = ["cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf",
                                                    "rw2", "rwl", "dng", "pef", "srw", "3fr", "iiq", "x3f", "erf",
                                                    "mef", "mos", "kdc", "dcr", "raw"]
    public static let imageExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "webp", "avif"]

    public static func isRAWFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if rawExtensions.contains(ext) { return true }
        return UTType(filenameExtension: ext)?.conforms(to: .rawImage) ?? false
    }

    public static func isSupported(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return rawExtensions.contains(ext) || imageExtensions.contains(ext) || isRAWFile(url)
    }

    public init(url: URL) throws {
        self.url = url
        var temp: Float = 6500, tint: Float = 0, sharp = 0.0, nr = 0.0
        if Self.isRAWFile(url), let f = CIRAWFilter(imageURL: url), let out = f.outputImage {
            isRAW = true
            pixelSize = out.extent.size
            temp = f.neutralTemperature
            tint = f.neutralTint
            sharp = Double(f.sharpnessAmount)
            nr = Double(f.luminanceNoiseReductionAmount)
        } else if let img = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) {
            isRAW = false
            pixelSize = img.extent.size
        } else {
            throw FulcrumError.cannotOpen(url)
        }
        asShotTemperature = temp
        asShotTint = tint
        rawDefaultSharpening = sharp
        rawDefaultNoiseReduction = nr
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] {
            metadata = props
        } else {
            metadata = [:]
        }
    }

    public var longEdge: CGFloat { max(pixelSize.width, pixelSize.height) }

    // Opening a RAW decoder costs ~300 ms (it parses the whole file), and changing its scale is nearly as slow;
    // changing white balance etc. on an open one costs a few ms. So keep one open decoder per output size.
    private let rawLock = NSLock()
    private var rawFilters: [Float: CIRAWFilter] = [:]
    private var rawFilterOrder: [Float] = []

    private func rawFilter(scale: Float) -> CIRAWFilter? {
        if let f = rawFilters[scale] {
            rawFilterOrder.removeAll { $0 == scale }; rawFilterOrder.append(scale)
            return f
        }
        guard let f = CIRAWFilter(imageURL: url) else { return nil }
        if scale < 1 { f.scaleFactor = scale }
        rawFilters[scale] = f; rawFilterOrder.append(scale)
        if rawFilterOrder.count > 5 { rawFilters.removeValue(forKey: rawFilterOrder.removeFirst()) }
        return f
    }

    /// Decoded, oriented image with its origin at (0,0), optionally downscaled so the long edge ≤ maxDimension.
    public func makeBase(_ s: EditSettings, maxDimension: CGFloat?) -> CIImage? {
        let scale = maxDimension.map { min(1, $0 / longEdge) } ?? 1
        var img: CIImage
        if isRAW {
            rawLock.lock(); defer { rawLock.unlock() }
            guard let f = rawFilter(scale: Float(scale)) else { return nil }
            // Set every parameter each time: the decoder is reused, so nothing may carry over from the last call.
            f.neutralTemperature = Float(WhiteBalance.kelvin(base: Double(asShotTemperature), slider: s.temperature))
            f.neutralTint = asShotTint + Float(s.tint)
            f.boostAmount = Float(s.rawBaseCurve)
            if f.isSharpnessSupported { f.sharpnessAmount = Float(s.rawSharpening ?? rawDefaultSharpening) }
            if f.isLuminanceNoiseReductionSupported {
                f.luminanceNoiseReductionAmount = Float(s.rawNoiseReduction ?? rawDefaultNoiseReduction)
            }
            guard let out = f.outputImage else { return nil }   // an immutable snapshot of the current parameters
            img = out
        } else {
            guard let out = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return nil }
            img = out
            if scale < 1 {
                img = img.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
            }
        }
        img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
        let size = CGSize(width: floor(img.extent.width), height: floor(img.extent.height))
        return img.cropped(to: CGRect(origin: .zero, size: size))
    }
}

/// Temperature slider → Kelvin on a mired (perceptually even) scale. ±100 ≈ ±120 mired.
public enum WhiteBalance {
    public static func kelvin(base: Double, slider: Double) -> Double {
        let mired = 1_000_000 / max(base, 1000) - slider * 1.2
        return 1_000_000 / max(mired, 20)
    }
}
