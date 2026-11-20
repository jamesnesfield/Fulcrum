import AppKit
import FulcrumCore
import os

/// The library: every shoot under the import folder, kept in an index that's refreshed in the background.
/// The sidecars stay the truth; the index (library.sqlite) can be deleted at any time and is rebuilt.
@MainActor
final class Library: ObservableObject {
    static let shared = Library()
    static let log = Logger(subsystem: "local.fulcrum.photo", category: "library")

    enum Scope: Hashable {
        case shoot(String), favourites, readyToUpload
        var filter: LibraryIndex.Filter {
            switch self {
            case .shoot(let f): return .shoot(f)
            case .favourites: return .favourites
            case .readyToUpload: return .readyToUpload
            }
        }
    }

    @Published private(set) var shoots: [LibraryIndex.Shoot] = []
    @Published private(set) var favourites = 0
    @Published private(set) var readyToUpload = 0
    @Published private(set) var root: URL
    @Published private(set) var hasLoaded = false

    private let queue = DispatchQueue(label: "fulcrum.library", qos: .utility)
    private nonisolated(unsafe) var index: LibraryIndex?   // only touched on `queue`
    private var refreshQueued = false

    static var importRoot: URL {
        // Test hook, like FULCRUM_SUPPORT_DIR: index another folder without changing the import setting.
        if let dir = ProcessInfo.processInfo.environment["FULCRUM_LIBRARY_DIR"] { return URL(fileURLWithPath: dir, isDirectory: true) }
        return UserDefaults.standard.string(forKey: "importRoot").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Fulcrum", isDirectory: true)
    }

    private init() {
        root = Self.importRoot
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Library.shared.refresh() }
        }
        nc.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let lib = Library.shared
                if Library.importRoot != lib.root { lib.root = Library.importRoot; lib.refresh() }
            }
        }
    }

    /// Re-reads any folder under the root that changed since last time. Cheap when nothing did.
    func refresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        let root = self.root
        queue.async { [self] in
            DispatchQueue.main.async { self.refreshQueued = false }
            do {
                let r = try openIndex().refresh(root: root)
                if r.foldersScanned > 0 { Self.log.info("Indexed \(r.foldersScanned) folder(s), \(r.shotsChanged) shot(s) changed") }
            } catch {
                Self.log.error("Library refresh failed: \(String(describing: error), privacy: .public)")
            }
            publish()
        }
    }

    /// A sidecar in `folder` was just saved or removed: update that folder straight away.
    func folderChanged(_ folder: URL) {
        queue.async { [self] in
            guard index != nil else { return }
            try? index?.refresh(folder: folder)
            publish()
        }
    }

    /// The source files of the shots in a scope, in capture order.
    func files(_ scope: Scope, completion: @escaping @MainActor ([URL]) -> Void) {
        queue.async { [self] in
            let urls = (try? openIndex().shots(scope.filter).map(\.sourceURL)) ?? []
            DispatchQueue.main.async { completion(urls) }
        }
    }

    func title(_ scope: Scope) -> String {
        switch scope {
        case .shoot(let f): return shoots.first { $0.folder == f }?.name ?? (f as NSString).lastPathComponent
        case .favourites: return "Favourites"
        case .readyToUpload: return "To Upload"
        }
    }

    // MARK: Queue-only

    private nonisolated func openIndex() throws -> LibraryIndex {
        if let index { return index }
        let i = try LibraryIndex(url: AppPaths.support.appendingPathComponent("library.sqlite"))
        index = i
        return i
    }

    private nonisolated func publish() {
        guard let index else { return }
        let shoots = (try? index.shoots()) ?? []
        let fav = (try? index.count(.favourites)) ?? 0
        let ready = (try? index.count(.readyToUpload)) ?? 0
        DispatchQueue.main.async {
            if self.shoots != shoots { self.shoots = shoots }
            if self.favourites != fav { self.favourites = fav }
            if self.readyToUpload != ready { self.readyToUpload = ready }
            self.hasLoaded = true
        }
    }
}
