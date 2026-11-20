import FulcrumCore
import SwiftUI

/// The current photo's edit. Only views that show sliders observe this, so a slider move
/// doesn't rebuild the file list, toolbar or canvas.
@MainActor
final class EditState: ObservableObject {
    @Published var settings = EditSettings() {
        didSet { if settings != oldValue { onChange?(oldValue) } }
    }
    var onChange: ((EditSettings) -> Void)?
}

/// What the renderer produced. Observed only by the canvas and small read-outs (histogram, medians).
@MainActor
final class RenderState: ObservableObject {
    @Published var display: Renderer.Display?     // zero-copy frame for the canvas
    @Published var preview: CGImage?              // uncropped CGImage, used by the crop tool
    @Published var beforeImage: CGImage?
    @Published var analysis: AnalysisResult?
    @Published var detail: AppModel.DetailTile?
    @Published var stamp = 0
    @Published var isLoading = false

    func setAnalysis(_ a: AnalysisResult) { if analysis != a { analysis = a } }
}
