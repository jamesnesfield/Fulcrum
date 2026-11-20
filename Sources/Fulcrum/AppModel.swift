import AppKit
import FulcrumCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published var files: [URL] = []
    /// What the file list is showing from the library, or nil for photos opened by hand.
    @Published private(set) var scope: Library.Scope?
    @Published var selection: URL? { didSet { if selection != oldValue { load(selection) } } }
    let edit = EditState()
    let out = RenderState()
    /// The current edit (lives in `edit` so slider moves only refresh the inspector).
    var settings: EditSettings {
        get { edit.settings }
        set { edit.settings = newValue }
    }
    var preview: CGImage? { out.preview }
    var beforeImage: CGImage? { out.beforeImage }
    var analysis: AnalysisResult? { out.analysis }
    @Published private(set) var isRAW = false
    @Published private(set) var rawDefaultSharpening = 0.0
    @Published private(set) var rawDefaultNoiseReduction = 0.0
    @Published private(set) var editedFiles: Set<URL> = []
    @Published var showBefore = false { didSet { if showBefore { requestBefore() } } }
    /// Split view: before on the left of a draggable vertical divider, after on the right. Stays on across photos.
    @Published var showSplit = false { didSet { if showSplit { requestBefore() } } }
    @Published var overlayMaskID: UUID? { didSet { if overlayMaskID != oldValue { scheduleRender() } } }
    @Published var errorMessage: String?
    @Published var exportStatus: String?
    /// For photos opened from Apple Photos ("Edit With"): the edit last saved back, per file.
    @Published private(set) var savedToPhotos: [URL: EditSettings] = [:]
    @Published private(set) var isSavingToPhotos = false
    @Published var showExportSheet = false
    @Published var exportOptions = ExportOptions.saved { didSet { ExportOptions.saved = exportOptions } }
    @Published private(set) var copiedSettings: EditSettings?
    @Published var showRanges = false { didSet { if showRanges != oldValue { scheduleRender() } } }
    @Published private(set) var isAutoBalancing = false
    @Published private(set) var snapshots: [Snapshot] = []

    // Crop tool
    @Published private(set) var isCropping = false
    @Published var cropDraft = CropRect()
    @Published var cropAspectID = "free"
    @Published var cropPortrait = false

    // Zoom: full-resolution tile for the visible region
    struct DetailTile { let image: CGImage; let region: CGRect; let stamp: Int }
    private var previewStamp: Int { out.stamp }
    @Published private(set) var sourcePixelSize = CGSize(width: 1, height: 1)
    private var detailPending: (CGRect, CGSize)?
    private var detailBusy = false

    private var beforeCrop: CropRect?
    private var cameraInfo: [String: Any] = [:]
    private var keyMonitor: Any?
    /// The editor window, so single-key shortcuts don't fire while the import window (or another) is in front.
    weak var mainWindow: NSWindow?
    @Published var showUploadSheet = false

    let looks = LookStore()

    private var renderer: Renderer?
    private let renderQueue = DispatchQueue(label: "fulcrum.render", qos: .userInitiated)
    private let exportQueue = DispatchQueue(label: "fulcrum.export", qos: .utility)
    private var generation = 0
    private var loadingSettings = false

    private var undoStack: [EditSettings] = []
    private var redoStack: [EditSettings] = []
    private var lastEdit = Date.distantPast
    private var isUndoing = false

    private var lastChange = CFAbsoluteTime(0)
    private var needsFull = false
    let sink = DisplaySink()
    private lazy var loop = RenderLoop(queue: renderQueue, sink: sink) { [weak self] result in
        DispatchQueue.main.async { self?.received(result) }
    }

    init() {
        _ = ShotStore.shared   // moves the old JSON stores to sidecars once, before anything reads them
        Library.shared.refresh()
        PhotosSession.cleanUp()
        edit.onChange = { [weak self] old in self?.settingsChanged(from: old) }
        // Hold space for before/after (ignored while typing in a text field or cropping).
        // Single-key shortcuts (ignored while typing in a text field):
        //   hold Space = before/after · \ = toggle before · Y = split before/after · C = crop · . = favourite · V = B&W
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] e in
            guard let self, e.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                  self.mainWindow == nil || NSApp.keyWindow === self.mainWindow,
                  !(NSApp.keyWindow?.firstResponder is NSTextView), self.selection != nil else { return e }
            switch (e.keyCode, e.type) {
            case (49, _):   // space
                guard !self.isCropping else { return e }
                if e.type == .keyDown { if !e.isARepeat { self.showBefore = true } } else { self.showBefore = false }
                return nil
            case (42, .keyDown):   // backslash
                guard !self.isCropping, !e.isARepeat else { return e }
                self.showBefore.toggle()
                return nil
            case (16, .keyDown):   // Y — split before/after (as in Lightroom)
                guard !self.isCropping, !e.isARepeat else { return e }
                self.showSplit.toggle()
                return nil
            case (9, .keyDown):    // V — colour ↔ black and white (as in Lightroom)
                guard !self.isCropping, !e.isARepeat else { return e }
                self.settings.bw.enabled.toggle()
                return nil
            case (47, .keyDown):   // . — favourite (as in Apple Photos)
                guard !e.isARepeat, let url = self.selection else { return nil }
                TagStore.shared.update(url) { $0.favorite.toggle() }
                return nil
            case (8, .keyDown):    // C
                guard !e.isARepeat else { return nil }
                self.isCropping ? self.commitCrop() : self.beginCrop()
                return nil
            default:
                return e
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { EditLog.shared.flush() }
        }
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    // MARK: Opening

    func openPanel() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = true
        p.allowedContentTypes = [.image, .rawImage]
        p.message = "Choose photos or a folder of photos"
        if p.runModal() == .OK { open(p.urls) }
    }

    /// Replaces the file list with a shoot or smart collection from the library.
    func show(_ scope: Library.Scope) {
        Library.shared.files(scope) { [weak self] urls in
            guard let self else { return }
            // One folder listing per folder, rather than one per photo.
            for folder in Set(urls.map { $0.deletingLastPathComponent() }) {
                ShotStore.shared.prime((try? FileManager.default.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            }
            self.scope = scope
            self.files = urls
            self.editedFiles = Set(urls.filter(EditStore.shared.hasEdits))
            if self.selection.map({ !urls.contains($0) }) ?? true { self.selection = urls.first }
        }
    }

    func open(_ urls: [URL]) {
        scope = nil
        var found: [URL] = []
        for u in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
                let items = (try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: nil,
                                                                          options: [.skipsHiddenFiles])) ?? []
                let photos = items.filter(ImageSource.isSupported)
                ShotStore.shared.prime(photos)
                found += photos.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            } else if ImageSource.isSupported(u) {
                found.append(u)
            }
        }
        // One row per shot: a RAW+JPEG pair opens as its RAW, which its edit renders from.
        var seen = Set<URL>()
        found = found.map { ShotStore.shared.sourceURL(for: $0) }.filter { seen.insert($0).inserted }
        guard !found.isEmpty else {
            errorMessage = "No supported photos found."
            return
        }
        let new = found.filter { !files.contains($0) }
        files += new
        editedFiles = Set(files.filter(EditStore.shared.hasEdits))
        selection = found.first
    }

    private func load(_ url: URL?) {
        EditLog.shared.flush()
        isCropping = false
        out.detail = nil
        beforeCrop = nil
        generation += 1
        let gen = generation
        renderer = nil
        out.display = nil
        out.preview = nil
        out.beforeImage = nil
        out.analysis = nil
        showBefore = false
        overlayMaskID = nil
        undoStack.removeAll(); redoStack.removeAll()
        showRanges = false
        snapshots = url.map { SnapshotStore.shared.snapshots(for: $0) } ?? []
        guard let url else { return }
        out.isLoading = true
        loadingSettings = true
        settings = EditStore.shared.settings(for: url) ?? looks.defaultLook?.settings.withoutCrop ?? EditSettings()
        loadingSettings = false
        EditLog.shared.begin(url, settings: settings)
        renderQueue.async {
            do {
                let r = try Renderer(url: PhotosSession.renderURL(for: url))
                DispatchQueue.main.async {
                    guard gen == self.generation else { return }
                    self.renderer = r
                    self.isRAW = r.source.isRAW
                    self.rawDefaultSharpening = r.source.rawDefaultSharpening
                    self.rawDefaultNoiseReduction = r.source.rawDefaultNoiseReduction
                    self.sourcePixelSize = r.source.pixelSize
                    self.cameraInfo = EditLog.cameraSummary(r.source.metadata)
                    self.scheduleRender()
                    if self.showSplit { self.requestBefore() }
                    let warm = self.settings
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.3) { r.prewarmDraftDecode(warm) }
                    // Test hook: FULCRUM_DEBUG_ACTION=crop opens the crop tool after loading.
                    if ProcessInfo.processInfo.environment["FULCRUM_DEBUG_ACTION"] == "crop" { self.beginCrop() }
                    if ProcessInfo.processInfo.environment["FULCRUM_DEBUG_ACTION"] == "split" { self.showSplit = true }
                    if ProcessInfo.processInfo.environment["FULCRUM_DEBUG_ACTION"] == "bench" {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.runDragBenchmark() }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard gen == self.generation else { return }
                    self.out.isLoading = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: Editing

    private func settingsChanged(from old: EditSettings) {
        lastChange = CFAbsoluteTimeGetCurrent()
        if out.detail != nil { out.detail = nil }
        if old.crop != settings.crop { out.beforeImage = nil; if showBefore || showSplit { requestBefore() } }
        if !loadingSettings {
            if !isUndoing {
                // Group a continuous slider drag into one undo step.
                if Date().timeIntervalSince(lastEdit) > 0.7 { undoStack.append(old); redoStack.removeAll() }
                lastEdit = Date()
            }
            if let url = selection {
                EditStore.shared.set(settings.isDefault ? nil : settings, for: url)
                // Only publish when membership actually changes (this runs on every slider tick).
                if settings.isDefault { if editedFiles.contains(url) { editedFiles.remove(url) } }
                else if !editedFiles.contains(url) { editedFiles.insert(url) }
                EditLog.shared.noteChange(url, settings: settings, context: logContext())
            }
        }
        scheduleRender()
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        isUndoing = true; redoStack.append(settings); settings = prev; isUndoing = false
        lastEdit = .distantPast
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        isUndoing = true; undoStack.append(settings); settings = next; isUndoing = false
        lastEdit = .distantPast
    }

    func resetAll() { lastEdit = .distantPast; settings = EditSettings() }
    func copySettings() { copiedSettings = settings }
    /// Paste and looks keep this photo's own crop.
    func pasteSettings() { if let c = copiedSettings { lastEdit = .distantPast; settings = keepingCrop(c) } }

    func apply(_ look: Look) {
        lastEdit = .distantPast
        settings = keepingCrop(look.settings)
        if let url = selection { EditLog.shared.record("look", file: url, settings: settings, context: logContext(), extra: ["look": look.name]) }
    }

    private func keepingCrop(_ n: EditSettings) -> EditSettings {
        var x = n; x.crop = settings.crop; x.cropAspect = settings.cropAspect; return x
    }

    /// Dragging the vignette handle places the centre by hand (switching Subject mode to Manual).
    func moveVignette(to p: CGPoint) {
        var v = settings.vignette
        v.centre = .manual
        v.x = (Double(p.x) * 1000).rounded() / 1000
        v.y = (Double(p.y) * 1000).rounded() / 1000
        if v != settings.vignette { settings.vignette = v }
    }

    func logContext() -> EditLog.Context {
        EditLog.Context(camera: cameraInfo, isRAW: isRAW, median: analysis?.globalMedian, bwMedian: settings.bw.enabled ? analysis?.bwMedian : nil,
                        imageSize: sourcePixelSize)
    }

    // MARK: Crop

    func beginCrop() {
        guard selection != nil, !isCropping else { return }
        showBefore = false
        cropDraft = settings.crop
        let parts = CropAspect.parse(settings.cropAspect)
        cropAspectID = parts.id; cropPortrait = parts.portrait
        isCropping = true
        out.detail = nil
        scheduleRender()
    }

    func commitCrop() {
        guard isCropping else { return }
        isCropping = false
        lastEdit = .distantPast
        var s = settings
        s.crop = cropDraft
        s.cropAspect = CropAspect.encode(cropAspectID, portrait: cropPortrait)
        if s == settings { scheduleRender() } else { settings = s }
    }

    func cancelCrop() {
        guard isCropping else { return }
        isCropping = false
        scheduleRender()
    }

    /// Aspect of the image being cropped (pixel width / height).
    var imageAspect: Double { Double(sourcePixelSize.width / max(sourcePixelSize.height, 1)) }

    var outputPixelSize: CGSize { settings.crop.pixelRect(in: CGRect(origin: .zero, size: sourcePixelSize)).size }

    func addLocal(_ kind: MaskSpec.Kind) {
        lastEdit = .distantPast
        settings.localAdjustments.append(LocalAdjustment(kind: kind))
    }

    func removeLocal(_ id: UUID) {
        lastEdit = .distantPast
        if overlayMaskID == id { overlayMaskID = nil }
        settings.localAdjustments.removeAll { $0.id == id }
    }

    // MARK: Colour

    func autoWhiteBalance() {
        guard let r = renderer, !isAutoBalancing else { return }
        isAutoBalancing = true
        let s = settings, gen = generation
        renderQueue.async {
            let wb = r.autoWhiteBalance(s)
            DispatchQueue.main.async {
                self.isAutoBalancing = false
                guard gen == self.generation else { return }
                self.lastEdit = .distantPast
                self.settings.temperature = wb.temperature
                self.settings.tint = wb.tint
            }
        }
    }

    /// Sets one wheel, then lets the harmony rule move the others.
    func setWheel(_ id: WheelID, _ w: Wheel) {
        var g = settings.grade
        let hueMoved = g[id].hue != w.hue
        g[id] = w
        if hueMoved { g.applyHarmony(changed: id) }
        settings.grade = g
    }

    func applyGrade(_ g: ColorGrade) { lastEdit = .distantPast; settings.grade = g }

    func surprise(subtle: Bool) {
        lastEdit = .distantPast
        settings.grade = ColorGrade.surprise(harmony: settings.grade.harmony, subtle: subtle)
    }

    func saveSnapshot() {
        guard let url = selection else { return }
        let n = (snapshots.map(\.number).max() ?? 0) + 1
        snapshots.append(Snapshot(number: n, settings: settings))
        SnapshotStore.shared.set(snapshots, for: url)
    }

    func restore(_ snap: Snapshot) { lastEdit = .distantPast; settings = snap.settings }

    func deleteSnapshot(_ snap: Snapshot) {
        guard let url = selection else { return }
        snapshots.removeAll { $0.id == snap.id }
        SnapshotStore.shared.set(snapshots, for: url)
    }

    // MARK: Self-benchmark (FULCRUM_DEBUG_ACTION=bench): simulates a 60 Hz slider drag.
    private var benchChangeTimes: [Int: CFAbsoluteTime] = [:]
    private var benchLatencies: [Double] = []
    private var benchGaps: [Double] = []
    private var benchPublishes = 0
    private var benchRender: [Double] = []
    private var benchStages: [(Double, Double, Double)] = []
    var benchActive = false

    func runDragBenchmark() {
        let kinds: [(String, (inout EditSettings, Int) -> Void)] = [
            ("contrast", { s, i in s.contrast = Double(i % 80) }),
            ("exposure", { s, i in s.exposure = Double(i % 40) / 40 }),
            ("grade hue", { s, i in s.grade.shadows = Wheel(hue: Double(i * 3 % 360), sat: 30) }),
            ("grain", { s, i in s.grain.amount = Double(i % 60) }),
            ("temp", { s, i in s.temperature = Double(i % 80) - 40 }),
            ("tint", { s, i in s.tint = Double(i % 60) - 30 }),
            ("base curve", { s, i in s.rawBaseCurve = Double(i % 40) / 40 }),
            ("noise red.", { s, i in s.rawNoiseReduction = Double(i % 40) / 40 }),
        ]
        var report = ""
        func run(_ k: Int) {
            guard k < kinds.count else {
                try? report.write(to: AppPaths.support.appendingPathComponent("bench.txt"), atomically: true, encoding: .utf8)
                NSApp.terminate(nil); return
            }
            benchLatencies = []; benchGaps = []; benchPublishes = 0; benchRender = []; benchStages = []; benchActive = true
            var i = 0
            var last = CFAbsoluteTimeGetCurrent()
            let start = last
            Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { t in
                MainActor.assumeIsolated {
                    let now = CFAbsoluteTimeGetCurrent()
                    self.benchGaps.append((now - last) * 1000); last = now
                    i += 1
                    kinds[k].1(&self.settings, i)
                    self.benchChangeTimes[i] = now
                    self.benchTick = i
                    if now - start > 3 {
                        t.invalidate()
                        self.benchActive = false
                        let lat = self.benchLatencies.sorted(), gaps = self.benchGaps.sorted(), rt = self.benchRender.sorted()
                        func p(_ a: [Double], _ q: Double) -> Double { a.isEmpty ? 0 : a[min(a.count - 1, Int(Double(a.count) * q))] }
                        report += String(format: "%-10@ frames shown %3d/%3d (%.0f fps) · latency p50 %5.1f p90 %5.1f ms · main-thread tick gap p50 %4.1f p90 %5.1f max %5.1f ms\n",
                                         kinds[k].0 as NSString, self.benchPublishes, i, Double(self.benchPublishes) / 3,
                                         p(lat, 0.5), p(lat, 0.9), p(gaps, 0.5), p(gaps, 0.9), gaps.last ?? 0)
                        _ = rt
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { run(k + 1) }
                    }
                }
            }
        }
        run(0)
    }
    private var benchTick = 0

    // MARK: Rendering

    func scheduleRender() {
        guard let r = renderer else { return }
        let cropping = isCropping
        // While a slider is moving: fast half-size draft re-using the last measurements.
        let dragging = !cropping && out.display != nil && CFAbsoluteTimeGetCurrent() - lastChange < 0.25
        loop.submit(RenderLoop.Job(renderer: r, generation: generation,
                                   settings: cropping ? settings.withoutCrop : settings,
                                   overlay: overlayMaskID, ranges: showRanges, cropping: cropping,
                                   draft: dragging, tick: benchTick))
        if dragging { needsFull = true; scheduleSettle() }
    }

    /// Main-thread bookkeeping for a frame that's already on screen (histogram, read-outs, crop tool image).
    private func received(_ r: RenderLoop.Result) {
        guard r.job.generation == generation else { return }
        if let e = r.error { errorMessage = e.localizedDescription }
        if let cg = r.preview { out.preview = cg }
        if let d = r.display { out.display = d }
        if let a = r.analysis { out.setAnalysis(a) }
        if !r.job.draft { out.stamp += 1 }
        if out.isLoading { out.isLoading = false }
        if benchActive, let t0 = benchChangeTimes[r.job.tick] {
            benchPublishes += 1
            benchLatencies.append((r.shownAt - t0) * 1000)
        }
    }

    /// After the last slider move, replace the draft with a full-quality frame.
    private func scheduleSettle() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
            guard self.needsFull, CFAbsoluteTimeGetCurrent() - self.lastChange >= 0.25 else { return }
            self.needsFull = false
            self.scheduleRender()
        }
    }

    private func requestBefore() {
        let crop = settings.crop
        guard beforeImage == nil || beforeCrop != crop, let r = renderer else { return }
        let gen = generation
        renderQueue.async {
            let img = r.renderBefore(crop: crop)
            DispatchQueue.main.async {
                if gen == self.generation, crop == self.settings.crop { self.out.beforeImage = img; self.beforeCrop = crop }
            }
        }
    }

    /// Canvas asks for full-resolution pixels for the visible region (normalised, top-left origin).
    func requestDetail(region: CGRect, maxPixels: CGSize) {
        guard renderer != nil, !isCropping, out.display?.isDraft == false else { return }
        detailPending = (region, maxPixels)
        if !detailBusy { pumpDetail() }
    }

    func clearDetail() { detailPending = nil; out.detail = nil }

    private func pumpDetail() {
        guard let (region, px) = detailPending, let r = renderer, let a = analysis else { detailBusy = false; return }
        detailPending = nil
        detailBusy = true
        let s = settings, gen = generation, stamp = previewStamp
        renderQueue.async {
            let img = try? r.renderDetail(s, analysis: a, region: region, maxPixels: px)
            DispatchQueue.main.async {
                if gen == self.generation, s == self.settings, stamp == self.previewStamp, let img {
                    self.out.detail = DetailTile(image: img, region: region, stamp: stamp)
                }
                self.pumpDetail()
            }
        }
    }

    // MARK: Export

    func exportCurrent() {
        guard let url = selection else { return }
        let p = NSSavePanel()
        p.allowedContentTypes = [UTType(filenameExtension: exportOptions.format.ext) ?? .jpeg]
        p.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + exportOptions.suffix + "." + exportOptions.format.ext
        guard p.runModal() == .OK, let dest = p.url else { return }
        EditLog.shared.record("export", file: url, settings: settings, context: logContext(),
                              extra: ["format": exportOptions.format.rawValue])
        runExport([(url, settings)], to: { _ in dest })
    }

    func exportAll() {
        guard !files.isEmpty else { return }
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = "Export Here"
        p.message = "Export \(files.count) photo(s) with their edits"
        guard p.runModal() == .OK, let dir = p.url else { return }
        let fallback = looks.defaultLook?.settings ?? EditSettings()
        let jobs = files.map { f in (f, f == selection ? settings : (EditStore.shared.settings(for: f) ?? fallback)) }
        for (f, js) in jobs {
            EditLog.shared.record("export", file: f, settings: js, context: f == selection ? logContext() : EditLog.Context(),
                                  extra: ["format": exportOptions.format.rawValue, "batch": true])
        }
        let o = exportOptions
        runExport(jobs, to: { src in
            dir.appendingPathComponent(src.deletingPathExtension().lastPathComponent + o.suffix + "." + o.format.ext)
        })
    }

    private func runExport(_ jobs: [(URL, EditSettings)], to destination: @escaping (URL) -> URL) {
        let o = exportOptions
        exportStatus = "Exporting…"
        exportQueue.async {
            var errors: [String] = []
            for (i, job) in jobs.enumerated() {
                DispatchQueue.main.async { self.exportStatus = "Exporting \(i + 1) of \(jobs.count)…" }
                do {
                    let r = try Renderer(url: PhotosSession.renderURL(for: job.0))
                    try r.export(job.1, to: destination(job.0), options: o)
                } catch {
                    errors.append("\(job.0.lastPathComponent): \(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async {
                self.exportStatus = errors.isEmpty ? "Exported \(jobs.count) photo(s)." : nil
                if !errors.isEmpty { self.errorMessage = errors.joined(separator: "\n") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if self.exportStatus?.hasPrefix("Exported") == true { self.exportStatus = nil }
                }
            }
        }
    }
}

// MARK: Apple Photos "Edit With"

extension AppModel {
    var isPhotosSession: Bool { selection.map(PhotosSession.isSession) ?? false }

    /// The edit as it stands for a file: the live one for the open photo, else its saved one.
    private func currentEdit(_ f: URL) -> EditSettings {
        f == selection ? settings : (EditStore.shared.settings(for: f) ?? EditSettings())
    }

    /// Photos-session files whose edit differs from what was last saved back to Photos.
    var unsavedPhotosFiles: [URL] {
        files.filter { f in
            guard PhotosSession.isSession(f) else { return false }
            let now = currentEdit(f)
            return now != (savedToPhotos[f] ?? EditSettings())
        }
    }

    /// Subtitle for a photo opened from Photos, so it's clear where ⌘S sends it.
    var photosStatus: String? {
        guard let url = selection, PhotosSession.isSession(url) else { return nil }
        if isSavingToPhotos { return "Saving to Photos…" }
        return unsavedPhotosFiles.contains(url) ? "From Photos · not saved (⌘S)" : "From Photos · saved"
    }

    /// Renders the edit from the original and writes it over the copy Photos is waiting on.
    func saveToPhotos(_ urls: [URL]? = nil, completion: ((Bool) -> Void)? = nil) {
        let targets = (urls ?? selection.map { [$0] } ?? []).filter(PhotosSession.isSession)
        guard !targets.isEmpty, !isSavingToPhotos else { completion?(targets.isEmpty); return }
        EditLog.shared.flush()
        let jobs = targets.map { ($0, currentEdit($0)) }
        isSavingToPhotos = true
        exportQueue.async {
            var errors: [String] = []
            var saved: [(URL, EditSettings)] = []
            for (url, s) in jobs {
                do { try PhotosSession.save(s, to: url); saved.append((url, s)) }
                catch { errors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            DispatchQueue.main.async {
                self.isSavingToPhotos = false
                for (url, s) in saved {
                    self.savedToPhotos[url] = s
                    EditLog.shared.record("photos", file: url, settings: s,
                                          context: url == self.selection ? self.logContext() : EditLog.Context())
                }
                if !errors.isEmpty { self.errorMessage = "Couldn't save to Photos.\n" + errors.joined(separator: "\n") }
                completion?(errors.isEmpty)
            }
        }
    }
}

