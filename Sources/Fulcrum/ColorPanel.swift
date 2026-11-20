import FulcrumCore
import SwiftUI

/// A Lightroom-style colour wheel: angle = hue, distance from centre = saturation.
struct ColorWheelView: View, Equatable {
    let title: String
    let wheel: Wheel
    let selected: Bool
    let onChange: (Wheel) -> Void
    let onSelect: () -> Void

    static func == (a: Self, b: Self) -> Bool { a.title == b.title && a.wheel == b.wheel && a.selected == b.selected }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let d = min(geo.size.width, geo.size.height)
                let r = d / 2
                let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                ZStack {
                    // The colour disc never changes, so it's drawn once and cached as an image.
                    Image(nsImage: WheelImage.shared)
                        .resizable()
                        .frame(width: d, height: d)
                        .position(center)
                    Canvas { ctx, _ in
                        let rect = CGRect(x: center.x - r, y: center.y - r, width: d, height: d)
                        let circle = Path(ellipseIn: rect)
                        ctx.stroke(circle, with: .color(selected ? .fcEngraving : .white.opacity(0.25)), lineWidth: selected ? 2.5 : 1)
                        var cross = Path()
                        cross.move(to: CGPoint(x: center.x - 4, y: center.y)); cross.addLine(to: CGPoint(x: center.x + 4, y: center.y))
                        cross.move(to: CGPoint(x: center.x, y: center.y - 4)); cross.addLine(to: CGPoint(x: center.x, y: center.y + 4))
                        ctx.stroke(cross, with: .color(.white.opacity(0.5)), lineWidth: 1)
                        let a = wheel.hue * .pi / 180, dist = wheel.sat / 100 * (r - 2)
                        let p = CGPoint(x: center.x + cos(a) * dist, y: center.y - sin(a) * dist)
                        if wheel.sat > 0 {
                            var line = Path(); line.move(to: center); line.addLine(to: p)
                            ctx.stroke(line, with: .color(.white.opacity(0.6)), lineWidth: 1)
                        }
                        let dot = CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)
                        ctx.fill(Path(ellipseIn: dot), with: .color(wheel.sat > 0
                            ? Color(hue: wheel.hue / 360, saturation: max(0.15, wheel.sat / 100), brightness: 0.95) : .gray))
                        ctx.stroke(Path(ellipseIn: dot), with: .color(.white), lineWidth: 1.5)
                    }
                }
                .contentShape(Circle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    onSelect()
                    let dx = g.location.x - center.x, dy = center.y - g.location.y
                    var hue = atan2(dy, dx) * 180 / .pi
                    if hue < 0 { hue += 360 }
                    var w = wheel
                    w.sat = (min(hypot(dx, dy) / (r - 2), 1) * 100).rounded()
                    if w.sat > 0 { w.hue = hue.rounded() }
                    onChange(w)
                })
                .onTapGesture(count: 2) { var w = wheel; w.sat = 0; w.lum = 0; onChange(w) }
            }
            .aspectRatio(1, contentMode: .fit)
            HStack(spacing: 4) {
                Text(title).font(.caption.weight(selected ? .semibold : .regular))
                if wheel.sat > 0 || wheel.lum != 0 {
                    Text("\(Int(wheel.hue))° · \(Int(wheel.sat))").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            FastSlider(value: wheel.lum, range: -100...100, defaultValue: 0, set: { var w = wheel; w.lum = $0.rounded(); onChange(w) })
                .help("Luminance — raise shadows to let black take colour, lower highlights to let white take it")
        }
        .onTapGesture { onSelect() }
    }
}

/// Colour sections of the inspector. The inspector asks for the parts it needs, in processing order,
/// so each control has one home; in B&W mode the Mixer feeds the conversion and Grading becomes Toning.
struct ColorTab: View {
    enum Part { case whiteBalance, presence, mixer, grading }

    @EnvironmentObject var model: AppModel
    @EnvironmentObject var edit: EditState
    let parts: [Part]
    var bwMode = false
    @State private var selectedWheel: WheelID = .shadows
    @State private var selectedBand = 5

    private var grade: ColorGrade { edit.settings.grade }

    var body: some View {
        let s = edit.settings
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                if i > 0 { Divider() }
                switch part {
                case .whiteBalance: whiteBalance.isolated(Pair([s.temperature, s.tint], model.isAutoBalancing))
                case .presence: presence.isolated([s.vibrance, s.saturation])
                case .mixer: mixer.isolated(Pair(Pair(s.mixer, selectedBand), bwMode))
                case .grading: grading.isolated(Pair(Pair(s.grade, selectedWheel), Pair(model.showRanges, bwMode)))
                }
            }
        }
    }

    // 1. Foundation
    private var whiteBalance: some View {
        InspectorSection(title: "White Balance", trailing: AnyView(
            Button {
                model.autoWhiteBalance()
            } label: {
                if model.isAutoBalancing { ProgressView().controlSize(.mini) } else { Text("Auto") }
            }
            .controlSize(.small)
            .help("Neutralise the photo's colour cast — a balanced foundation to grade on top of")
        )) {
            Text("Set first: it changes every step after it, including the black and white conversion.")
                .font(.caption).foregroundStyle(.secondary)
            ParamSlider(title: "Temperature  (cool ↔ warm)", value: $edit.settings.temperature, range: -100...100)
            ParamSlider(title: "Tint  (green ↔ magenta)", value: $edit.settings.tint, range: -100...100)
        }
    }

    // 2. Colour grading
    private var grading: some View {
        InspectorSection(title: bwMode ? "Toning" : "Colour Grading", trailing: AnyView(HStack(spacing: 6) {
            Menu {
                ForEach(ColorGrade.starters, id: \.name) { s in
                    Button(s.name) { model.applyGrade(s.grade) }
                }
                Divider()
                Button("Reset Grade") { model.applyGrade(ColorGrade()) }
            } label: { Image(systemName: "swatchpalette") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Starting points")
            Button { model.surprise(subtle: NSEvent.modifierFlags.contains(.option)) } label: { Image(systemName: "dice") }
                .buttonStyle(.borderless)
                .help("Surprise me — a random grade following the harmony (⌥ for subtle)")
            Toggle("", isOn: $edit.settings.grade.enabled).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                .help("Grade on/off — compare with and without")
        }.isolated(grade.enabled))) {
            VStack(alignment: .leading, spacing: 4) {
                Picker("Harmony", selection: $edit.settings.grade.harmony) {
                    ForEach(Harmony.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                Text(grade.harmony.help).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .isolated(grade.harmony)

            Grid(horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    wheel(.shadows)
                    wheel(.highlights)
                }
                GridRow {
                    wheel(.midtones)
                    wheel(.global)
                }
            }
            .opacity(grade.enabled ? 1 : 0.4)

            VStack(alignment: .leading, spacing: 6) {
                Text(selectedWheel.label).font(.callout.weight(.semibold))
                ParamSlider(title: "Hue", value: Binding(get: { grade[selectedWheel].hue },
                                                         set: { var w = grade[selectedWheel]; w.hue = $0.rounded(); model.setWheel(selectedWheel, w) }),
                            range: 0...360, format: { "\(Int($0))°" })
                ParamSlider(title: "Saturation", value: Binding(get: { grade[selectedWheel].sat },
                                                                set: { var w = grade[selectedWheel]; w.sat = $0.rounded(); model.setWheel(selectedWheel, w) }),
                            range: 0...100, format: { "\(Int($0))" })
                ParamSlider(title: "Luminance", value: Binding(get: { grade[selectedWheel].lum },
                                                               set: { var w = grade[selectedWheel]; w.lum = $0.rounded(); model.setWheel(selectedWheel, w) }),
                            range: -100...100)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))

            ParamSlider(title: "Blending", value: $edit.settings.grade.blending, range: 0...100, defaultValue: 50,
                        format: { "\(Int($0))" })
            ParamSlider(title: "Balance  (shadows ↔ highlights)", value: $edit.settings.grade.balance, range: -100...100)
            Toggle("Show tonal ranges", isOn: $model.showRanges)
                .font(.callout)
                .help("Blue = shadows, grey = midtones, orange = highlights. Watch it change with Blending and Balance.")
                .isolated(model.showRanges)
        }
    }

    private func wheel(_ id: WheelID) -> some View {
        ColorWheelView(title: id.label, wheel: grade[id], selected: selectedWheel == id,
                       onChange: { model.setWheel(id, $0) }, onSelect: { selectedWheel = id })
            .equatable()
    }

    // 3. Mixer
    private var mixer: some View {
        InspectorSection(title: bwMode ? "B&W Mix" : "Colour Mixer") {
            Text(bwMode ? "Sets how bright each colour turns in black and white. Darken Blue to deepen a sky."
                        : "Edits colours already in the photo — it can't add colour that isn't there.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 0) {
                ForEach(0..<8, id: \.self) { i in
                    let changed = edit.settings.mixer.hue[i] != 0 || edit.settings.mixer.sat[i] != 0 || edit.settings.mixer.lum[i] != 0
                    Button { selectedBand = i } label: {
                        Circle()
                            .fill(Color(hue: ColorMixer.bandHues[i] / 360, saturation: 0.85, brightness: 0.9))
                            .frame(width: 20, height: 20)
                            .overlay(Circle().stroke(Color.white, lineWidth: selectedBand == i ? 2 : 0).padding(-3))
                            .overlay(alignment: .bottom) {
                                if changed { Circle().fill(.white).frame(width: 4, height: 4).offset(y: 9) }
                            }
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(ColorMixer.bandNames[i])
                }
            }
            .padding(.vertical, 4)
            Text(ColorMixer.bandNames[selectedBand]).font(.callout.weight(.semibold))
            ParamSlider(title: "Hue", value: $edit.settings.mixer.hue[selectedBand], range: -100...100)
            ParamSlider(title: "Saturation", value: $edit.settings.mixer.sat[selectedBand], range: -100...100)
            ParamSlider(title: "Luminance", value: $edit.settings.mixer.lum[selectedBand], range: -100...100)
            if !edit.settings.mixer.isNeutral {
                Button("Reset Mixer") { edit.settings.mixer = ColorMixer() }.controlSize(.small)
            }
        }
    }

    private var presence: some View {
        InspectorSection(title: "Vibrance & Saturation") {
            ParamSlider(title: "Vibrance", value: $edit.settings.vibrance, range: -100...100)
            ParamSlider(title: "Saturation", value: $edit.settings.saturation, range: -100...100)
        }
    }

}

/// Tiny shadows → midtones → highlights preview of a grade.
struct GradeSwatch: View {
    let grade: ColorGrade
    var body: some View {
        HStack(spacing: 0) {
            ForEach([WheelID.shadows, .midtones, .highlights], id: \.self) { id in
                let w = grade[id]
                let base = id == .shadows ? 0.25 : id == .midtones ? 0.5 : 0.8
                Rectangle().fill(w.sat > 0 && grade.enabled
                    ? Color(hue: w.hue / 360, saturation: min(1, w.sat / 60), brightness: base + 0.1)
                    : Color(white: base))
            }
        }
        .frame(width: 36, height: 14)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

/// Hue/saturation disc rendered once (hue around the circle, fading to grey at the centre).
enum WheelImage {
    static let shared: NSImage = {
        let n = 256
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        var px = [UInt8](repeating: 0, count: n * n * 4)
        let c = Double(n - 1) / 2
        for y in 0..<n { for x in 0..<n {
            let dx = Double(x) - c, dy = c - Double(y)
            let r = (dx * dx + dy * dy).squareRoot() / c
            let o = (y * n + x) * 4
            guard r <= 1.0 else { continue }
            var h = atan2(dy, dx) / (2 * .pi); if h < 0 { h += 1 }
            let col = NSColor(hue: h, saturation: 0.8, brightness: 0.85, alpha: 1).usingColorSpace(.sRGB)!
            let t = min(r, 1)   // blend from grey centre to full colour at the rim
            let g = 0.42
            px[o] = UInt8((g + (col.redComponent - g) * t) * 255)
            px[o + 1] = UInt8((g + (col.greenComponent - g) * t) * 255)
            px[o + 2] = UInt8((g + (col.blueComponent - g) * t) * 255)
            px[o + 3] = r > 0.995 ? UInt8((1 - r) / 0.005 * 255) : 255
            for k in 0..<3 { px[o + k] = UInt8(Double(px[o + k]) * Double(px[o + 3]) / 255) }
        } }
        let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return NSImage(cgImage: ctx.makeImage()!, size: NSSize(width: n, height: n))
    }()
}
