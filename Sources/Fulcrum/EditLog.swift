import Foundation
import FulcrumCore
import ImageIO

/// Append-only log of every edit, one JSON object per line (edit-log.jsonl in Application Support/Fulcrum).
/// Each "edit" entry is written once the sliders have been still for a few seconds, and holds:
/// the photo + camera info, what was measured, every non-default setting, and what changed since the last entry.
@MainActor
final class EditLog {
    static let shared = EditLog()
    let url = AppPaths.support.appendingPathComponent("edit-log.jsonl")

    struct Context {
        var camera: [String: Any] = [:]
        var isRAW: Bool? = nil
        var median: Double? = nil
        var bwMedian: Double? = nil
        var imageSize: CGSize? = nil
    }

    private var lastLogged: [String: [String: Any]] = [:]   // flattened settings per file
    private var pending: (URL, EditSettings, Context)?
    private var timer: Timer?
    private let settleDelay: TimeInterval = 3

    /// Baseline for a photo when it's opened — the first logged edit diffs against this.
    func begin(_ file: URL, settings: EditSettings) {
        if lastLogged[file.path] == nil { lastLogged[file.path] = EditLogFormat.flatten(settings) }
    }

    func noteChange(_ file: URL, settings: EditSettings, context: Context) {
        pending = (file, settings, context)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: settleDelay, repeats: false) { _ in
            MainActor.assumeIsolated { EditLog.shared.flush() }
        }
    }

    func flush() {
        timer?.invalidate(); timer = nil
        guard let (file, s, ctx) = pending else { return }
        pending = nil
        record("edit", file: file, settings: s, context: ctx)
    }

    func record(_ event: String, file: URL, settings s: EditSettings, context ctx: Context, extra: [String: Any] = [:]) {
        if event != "edit" { flush() }
        let previous = lastLogged[file.path]
        var entry = EditLogFormat.entry(event: event, file: file, settings: s, previous: previous, camera: ctx.camera,
                                        isRAW: ctx.isRAW, median: ctx.median, bwMedian: ctx.bwMedian, imageSize: ctx.imageSize)
        if event == "edit", (entry["changed"] as? [String: Any])?.isEmpty ?? true { return }
        lastLogged[file.path] = EditLogFormat.flatten(s)
        if let id = ShotStore.shared.savedID(for: file) { entry["shot"] = id.uuidString }
        for (k, v) in extra { entry[k] = v }
        guard var line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        line.append(0x0A)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(line); try? h.close()
        } else {
            try? line.write(to: url)
        }
    }

    static func cameraSummary(_ m: [String: Any]) -> [String: Any] { EditLogFormat.cameraSummary(m) }

    // MARK: Reading

    /// All entries, oldest first.
    func entries() -> [[String: Any]] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }
}
