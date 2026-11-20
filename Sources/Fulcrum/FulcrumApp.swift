import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var pendingURLs: [URL] = []
    static var openHandler: (([URL]) -> Void)?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let h = Self.openHandler { h(urls) } else { Self.pendingURLs += urls }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    static weak var model: AppModel?

    /// Photos waits for its "Edit With" copy to be saved; quitting first would drop the edit on the floor there.
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model else { return .terminateNow }
        let unsaved = model.unsavedPhotosFiles
        guard !unsaved.isEmpty else { return .terminateNow }
        let a = NSAlert()
        a.messageText = unsaved.count == 1 ? "Save your edit to Photos before quitting?"
                                           : "Save \(unsaved.count) edits to Photos before quitting?"
        a.informativeText = "Photos only shows changes saved back to the copy it opened in Fulcrum. "
            + "Your edits stay in Fulcrum either way."
        a.addButton(withTitle: "Save to Photos")
        a.addButton(withTitle: "Cancel")
        a.addButton(withTitle: "Don't Save")
        switch a.runModal() {
        case .alertFirstButtonReturn:
            model.saveToPhotos(unsaved) { ok in sender.reply(toApplicationShouldTerminate: ok) }
            return .terminateLater
        case .alertSecondButtonReturn:
            return .terminateCancel
        default:
            return .terminateNow
        }
    }
}

@main
struct FulcrumApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Fulcrum", id: "main") {
            ContentView(looks: model.looks)
                .environmentObject(model)
                .environmentObject(model.edit)
                .environmentObject(model.out)
                .frame(minWidth: 960, minHeight: 600)
                .preferredColorScheme(.dark)
                .onAppear {
                    AppDelegate.openHandler = { model.open($0) }
                    AppDelegate.model = model
                    if !AppDelegate.pendingURLs.isEmpty { model.open(AppDelegate.pendingURLs); AppDelegate.pendingURLs = [] }
                }
        }
        Window("Import from Camera", id: "import") {
            CameraImportView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1180, height: 780)
        Window("Style Patterns", id: "style") {
            StyleView()
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 680, height: 760)

        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Photos…") { model.openPanel() }.keyboardShortcut("o")
                ImportWindowButton()
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { model.undo() }.keyboardShortcut("z").disabled(!model.canUndo)
                Button("Redo") { model.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!model.canRedo)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save to Photos") { model.saveToPhotos() }
                    .keyboardShortcut("s")
                    .disabled(!model.isPhotosSession || model.isSavingToPhotos)
            }
            CommandMenu("Photo") {
                Button(model.showBefore ? "Show Edited  (\\)" : "Show Before  (hold Space, or \\)") { model.showBefore.toggle() }
                    .disabled(model.selection == nil)
                Button(model.showSplit ? "Hide Split Before / After  (Y)" : "Split Before / After  (Y)") { model.showSplit.toggle() }
                    .disabled(model.selection == nil || model.isCropping)
                Button(model.isCropping ? "Finish Crop  (C)" : "Crop  (C)") { model.isCropping ? model.commitCrop() : model.beginCrop() }
                    .disabled(model.selection == nil)
                Divider()
                Button("Copy Settings") { model.copySettings() }.keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Paste Settings") { model.pasteSettings() }.keyboardShortcut("v", modifiers: [.command, .shift])
                    .disabled(model.copiedSettings == nil)
                Button("Reset All Edits") { model.resetAll() }.keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button("Save Current as Look…") { NotificationCenter.default.post(name: .saveLook, object: nil) }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Divider()
                Button("Export…") { model.showExportSheet = true }.keyboardShortcut("e")
                    .disabled(model.files.isEmpty)
                Button("Upload") {
                    if Uploader.shared.canRunDirectly { Uploader.shared.run(model: model) } else { model.showUploadSheet = true }
                }
                .keyboardShortcut("u")
                .disabled(model.files.isEmpty)
                Button("Upload Options…") { model.showUploadSheet = true }.keyboardShortcut("u", modifiers: [.command, .shift])
                Divider()
                Button("Colour / Black & White  (V)") { model.settings.bw.enabled.toggle() }
                    .disabled(model.selection == nil || model.isCropping)
                Button("Favourite  (.)") { if let u = model.selection { TagStore.shared.update(u) { $0.favorite.toggle() } } }
                    .disabled(model.selection == nil)
                Button("Labels…") { NotificationCenter.default.post(name: .editLabels, object: nil) }
                    .keyboardShortcut("k")
                    .disabled(model.selection == nil)
                Divider()
                StyleWindowButton()
            }
        }
    }
}

struct ImportWindowButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Import from Camera…") { openWindow(id: "import") }.keyboardShortcut("i", modifiers: [.command, .shift])
    }
}

/// Hands back the NSWindow a view lives in.
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { onWindow(v.window) }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {}
}

struct StyleWindowButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Style Patterns…") { openWindow(id: "style") }.keyboardShortcut("p", modifiers: [.command, .option])
        Button("Show Edit Log in Finder") { NSWorkspace.shared.activateFileViewerSelecting([EditLog.shared.url]) }
    }
}
