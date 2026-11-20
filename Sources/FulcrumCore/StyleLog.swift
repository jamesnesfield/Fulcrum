import CoreGraphics
import Foundation
import ImageIO

/// Pure helpers for the edit log (one JSON object per line) and the style summary built from it.
public enum EditLogFormat {
    public static let defaults = flatten(EditSettings())

    /// "grade.shadows.hue": 210, "mixer.sat.Blue": -20, "local[0].mask.kind": "sky", …
    public static func flatten(_ s: EditSettings) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(s),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        var out: [String: Any] = [:]
        func walk(_ v: Any, _ path: String) {
            if let d = v as? [String: Any] {
                for (k, x) in d where k != "id" {
                    let key = k == "localAdjustments" ? "local" : k
                    walk(x, path.isEmpty ? key : "\(path).\(key)")
                }
            } else if let a = v as? [Any] {
                let mixerArray = path.hasPrefix("mixer.")
                for (i, x) in a.enumerated() {
                    walk(x, mixerArray && i < ColorMixer.bandNames.count ? "\(path).\(ColorMixer.bandNames[i])" : "\(path)[\(i)]")
                }
            } else {
                out[path] = v
            }
        }
        walk(obj, "")
        return out
    }

    public static func same(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x as NSNumber, y as NSNumber): return abs(x.doubleValue - y.doubleValue) < 1e-9
        case let (x as String, y as String): return x == y
        default: return false
        }
    }

    /// Keys whose values differ, as key: [old, new].
    public static func diff(_ old: [String: Any], _ new: [String: Any]) -> [String: Any] {
        var changed: [String: Any] = [:]
        for key in Set(new.keys).union(old.keys) where !same(old[key], new[key]) {
            changed[key] = [old[key] ?? NSNull(), new[key] ?? NSNull()]
        }
        return changed
    }

    public static func entry(event: String, file: URL, settings s: EditSettings, previous: [String: Any]?,
                             camera: [String: Any] = [:], isRAW: Bool? = nil, median: Double? = nil,
                             bwMedian: Double? = nil, imageSize: CGSize? = nil, date: Date = Date()) -> [String: Any] {
        let flat = flatten(s)
        var e: [String: Any] = [
            "time": ISO8601DateFormatter().string(from: date),
            "event": event,
            "file": file.path,
            "name": file.lastPathComponent,
            "settings": flat.filter { !same($0.value, defaults[$0.key]) },
            "changed": diff(previous ?? defaults, flat),
        ]
        if !camera.isEmpty { e["camera"] = camera }
        if let isRAW { e["raw"] = isRAW }
        var m: [String: Any] = [:]
        if let median { m["median"] = (median * 10).rounded() / 10 }
        if let bwMedian { m["bwMedian"] = (bwMedian * 10).rounded() / 10 }
        if let sz = imageSize, sz.width > 1 {
            let c = s.crop.pixelRect(in: CGRect(origin: .zero, size: sz))
            m["outputAspect"] = (Double(c.width / max(c.height, 1)) * 1000).rounded() / 1000
            m["outputPixels"] = [Int(c.width), Int(c.height)]
        }
        if !m.isEmpty { e["measured"] = m }
        return e
    }

    public static func cameraSummary(_ m: [String: Any]) -> [String: Any] {
        var c: [String: Any] = [:]
        let tiff = m[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let exif = m[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        if let v = tiff[kCGImagePropertyTIFFMake as String] { c["make"] = v }
        if let v = tiff[kCGImagePropertyTIFFModel as String] { c["model"] = v }
        if let v = exif[kCGImagePropertyExifLensModel as String] { c["lens"] = v }
        if let v = exif[kCGImagePropertyExifFocalLength as String] { c["focalLength"] = v }
        if let v = exif[kCGImagePropertyExifFNumber as String] { c["aperture"] = v }
        if let v = exif[kCGImagePropertyExifExposureTime as String] { c["shutter"] = v }
        if let v = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Any])?.first { c["iso"] = v }
        if let v = exif[kCGImagePropertyExifDateTimeOriginal as String] { c["taken"] = v }
        return c
    }
}

/// Reads the edit log and summarises habits across photos (each photo counted once, at its latest state).
public struct StyleSummary {
    public struct Usage: Identifiable { public let id: String; public let share: Double; public let average: Double?; public let count: Int }

    public var entries = 0
    public var photos = 0
    public var first: String?
    public var last: String?
    public var usage: [Usage] = []
    public var bwShare = 0.0
    public var grainShare = 0.0
    public var grainAverage = 0.0
    public var cropShare = 0.0
    public var aspects: [(String, Int)] = []
    public var cameras: [(String, Int)] = []
    public var harmonies: [(String, Int)] = []
    public var bwFilters: [(String, Int)] = []
    public var shadowHues: [Double] = []
    public var highlightHues: [Double] = []
    public var medians: [Double] = []

    public init(_ log: [[String: Any]]) {
        entries = log.count
        first = log.first?["time"] as? String
        last = log.last?["time"] as? String
        var latest: [String: [String: Any]] = [:]
        var meta: [String: [String: Any]] = [:]
        for e in log {
            guard let f = e["file"] as? String, let s = e["settings"] as? [String: Any] else { continue }
            latest[f] = s
            meta[f] = e
        }
        photos = latest.count
        guard photos > 0 else { return }
        let n = Double(photos)

        var counts: [String: Int] = [:], sums: [String: Double] = [:]
        for s in latest.values {
            for (k, v) in s where !k.hasPrefix("local[") && k != "cropAspect" && !k.hasPrefix("crop.") {
                counts[k, default: 0] += 1
                if let x = v as? NSNumber, CFGetTypeID(x) != CFBooleanGetTypeID() { sums[k, default: 0] += x.doubleValue }
            }
            if (s.keys.contains { $0.hasPrefix("local[") }) { counts["local adjustments", default: 0] += 1 }
        }
        usage = counts.map { k, c in Usage(id: k, share: Double(c) / n, average: sums[k].map { $0 / Double(c) }, count: c) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.id < $1.id }

        let bw = latest.values.filter { ($0["bw.enabled"] as? Bool) == true }
        bwShare = Double(bw.count) / n
        bwFilters = tally(bw.map { ($0["bw.filter"] as? String) ?? "yellow" })
        let grained = latest.values.compactMap { ($0["grain.amount"] as? NSNumber)?.doubleValue }.filter { $0 > 0 }
        grainShare = Double(grained.count) / n
        grainAverage = grained.isEmpty ? 0 : grained.reduce(0, +) / Double(grained.count)
        cropShare = Double(latest.values.filter { $0.keys.contains { $0.hasPrefix("crop.") } }.count) / n
        aspects = tally(latest.values.compactMap { $0["cropAspect"] as? String })
        harmonies = tally(latest.values.compactMap { $0["grade.harmony"] as? String })
        cameras = tally(meta.values.compactMap { e in
            (e["camera"] as? [String: Any]).flatMap { c in [c["make"], c["model"]].compactMap { $0 as? String }.joined(separator: " ") }
        }.filter { !$0.isEmpty })
        for s in latest.values {
            if ((s["grade.shadows.sat"] as? NSNumber)?.doubleValue ?? 0) > 0 { shadowHues.append((s["grade.shadows.hue"] as? NSNumber)?.doubleValue ?? 0) }
            if ((s["grade.highlights.sat"] as? NSNumber)?.doubleValue ?? 0) > 0 { highlightHues.append((s["grade.highlights.hue"] as? NSNumber)?.doubleValue ?? 0) }
        }
        medians = meta.values.compactMap { (($0["measured"] as? [String: Any])?["median"] as? NSNumber)?.doubleValue }
    }

    private func tally(_ xs: [String]) -> [(String, Int)] {
        Dictionary(grouping: xs, by: { $0 }).map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }
    }

    public static func circularMean(_ hues: [Double]) -> Double? {
        guard !hues.isEmpty else { return nil }
        let x = hues.map { cos($0 * .pi / 180) }.reduce(0, +), y = hues.map { sin($0 * .pi / 180) }.reduce(0, +)
        let h = atan2(y, x) * 180 / .pi
        return h < 0 ? h + 360 : h
    }

    public var text: String {
        var t = "Fulcrum style summary — \(photos) photos, \(entries) log entries\n"
        t += String(format: "B&W %.0f%%, grain %.0f%% (avg %.0f), cropped %.0f%%\n", bwShare * 100, grainShare * 100, grainAverage, cropShare * 100)
        for u in usage.prefix(25) {
            t += "\(u.id): \(Int((u.share * 100).rounded()))%" + (u.average.map { String(format: ", avg %.1f", $0) } ?? "") + "\n"
        }
        return t
    }
}

