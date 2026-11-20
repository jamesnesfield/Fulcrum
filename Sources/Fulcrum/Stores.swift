import Foundation
import FulcrumCore

enum AppPaths {
    static var support: URL {
        let u = ProcessInfo.processInfo.environment["FULCRUM_SUPPORT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Fulcrum", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}

/// A saved look — your personal starting point for photos.
struct Look: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var settings: EditSettings
}

@MainActor
final class LookStore: ObservableObject {
    @Published private(set) var looks: [Look] = []
    @Published var defaultLookID: UUID? { didSet { save() } }

    private struct File: Codable { var looks: [Look]; var defaultLookID: UUID? }
    private let url = AppPaths.support.appendingPathComponent("looks.json")

    init() {
        if let d = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(File.self, from: d) {
            looks = f.looks
            defaultLookID = f.defaultLookID
        }
    }

    var defaultLook: Look? { looks.first { $0.id == defaultLookID } }

    func add(name: String, settings: EditSettings) {
        if let i = looks.firstIndex(where: { $0.name == name }) {
            looks[i].settings = settings
        } else {
            looks.append(Look(name: name, settings: settings))
        }
        save()
    }

    func delete(_ look: Look) {
        looks.removeAll { $0.id == look.id }
        if defaultLookID == look.id { defaultLookID = nil }
        save()
    }

    private func save() {
        if let d = try? JSONEncoder().encode(File(looks: looks, defaultLookID: defaultLookID)) {
            try? d.write(to: url, options: .atomic)
        }
    }
}

/// Per-shot edits (non-destructive — originals are never touched). Stored in each shot's sidecar.
@MainActor
final class EditStore {
    static let shared = EditStore()
    private init() {}

    func settings(for file: URL) -> EditSettings? { ShotStore.shared.sidecar(for: file).edit }
    func hasEdits(_ file: URL) -> Bool { settings(for: file) != nil }
    func set(_ s: EditSettings?, for file: URL) { ShotStore.shared.update(file) { $0.edit = s } }
}

extension ExportOptions {
    static var saved: ExportOptions {
        get {
            guard let d = UserDefaults.standard.data(forKey: "exportOptions"),
                  let o = try? JSONDecoder().decode(ExportOptions.self, from: d) else { return ExportOptions() }
            return o
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "exportOptions") }
    }
}

/// A saved variation of one shot's edit ("Variation 2") to compare grades side by side.
typealias Snapshot = ShotSidecar.Variation

extension ShotSidecar.Variation {
    var name: String { "Variation \(number)" }
}

@MainActor
final class SnapshotStore {
    static let shared = SnapshotStore()
    private init() {}

    func snapshots(for file: URL) -> [Snapshot] { ShotStore.shared.sidecar(for: file).variations }
    func set(_ s: [Snapshot], for file: URL) { ShotStore.shared.update(file) { $0.variations = s } }
}
