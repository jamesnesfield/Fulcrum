import AppKit
import ImageCaptureCore
import os
import SwiftUI
import UniformTypeIdentifiers

/// One shot on the card. RAW+JPEG pairs (same name, same folder) are one shot, so they're kept or rejected together.
final class CameraShot: Identifiable, ObservableObject {
    enum Flag { case none, keep, reject }

    let id: String
    var files: [ICCameraFile]
    @Published var flag: Flag = .none
    @Published var thumbnail: CGImage?
    @Published var preview: CGImage?
    @Published var thumbFailed = false
    @Published var previewFailed = false
    var thumbRequested = false
    var previewRequested = false

    init(id: String, files: [ICCameraFile]) { self.id = id; self.files = files }

    var name: String { (files.first?.name as NSString?)?.deletingPathExtension ?? id }
    var date: Date? { files.lazy.compactMap { $0.exifCreationDate ?? $0.creationDate }.first }
    var bytes: Int64 { files.reduce(0) { $0 + Int64($1.fileSize) } }
    var kinds: String { files.compactMap { ($0.name as NSString?)?.pathExtension.uppercased() }.sorted().joined(separator: "+") }
    var isVideo: Bool { files.contains { $0.uti.map { UTType($0)?.conforms(to: .movie) ?? false } ?? false } }

    /// The file we ask for previews: a JPEG/HEIC if there is one (its embedded preview is quicker), else the RAW.
    var previewFile: ICCameraFile? {
        files.first { f in
            guard let ext = (f.name as NSString?)?.pathExtension.lowercased() else { return false }
            return ["jpg", "jpeg", "heic", "heif", "png"].contains(ext)
        } ?? files.first
    }
}

/// Finds cameras and card readers over USB, lists their photos, imports the keepers and deletes the rest.
final class CameraImporter: NSObject, ObservableObject, ICDeviceBrowserDelegate, ICCameraDeviceDelegate {
    enum Filter: String, CaseIterable, Identifiable { case all = "All", unflagged = "Unflagged", keep = "Keep", reject = "Reject"; var id: String { rawValue } }

    @Published private(set) var cameras: [ICCameraDevice] = []
    @Published private(set) var camera: ICCameraDevice?
    @Published private(set) var shots: [CameraShot] = []
    @Published private(set) var isReadingCard = false
    @Published var focusID: String?
    @Published var filter: Filter = .all
    @Published var autoAdvance = true
    @Published private(set) var status: String?
    @Published private(set) var isBusy = false
    @Published var pendingDelete: [CameraShot] = []      // set after a successful import; the view asks before deleting
    @Published var lastImported: [URL] = []
    @Published var destinationRoot: URL {
        didSet { UserDefaults.standard.set(destinationRoot.path, forKey: "importRoot") }
    }
    /// Bumped when a flag changes so counts in the view refresh.
    @Published private(set) var flagStamp = 0

    private let browser = ICDeviceBrowser()

    override init() {
        let saved = UserDefaults.standard.string(forKey: "importRoot").map { URL(fileURLWithPath: $0, isDirectory: true) }
        destinationRoot = saved ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fulcrum", isDirectory: true)
        super.init()
        browser.delegate = self
        let mask = ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: mask)!
    }

    func start() { if !browser.isBrowsing { browser.start() } }
    func stop() {
        queue.removeAll()
        try? FileManager.default.removeItem(at: previewCache)
        camera?.requestCloseSession()
        browser.stop()
    }

    // MARK: Lists

    var visibleShots: [CameraShot] {
        switch filter {
        case .all: shots
        case .unflagged: shots.filter { $0.flag == .none }
        case .keep: shots.filter { $0.flag == .keep }
        case .reject: shots.filter { $0.flag == .reject }
        }
    }
    var keepers: [CameraShot] { shots.filter { $0.flag == .keep } }
    var notKept: [CameraShot] { shots.filter { $0.flag != .keep } }
    var focused: CameraShot? { shots.first { $0.id == focusID } }

    // MARK: Devices

    func select(_ cam: ICCameraDevice) {
        guard cam !== camera else { return }
        camera?.requestCloseSession()
        camera = cam
        shots = []; focusID = nil; pendingDelete = []
        isReadingCard = true
        cam.delegate = self
        cam.requestOpenSession()
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let cam = device as? ICCameraDevice else { return }
        cameras.append(cam)
        if camera == nil { select(cam) }
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        cameras.removeAll { $0 === device }
        if camera === device {
            camera = nil; shots = []; focusID = nil; pendingDelete = []; isReadingCard = false
            status = "\(device.name ?? "Camera") disconnected."
            if let next = cameras.first { select(next) }
        }
    }

    func didRemove(_ device: ICDevice) {}
    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        if let error { isReadingCard = false; status = "Couldn't open \(device.name ?? "camera"): \(error.localizedDescription)" }
    }
    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}

    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        isReadingCard = false
        rebuild()
    }
    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) { if !isReadingCard { rebuild() } }
    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) { if !isReadingCard { rebuild() } }
    /// ImageCaptureCore fetches thumbnails for the whole card in the background; take each as it arrives.
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {
        if let error { Self.log.error("thumbnail for \(item.name ?? "?", privacy: .public) failed: \(error.localizedDescription, privacy: .public)") }
        guard let thumbnail, let shot = shotForFile[ObjectIdentifier(item)] else { return }
        DispatchQueue.main.async {
            if shot.thumbnail == nil { shot.thumbnail = thumbnail; shot.thumbFailed = false }
        }
    }
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) { rebuild() }
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        status = "\(device.name ?? "The camera") is locked — unlock it to see its photos."
    }
    // Thumbnails are allowed (blocking them also blocked our own requests on some cameras); metadata isn't needed.
    func cameraDevice(_ cameraDevice: ICCameraDevice, shouldGetThumbnailOf item: ICCameraItem) -> Bool { true }
    func cameraDevice(_ cameraDevice: ICCameraDevice, shouldGetMetadataOf item: ICCameraItem) -> Bool { false }

    /// Groups the card's files into shots, keeping any flags already set.
    private func rebuild() {
        guard let cam = camera else { return }
        let files = (cam.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }
        var groups: [String: [ICCameraFile]] = [:]
        var order: [String] = []
        for f in files {
            let base = ((f.name ?? "") as NSString).deletingPathExtension
            let key = (f.parentFolder?.name ?? "") + "/" + base
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(f)
        }
        let old = Dictionary(shots.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        shots = order.map { key in
            if let s = old[key] { s.files = groups[key]!; return s }
            return CameraShot(id: key, files: groups[key]!)
        }.sorted { ($0.date ?? .distantPast, $0.name) < ($1.date ?? .distantPast, $1.name) }
        shotForFile = Dictionary(shots.flatMap { s in s.files.map { (ObjectIdentifier($0), s) } }, uniquingKeysWith: { a, _ in a })
        if focusID == nil || !shots.contains(where: { $0.id == focusID }) { focusID = shots.first?.id }
        if shots.isEmpty { status = "No photos on \(cam.name ?? "the camera")." } else { status = nil }
    }

    // MARK: Thumbnails & previews

    static let log = Logger(subsystem: "local.fulcrum.photo", category: "import")
    private var shotForFile: [ObjectIdentifier: CameraShot] = [:]

    // Requests to the camera go through a small queue: two at a time, newest preview first, each with a
    // timeout, so one request the camera never answers can't leave the window spinning.
    private struct Request { let file: ICCameraFile; let size: Int; let done: (CGImage?) -> Void }
    private var queue: [Request] = []
    private var inFlight = 0
    private let maxInFlight = 2

    private func enqueue(_ r: Request, urgent: Bool) {
        if urgent { queue.insert(r, at: 0) } else { queue.append(r) }
        pump()
    }

    private func pump() {
        while inFlight < maxInFlight, !queue.isEmpty {
            let r = queue.removeFirst()
            inFlight += 1
            var finished = false
            let finish: (CGImage?, String?) -> Void = { [weak self] img, problem in
                DispatchQueue.main.async {
                    guard let self, !finished else { return }
                    finished = true
                    self.inFlight -= 1
                    if let problem { Self.log.error("\(r.file.name ?? "?", privacy: .public) @\(r.size): \(problem, privacy: .public)") }
                    r.done(img)
                    self.pump()
                }
            }
            r.file.requestThumbnailData(options: [.imageSourceThumbnailMaxPixelSize: r.size]) { data, error in
                let img = data.flatMap { Self.decode($0, max: r.size) }
                finish(img, img == nil ? (error?.localizedDescription ?? (data == nil ? "no data" : "couldn't decode")) : nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { finish(nil, "timed out after 20 s") }
        }
    }

    func loadThumbnail(_ shot: CameraShot, retry: Bool = false) {
        guard retry || !shot.thumbRequested, shot.thumbnail == nil, let f = shot.previewFile else { return }
        shot.thumbRequested = true
        shot.thumbFailed = false
        enqueue(Request(file: f, size: 360) { [weak shot] img in
            guard let shot, shot.thumbnail == nil else { return }
            if let img { shot.thumbnail = img } else { shot.thumbFailed = true }
        }, urgent: false)
    }

    /// A large preview of the focused shot. If the camera won't make one, the file itself is fetched into
    /// a cache (never into your library) and previewed from there.
    func loadPreview(_ shot: CameraShot, retry: Bool = false) {
        loadThumbnail(shot, retry: retry)
        guard retry || !shot.previewRequested, shot.preview == nil, let f = shot.previewFile else { return }
        shot.previewRequested = true
        shot.previewFailed = false
        enqueue(Request(file: f, size: 2400) { [weak self, weak shot] img in
            guard let self, let shot else { return }
            if let img { shot.preview = img; return }
            self.previewFromDownload(f, for: shot)
        }, urgent: true)
    }

    private lazy var previewCache: URL = {
        let u = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("local.fulcrum.photo/ImportPreviews", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    private func previewFromDownload(_ f: ICCameraFile, for shot: CameraShot) {
        let name = "\(UUID().uuidString)-\(f.name ?? "photo")"
        f.requestDownload(options: [.downloadsDirectoryURL: previewCache, .saveAsFilename: name, .overwrite: true]) { _, error in
            let url = self.previewCache.appendingPathComponent(name)
            var img: CGImage?
            if error == nil, let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
                img = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2400,
                ] as CFDictionary)
            }
            try? FileManager.default.removeItem(at: url)
            if img == nil { Self.log.error("preview download for \(f.name ?? "?", privacy: .public) failed: \(error?.localizedDescription ?? "couldn't decode", privacy: .public)") }
            DispatchQueue.main.async {
                if let img { shot.preview = img; if shot.thumbnail == nil { shot.thumbnail = img; shot.thumbFailed = false } }
                else { shot.previewFailed = true }
            }
        }
    }

    private static func decode(_ data: Data, max: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        // Apply the EXIF orientation so portrait shots stand up.
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max,
        ] as CFDictionary)
    }

    // MARK: Triage

    func setFlag(_ flag: CameraShot.Flag, advance: Bool = true) {
        guard let s = focused else { return }
        s.flag = (s.flag == flag && flag != .none) ? .none : flag
        flagStamp += 1
        if advance && autoAdvance { move(1) }
    }

    func move(_ delta: Int) {
        let list = visibleShots
        guard !list.isEmpty else { return }
        let i = list.firstIndex { $0.id == focusID } ?? 0
        focusID = list[min(max(i + delta, 0), list.count - 1)].id
    }

    // MARK: Import

    var keeperBytes: Int64 { keepers.reduce(0) { $0 + $1.bytes } }

    var freeBytes: Int64? {
        var dir = destinationRoot
        while !FileManager.default.fileExists(atPath: dir.path), dir.pathComponents.count > 1 { dir.deleteLastPathComponent() }
        let v = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage
    }

    /// Downloads every file of every kept shot into <root>/<capture date>/. Existing files are left alone.
    func importKeepers(completion: @escaping ([URL]) -> Void) {
        let shots = keepers
        guard !shots.isEmpty, !isBusy else { return }
        isBusy = true
        let dayFormat = DateFormatter(); dayFormat.dateFormat = "yyyy-MM-dd"
        let jobs: [(ICCameraFile, URL, CameraShot)] = shots.flatMap { s in
            let dir = destinationRoot.appendingPathComponent(dayFormat.string(from: s.date ?? Date()), isDirectory: true)
            return s.files.map { ($0, dir, s) }
        }
        var done = 0, failed: [String] = [], imported: [URL] = [], okShots = Set<String>()
        var failedShots = Set<String>()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "fulcrum.import")
        status = "Importing 0 of \(jobs.count) files…"

        // One file at a time: cameras over PTP don't like parallel transfers.
        func next(_ i: Int) {
            guard i < jobs.count else { group.leave(); return }
            let (file, dir, shot) = jobs[i]
            let name = file.name ?? "photo"
            let dest = dir.appendingPathComponent(name)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let finish: (Error?) -> Void = { error in
                queue.async {
                    done += 1
                    if let error { failed.append("\(name): \(error.localizedDescription)"); failedShots.insert(shot.id) }
                    else { imported.append(dest); okShots.insert(shot.id) }
                    DispatchQueue.main.async { self.status = "Importing \(done) of \(jobs.count) files…" }
                    next(i + 1)
                }
            }
            if let size = (try? FileManager.default.attributesOfItem(atPath: dest.path))?[.size] as? Int64, size == Int64(file.fileSize) {
                finish(nil)   // already imported earlier
                return
            }
            file.requestDownload(options: [
                .downloadsDirectoryURL: dir,
                .saveAsFilename: name,
                .overwrite: true,
            ]) { _, error in finish(error) }
        }
        group.enter()
        next(0)
        group.notify(queue: .main) {
            self.isBusy = false
            let photos = imported.filter { ImageSourceKinds.isPhoto($0) }
            self.lastImported = photos
            if failed.isEmpty {
                self.status = "Imported \(shots.count) shot(s) to \(self.destinationRoot.lastPathComponent)."
                // Only offer to delete once every keeper is safely on disk.
                self.pendingDelete = self.notKept
            } else {
                self.status = "Imported with \(failed.count) error(s). Nothing was deleted.\n" + failed.prefix(5).joined(separator: "\n")
            }
            completion(photos)
        }
    }

    /// Permanently deletes the given shots' files from the card.
    func delete(_ shots: [CameraShot]) {
        guard let cam = camera, !shots.isEmpty else { return }
        let files = shots.flatMap(\.files).filter { !$0.isLocked }
        let locked = shots.flatMap(\.files).count - files.count
        isBusy = true
        status = "Deleting \(files.count) file(s) from the camera…"
        pendingDelete = []
        _ = cam.requestDeleteFiles(files, deleteFailed: { _ in }) { result, error in
            DispatchQueue.main.async {
                self.isBusy = false
                let failed = result[.failed]?.count ?? 0
                var msg = "Deleted \(files.count - failed) file(s) from the camera."
                if failed > 0 { msg += " \(failed) couldn't be deleted." }
                if locked > 0 { msg += " \(locked) protected file(s) were left." }
                if let error { msg += " \(error.localizedDescription)" }
                self.status = msg
                self.rebuild()
            }
        }
    }
}

enum ImageSourceKinds {
    static func isPhoto(_ url: URL) -> Bool {
        guard let t = UTType(filenameExtension: url.pathExtension) else { return false }
        return t.conforms(to: .image)
    }
}

// MARK: - View

struct CameraImportView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var importer = CameraImporter()
    @FocusState private var gridFocused: Bool
    @State private var confirmDelete = false

    private let columns = [GridItem(.adaptive(minimum: 132, maximum: 180), spacing: 8)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if importer.camera == nil {
                emptyState
            } else if importer.isReadingCard {
                VStack(spacing: 10) { ProgressView(); Text("Reading \(importer.camera?.name ?? "camera")…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    grid.frame(minWidth: 300, idealWidth: 460)
                    preview.frame(minWidth: 400)
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(Color(nsColor: NSColor(white: 0.11, alpha: 1)))
        .onAppear { importer.start() }
        .onDisappear { importer.stop() }
        .onChange(of: importer.pendingDelete.count) { _, n in if n > 0 { confirmDelete = true } }
        .confirmationDialog(deleteTitle, isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete \(importer.pendingDelete.count) from Camera", role: .destructive) { importer.delete(importer.pendingDelete) }
            Button("Keep Them on the Card", role: .cancel) { importer.pendingDelete = [] }
        } message: {
            Text("Your \(importer.keepers.count) keeper(s) are imported. This permanently deletes every other photo on the card, including ones you didn't flag. It can't be undone.")
        }
    }

    private var deleteTitle: String {
        let n = importer.pendingDelete.count
        let rejected = importer.pendingDelete.filter { $0.flag == .reject }.count
        return "Delete the \(n) shot(s) you didn't keep? (\(rejected) rejected, \(n - rejected) unflagged)"
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "camera").font(.title3)
            if importer.cameras.count > 1 {
                Picker("Camera", selection: Binding(get: { importer.camera.map(ObjectIdentifier.init) },
                                                    set: { id in if let c = importer.cameras.first(where: { ObjectIdentifier($0) == id }) { importer.select(c) } })) {
                    ForEach(importer.cameras, id: \.self) { c in Text(c.name ?? "Camera").tag(Optional(ObjectIdentifier(c))) }
                }
                .labelsHidden().frame(width: 200)
            } else {
                Text(importer.camera?.name ?? "No camera").font(.headline)
            }
            Spacer()
            let _ = importer.flagStamp
            Picker("Show", selection: $importer.filter) {
                ForEach(CameraImporter.Filter.allCases) { f in Text(label(for: f)).tag(f) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 380)
            Toggle("Auto-advance", isOn: $importer.autoAdvance).toggleStyle(.checkbox)
                .help("Move to the next shot after flagging")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func label(for f: CameraImporter.Filter) -> String {
        let n: Int = switch f {
        case .all: importer.shots.count
        case .unflagged: importer.shots.filter { $0.flag == .none }.count
        case .keep: importer.keepers.count
        case .reject: importer.shots.filter { $0.flag == .reject }.count
        }
        return "\(f.rawValue) \(n)"
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "cable.connector").font(.system(size: 44, weight: .thin))
            Text("Connect your camera with USB-C and turn it on").font(.title3)
            Text("Or insert its card. If nothing appears, set the camera's USB mode to PTP or Mass Storage, and close Photos or Image Capture if they grabbed it first.")
                .multilineTextAlignment(.center).frame(maxWidth: 420)
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Grid

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(importer.visibleShots) { shot in
                        ShotCell(shot: shot, focused: shot.id == importer.focusID)
                            .id(shot.id)
                            .onAppear { importer.loadThumbnail(shot) }
                            .onTapGesture { importer.focusID = shot.id; gridFocused = true; if shot.thumbFailed { importer.loadThumbnail(shot, retry: true) } }
                    }
                }
                .padding(10)
            }
            .focusable()
            .focusEffectDisabled()
            .focused($gridFocused)
            .onAppear { gridFocused = true }
            .onChange(of: importer.focusID) { _, id in
                if let id { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) } }
            }
            .onKeyPress(.leftArrow) { importer.move(-1); return .handled }
            .onKeyPress(.rightArrow) { importer.move(1); return .handled }
            .onKeyPress(.upArrow) { importer.move(-columnsEstimate); return .handled }
            .onKeyPress(.downArrow) { importer.move(columnsEstimate); return .handled }
            .onKeyPress(characters: .init(charactersIn: "pPxXuU")) { press in
                switch press.characters.lowercased() {
                case "p": importer.setFlag(.keep)
                case "x": importer.setFlag(.reject)
                default: importer.setFlag(.none, advance: false)
                }
                return .handled
            }
        }
    }

    private var columnsEstimate: Int { 3 }

    // MARK: Preview

    private var preview: some View {
        VStack(spacing: 0) {
            if let shot = importer.focused {
                ShotPreview(shot: shot, retry: { importer.loadPreview(shot, retry: true) }).onAppear { importer.loadPreview(shot) }
                    .id(shot.id)
                HStack(spacing: 10) {
                    Text(shot.name).font(.headline)
                    Text(shot.kinds).font(.caption).foregroundStyle(.secondary)
                    if let d = shot.date { Text(d.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    FlagButtons(shot: shot) { importer.focusID = shot.id; importer.setFlag($0, advance: false) }
                }
                .padding(10)
            } else {
                Text("No shot selected").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Text("P keep · X reject · U clear · arrows move").font(.caption).foregroundStyle(.secondary)
            if let s = importer.status { Text(s).font(.caption).lineLimit(2).foregroundStyle(.secondary) }
            Spacer()
            Button {
                let p = NSOpenPanel()
                p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                p.directoryURL = importer.destinationRoot
                p.prompt = "Import Here"
                if p.runModal() == .OK, let u = p.url { importer.destinationRoot = u }
            } label: {
                Label(importer.destinationRoot.lastPathComponent, systemImage: "folder")
            }
            .help("Keepers go into dated folders inside \(importer.destinationRoot.path)")
            let _ = importer.flagStamp
            let size = ByteCountFormatter.string(fromByteCount: importer.keeperBytes, countStyle: .file)
            let tooBig = importer.freeBytes.map { $0 < importer.keeperBytes } ?? false
            Button("Import \(importer.keepers.count) Keeper(s) · \(size)") {
                importer.importKeepers { urls in Library.shared.refresh(); if !urls.isEmpty { model.open(urls) } }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(importer.keepers.isEmpty || importer.isBusy || tooBig)
            .help(tooBig ? "Not enough free space" : "Copy the keepers to your Mac, then choose whether to delete the rest from the camera")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

private struct ShotCell: View {
    @ObservedObject var shot: CameraShot
    let focused: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let t = shot.thumbnail {
                    Image(decorative: t, scale: 1).resizable().aspectRatio(contentMode: .fit)
                } else if shot.thumbFailed {
                    Rectangle().fill(Color.white.opacity(0.05)).overlay(
                        VStack(spacing: 4) {
                            Image(systemName: "photo").font(.system(size: 18))
                            Text(shot.name).font(.system(size: 11))
                        }.foregroundStyle(Color.fcMetadata))
                        .help("The camera didn't send a preview for this shot. Select it to try again.")
                } else {
                    Rectangle().fill(Color.white.opacity(0.05)).overlay(ProgressView().controlSize(.small))
                }
            }
            .frame(height: 110)
            .frame(maxWidth: .infinity)
            .opacity(shot.flag == .reject ? 0.35 : 1)
            badge.padding(5)
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 6).fill(focused ? Color.fcRing : Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(shot.flag == .keep ? Color.green : .clear, lineWidth: 2))
        .contentShape(Rectangle())
    }

    @ViewBuilder private var badge: some View {
        switch shot.flag {
        case .keep: Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, .green)
        case .reject: Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .red)
        case .none: EmptyView()
        }
    }
}

private struct ShotPreview: View {
    @ObservedObject var shot: CameraShot
    var retry: () -> Void = {}
    var body: some View {
        ZStack {
            if let img = shot.preview ?? shot.thumbnail {
                Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fit).padding(16)
            } else if shot.previewFailed {
                VStack(spacing: 10) {
                    Image(systemName: "photo").font(.system(size: 36, weight: .thin))
                    Text("The camera didn't send a preview of \(shot.name).").font(.system(size: 13))
                    Button("Try Again", action: retry)
                }
                .foregroundStyle(Color.fcMetadata)
            } else {
                ProgressView()
            }
            if shot.isVideo {
                Image(systemName: "video.fill").padding(8).background(.black.opacity(0.5), in: Circle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FlagButtons: View {
    @ObservedObject var shot: CameraShot
    let set: (CameraShot.Flag) -> Void
    var body: some View {
        HStack(spacing: 6) {
            Button { set(.keep) } label: { Label("Keep", systemImage: shot.flag == .keep ? "checkmark.circle.fill" : "checkmark.circle") }
                .tint(.green).help("Keep (P)")
            Button { set(.reject) } label: { Label("Reject", systemImage: shot.flag == .reject ? "xmark.circle.fill" : "xmark.circle") }
                .tint(.red).help("Reject (X)")
        }
        .buttonStyle(.bordered)
    }
}
