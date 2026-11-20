import FulcrumCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var looks: LookStore
    @State private var showInspector = true
    @State private var showSaveLook = false
    @State private var showLabels = false
    @ObservedObject private var tags = TagStore.shared
    @ObservedObject private var uploader = Uploader.shared
    @State private var lookName = ""

    var body: some View {
        NavigationSplitView {
            FileList()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            PhotoCanvas()
        }
        .inspector(isPresented: $showInspector) {
            InspectorView()
                .inspectorColumnWidth(min: 300, ideal: 330, max: 440)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.openPanel() } label: { Label("Open", systemImage: "folder") }
                    .help("Open photos or a folder (⌘O)")
                Button { model.isCropping ? model.commitCrop() : model.beginCrop() } label: {
                    Label("Crop", systemImage: "crop")
                }
                .help("Crop (C)")
                .disabled(model.selection == nil)
                Toggle(isOn: $model.showBefore) { Label("Before", systemImage: "rectangle.on.rectangle") }
                    .help("Before / after — hold Space, or press \\ to toggle")
                    .disabled(model.selection == nil || model.isCropping)
                Toggle(isOn: $model.showSplit) { Label("Split", systemImage: "square.split.2x1") }
                    .help("Split before / after — drag the divider (Y)")
                    .disabled(model.selection == nil || model.isCropping)
                looksMenu
                variationsMenu
                favouriteButton
                Button { showLabels.toggle() } label: { Label("Labels", systemImage: "tag") }
                    .help("Labels (⌘K)")
                    .disabled(model.selection == nil)
                    .popover(isPresented: $showLabels, arrowEdge: .bottom) {
                        if let url = model.selection { LabelsPopover(file: url) }
                    }
                Button { model.showExportSheet = true } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .help("Export (⌘E)")
                    .disabled(model.files.isEmpty)
                uploadMenu
                Button { showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
            }
        }
        .tint(Color.fcOnFill)   // one graphite on-colour instead of the system accent (DESIGN.md)
        .toolbarBackground(Color.fcBarrel, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .navigationTitle(model.selection?.lastPathComponent ?? "Fulcrum")
        .navigationSubtitle(model.exportStatus ?? model.photosStatus ?? (model.isRAW ? "RAW" : ""))
        .sheet(isPresented: $model.showExportSheet) { ExportSheet() }
        .sheet(isPresented: $model.showUploadSheet) { UploadSheet() }
        .background(WindowReader { model.mainWindow = $0 })
        .onReceive(NotificationCenter.default.publisher(for: .editLabels)) { _ in
            if model.selection != nil { showLabels = true }
        }
        .alert("Save Look", isPresented: $showSaveLook) {
            TextField("Name", text: $lookName)
            Button("Save") { if !lookName.isEmpty { looks.add(name: lookName, settings: model.settings.withoutCrop) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves every setting except the crop, including local masks. Masks like Sky re-measure their median on each photo.")
        }
        .alert("Fulcrum", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveLook)) { _ in
            lookName = ""; showSaveLook = true
        }
    }

    /// Variations: save the current edit, try something else, then click between them to compare.
    private var variationsMenu: some View {
        Menu {
            Button("Save Current as Variation") { model.saveSnapshot() }
            if !model.snapshots.isEmpty {
                Divider()
                ForEach(model.snapshots) { snap in
                    Button { model.restore(snap) } label: {
                        if snap.settings == model.settings { Label(snap.name, systemImage: "checkmark") } else { Text(snap.name) }
                    }
                }
                Divider()
                Menu("Delete Variation") {
                    ForEach(model.snapshots) { snap in Button(snap.name) { model.deleteSnapshot(snap) } }
                }
            }
        } label: {
            Label("Variations", systemImage: "square.on.square")
        }
        .help("Save this edit as a variation, try something different, then switch between them to compare")
        .disabled(model.selection == nil)
    }

    private var favouriteButton: some View {
        let fav = model.selection.map { tags.tags($0).favorite } ?? false
        return Button {
            if let url = model.selection { tags.update(url) { $0.favorite.toggle() } }
        } label: {
            Label("Favourite", systemImage: fav ? "heart.fill" : "heart")
        }
        .help("Favourite (.)")
        .disabled(model.selection == nil)
    }

    /// Click uploads with your saved choices; the arrow opens the options.
    private var uploadMenu: some View {
        Menu {
            Button("Upload Options…") { model.showUploadSheet = true }
        } label: {
            Label(uploader.isRunning ? "Uploading…" : "Upload", systemImage: "icloud.and.arrow.up")
        } primaryAction: {
            if uploader.canRunDirectly { uploader.run(model: model) } else { model.showUploadSheet = true }
        }
        .help("Upload to Apple Photos / Google Photos (⌘U)")
        .disabled(model.files.isEmpty || uploader.isRunning)
    }

    private var looksMenu: some View {
        Menu {
            if looks.looks.isEmpty { Text("No saved looks yet") }
            ForEach(looks.looks) { look in
                Button(look.name + (look.id == looks.defaultLookID ? "  ★" : "")) { model.apply(look) }
            }
            Divider()
            Button("Save Current as Look…") { lookName = ""; showSaveLook = true }
                .disabled(model.selection == nil)
            if !looks.looks.isEmpty {
                Menu("Default for New Photos") {
                    Button("None") { looks.defaultLookID = nil }
                    ForEach(looks.looks) { look in
                        Button(look.name) { looks.defaultLookID = look.id }
                    }
                }
                Menu("Delete Look") {
                    ForEach(looks.looks) { look in Button(look.name) { looks.delete(look) } }
                }
            }
        } label: {
            Label("Looks", systemImage: "wand.and.stars")
        }
        .help("Your saved looks")
    }
}

extension Notification.Name {
    static let saveLook = Notification.Name("fulcrum.saveLook")
    static let editLabels = Notification.Name("fulcrum.editLabels")
}

struct FileList: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var library = Library.shared
    @AppStorage("libraryExpanded") private var libraryExpanded = true

    var body: some View {
        List(selection: $model.selection) {
            Section(isExpanded: $libraryExpanded) {
                libraryRows
            } header: {
                Text("Library")
                    .help("Shoots in \(library.root.path). Each shot's edits are saved beside its photos.")
            }
            Section {
                ForEach(model.files, id: \.self) { url in fileRow(url) }
            } header: {
                Text(model.scope.map(library.title) ?? (model.files.isEmpty ? "Photos" : "Opened"))
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color.fcBarrel)
    }

    @ViewBuilder private var libraryRows: some View {
        if library.favourites > 0 {
            scopeRow(.favourites, "Favourites", systemImage: "heart", count: library.favourites,
                     help: "Every favourite in the library")
        }
        if library.readyToUpload > 0 {
            scopeRow(.readyToUpload, "To Upload", systemImage: "icloud.and.arrow.up", count: library.readyToUpload,
                     help: "Edited photos that haven't been uploaded anywhere yet")
        }
        ForEach(library.shoots) { shoot in
            scopeRow(.shoot(shoot.folder), shoot.name, systemImage: "folder", count: shoot.shots,
                     help: "\(shoot.shots) shot(s), \(shoot.edited) edited, \(shoot.favourites) favourite(s)")
                .contextMenu {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([shoot.url]) }
                }
        }
        if library.hasLoaded, library.shoots.isEmpty {
            Text("No shoots yet. Imports go to \(library.root.lastPathComponent).")
                .font(.system(size: 11)).foregroundStyle(Color.fcMetadata)
                .selectionDisabled()
                .help(library.root.path)
        }
    }

    private func scopeRow(_ scope: Library.Scope, _ title: String, systemImage: String, count: Int, help: String) -> some View {
        let current = model.scope == scope
        return Button { model.show(scope) } label: {
            HStack(spacing: 8) {
                Image(systemName: systemImage).font(.system(size: 12)).frame(width: 16)
                    .foregroundStyle(current ? Color.fcEngraving : Color.fcMetadata)
                Text(title).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(current ? Color.fcEngraving : Color.fcLabel)
                Spacer(minLength: 4)
                Text("\(count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(Color.fcMetadata)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(current ? RoundedRectangle(cornerRadius: 5).fill(Color.fcRing).padding(.horizontal, 10) : nil)
        .selectionDisabled()
        .help(help)
    }

    private func fileRow(_ url: URL) -> some View {
        HStack(spacing: 10) {
            ThumbnailView(url: url)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.deletingPathExtension().lastPathComponent).font(.system(size: 13))
                    .lineLimit(1).truncationMode(.middle)
                Text(ShotStore.shared.kinds(for: url)).font(.system(size: 11)).foregroundStyle(Color.fcMetadata)
            }
            Spacer(minLength: 0)
            if TagStore.shared.tags(url).favorite {
                Image(systemName: "heart.fill").font(.system(size: 11)).foregroundStyle(Color.fcEngraving)
                    .help("Favourite")
            }
            if model.editedFiles.contains(url) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 11)).foregroundStyle(Color.fcMetadata)
                    .help("Edited")
            }
        }
        .padding(.vertical, 2)
        .tag(url)
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("Remove from List") {
                if model.selection == url { model.selection = nil }
                model.files.removeAll { $0 == url }
            }
        }
    }
}

struct PhotoCanvas: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var render: RenderState
    @State private var dropTargeted = false
    @State private var zoom: (value: Double, fit: Bool) = (0, true)

    var body: some View {
        VStack(spacing: 0) {
            canvas
            if render.display != nil, !model.isCropping {
                StatusBar(zoom: zoom.value, fit: zoom.fit, pixels: model.outputPixelSize, split: model.showSplit)
            }
        }
        .background(Color.fcAnodised.ignoresSafeArea())
    }

    private var canvas: some View {
        ZStack {
            Color.fcAnodised.ignoresSafeArea()
            if model.isCropping, let img = render.preview {
                CropEditor(image: img)
            } else if let d = render.display {
                let before = model.showBefore ? render.beforeImage : nil
                let split = model.showSplit && !model.showBefore ? render.beforeImage : nil
                ZoomCanvas(content: before ?? d.surface,
                           showingBefore: before != nil,
                           splitBefore: split,
                           sink: model.sink,
                           logicalSize: d.logicalSize,
                           detail: model.showBefore ? nil : render.detail,
                           fullPixelSize: model.outputPixelSize,
                           resetToken: AnyHashable("\(model.selection?.path ?? "")|\(d.logicalSize)"),
                           onNeedDetail: { model.requestDetail(region: $0, maxPixels: $1) },
                           onZoom: { zoom = ($0, $1) },
                           vignetteCentre: before == nil && render.analysis?.vignetteHandle == true
                               ? render.analysis?.vignetteCentre : nil,
                           vignetteShape: render.analysis?.vignette,
                           onVignetteMove: { model.moveVignette(to: $0) },
                           onVignetteReset: { model.moveVignette(to: CGPoint(x: 0.5, y: 0.5)) })
                    .overlay(alignment: .topLeading) {
                        if model.showBefore || split != nil { CanvasBadge(text: "Before") }
                    }
                    .overlay(alignment: .topTrailing) {
                        if split != nil { CanvasBadge(text: "After") }
                    }
            } else if render.isLoading {
                ProgressView().controlSize(.large)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "camera.aperture").font(.system(size: 48, weight: .thin))
                    Text("Drop RAW or JPEG/HEIC photos here").font(.title3)
                    Button("Open Photos…") { model.openPanel() }
                        .controlSize(.large)
                }
                .foregroundStyle(.secondary)
            }
            if render.isLoading, render.display != nil {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding().allowsHitTesting(false)
            }
        }
        .overlay {
            if dropTargeted { RoundedRectangle(cornerRadius: 10).stroke(Color.fcEngraving, lineWidth: 2).padding(6) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.open(urls); return true
        } isTargeted: { dropTargeted = $0 }
    }
}

/// The strip under the photo: zoom, output size, and the shortcuts that work here.
private struct StatusBar: View {
    let zoom: Double
    let fit: Bool
    let pixels: CGSize
    let split: Bool

    var body: some View {
        HStack(spacing: 18) {
            Text(verbatim: zoom > 0 ? (fit ? "Fit " : "") + "\(Int((zoom * 100).rounded()))%" : "–")
                .help("Screen pixels per photo pixel. Double-click the photo to switch between fit and 100%.")
            Text(verbatim: "\(Int(pixels.width)) × \(Int(pixels.height))")
                .help("Size of the exported photo, after the crop")
            Spacer(minLength: 12)
            Text(split ? "Drag the divider · Y split · \\ before · hold Space"
                       : "Y split · \\ before · hold Space · C crop")
                .font(.system(size: 12))
                .lineLimit(1)
        }
        .font(FulcrumFont.figures(12))
        .foregroundStyle(Color.fcMetadata)
        .padding(.horizontal, 16)
        .frame(height: 30)
        .background(Color.fcAnodised)
        .overlay(alignment: .top) { Rectangle().fill(Color(hex: 0x1C1C1E)).frame(height: 1) }
    }
}

private struct CanvasBadge: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.fcEngraving)
            .padding(.vertical, 3).padding(.horizontal, 8)
            .background(Color.fcAnodised.opacity(0.72), in: RoundedRectangle(cornerRadius: 4))
            .padding(12)
            .allowsHitTesting(false)
    }
}

struct ExportSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export").font(.title2.weight(.semibold))
            Form {
                Picker("Format", selection: $model.exportOptions.format) {
                    ForEach(ExportOptions.Format.allCases) { Text($0.label).tag($0) }
                }
                if model.exportOptions.format == .jpeg || model.exportOptions.format == .heic {
                    LabeledContent("Quality") {
                        HStack {
                            Slider(value: $model.exportOptions.quality, in: 0.5...1)
                            Text("\(Int(model.exportOptions.quality * 100))").monospacedDigit().frame(width: 30)
                        }
                    }
                }
                Picker("Size", selection: $model.exportOptions.maxLongEdge) {
                    Text("Full resolution").tag(0)
                    Text("6000 px long edge").tag(6000)
                    Text("4096 px long edge").tag(4096)
                    Text("2048 px long edge").tag(2048)
                    Text("1080 px long edge").tag(1080)
                }
                Picker("Color space", selection: $model.exportOptions.colorSpace) {
                    ForEach(ExportOptions.Space.allCases) { Text($0.label).tag($0) }
                }
                TextField("File name suffix", text: $model.exportOptions.suffix, prompt: Text("e.g. -edit"))
            }
            .formStyle(.grouped)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Export All (\(model.files.count))…") { dismiss(); DispatchQueue.main.async { model.exportAll() } }
                    .disabled(model.files.isEmpty)
                Button("Export This Photo…") { dismiss(); DispatchQueue.main.async { model.exportCurrent() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.selection == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
