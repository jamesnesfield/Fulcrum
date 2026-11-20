import Foundation
import ImageIO
import SQLite3

/// A cache of the library's shots for browsing and filtering. The sidecars are the truth: deleting the database is
/// always safe, the next refresh rebuilds it. Not thread-safe; use from one queue.
public final class LibraryIndex {
    public struct Shot: Equatable, Sendable {
        public var folder: String
        public var basename: String     // lowercased, as in ShotGrouping.Key
        public var source: String       // file name of the source
        public var kinds: String        // "ARW+JPG"
        public var id: String?
        public var capture: Date?
        public var edited: Bool
        public var favourite: Bool
        public var labels: [String]
        public var uploadedApple: Bool
        public var uploadedGoogle: Bool
        public var sidecarDate: Date?
        public var sourceURL: URL { URL(fileURLWithPath: folder).appendingPathComponent(source) }
    }

    /// A folder that directly holds photos.
    public struct Shoot: Equatable, Identifiable, Sendable {
        public var folder: String
        public var name: String         // path relative to the library root
        public var shots: Int
        public var edited: Int
        public var favourites: Int
        public var earliest: Date?
        public var id: String { folder }
        public var url: URL { URL(fileURLWithPath: folder, isDirectory: true) }
    }

    public enum Filter: Sendable { case shoot(String), favourites, readyToUpload }

    public struct RefreshResult: Equatable { public var foldersScanned = 0; public var shotsChanged = 0 }

    static let schemaVersion = "1"
    private var db: OpaquePointer?
    public private(set) var root: String?

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw Failure("Couldn't open \(url.path)") }
        try exec("PRAGMA journal_mode=WAL")
        if try metaValue("schema") != Self.schemaVersion {
            // The index is a cache, so a schema change just starts again.
            try exec("DROP TABLE IF EXISTS shots; DROP TABLE IF EXISTS folders; DROP TABLE IF EXISTS meta")
        }
        try exec("""
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE IF NOT EXISTS folders(path TEXT PRIMARY KEY, mtime REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS shots(
                folder TEXT NOT NULL, basename TEXT NOT NULL, source TEXT NOT NULL, kinds TEXT NOT NULL,
                id TEXT, capture REAL, edited INTEGER NOT NULL, favourite INTEGER NOT NULL, labels TEXT NOT NULL,
                uploaded_apple INTEGER NOT NULL, uploaded_google INTEGER NOT NULL, sidecar_mtime REAL,
                PRIMARY KEY(folder, basename));
            CREATE INDEX IF NOT EXISTS shots_favourite ON shots(favourite);
            """)
        try setMeta("schema", Self.schemaVersion)
        root = try metaValue("root")
    }

    deinit { sqlite3_close(db) }

    // MARK: Refreshing

    /// Brings the index up to date with the folders under `root`. Only folders whose modification date changed are
    /// re-read (adding, removing or saving a sidecar all change it). A different root starts the index again.
    @discardableResult
    public func refresh(root rootURL: URL) throws -> RefreshResult {
        let rootPath = rootURL.standardizedFileURL.path
        if root != rootPath {
            try exec("DELETE FROM shots; DELETE FROM folders")
            try setMeta("root", rootPath)
            root = rootPath
        }
        var result = RefreshResult()
        let known = try folderDates()
        var seen = Set<String>()
        for folder in Self.folders(under: rootURL) {
            let path = folder.standardizedFileURL.path
            seen.insert(path)
            let date = Self.modificationDate(folder) ?? .distantPast
            if let k = known[path], Self.same(k, date) { continue }
            result.shotsChanged += try rescan(folder: folder, date: date)
            result.foldersScanned += 1
        }
        for gone in Set(known.keys).subtracting(seen) {
            try run("DELETE FROM shots WHERE folder = ?", [gone])
            try run("DELETE FROM folders WHERE path = ?", [gone])
            result.shotsChanged += 1
        }
        return result
    }

    /// Re-reads one folder now, e.g. right after Fulcrum saved a sidecar in it. Ignored outside the root.
    public func refresh(folder: URL) throws {
        let path = folder.standardizedFileURL.path
        guard let root, path == root || path.hasPrefix(root + "/") else { return }
        try rescan(folder: folder, date: Self.modificationDate(folder) ?? .distantPast)
    }

    @discardableResult
    private func rescan(folder: URL, date: Date) throws -> Int {
        let path = folder.standardizedFileURL.path
        let old = Dictionary(uniqueKeysWithValues: try shots(sql: "SELECT * FROM shots WHERE folder = ?", [path]).map { ($0.basename, $0) })
        let contents = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                                     options: [.skipsHiddenFiles])) ?? []
        var rows: [Shot] = []
        for files in ShotGrouping.group(contents) {
            let source = files[0]
            let key = ShotGrouping.key(for: source)
            let sidecarURL = ShotGrouping.sidecarURL(forSource: source)
            let sidecarDate = Self.modificationDate(sidecarURL)
            let kinds = files.map { $0.pathExtension.uppercased() }.joined(separator: "+")
            let prev = old[key.basename]
            var row = Shot(folder: path, basename: key.basename, source: source.lastPathComponent, kinds: kinds,
                           id: nil, capture: nil, edited: false, favourite: false, labels: [],
                           uploadedApple: false, uploadedGoogle: false, sidecarDate: sidecarDate)
            row.capture = prev?.source == row.source ? prev?.capture : Self.captureDate(source)
            if let prev, Self.same(prev.sidecarDate, sidecarDate), prev.source == row.source {
                row.id = prev.id; row.edited = prev.edited; row.favourite = prev.favourite; row.labels = prev.labels
                row.uploadedApple = prev.uploadedApple; row.uploadedGoogle = prev.uploadedGoogle
            } else if sidecarDate != nil, let d = try? Data(contentsOf: sidecarURL), let s = try? ShotSidecar.decode(d) {
                row.id = s.id.uuidString
                row.edited = s.edit != nil
                row.favourite = s.tags.favourite
                row.labels = s.tags.labels
                row.uploadedApple = s.uploads.apple != nil
                row.uploadedGoogle = s.uploads.google != nil
            }
            rows.append(row)
        }
        let changed = rows.filter { r in old[r.basename].map { !Self.sameRow($0, r) } ?? true }.count + Set(old.keys).subtracting(rows.map(\.basename)).count
        try exec("BEGIN")
        do {
            try run("DELETE FROM shots WHERE folder = ?", [path])
            for r in rows {
                try run("""
                    INSERT INTO shots(folder, basename, source, kinds, id, capture, edited, favourite, labels,
                                      uploaded_apple, uploaded_google, sidecar_mtime)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
                    """, [r.folder, r.basename, r.source, r.kinds, r.id, r.capture?.timeIntervalSince1970,
                          r.edited, r.favourite, r.labels.joined(separator: "\n"), r.uploadedApple, r.uploadedGoogle,
                          r.sidecarDate?.timeIntervalSince1970])
            }
            try run("INSERT OR REPLACE INTO folders(path, mtime) VALUES (?, ?)", [path, date.timeIntervalSince1970])
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        return changed
    }

    // MARK: Queries

    /// Folders holding photos, newest first.
    public func shoots() throws -> [Shoot] {
        let root = self.root ?? ""
        var out: [Shoot] = []
        try query("""
            SELECT folder, COUNT(*), SUM(edited), SUM(favourite), MIN(capture) FROM shots GROUP BY folder
            """, []) { s in
            let folder = Self.text(s, 0) ?? ""
            var name = folder.hasPrefix(root + "/") ? String(folder.dropFirst(root.count + 1)) : (folder as NSString).lastPathComponent
            if folder == root { name = (root as NSString).lastPathComponent }
            out.append(Shoot(folder: folder, name: name, shots: Int(sqlite3_column_int64(s, 1)),
                             edited: Int(sqlite3_column_int64(s, 2)), favourites: Int(sqlite3_column_int64(s, 3)),
                             earliest: sqlite3_column_type(s, 4) == SQLITE_NULL ? nil
                                 : Date(timeIntervalSince1970: sqlite3_column_double(s, 4))))
        }
        // Newest first by the shoot's earliest photo, then by name (dated folder names sort the same way).
        return out.sorted { a, b in
            switch (a.earliest, b.earliest) {
            case let (x?, y?) where x != y: return x > y
            default: return a.name.localizedStandardCompare(b.name) == .orderedDescending
            }
        }
    }

    /// Shots matching a filter, in capture order (then by name).
    public func shots(_ filter: Filter) throws -> [Shot] {
        let order = " ORDER BY capture IS NULL, capture, source COLLATE NOCASE"
        switch filter {
        case .shoot(let folder): return try shots(sql: "SELECT * FROM shots WHERE folder = ?" + order, [folder])
        case .favourites: return try shots(sql: "SELECT * FROM shots WHERE favourite = 1" + order, [])
        case .readyToUpload:
            return try shots(sql: "SELECT * FROM shots WHERE edited = 1 AND uploaded_apple = 0 AND uploaded_google = 0" + order, [])
        }
    }

    public func count(_ filter: Filter) throws -> Int {
        let sql: String
        var args: [Any?] = []
        switch filter {
        case .shoot(let f): sql = "SELECT COUNT(*) FROM shots WHERE folder = ?"; args = [f]
        case .favourites: sql = "SELECT COUNT(*) FROM shots WHERE favourite = 1"
        case .readyToUpload: sql = "SELECT COUNT(*) FROM shots WHERE edited = 1 AND uploaded_apple = 0 AND uploaded_google = 0"
        }
        var n = 0
        try query(sql, args) { n = Int(sqlite3_column_int64($0, 0)) }
        return n
    }

    // MARK: File system

    /// Every non-hidden folder under root (including root), not descending into packages such as Photos libraries.
    static func folders(under root: URL) -> [URL] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { return [] }
        var out = [root]
        let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                                               options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let u = e?.nextObject() as? URL {
            let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            if v?.isDirectory == true, v?.isPackage != true { out.append(u) }
        }
        return out
    }

    /// Dates go through SQLite as doubles, so compare to the microsecond rather than exactly.
    static func same(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?): return abs(x.timeIntervalSince(y)) < 0.000_01
        default: return false
        }
    }

    static func sameRow(_ a: Shot, _ b: Shot) -> Bool {
        var a2 = a, b2 = b
        guard same(a.capture, b.capture), same(a.sidecarDate, b.sidecarDate) else { return false }
        a2.capture = nil; b2.capture = nil; a2.sidecarDate = nil; b2.sidecarDate = nil
        return a2 == b2
    }

    static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// EXIF capture time, else the file's modification date.
    static func captureDate(_ url: URL) -> Date? {
        if let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy:MM:dd HH:mm:ss"
            if let d = f.date(from: s) { return d }
        }
        return modificationDate(url)
    }

    // MARK: SQLite

    struct Failure: Error, CustomStringConvertible { let description: String; init(_ d: String) { description = d } }

    private var lastError: String { String(cString: sqlite3_errmsg(db)) }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw Failure(lastError) }
    }

    private func run(_ sql: String, _ args: [Any?]) throws { try query(sql, args) { _ in } }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func query(_ sql: String, _ args: [Any?], row: (OpaquePointer) throws -> Void) throws {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK, let s else { throw Failure(lastError) }
        defer { sqlite3_finalize(s) }
        for (i, a) in args.enumerated() {
            let n = Int32(i + 1)
            switch a {
            case nil: sqlite3_bind_null(s, n)
            case let v as String: sqlite3_bind_text(s, n, v, -1, Self.transient)
            case let v as Bool: sqlite3_bind_int(s, n, v ? 1 : 0)
            case let v as Int: sqlite3_bind_int64(s, n, Int64(v))
            case let v as Double: sqlite3_bind_double(s, n, v)
            default: throw Failure("Unsupported value \(String(describing: a))")
            }
        }
        while true {
            let r = sqlite3_step(s)
            if r == SQLITE_ROW { try row(s) } else if r == SQLITE_DONE { return } else { throw Failure(lastError) }
        }
    }

    private static func text(_ s: OpaquePointer, _ i: Int32) -> String? {
        sqlite3_column_text(s, i).map { String(cString: $0) }
    }

    private func shots(sql: String, _ args: [Any?]) throws -> [Shot] {
        var out: [Shot] = []
        try query(sql, args) { s in
            func double(_ i: Int32) -> Date? {
                sqlite3_column_type(s, i) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(s, i))
            }
            let labels = Self.text(s, 8) ?? ""
            out.append(Shot(folder: Self.text(s, 0) ?? "", basename: Self.text(s, 1) ?? "", source: Self.text(s, 2) ?? "",
                            kinds: Self.text(s, 3) ?? "", id: Self.text(s, 4), capture: double(5),
                            edited: sqlite3_column_int(s, 6) != 0, favourite: sqlite3_column_int(s, 7) != 0,
                            labels: labels.isEmpty ? [] : labels.components(separatedBy: "\n"),
                            uploadedApple: sqlite3_column_int(s, 9) != 0, uploadedGoogle: sqlite3_column_int(s, 10) != 0,
                            sidecarDate: double(11)))
        }
        return out
    }

    private func folderDates() throws -> [String: Date] {
        var out: [String: Date] = [:]
        try query("SELECT path, mtime FROM folders", []) { s in
            out[Self.text(s, 0) ?? ""] = Date(timeIntervalSince1970: sqlite3_column_double(s, 1))
        }
        return out
    }

    private func metaValue(_ key: String) throws -> String? {
        var v: String?
        // meta may not exist yet on a brand-new database.
        try? query("SELECT value FROM meta WHERE key = ?", [key]) { v = Self.text($0, 0) }
        return v
    }

    private func setMeta(_ key: String, _ value: String) throws {
        try run("INSERT OR REPLACE INTO meta(key, value) VALUES (?, ?)", [key, value])
    }
}
