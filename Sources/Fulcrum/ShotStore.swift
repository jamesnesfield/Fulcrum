import AppKit
import FulcrumCore
import os

/// Reads and writes each shot's sidecar (`<basename>.fulcrum` beside its photos). The source of truth for edits,
/// variations, tags and upload state. See docs/library-sidecars.md.
@MainActor
final class ShotStore {
    static let shared = ShotStore()
    static let log = Logger(subsystem: "local.fulcrum.photo", category: "shots")

    private final class Entry {
        var sidecar: ShotSidecar
        /// Where it's stored: beside the photos, or in Application Support when that folder can't be written.
        var url: URL
        var diskDate: Date?
        let readOnly: Bool
        var pending: DispatchWorkItem?
        init(sidecar: ShotSidecar, url: URL, diskDate: Date?, readOnly: Bool) {
            self.sidecar = sidecar; self.url = url; self.diskDate = diskDate; self.readOnly = readOnly
        }
    }

    private var entries: [ShotGrouping.Key: Entry] = [:]
    /// Source path → sidecar id, for shots whose folder couldn't be written.
    private var fallbackIndex: [String: UUID] = [:]
    private let fallbackDir = AppPaths.support.appendingPathComponent("Sidecars", isDirectory: true)
    private var fallbackIndexURL: URL { fallbackDir.appendingPathComponent("index.json") }

    private init() {
        if let d = try? Data(contentsOf: fallbackIndexURL), let i = try? JSONDecoder().decode([String: UUID].self, from: d) {
            fallbackIndex = i
        }
        LegacyMigration.runIfNeeded(store: self)
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ShotStore.shared.flush() }
        }
    }

    // MARK: Reading

    func sidecar(for file: URL) -> ShotSidecar { entry(for: file).sidecar }

    /// The shot's id, but only once it's saved, so it can be referred to later (e.g. from the edit log).
    func savedID(for file: URL) -> UUID? {
        let e = entry(for: file)
        return e.diskDate != nil || e.pending != nil ? e.sidecar.id : nil
    }

    /// The file a shot renders from (its RAW if it has one).
    func sourceURL(for file: URL) -> URL {
        let e = entry(for: file)
        guard let name = e.sidecar.sourceName else { return file }
        let u = file.deletingLastPathComponent().appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: u.path) ? u : file
    }

    func isReadOnly(_ file: URL) -> Bool { entry(for: file).readOnly }

    /// The shot's file types, source first: "ARW+JPG".
    func kinds(for file: URL) -> String {
        let names = entry(for: file).sidecar.files.map { ($0.name as NSString).pathExtension.uppercased() }
        return names.isEmpty ? file.pathExtension.uppercased() : names.joined(separator: "+")
    }

    /// Sets up shots from a folder listing already in hand, so opening a big folder doesn't list it once per photo.
    func prime(_ folderContents: [URL]) {
        for files in ShotGrouping.group(folderContents) where entries[ShotGrouping.key(for: files[0])] == nil {
            _ = entry(for: files[0], files: files)
        }
    }

    // MARK: Writing

    func update(_ file: URL, _ change: (inout ShotSidecar) -> Void) {
        let e = entry(for: file)
        reloadIfChangedOnDisk(e)
        var s = e.sidecar
        change(&s)
        guard s != e.sidecar else { return }
        guard !e.readOnly else {
            Self.log.error("Not saving \(e.url.path, privacy: .public): written by a newer Fulcrum")
            return
        }
        e.sidecar = s
        e.pending?.cancel()
        let work = DispatchWorkItem { [weak self, e] in self?.write(e) }
        e.pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Writes anything still waiting on its debounce. Called on quit.
    func flush() {
        for e in entries.values where e.pending != nil { write(e) }
    }

    // MARK: Internals

    private func entry(for file: URL, files known: [URL]? = nil) -> Entry {
        let k = ShotGrouping.key(for: file)
        if let e = entries[k] { return e }
        let files = known ?? ShotGrouping.shotFiles(containing: file)
        let source = files[0]
        let beside = ShotGrouping.sidecarURL(forSource: source)
        let e: Entry
        if let loaded = load(beside) {
            e = loaded
        } else if let id = fallbackIndex[source.path], let loaded = load(fallbackURL(id)) {
            e = loaded
        } else {
            var s = ShotSidecar()
            s.files = ShotGrouping.makeFiles(files)
            e = Entry(sidecar: s, url: beside, diskDate: nil, readOnly: false)
        }
        entries[k] = e
        return e
    }

    private func load(_ url: URL) -> Entry? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        do {
            let s = try ShotSidecar.decode(d)
            return Entry(sidecar: s, url: url, diskDate: modificationDate(url), readOnly: s.version > ShotSidecar.currentVersion)
        } catch {
            Self.log.error("Couldn't read \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Another Mac or a restore changed the sidecar since we read it: start from what's on disk.
    private func reloadIfChangedOnDisk(_ e: Entry) {
        guard let onDisk = modificationDate(e.url), onDisk != e.diskDate,
              let d = try? Data(contentsOf: e.url), let s = try? ShotSidecar.decode(d) else { return }
        e.sidecar = s
        e.diskDate = onDisk
    }

    private func write(_ e: Entry) {
        e.pending?.cancel()
        e.pending = nil
        let fm = FileManager.default
        if e.sidecar.isEmpty {
            if e.diskDate != nil {
                try? fm.removeItem(at: e.url)
                Library.shared.folderChanged(e.url.deletingLastPathComponent())
            }
            e.diskDate = nil
            if let source = sourcePath(e), fallbackIndex.removeValue(forKey: source) != nil { saveFallbackIndex() }
            return
        }
        e.sidecar.modified = Date()
        do {
            let data = try ShotSidecar.encode(e.sidecar)
            func moveToFallback() throws {
                let source = sourcePath(e)
                e.url = fallbackURL(e.sidecar.id)
                try fm.createDirectory(at: fallbackDir, withIntermediateDirectories: true)
                if let source { fallbackIndex[source] = e.sidecar.id; saveFallbackIndex() }
            }
            // Never write into a Photos library package (e.g. an "Edit With" copy): keep it with Fulcrum.
            if !e.url.path.hasPrefix(fallbackDir.path), PhotosSession.isInsidePhotosLibrary(e.url) { try moveToFallback() }
            do {
                try data.write(to: e.url, options: .atomic)
            } catch let besideError where !e.url.path.hasPrefix(fallbackDir.path) {
                // The photo's folder can't be written (read-only volume, locked folder): keep it with Fulcrum.
                Self.log.info("Saving \(e.url.lastPathComponent, privacy: .public) with Fulcrum: \(besideError.localizedDescription, privacy: .public)")
                try moveToFallback()
                try data.write(to: e.url, options: .atomic)
            }
            e.diskDate = modificationDate(e.url)
            Library.shared.folderChanged(e.url.deletingLastPathComponent())
        } catch {
            Self.log.error("Couldn't save \(e.url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Writes a sidecar straight away (migration). Returns false if one already exists there.
    func writeNew(_ s: ShotSidecar, beside url: URL, source: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) || fallbackIndex[source.path] != nil { return false }
        let e = Entry(sidecar: s, url: url, diskDate: nil, readOnly: false)
        write(e)
        return e.diskDate != nil
    }

    private func sourcePath(_ e: Entry) -> String? {
        guard let name = e.sidecar.sourceName else { return nil }
        if e.url.path.hasPrefix(fallbackDir.path) { return fallbackIndex.first { $0.value == e.sidecar.id }?.key }
        return e.url.deletingLastPathComponent().appendingPathComponent(name).path
    }

    private func fallbackURL(_ id: UUID) -> URL {
        fallbackDir.appendingPathComponent(id.uuidString).appendingPathExtension(ShotSidecar.fileExtension)
    }

    private func saveFallbackIndex() {
        try? FileManager.default.createDirectory(at: fallbackDir, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(fallbackIndex) { try? d.write(to: fallbackIndexURL, options: .atomic) }
    }

    private func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

/// One-time move from the path-keyed JSON stores to sidecars. Idempotent: shots that already have a sidecar are
/// skipped, and nothing is deleted — the old files are moved to Migration/v0/.
enum LegacyMigration {
    static var dir: URL { AppPaths.support.appendingPathComponent("Migration", isDirectory: true) }
    static var doneMarker: URL { dir.appendingPathComponent("v1.done") }
    static let legacyNames = ["edits.json", "snapshots.json", "tags.json"]

    @MainActor
    static func runIfNeeded(store: ShotStore) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: doneMarker.path) else { return }
        let support = AppPaths.support
        var unreadable: [String] = []
        func read<T: Decodable>(_ name: String, _ type: T.Type) -> T? {
            guard let d = try? Data(contentsOf: support.appendingPathComponent(name)) else { return nil }
            do { return try JSONDecoder().decode(T.self, from: d) } catch { unreadable.append(name); return nil }
        }
        let present = legacyNames.filter { fm.fileExists(atPath: support.appendingPathComponent($0).path) }
        guard !present.isEmpty else {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            fm.createFile(atPath: doneMarker.path, contents: nil)
            return
        }
        // Old stores used JSONEncoder defaults, so their dates are seconds since 2001 — the decoder default.
        let legacy = ShotMigration.Legacy(
            edits: read("edits.json", [String: EditSettings].self) ?? [:],
            snapshots: read("snapshots.json", [String: [ShotSidecar.Variation]].self) ?? [:],
            tags: read("tags.json", [String: LegacyPhotoTags].self) ?? [:])
        // A store that exists but can't be read: stop, leave everything as it is, try again next launch.
        guard unreadable.isEmpty else {
            ShotStore.log.error("Migration skipped: couldn't read \(unreadable.joined(separator: ", "), privacy: .public)")
            return
        }
        let plan = ShotMigration.plan(legacy)
        var written = 0, skipped = 0, failed = 0
        for p in plan.shots where !p.sidecar.isEmpty {
            let source = p.sidecarURL.deletingLastPathComponent().appendingPathComponent(p.sidecar.sourceName ?? "")
            if store.writeNew(p.sidecar, beside: p.sidecarURL, source: source) { written += 1 }
            else if FileManager.default.fileExists(atPath: p.sidecarURL.path) { skipped += 1 }
            else { failed += 1 }
        }
        guard failed == 0 else {
            ShotStore.log.error("Migration incomplete: \(failed) shot(s) couldn't be saved; will retry next launch")
            return
        }
        RecentLabels.seed(legacy.tags.values.flatMap(\.labels))
        do {
            let archive = dir.appendingPathComponent("v0", isDirectory: true)
            try fm.createDirectory(at: archive, withIntermediateDirectories: true)
            let u = plan.unmatched
            if !u.allPaths.isEmpty {
                let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
                struct Unmatched: Encodable {
                    let edits: [String: EditSettings]; let snapshots: [String: [ShotSidecar.Variation]]; let tags: [String: LegacyPhotoTags]
                }
                try e.encode(Unmatched(edits: u.edits, snapshots: u.snapshots, tags: u.tags))
                    .write(to: dir.appendingPathComponent("unmatched.json"), options: .atomic)
            }
            for name in present {
                let to = archive.appendingPathComponent(name)
                if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
                try fm.moveItem(at: support.appendingPathComponent(name), to: to)
            }
            fm.createFile(atPath: doneMarker.path, contents: nil)
            ShotStore.log.info("Migrated \(written) shot(s), \(skipped) already had sidecars, \(u.allPaths.count) unmatched")
        } catch {
            ShotStore.log.error("Migration couldn't archive old stores: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Labels used recently, most recent first, for the labels popover's suggestions.
enum RecentLabels {
    private static let key = "recentLabels"
    static var all: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }

    static func use(_ labels: [String]) {
        var list = all
        for l in labels.reversed() {
            list.removeAll { $0.lowercased() == l.lowercased() }
            list.insert(l, at: 0)
        }
        UserDefaults.standard.set(Array(list.prefix(60)), forKey: key)
    }

    /// Most-used first, as the suggestions were ordered before sidecars.
    static func seed(_ labels: [String]) {
        var counts: [String: Int] = [:]
        for l in labels { counts[l, default: 0] += 1 }
        let ordered = counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
        use(ordered)
    }
}
