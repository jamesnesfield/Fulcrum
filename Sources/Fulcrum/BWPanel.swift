import FulcrumCore
import SwiftUI

/// Black & White and Grain sections. The inspector's Colour | Black & White switch turns the
/// conversion on; this only holds its settings.
struct BWTab: View {
    enum Part { case conversion, grain }

    @EnvironmentObject var model: AppModel
    @EnvironmentObject var edit: EditState
    let parts: [Part]

    private static let toning: [(String, ColorGrade)] = {
        func g(_ s: Wheel, _ m: Wheel, _ h: Wheel, blend: Double = 60) -> ColorGrade {
            var x = ColorGrade(); x.shadows = s; x.midtones = m; x.highlights = h; x.blending = blend; return x
        }
        return [
            ("None", ColorGrade()),
            ("Sepia", g(Wheel(hue: 30, sat: 12), Wheel(hue: 35, sat: 18), Wheel(hue: 40, sat: 22))),
            ("Selenium", g(Wheel(hue: 285, sat: 14), Wheel(hue: 300, sat: 5), Wheel())),
            ("Cyanotype", g(Wheel(hue: 210, sat: 30), Wheel(hue: 205, sat: 24), Wheel(hue: 200, sat: 12))),
            ("Split Warm / Cool", g(Wheel(hue: 215, sat: 18), Wheel(), Wheel(hue: 40, sat: 20))),
            ("Platinum", g(Wheel(hue: 25, sat: 8), Wheel(hue: 35, sat: 6), Wheel(hue: 45, sat: 4))),
        ]
    }()

    var body: some View {
        let s = edit.settings
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                if i > 0 { Divider() }
                switch part {
                case .conversion: blackAndWhite.isolated(s.bw)
                case .grain: grain.isolated(s.grain)
                }
            }
        }
    }

    private var bw: BlackWhite { edit.settings.bw }

    private var blackAndWhite: some View {
        InspectorSection(title: "Black & White") {
            Group {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Filter").font(.callout)
                    Picker("Filter", selection: $edit.settings.bw.filter) {
                        ForEach(BWFilter.allCases) { f in Text(f.label).tag(f) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    Text(bw.filter.help).font(.caption).foregroundStyle(.secondary)
                }
                ParamSlider(title: "Intensity", value: $edit.settings.bw.intensity, range: 0...100, defaultValue: 50,
                            format: { "\(Int($0))" })
                    .help("How strongly colours separate into different greys through the filter")
                ParamSlider(title: "Neutrals", value: $edit.settings.bw.neutrals, range: -100...100)
                    .help("Lighten or darken the grey midtones; black and white stay put")
                ParamSlider(title: "Tone", value: $edit.settings.bw.tone, range: -100...100)
                    .help("Contrast, pivoted on this B&W conversion's own median")
                HStack {
                    Label { AnalysisText { "B&W median \(Int(($0?.bwMedian ?? 128).rounded()))" } } icon: { Image(systemName: "circle.lefthalf.filled") }
                    Spacer()
                    Text("Tone pivots here").foregroundStyle(Color.fcFigure)
                }
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                HStack {
                    Menu("Toning") {
                        ForEach(Self.toning, id: \.0) { t in
                            Button(t.0) { model.applyGrade(t.1) }
                        }
                    }
                    .fixedSize()
                    Text("Fine-tune in Toning below").font(.caption).foregroundStyle(.secondary)
                }
                Text("Tone pivots on the black and white conversion's own median, not the colour photo's, so it can differ from the Contrast pivot.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var grain: some View {
        InspectorSection(title: "Grain") {
            ParamSlider(title: "Amount", value: $edit.settings.grain.amount, range: 0...100, format: { "\(Int($0))" })
            ParamSlider(title: "Size", value: $edit.settings.grain.size, range: 0...100, defaultValue: 25, format: { "\(Int($0))" })
            ParamSlider(title: "Roughness", value: $edit.settings.grain.roughness, range: 0...100, defaultValue: 50, format: { "\(Int($0))" })
            Text("Film-style mono grain, strongest in the midtones. Works in colour too. Sized to the photo, so exports match the preview.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
