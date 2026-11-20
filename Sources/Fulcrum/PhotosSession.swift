import Foundation
import FulcrumCore
import ImageIO

/// Apple Photos' "Edit With": Photos copies the photo into its library's ExternalEditSessions folder, opens that
/// copy here, and takes whatever is saved over it as the photo's edit. Fulcrum never overwrites originals, so the
/// first save keeps a pristine copy in Application Support, and every render and save works from that copy.
/// Saving again re-renders from the original instead of stacking edits on an already-edited file.
enum PhotosSession {
    static func isInsidePhotosLibrary(_ url: URL) -> Bool { url.path.contains(".photoslibrary/") }

    static func isSession(_ url: URL) -> Bool {
        isInsidePhotosLibrary(url) && url.pathComponents.contains("ExternalEditSessions")
    }

    private static var originalsDir: URL { AppPaths.support.appendingPathComponent("PhotosSessions", isDirectory: true) }

    /// Session folder name (a UUID) + file name, so two sessions never share a copy.
    static func originalURL(for url: URL) -> URL {
        originalsDir.appendingPathComponent(url.deletingLastPathComponent().lastPathComponent, isDirectory: true)
            .appendingPathComponent(url.lastPathComponent)
    }

    /// The file to decode: the pristine copy once Fulcrum has saved over Photos' file, else the file itself.
    static func renderURL(for url: URL) -> URL {
        guard isSession(url) else { return url }
        let o = originalURL(for: url)
        return FileManager.default.fileExists(atPath: o.path) ? o : url
    }

    /// The format to write back: the same as the file Photos handed over. Nil when Fulcrum can't write it (RAW).
    static func format(for url: URL) -> ExportOptions.Format? {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return .jpeg
        case "heic", "heif": return .heic
        case "png": return .png
        case "tif", "tiff": return .tiff16
        default: return nil
        }
    }

    /// Renders `settings` from the original and writes the result over Photos' file, in place.
    static func save(_ settings: EditSettings, to url: URL) throws {
        guard let format = format(for: url) else { throw SaveError.unsupported(url.pathExtension.uppercased()) }
        let fm = FileManager.default
        let original = originalURL(for: url)
        if !fm.fileExists(atPath: original.path) {
            try fm.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: url, to: original)
        }
        let r = try Renderer(url: original)
        var o = ExportOptions()
        o.format = format
        o.quality = 0.95
        let profile = (r.source.metadata[kCGImagePropertyProfileName as String] as? String) ?? ""
        o.colorSpace = profile.localizedCaseInsensitiveContains("P3") ? .displayP3 : .sRGB
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(format.ext)
        defer { try? fm.removeItem(at: tmp) }
        try r.export(settings, to: tmp, options: o)
        let data = try Data(contentsOf: tmp)

        // Write into the same file (same inode) under file coordination, so Photos sees its own file change.
        var coordError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordError) { target in
            do {
                let h = try FileHandle(forWritingTo: target)
                defer { try? h.close() }
                try h.truncate(atOffset: 0)
                try h.write(contentsOf: data)
                try h.synchronize()
            } catch { writeError = error }
        }
        if let e = coordError ?? writeError { throw e }
    }

    /// Drops pristine copies from sessions more than three days old. Photos removes its session folders, but
    /// Fulcrum may not be allowed to look inside the library to check, so age is the safe signal.
    static func cleanUp() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-3 * 86_400)
        for d in (try? fm.contentsOfDirectory(at: originalsDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let date = (try? d.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture
            if date < cutoff { try? fm.removeItem(at: d) }
        }
    }

    enum SaveError: LocalizedError {
        case unsupported(String)
        var errorDescription: String? {
            switch self {
            case .unsupported(let ext):
                return "Photos handed Fulcrum a \(ext) file, which Fulcrum can't write back. Export the photo instead."
            }
        }
    }
}
