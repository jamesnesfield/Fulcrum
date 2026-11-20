import Foundation

/// Everything Fulcrum knows about one shot, stored as `<basename>.fulcrum` beside the shot's files.
/// See docs/library-sidecars.md.
public struct ShotSidecar: Codable, Equatable {
    public static let formatName = "fulcrum.shot"
    public static let currentVersion = 1
    public static let fileExtension = "fulcrum"

    public var format = ShotSidecar.formatName
    public var version = ShotSidecar.currentVersion
    public var id = UUID()
    public var created = Date()
    public var modified = Date()
    public var files: [File] = []
    public var edit: EditSettings?
    public var variations: [Variation] = []
    public var tags = Tags()
    public var uploads = Uploads()

    public enum Role: String, Codable { case source, companion }

    public struct File: Codable, Equatable {
        public var name: String
        public var role: Role
        public var bytes: Int64?
        public init(name: String, role: Role, bytes: Int64? = nil) { self.name = name; self.role = role; self.bytes = bytes }
    }

    /// A saved alternative edit of this shot ("Variation 2").
    public struct Variation: Codable, Equatable, Identifiable {
        public var id = UUID()
        public var number: Int
        public var date = Date()
        public var settings: EditSettings
        public init(id: UUID = UUID(), number: Int, date: Date = Date(), settings: EditSettings) {
            self.id = id; self.number = number; self.date = date; self.settings = settings
        }
    }

    public struct Tags: Codable, Equatable {
        public var favourite = false
        public var labels: [String] = []
        public init(favourite: Bool = false, labels: [String] = []) { self.favourite = favourite; self.labels = labels }
        enum CodingKeys: String, CodingKey { case favourite, labels }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            favourite = try c.decodeIfPresent(Bool.self, forKey: .favourite) ?? false
            labels = try c.decodeIfPresent([String].self, forKey: .labels) ?? []
        }
    }

    public struct Upload: Codable, Equatable {
        public var date: Date
        /// What was uploaded (edit + format). Nil for uploads made before Fulcrum recorded it.
        public var version: String?
        public init(date: Date, version: String?) { self.date = date; self.version = version }
    }

    public struct Uploads: Codable, Equatable {
        public var apple: Upload?
        public var google: Upload?
        public init(apple: Upload? = nil, google: Upload? = nil) { self.apple = apple; self.google = google }
    }

    public init() {}

    /// True when there's nothing worth keeping, so the sidecar file shouldn't exist.
    public var isEmpty: Bool {
        edit == nil && variations.isEmpty && !tags.favourite && tags.labels.isEmpty
            && uploads.apple == nil && uploads.google == nil
    }

    public var sourceName: String? { files.first { $0.role == .source }?.name ?? files.first?.name }

    enum CodingKeys: String, CodingKey { case format, version, id, created, modified, files, edit, variations, tags, uploads }

    // Lenient: anything missing falls back to its default, so a hand-edited or older sidecar still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(String.self, forKey: .format) ?? ShotSidecar.formatName
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? ShotSidecar.currentVersion
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        modified = try c.decodeIfPresent(Date.self, forKey: .modified) ?? created
        files = try c.decodeIfPresent([File].self, forKey: .files) ?? []
        edit = try c.decodeIfPresent(EditSettings.self, forKey: .edit)
        variations = try c.decodeIfPresent([Variation].self, forKey: .variations) ?? []
        tags = try c.decodeIfPresent(Tags.self, forKey: .tags) ?? Tags()
        uploads = try c.decodeIfPresent(Uploads.self, forKey: .uploads) ?? Uploads()
    }

    public static func encode(_ s: ShotSidecar) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        var d = try e.encode(s)
        d.append(0x0A)
        return d
    }

    public static func decode(_ data: Data) throws -> ShotSidecar {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(ShotSidecar.self, from: data)
    }
}

/// Which files make up a shot: supported files in one folder sharing a basename, compared case-insensitively.
public enum ShotGrouping {
    public struct Key: Hashable {
        public let folder: String
        public let basename: String   // lowercased
    }

    public static func key(for url: URL) -> Key {
        Key(folder: url.deletingLastPathComponent().standardizedFileURL.path,
            basename: url.deletingPathExtension().lastPathComponent.lowercased())
    }

    /// Lower is preferred as the file the edit renders from: RAW, then HEIC/HEIF, JPEG, TIFF, PNG, anything else.
    public static func sourceRank(_ url: URL) -> Int {
        if ImageSource.isRAWFile(url) { return 0 }
        switch url.pathExtension.lowercased() {
        case "heic", "heif": return 1
        case "jpg", "jpeg": return 2
        case "tif", "tiff": return 3
        case "png": return 4
        default: return 5
        }
    }

    /// The shot's files with the source first, then companions by name.
    public static func ordered(_ files: [URL]) -> [URL] {
        files.sorted {
            let a = sourceRank($0), b = sourceRank($1)
            return a != b ? a < b : $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    /// Groups URLs into shots, each ordered source-first. Shots come out in the order their first file appeared.
    public static func group(_ urls: [URL]) -> [[URL]] {
        var order: [Key] = []
        var byKey: [Key: [URL]] = [:]
        for u in urls where ImageSource.isSupported(u) {
            let k = key(for: u)
            if byKey[k] == nil { order.append(k); byKey[k] = [] }
            if !byKey[k]!.contains(u) { byKey[k]!.append(u) }
        }
        return order.map { ordered(byKey[$0]!) }
    }

    /// Every supported file in `url`'s folder that belongs to the same shot, source first (includes `url`).
    public static func shotFiles(containing url: URL, folderContents: [URL]? = nil) -> [URL] {
        let k = key(for: url)
        let contents = folderContents ?? ((try? FileManager.default.contentsOfDirectory(
            at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
        var files = contents.filter { ImageSource.isSupported($0) && key(for: $0) == k }
        if !files.contains(where: { $0.standardizedFileURL.path == url.standardizedFileURL.path }) { files.append(url) }
        return ordered(files)
    }

    /// Where a shot's sidecar lives: beside its source file, named after it.
    public static func sidecarURL(forSource source: URL) -> URL {
        source.deletingPathExtension().appendingPathExtension(ShotSidecar.fileExtension)
    }

    public static func makeFiles(_ ordered: [URL]) -> [ShotSidecar.File] {
        ordered.enumerated().map { i, u in
            let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init)
            return ShotSidecar.File(name: u.lastPathComponent, role: i == 0 ? .source : .companion, bytes: size)
        }
    }
}

/// The per-photo tags as they were stored in tags.json before sidecars.
public struct LegacyPhotoTags: Codable, Equatable {
    public var favorite = false
    public var labels: [String] = []
    public var uploadedApple: Date?
    public var uploadedGoogle: Date?
    public var uploadedAppleVersion: String?
    public var uploadedGoogleVersion: String?
    public init() {}
    enum CodingKeys: String, CodingKey { case favorite, labels, uploadedApple, uploadedGoogle, uploadedAppleVersion, uploadedGoogleVersion }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        labels = try c.decodeIfPresent([String].self, forKey: .labels) ?? []
        uploadedApple = try c.decodeIfPresent(Date.self, forKey: .uploadedApple)
        uploadedGoogle = try c.decodeIfPresent(Date.self, forKey: .uploadedGoogle)
        uploadedAppleVersion = try c.decodeIfPresent(String.self, forKey: .uploadedAppleVersion)
        uploadedGoogleVersion = try c.decodeIfPresent(String.self, forKey: .uploadedGoogleVersion)
    }
}

/// Turns the old path-keyed stores (edits.json, snapshots.json, tags.json) into one sidecar per shot.
public enum ShotMigration {
    public struct Legacy {
        public var edits: [String: EditSettings] = [:]
        public var snapshots: [String: [ShotSidecar.Variation]] = [:]
        public var tags: [String: LegacyPhotoTags] = [:]
        public init(edits: [String: EditSettings] = [:], snapshots: [String: [ShotSidecar.Variation]] = [:],
                    tags: [String: LegacyPhotoTags] = [:]) {
            self.edits = edits; self.snapshots = snapshots; self.tags = tags
        }
        public var allPaths: Set<String> { Set(edits.keys).union(snapshots.keys).union(tags.keys) }
    }

    public struct Planned {
        public var sidecarURL: URL
        public var sidecar: ShotSidecar
    }

    public struct Plan {
        public var shots: [Planned]
        /// Entries whose photo no longer exists. Kept, not dropped.
        public var unmatched: Legacy
    }

    /// `shotFiles` returns the files of the shot containing a path (source first); it's a parameter so tests can
    /// run without a real folder listing.
    public static func plan(_ legacy: Legacy, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                            shotFiles: (URL) -> [URL] = { ShotGrouping.shotFiles(containing: $0) },
                            now: Date = Date()) -> Plan {
        var unmatched = Legacy()
        var groups: [ShotGrouping.Key: [URL]] = [:]
        var order: [ShotGrouping.Key] = []
        for path in legacy.allPaths.sorted() {
            guard exists(path) else {
                unmatched.edits[path] = legacy.edits[path]
                unmatched.snapshots[path] = legacy.snapshots[path]
                unmatched.tags[path] = legacy.tags[path]
                continue
            }
            let url = URL(fileURLWithPath: path)
            let k = ShotGrouping.key(for: url)
            if groups[k] == nil { order.append(k); groups[k] = shotFiles(url) }
        }
        let shots = order.map { k -> Planned in
            let files = groups[k]!
            return Planned(sidecarURL: ShotGrouping.sidecarURL(forSource: files[0]),
                           sidecar: merge(files: files, legacy, now: now))
        }
        return Plan(shots: shots, unmatched: unmatched)
    }

    /// One shot's sidecar from whatever its files had in the old stores. `files` is source-first.
    public static func merge(files: [URL], _ legacy: Legacy, now: Date = Date()) -> ShotSidecar {
        let paths = files.map(\.path)
        var s = ShotSidecar()
        s.created = now; s.modified = now
        s.files = ShotGrouping.makeFiles(files)

        // The source's edit wins; any other file's edit that differs is kept as a variation.
        let edits = paths.compactMap { legacy.edits[$0] }
        s.edit = edits.first
        var extra: [EditSettings] = []
        for e in edits.dropFirst() where e != s.edit && !extra.contains(e) { extra.append(e) }

        var vars = paths.flatMap { legacy.snapshots[$0] ?? [] }.sorted { $0.date < $1.date }
        for e in extra { vars.append(ShotSidecar.Variation(number: 0, date: now, settings: e)) }
        for i in vars.indices { vars[i].number = i + 1 }
        s.variations = vars

        let tags = paths.compactMap { legacy.tags[$0] }
        s.tags.favourite = tags.contains { $0.favorite }
        var seen = Set<String>()
        s.tags.labels = tags.flatMap(\.labels).filter { seen.insert($0.lowercased()).inserted }
        s.uploads.apple = tags.compactMap { t in t.uploadedApple.map { ShotSidecar.Upload(date: $0, version: t.uploadedAppleVersion) } }
            .max { $0.date < $1.date }
        s.uploads.google = tags.compactMap { t in t.uploadedGoogle.map { ShotSidecar.Upload(date: $0, version: t.uploadedGoogleVersion) } }
            .max { $0.date < $1.date }
        return s
    }
}
