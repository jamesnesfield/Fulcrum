import FulcrumCore
import SwiftUI

struct InspectorView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var edit: EditState

    private func ev(_ v: Double) -> String { String(format: "%+.2f EV", v) }
    private func tone(_ v: Double) -> String { "\(Int(v.rounded()))" }
    private func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))" }

    var body: some View {
        VStack(spacing: 0) {
            HistogramPanel()
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 4)
            Picker("Mode", selection: $edit.settings.bw.enabled) {
                Text("Colour").tag(false)
                Text("Black & White").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Colour or black and white (V)")
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            ScrollView {
                // One column in processing order: each control has one home, and anything above
                // feeds everything below it.
                VStack(alignment: .leading, spacing: 4) {
                    let s = edit.settings
                    let mono = s.bw.enabled
                    // Base: what the engine does first.
                    ColorTab(parts: [.whiteBalance])
                    if model.isRAW {
                        Divider()
                        rawSection.isolated([s.rawBaseCurve, s.rawSharpening ?? -1, s.rawNoiseReduction ?? -1])
                    }
                    Divider()
                    lightSection.isolated([s.exposure, s.brilliance, s.highlights, s.shadows])
                    Divider()
                    contrastSection.isolated(Pair([s.contrast, s.pivotOffset, s.manualPivot],
                                                  [s.pivotAuto, s.contrastLuminosityOnly]))
                    Divider()
                    localSection.isolated(Pair(s.localAdjustments, model.overlayMaskID))
                    Divider()
                    if mono {
                        BWTab(parts: [.conversion])
                        Divider()
                        ColorTab(parts: [.mixer, .grading], bwMode: true)
                    } else {
                        ColorTab(parts: [.presence, .mixer, .grading])
                    }
                    Divider()
                    // Finish.
                    detailSection.isolated(s.clarity)
                    Divider()
                    vignetteSection.isolated(s.vignette)
                    Divider()
                    BWTab(parts: [.grain])
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
        }
        .background(Color.fcBarrel)
        .disabled(model.selection == nil)
    }

    private var lightSection: some View {
        InspectorSection(title: "Light") {
            ParamSlider(title: "Exposure", value: $edit.settings.exposure, range: -4...4, format: ev)
            ParamSlider(title: "Brilliance", value: $edit.settings.brilliance, range: -100...100)
            ParamSlider(title: "Highlight Recovery", value: $edit.settings.highlights, range: 0...100)
            ParamSlider(title: "Shadows", value: $edit.settings.shadows, range: -100...100)
        }
    }

    private var contrastSection: some View {
        let s = edit.settings
        return InspectorSection(title: "Contrast") {
            ContrastReadout()
            ParamSlider(title: "Amount", value: $edit.settings.contrast, range: -100...100)
            PivotExplainer()
            Picker("Pivot", selection: $edit.settings.pivotAuto) {
                Text("At median").tag(true)
                Text("Manual").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if s.pivotAuto {
                ParamSlider(title: "Pivot Offset", value: $edit.settings.pivotOffset, range: -80...80)
            } else {
                ParamSlider(title: "Pivot", value: $edit.settings.manualPivot, range: 5...250, defaultValue: 128, format: tone)
            }
            Toggle("Luminosity only (don't boost saturation)", isOn: $edit.settings.contrastLuminosityOnly)
                .font(.callout)
        }
    }

    private var vignetteSection: some View {
        let v = edit.settings.vignette
        return InspectorSection(title: "Vignette") {
            Picker("Centre", selection: $edit.settings.vignette.centre) {
                ForEach(Vignette.Centre.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Where the vignette is centred: the frame's centre, a point you drag on the photo, or the detected subject")
            ParamSlider(title: "Amount", value: $edit.settings.vignette.amount, range: -100...100)
                .help("Negative darkens the edges, positive lightens them. Works as exposure, so colours and B&W tones stay true.")
            ParamSlider(title: "Size", value: $edit.settings.vignette.size, range: 0...100, defaultValue: 50,
                        format: { "\(Int($0.rounded()))" })
            ParamSlider(title: "Roundness", value: $edit.settings.vignette.roundness, range: -100...100)
                .help("−100 follows the frame's shape; +100 is a circle")
            ParamSlider(title: "Feather", value: $edit.settings.vignette.feather, range: 0...100, defaultValue: 50,
                        format: { "\(Int($0.rounded()))" })
            VignetteNote(centre: v.centre, active: v.isActive)
        }
    }

    private var detailSection: some View {
        InspectorSection(title: "Detail") {
            ParamSlider(title: "Clarity", value: $edit.settings.clarity, range: -100...100)
        }
    }

    private var rawSection: some View {
        InspectorSection(title: "RAW Decode") {
            ParamSlider(title: "Base Curve", value: $edit.settings.rawBaseCurve, range: 0...1, defaultValue: 1, format: pct)
                .help("Apple's default RAW tone curve. Lower it for a flatter start so the median contrast does the work.")
            ParamSlider(title: "Sharpening",
                        value: Binding(get: { edit.settings.rawSharpening ?? model.rawDefaultSharpening },
                                       set: { edit.settings.rawSharpening = $0 }),
                        range: 0...2, defaultValue: model.rawDefaultSharpening, format: pct)
            ParamSlider(title: "Noise Reduction",
                        value: Binding(get: { edit.settings.rawNoiseReduction ?? model.rawDefaultNoiseReduction },
                                       set: { edit.settings.rawNoiseReduction = $0 }),
                        range: 0...1, defaultValue: model.rawDefaultNoiseReduction, format: pct)
        }
    }

    private var localSection: some View {
        InspectorSection(title: "Local Contrast", trailing: AnyView(
            Menu {
                ForEach(MaskSpec.Kind.allCases) { k in
                    Button { model.addLocal(k) } label: { Label(k.label, systemImage: k.symbol) }
                }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add a masked adjustment that pivots on the mask's own median")
        )) {
            if edit.settings.localAdjustments.isEmpty {
                Text("Add a mask (e.g. Sky) to apply contrast pivoted on that region's own median.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach($edit.settings.localAdjustments) { $adj in
                LocalAdjustmentEditor(adj: $adj)
            }
        }
    }
}

struct LocalAdjustmentEditor: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var render: RenderState
    @Binding var adj: LocalAdjustment

    var body: some View {
        let a = render.analysis
        let showing = model.overlayMaskID == adj.id
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Toggle("", isOn: $adj.enabled).labelsHidden().toggleStyle(.checkbox)
                Image(systemName: adj.mask.kind.symbol)
                Text(adj.name).font(.callout.weight(.medium))
                Spacer()
                Button { model.overlayMaskID = showing ? nil : adj.id } label: {
                    Image(systemName: showing ? "eye.fill" : "eye")
                }
                .buttonStyle(.borderless)
                .help("Show mask overlay")
                Button { model.removeLocal(adj.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
            if adj.enabled {
                HStack {
                    Text("Mask median \(Int((a?.localMedians[adj.id] ?? 0).rounded()))")
                    Spacer()
                    Text("Pivot \(Int((a?.localPivots[adj.id] ?? 0).rounded()))").foregroundStyle(Color.fcFigure)
                    Spacer()
                    Text("Covers \(Int(((a?.localCoverage[adj.id] ?? 0) * 100).rounded()))%")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

                maskControls

                ParamSlider(title: "Contrast", value: $adj.contrast, range: -100...100)
                ParamSlider(title: "Pivot Offset", value: $adj.pivotOffset, range: -80...80)
                ParamSlider(title: "Exposure", value: $adj.exposure, range: -2...2, format: { String(format: "%+.2f EV", $0) })
                ParamSlider(title: "Saturation", value: $adj.saturation, range: -100...100)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }

    @ViewBuilder private var maskControls: some View {
        switch adj.mask.kind {
        case .linearGradient:
            ParamSlider(title: "Full effect at", value: $adj.mask.gradientFrom, range: 0...1, defaultValue: 0,
                        format: { "\(Int(($0 * 100).rounded()))% from top" })
            ParamSlider(title: "Fades out by", value: $adj.mask.gradientTo, range: 0...1, defaultValue: 0.45,
                        format: { "\(Int(($0 * 100).rounded()))% from top" })
        case .luminanceRange:
            ParamSlider(title: "From", value: $adj.mask.lumaLow, range: 0...255, defaultValue: 150, format: { "\(Int($0))" })
            ParamSlider(title: "To", value: $adj.mask.lumaHigh, range: 0...255, defaultValue: 255, format: { "\(Int($0))" })
            ParamSlider(title: "Feather", value: $adj.mask.lumaFeather, range: 0...80, defaultValue: 24, format: { "\(Int($0))" })
        default:
            EmptyView()
        }
        Toggle("Invert mask", isOn: $adj.mask.invert).font(.callout)
    }
}

/// The pivot scale (watches render results and the contrast amount). Drag it sideways to move the
/// pivot: right for a brighter pivot, left for a darker one. The index stays centred and the tone
/// scale slides under it, like a lens ring past its index. Double-click puts the pivot back on the median.
struct ContrastReadout: View {
    @EnvironmentObject var render: RenderState
    @EnvironmentObject var edit: EditState
    @State private var dragStart: Double?     // pivot when the drag began
    @State private var dragPivot: Double?     // shown while dragging, ahead of the render

    private var median: Double { render.analysis?.globalMedian ?? 128 }
    private var pivot: Double { dragPivot ?? render.analysis?.globalPivot ?? 128 }

    /// Moves the pivot to `target` (0–255) through the settings that own it, within their ranges.
    private func setPivot(_ target: Double) {
        if edit.settings.pivotAuto {
            let offset = min(max((target - median).rounded(), -80), 80)
            edit.settings.pivotOffset = offset
            dragPivot = median + offset
        } else {
            let t = min(max(target.rounded(), 5), 250)
            edit.settings.manualPivot = t
            dragPivot = t
        }
    }

    var body: some View {
        GeometryReader { g in
            // The scale draws 26 tones per 32 pt at its 288 pt design width.
            let tonesPerPoint = 26 / (32 * max(g.size.width, 1) / 288)
            PivotScaleView(amount: edit.settings.contrast, pivot: pivot)
                .equatable()
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 2)
                    .onChanged { d in
                        let start = dragStart ?? (render.analysis?.globalPivot ?? 128)
                        if dragStart == nil { dragStart = start }
                        setPivot(start + Double(d.translation.width) * tonesPerPoint)
                    }
                    .onEnded { _ in dragStart = nil; dragPivot = nil })
                .onTapGesture(count: 2) {
                    edit.settings.pivotAuto = true
                    edit.settings.pivotOffset = 0
                }
                .onHover { inside in
                    if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                }
        }
        .frame(height: 92)
        .help("Drag sideways to move the pivot; double-click to put it back on the median. Brackets open with more contrast; dashed brackets mean negative contrast.")
        .accessibilityElement()
        .accessibilityLabel("Contrast pivot")
        .accessibilityValue("Tone \(Int(pivot.rounded())), median \(Int(median.rounded()))")
        .accessibilityAdjustableAction { dir in setPivot(pivot + (dir == .increment ? 1 : -1)) }
    }
}

/// One plain sentence naming where contrast pivots.
struct PivotExplainer: View {
    @EnvironmentObject var render: RenderState
    @EnvironmentObject var edit: EditState

    var body: some View {
        let a = render.analysis
        let median = Int((a?.globalMedian ?? 128).rounded()), pivot = Int((a?.globalPivot ?? 128).rounded())
        Text(pivot == median
             ? "Pivots on this photo's median, tone \(median). Above it brightens, below darkens. Drag the scale to move the pivot."
             : "Pivots at tone \(pivot); this photo's median is \(median). Double-click the scale to return to the median.")
            .font(.system(size: 12))
            .lineSpacing(3)
            .foregroundStyle(Color.fcFigure)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One line saying where the vignette is centred (watches the analysis for the subject result).
struct VignetteNote: View {
    @EnvironmentObject var render: RenderState
    let centre: Vignette.Centre
    let active: Bool

    var body: some View {
        let text: String = switch centre {
        case .frame: "Centred on the frame. Pick Manual to place it, or Subject to follow what's in focus."
        case .manual: active ? "Drag the ring on the photo to move the centre. Double-click it to return to the frame's centre."
                             : "Set an Amount, then drag the ring that appears on the photo to place the centre."
        case .subject: active && render.analysis?.vignetteSubjectFound == false
            ? "No face or subject found in this photo, so it's centred on the frame."
            : "Centred on the main face (or between faces of a similar size), or on the subject when there's no face. It follows them if you crop."
        }
        Text(text)
            .font(.system(size: 12))
            .lineSpacing(3)
            .foregroundStyle(Color.fcFigure)
            .fixedSize(horizontal: false, vertical: true)
    }
}
