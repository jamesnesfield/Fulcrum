import AppKit
import CryptoKit
import FulcrumCore
import Photos
import SwiftUI

/// Adds photos to the Apple Photos library. PhotoKit (add-only access) creates the asset and sets the favourite;
/// keywords have no PhotoKit API, so they're set by scripting Photos (asks once for Automation permission).
enum ApplePhotos {
    enum APError: LocalizedError {
        case denied, script(String)
        var errorDescription: String? {
            switch self {
            case .denied: "Fulcrum isn't allowed to add to Photos. Turn it on in System Settings → Privacy & Security → Photos."
            case let .script(s): "Couldn't set keywords in Photos: \(s)"
            }
        }
    }

    static func authorize() async throws {
        let s = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard s == .authorized || s == .limited else { throw APError.denied }
    }

    private final class Box: @unchecked Sendable { var id: String? }

    static func add(_ file: URL, favorite: Bool, keywords: [String]) async throws {
        let box = Box()
        var favouriteSet = favorite
        do {
            try await create(file, favorite: favorite, box: box)
        } catch where favorite {
            // Some systems refuse favourites with add-only access; add plainly and favourite via scripting.
            try await create(file, favorite: false, box: box)
            favouriteSet = false
        }
        let needsScript = !keywords.isEmpty || (favorite && !favouriteSet)
        guard needsScript, let id = box.id else { return }
        try await script(id: id, favorite: favorite && !favouriteSet, keywords: keywords)
    }

    private static func create(_ file: URL, favorite: Bool, box: Box) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let r = PHAssetCreationRequest.forAsset()
            let o = PHAssetResourceCreationOptions()
            o.originalFilename = file.lastPathComponent
            r.addResource(with: .photo, fileURL: file, options: o)
            if favorite { r.isFavorite = true }
            box.id = r.placeholderForCreatedAsset?.localIdentifier
        }
    }

    private static let source = """
    on run argv
        set theID to item 1 of argv
        set fav to item 2 of argv
        set kws to {}
        if (count of argv) > 2 then set kws to items 3 thru -1 of argv
        tell application "Photos"
            set m to media item id theID
            if fav is "1" then set favorite of m to true
            if (count of kws) > 0 then set keywords of m to kws
        end tell
    end run
    """

    /// Photos can take a moment to see a newly added asset, so retry briefly.
    private static func script(id: String, favorite: Bool, keywords: [String]) async throws {
        var lastError = ""
        for attempt in 0..<6 {
            if attempt > 0 { try await Task.sleep(nanoseconds: 1_000_000_000) }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", source, id, favorite ? "1" : "0"] + keywords
            let err = Pipe()
            p.standardError = err
            p.standardOutput = Pipe()
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus == 0 { return }
            lastError = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "osascript failed"
            if lastError.contains("-1743") || lastError.contains("Not authorized") {
                throw APError.script("Fulcrum isn't allowed to control Photos. Turn it on in System Settings → Privacy & Security → Automation.")
            }
        }
        throw APError.script(lastError)
    }
}

/// One-click upload of edited photos to Apple Photos and/or Google Photos.
@MainActor
final class Uploader: ObservableObject {
    static let shared = Uploader()

    enum Scope: String, CaseIterable, Identifiable {
        case current, favourites, all
        var id: String { rawValue }
    }

    @Published var scope: Scope { didSet { UserDefaults.standard.set(scope.rawValue, forKey: "uploadScope") } }
    @Published var toApple: Bool { didSet { UserDefaults.standard.set(toApple, forKey: "uploadApple") } }
    @Published var toGoogle: Bool { didSet { UserDefaults.standard.set(toGoogle, forKey: "uploadGoogle") } }
    /// What gets uploaded: a JPEG rendered with your edits, or the untouched original (the RAW, for RAW files).
    enum Format: String, CaseIterable, Identifiable {
        case editedJPEG, original
        var id: String { rawValue }
        var label: String { self == .editedJPEG ? "Edited JPEG" : "Original file (RAW)" }
    }
    @Published var format: Format { didSet { UserDefaults.standard.set(format.rawValue, forKey: "uploadFormat") } }
    @Published var skipUploaded: Bool { didSet { UserDefaults.standard.set(skipUploaded, forKey: "uploadSkip") } }
    @Published var isConfigured: Bool { didSet { UserDefaults.standard.set(isConfigured, forKey: "uploadConfigured") } }
    @Published private(set) var isRunning = false
    @Published var googleConnected = GooglePhotos.shared.isConnected
    @Published var googleBusy = false
    @Published var googleError: String?

    private init() {
        let d = UserDefaults.standard
        scope = Scope(rawValue: d.string(forKey: "uploadScope") ?? "") ?? .all
        toApple = d.object(forKey: "uploadApple") as? Bool ?? true
        toGoogle = d.object(forKey: "uploadGoogle") as? Bool ?? false
        skipUploaded = d.object(forKey: "uploadSkip") as? Bool ?? true
        format = Format(rawValue: d.string(forKey: "uploadFormat") ?? "") ?? .editedJPEG
        isConfigured = d.bool(forKey: "uploadConfigured")
    }

    /// Whether the toolbar button can upload straight away, or needs the options sheet first.
    var canRunDirectly: Bool { isConfigured && (toApple || toGoogle) && (!toGoogle || googleConnected) }

    func files(for scope: Scope, model: AppModel) -> [URL] {
        switch scope {
        case .current: model.selection.map { [$0] } ?? []
        case .favourites: model.files.filter { TagStore.shared.tags($0).favorite }
        case .all: model.files
        }
    }

    func connectGoogle() {
        googleBusy = true; googleError = nil
        Task {
            do { try await GooglePhotos.shared.connect() } catch GooglePhotos.GPError.cancelled {
                googleError = nil
            } catch { googleError = error.localizedDescription }
            googleBusy = false
            googleConnected = GooglePhotos.shared.isConnected
        }
    }

    func cancelGoogleSignIn() {
        GooglePhotos.shared.cancelSignIn()   // connect() then throws .cancelled, which clears googleBusy
    }

    func disconnectGoogle() {
        GooglePhotos.shared.disconnect()
        googleConnected = false
    }

    func run(model: AppModel) {
        guard !isRunning else { return }
        let tags = TagStore.shared
        let wantApple = toApple, wantGoogle = toGoogle && googleConnected, skip = skipUploaded, format = format
        struct Job { let file: URL; let settings: EditSettings; let tags: PhotoTags; let apple: Bool; let google: Bool; let version: String }
        let jobs: [Job] = files(for: scope, model: model).compactMap { f in
            let t = tags.tags(f)
            let s = model.exportSettings(for: f)
            let v = Self.version(s, format)
            // Skip only if this exact edit, in this format, is already there.
            let a = wantApple && !(skip && t.uploadedApple != nil && t.uploadedAppleVersion == v)
            let g = wantGoogle && !(skip && t.uploadedGoogle != nil && t.uploadedGoogleVersion == v)
            guard a || g else { return nil }
            return Job(file: f, settings: s, tags: t, apple: a, google: g, version: v)
        }
        guard !jobs.isEmpty else {
            model.exportStatus = "Nothing new to upload."
            clearStatusSoon(model)
            return
        }
        isRunning = true
        var options = ExportOptions()
        options.format = .jpeg; options.quality = 0.92; options.colorSpace = .sRGB
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("Fulcrum-upload-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        Task {
            var errors: [String] = []
            var appleOK = 0, googleOK = 0
            if jobs.contains(where: \.apple) {
                do { try await ApplePhotos.authorize() } catch { errors.append(error.localizedDescription) }
            }
            let appleAllowed = errors.isEmpty
            for (i, job) in jobs.enumerated() {
                model.exportStatus = "Uploading \(i + 1) of \(jobs.count)…"
                // The original is uploaded in place — never rendered, and never deleted afterwards.
                let out = format == .original ? job.file
                    : tmp.appendingPathComponent(job.file.deletingPathExtension().lastPathComponent + ".jpg")
                if format == .editedJPEG {
                    do {
                        try await Self.render(job.file, settings: job.settings, to: out, options: options)
                    } catch {
                        errors.append("\(job.file.lastPathComponent): \(error.localizedDescription)")
                        continue
                    }
                }
                if job.apple && appleAllowed {
                    do {
                        try await ApplePhotos.add(out, favorite: job.tags.favorite, keywords: job.tags.labels)
                        tags.update(job.file) { $0.uploadedApple = Date(); $0.uploadedAppleVersion = job.version }
                        appleOK += 1
                    } catch {
                        errors.append("Apple Photos — \(job.file.lastPathComponent): \(error.localizedDescription)")
                    }
                }
                if job.google {
                    do {
                        let albums = job.tags.labels + (job.tags.favorite ? ["Favourites"] : [])
                        try await GooglePhotos.shared.upload(out, albums: albums)
                        tags.update(job.file) { $0.uploadedGoogle = Date(); $0.uploadedGoogleVersion = job.version }
                        googleOK += 1
                    } catch {
                        errors.append("Google Photos — \(job.file.lastPathComponent): \(error.localizedDescription)")
                        if case GooglePhotos.GPError.notConnected = error { googleConnected = false }
                    }
                }
                if out != job.file { try? FileManager.default.removeItem(at: out) }
            }
            try? FileManager.default.removeItem(at: tmp)
            isRunning = false
            var parts: [String] = []
            if wantApple { parts.append("\(appleOK) to Apple Photos") }
            if wantGoogle { parts.append("\(googleOK) to Google Photos") }
            model.exportStatus = "Uploaded " + parts.joined(separator: ", ") + "."
            if !errors.isEmpty { model.errorMessage = Array(Set(errors)).sorted().prefix(8).joined(separator: "\n") }
            clearStatusSoon(model)
        }
    }

    /// Identifies what an upload contains: the original file, or a JPEG of one particular edit.
    static func version(_ s: EditSettings, _ format: Format) -> String {
        guard format == .editedJPEG else { return "original" }
        let enc = JSONEncoder(); enc.outputFormatting = .sortedKeys
        let data = (try? enc.encode(s)) ?? Data()
        return "jpeg:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func clearStatusSoon(_ model: AppModel) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if model.exportStatus?.hasPrefix("Uploaded") == true || model.exportStatus == "Nothing new to upload." { model.exportStatus = nil }
        }
    }

    private static let renderQueue = DispatchQueue(label: "fulcrum.upload", qos: .utility)

    private static func render(_ file: URL, settings: EditSettings, to out: URL, options: ExportOptions) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            renderQueue.async {
                do { try Renderer(url: PhotosSession.renderURL(for: file)).export(settings, to: out, options: options); c.resume() } catch { c.resume(throwing: error) }
            }
        }
    }
}

extension AppModel {
    /// The edit to export for a file: the live edit for the open photo, else its saved edit, else the default look.
    func exportSettings(for f: URL) -> EditSettings {
        if f == selection { return settings }
        return EditStore.shared.settings(for: f) ?? looks.defaultLook?.settings ?? EditSettings()
    }
}

// MARK: - Sheet

struct UploadSheet: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var up = Uploader.shared
    @Environment(\.dismiss) private var dismiss
    @State private var clientID = GooglePhotos.shared.clientID
    @State private var clientSecret = GooglePhotos.shared.clientSecret
    @State private var showHelp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Upload").font(.title2.weight(.semibold))
            Form {
                Picker("Photos", selection: $up.scope) {
                    Text("This photo").tag(Uploader.Scope.current)
                    Text("Favourites (\(up.files(for: .favourites, model: model).count))").tag(Uploader.Scope.favourites)
                    Text("All in the list (\(model.files.count))").tag(Uploader.Scope.all)
                }
                Toggle("Apple Photos", isOn: $up.toApple)
                Toggle("Google Photos", isOn: $up.toGoogle)
                Picker("Upload as", selection: $up.format) {
                    ForEach(Uploader.Format.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Skip photos already uploaded there, unless edited since", isOn: $up.skipUploaded)
                Text((up.format == .editedJPEG
                      ? "Full-resolution JPEG with your edits."
                      : "The untouched original — your edits aren't included. RAW files use more Google storage.")
                     + " Apple Photos gets favourites and labels as keywords; Google Photos puts each label, and Favourites, in an album of that name.")
                    .font(.caption).foregroundStyle(.secondary)

                Section("Google Photos") {
                    if up.googleConnected {
                        LabeledContent("Account") {
                            HStack { Text("Connected").foregroundStyle(.green); Button("Disconnect") { up.disconnectGoogle() } }
                        }
                    } else {
                        TextField("Client ID", text: $clientID, prompt: Text("…apps.googleusercontent.com"))
                        SecureField("Client secret", text: $clientSecret)
                        HStack {
                            Button(up.googleBusy ? "Waiting for browser…" : "Connect Google Account…") {
                                GooglePhotos.shared.clientID = clientID
                                GooglePhotos.shared.clientSecret = clientSecret
                                up.connectGoogle()
                            }
                            .disabled(clientID.isEmpty || clientSecret.isEmpty || up.googleBusy)
                            if up.googleBusy {
                                Button("Cancel") { up.cancelGoogleSignIn() }
                                    .help("Closed the Google tab? Cancel, then connect again.")
                            }
                            Spacer()
                            Button("How do I get these?") { showHelp.toggle() }.buttonStyle(.link)
                        }
                        if let e = up.googleError { Text(e).font(.caption).foregroundStyle(.red) }
                        if showHelp { googleHelp }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Upload") {
                    up.isConfigured = true
                    dismiss()
                    DispatchQueue.main.async { up.run(model: model) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!(up.toApple || (up.toGoogle && up.googleConnected)) || up.isRunning
                          || up.files(for: up.scope, model: model).isEmpty)
            }
            if up.toGoogle && !up.googleConnected {
                Text("Google Photos is skipped until you connect an account.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var googleHelp: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("One-time setup, about 5 minutes:").font(.callout.weight(.semibold))
            Text("1. Go to console.cloud.google.com and create a project (e.g. “Fulcrum”).")
            Text("2. APIs & Services → Library → enable **Photos Library API**.")
            Text("3. Google Auth Platform → set up the consent screen as **External**, and add your Google account under Audience → Test users.")
            Text("4. Clients → Create client → Application type **Desktop app**. Copy the client ID and secret here.")
            Text("While the app is in “Testing”, Google signs you out every 7 days. Press **Publish app** on the Audience page to stay connected; Google will show an “unverified app” warning, which is fine for your own use.")
                .foregroundStyle(.secondary)
            Link("Open Google Cloud Console", destination: URL(string: "https://console.cloud.google.com/apis/library/photoslibrary.googleapis.com")!)
        }
        .font(.caption)
    }
}
