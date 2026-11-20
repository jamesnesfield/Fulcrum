import FulcrumCore
import QuickLookThumbnailing
import SwiftUI

/// Labelled slider. Double-click the label to reset.
/// Wraps an Equatable body so it only redraws when its own value changes, not on every edit.
struct ParamSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var defaultValue: Double = 0
    var format: (Double) -> String = { v in
        let r = Int(v.rounded()); return r > 0 ? "+\(r)" : "\(r)"
    }

    var body: some View {
        ParamSliderBody(title: title, value: value, range: range, defaultValue: defaultValue,
                        label: format(value), set: { value = $0 })
            .equatable()
    }
}

struct ParamSliderBody: View, Equatable {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let defaultValue: Double
    let label: String
    let set: (Double) -> Void

    static func == (a: Self, b: Self) -> Bool {
        a.title == b.title && a.value == b.value && a.range == b.range && a.defaultValue == b.defaultValue && a.label == b.label
    }

    /// "+0.35 EV" → ("+0.35", "EV"), so the unit can be set smaller.
    private var valueParts: (String, String?) {
        let parts = label.split(separator: " ")
        if parts.count == 2, parts[1].allSatisfy(\.isLetter) { return (String(parts[0]), String(parts[1])) }
        return (label, nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 12)).foregroundStyle(Color.fcLabel)
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(valueParts.0).font(FulcrumFont.value).foregroundStyle(Color.fcLabel)
                    if let unit = valueParts.1 { Text(unit).font(.system(size: 11)).foregroundStyle(Color.fcMetadata) }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { set(defaultValue) }
            .help("Double-click to reset")
            FastSlider(value: value, range: range, defaultValue: defaultValue, set: set)
            TickFigures(range: range, defaultValue: defaultValue)
        }
    }
}

/// Engraved figures under a slider: the ends and the middle, with the figure at the default lit.
struct TickFigures: View {
    let range: ClosedRange<Double>
    let defaultValue: Double

    private var ticks: [Double] {
        let lo = range.lowerBound, hi = range.upperBound
        if lo < 0, abs(lo + hi) < 1e-9 {
            return hi <= 10 ? [lo, lo / 2, 0, hi / 2, hi] : [lo, 0, hi]
        }
        return [lo, (lo + hi) / 2, hi]
    }

    private func label(_ v: Double) -> String {
        let bipolar = range.lowerBound < 0
        // 0…1 and 0…2 scales read as percentages, like their values.
        let shown = range.upperBound <= 2 && range.lowerBound >= 0 ? v * 100 : v
        let mag = abs(shown)
        let digits = mag == mag.rounded() ? String(Int(mag)) : String(format: "%g", mag)
        if shown < 0 { return "\u{2212}" + digits }
        return bipolar && shown > 0 ? "+" + digits : digits
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(ticks.enumerated()), id: \.offset) { i, t in
                if i > 0 { Spacer(minLength: 0) }
                Text(label(t))
                    .font(FulcrumFont.scale)
                    .foregroundStyle(abs(t - defaultValue) < 1e-9 ? Color.fcLabel : Color.fcMetadata)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A lightweight slider drawn in SwiftUI (no AppKit control to sync on every frame), engraved like a
/// lens scale: a 2px track, a fill from the default to the knob, and an index dot above the default.
/// It snaps gently to the default. Double-click resets it.
struct FastSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    let defaultValue: Double
    let set: (Double) -> Void
    @State private var dragging = false
    @State private var lastClick: (time: TimeInterval, x: CGFloat)?

    var body: some View {
        GeometryReader { g in
            let w = max(g.size.width - 14, 1)
            let span = range.upperBound - range.lowerBound
            let x = { (v: Double) in 7 + CGFloat((min(max(v, range.lowerBound), range.upperBound) - range.lowerBound) / span) * w }
            ZStack(alignment: .topLeading) {
                Circle().fill(Color.fcEngraving).frame(width: 4, height: 4).offset(x: x(defaultValue) - 2, y: 0)
                Capsule().fill(Color.fcTrack).frame(width: g.size.width, height: 2).offset(y: 8)
                let a = min(x(value), x(defaultValue)), b = max(x(value), x(defaultValue))
                Rectangle().fill(Color.fcOnFill).frame(width: max(b - a, 0), height: 2).offset(x: a, y: 8)
                Circle()
                    .fill(Color.fcKnob)
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
                    .frame(width: dragging ? 15 : 14, height: dragging ? 15 : 14)
                    .offset(x: x(value) - (dragging ? 7.5 : 7), y: dragging ? 1.5 : 2)
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { d in
                dragging = true
                var v = range.lowerBound + Double((d.location.x - 7) / w) * span
                v = min(max(v, range.lowerBound), range.upperBound)
                if abs(v - defaultValue) < span * 0.012 { v = defaultValue }   // gentle detent at default
                if v != value { set(v) }
            }.onEnded { d in
                dragging = false
                // A click (not a drag): two in quick succession, in about the same place, reset to default.
                guard hypot(d.translation.width, d.translation.height) < 3 else { lastClick = nil; return }
                let now = ProcessInfo.processInfo.systemUptime
                if let c = lastClick, now - c.time < NSEvent.doubleClickInterval, abs(d.location.x - c.x) < 6 {
                    set(defaultValue)
                    lastClick = nil
                } else {
                    lastClick = (now, d.location.x)
                }
            })
        }
        .frame(height: 18)
        .help("Double-click to reset")
        .accessibilityElement()
        .accessibilityValue(Text(String(format: "%.2f", value)))
        .accessibilityAdjustableAction { dir in
            let step = (range.upperBound - range.lowerBound) / 100
            set(min(max(value + (dir == .increment ? step : -step), range.lowerBound), range.upperBound))
        }
    }
}

struct InspectorSection<Content: View>: View {
    let title: String
    let trailing: AnyView?
    let content: Content
    @AppStorage private var expanded: Bool

    init(title: String, trailing: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content()
        _expanded = AppStorage(wrappedValue: true, "inspector.open.\(title)")   // remembered per section
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.fcMetadata)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                        Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.fcLabel)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                trailing
            }
            if expanded { content }
        }
        .padding(.vertical, 6)
    }
}

/// Luminance histogram with red, green and blue channel lines over it, and the measured median marked
/// by an engraved index (see DESIGN.md › Histogram).
struct HistogramView: View, Equatable {
    let analysis: AnalysisResult?

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Luminance").font(.system(size: 11)).foregroundStyle(Color.fcMetadata)
                Spacer()
                Text("median").font(.system(size: 11)).foregroundStyle(Color.fcMetadata)
                Text(analysis.map { "\(Int($0.outputMedian.rounded()))" } ?? "–")
                    .font(FulcrumFont.figures(13, weight: 600)).foregroundStyle(Color.fcEngraving)
            }
            Canvas { ctx, size in
                guard let a = analysis else { return }
                func path(_ bins: [Float], closed: Bool) -> Path {
                    var p = Path()
                    let w = size.width / CGFloat(max(bins.count - 1, 1))
                    p.move(to: CGPoint(x: 0, y: size.height))
                    for (i, v) in bins.enumerated() {
                        p.addLine(to: CGPoint(x: CGFloat(i) * w, y: size.height - CGFloat(v) * size.height * 0.95))
                    }
                    if closed { p.addLine(to: CGPoint(x: size.width, y: size.height)); p.closeSubpath() }
                    return p
                }
                let h = a.histogram
                ctx.fill(path(h.luma, closed: true), with: .color(.fcTrack))
                // Channel lines: the one place colour reads in the chrome, because it is data (clipping, casts).
                ctx.stroke(path(h.red, closed: false), with: .color(.fcChannelRed), lineWidth: 1)
                ctx.stroke(path(h.green, closed: false), with: .color(.fcChannelGreen), lineWidth: 1)
                ctx.stroke(path(h.blue, closed: false), with: .color(.fcChannelBlue), lineWidth: 1)
                let x = size.width * CGFloat(a.outputMedian / 255)
                var m = Path(); m.move(to: CGPoint(x: x, y: 0)); m.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(m, with: .color(.fcEngraving), lineWidth: 1.2)
                ctx.fill(IndexTriangle(pointingUp: false).path(in: CGRect(x: x - 4, y: 0, width: 8, height: 6)), with: .color(.fcEngraving))
            }
            .frame(height: 56)
            HStack {
                Text("0"); Spacer(); Text("255")
            }
            .font(FulcrumFont.scale).foregroundStyle(Color.fcMetadata)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(analysis.map { "Histogram with red, green and blue channels, median \(Int($0.outputMedian.rounded()))" } ?? "Histogram")
    }
}

/// The Contrast control's readout, drawn like a lens's depth-of-field scale: a fixed index on the
/// pivot (the photo's median), brackets that open with positive contrast and close (dashed) with
/// negative, tone values either side and their zones beneath as the scale's second unit.
/// It only draws; ContrastReadout makes it draggable to move the pivot.
struct PivotScaleView: View, Equatable {
    let amount: Double     // −100…100
    let pivot: Double      // 0–255

    private static let romans = ["0", "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X"]
    private static func zone(_ tone: Double) -> String { romans[min(max(Int((tone / 25.5).rounded()), 0), 10)] }

    var body: some View {
        Canvas { ctx, size in
            let k = size.width / 288, cx = size.width / 2
            let topY: CGFloat = 2, kneeY: CGFloat = 24, footY: CGFloat = 52
            func bracket(_ top: CGFloat, _ foot: CGFloat) -> Path {
                var p = Path()
                for side: CGFloat in [-1, 1] {
                    p.move(to: CGPoint(x: cx + side * top, y: topY))
                    p.addLine(to: CGPoint(x: cx + side * top, y: kneeY))
                    p.addLine(to: CGPoint(x: cx + side * foot, y: footY))
                }
                return p
            }
            // Fixed brackets, unlit.
            for (i, top) in [10.0, 18, 26, 34].enumerated() {
                ctx.stroke(bracket(top * k, CGFloat(32 * (i + 1)) * k), with: .color(.fcGhostMark), lineWidth: 1)
            }
            // The live bracket: wider with stronger contrast; dashed and closing in when negative.
            if abs(amount) >= 0.5 {
                let foot = 136 * k * CGFloat((abs(amount) / 100).squareRoot())
                let top = 6 * k + foot * 0.22
                let style = amount > 0 ? StrokeStyle(lineWidth: 1.8, lineJoin: .round)
                                       : StrokeStyle(lineWidth: 1.8, lineJoin: .round, dash: [4, 3])
                ctx.stroke(bracket(top, foot), with: .color(.fcEngraving), style: style)
            }
            // Index on the pivot.
            var line = Path(); line.move(to: CGPoint(x: cx, y: 0)); line.addLine(to: CGPoint(x: cx, y: 48))
            ctx.stroke(line, with: .color(.fcEngraving), lineWidth: 1.5)
            ctx.fill(IndexTriangle().path(in: CGRect(x: cx - 7, y: 46, width: 14, height: 10)), with: .color(.fcEngraving))
            // Tone values either side of the pivot, zones beneath.
            ctx.draw(Text("\(Int(pivot.rounded()))").font(FulcrumFont.valueAtIndex).foregroundColor(.fcEngraving),
                     at: CGPoint(x: cx, y: 67))
            ctx.draw(Text(Self.zone(pivot)).font(FulcrumFont.zone).foregroundColor(.fcSecondScale), at: CGPoint(x: cx, y: 84))
            for i in 1...4 {
                for side in [-1.0, 1.0] {
                    let tone = pivot + side * 26 * Double(i)
                    guard (0...255).contains(tone) else { continue }
                    let x = cx + CGFloat(side) * CGFloat(32 * i) * k
                    ctx.draw(Text("\(Int(tone.rounded()))").font(FulcrumFont.scale).foregroundColor(.fcFigure), at: CGPoint(x: x, y: 67))
                    ctx.draw(Text(Self.zone(tone)).font(FulcrumFont.zone).foregroundColor(.fcSecondScale), at: CGPoint(x: x, y: 84))
                }
            }
        }
        .frame(height: 92)
    }
}

struct ThumbnailView: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2).fill(Color.fcRing)
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            }
        }
        .frame(width: 36, height: 24)
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .task(id: url) {
            let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 104, height: 80),
                                                   scale: 2, representationTypes: .thumbnail)
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) {
                image = rep.nsImage
            }
        }
    }
}

/// Small read-outs that watch render results, so the rest of the inspector doesn't redraw on every frame.
struct HistogramPanel: View {
    @EnvironmentObject var render: RenderState
    var body: some View { HistogramView(analysis: render.analysis).equatable() }
}

struct AnalysisText: View {
    @EnvironmentObject var render: RenderState
    let text: (AnalysisResult?) -> String
    var body: some View { Text(text(render.analysis)) }
}

/// Rebuilds its content only when `key` changes. Wrapping each inspector section in one means
/// dragging a slider only redraws that slider's section, not the whole panel.
struct Isolated<Key: Equatable, Content: View>: View, Equatable {
    let key: Key
    @ViewBuilder let content: () -> Content
    static func == (a: Self, b: Self) -> Bool { a.key == b.key }
    var body: some View { content() }
}

struct Pair<A: Equatable, B: Equatable>: Equatable { let a: A; let b: B; init(_ a: A, _ b: B) { self.a = a; self.b = b } }

extension View {
    /// Only re-evaluate this section when `key` changes.
    func isolated<K: Equatable>(_ key: K) -> some View { Isolated(key: key) { self }.equatable() }
}
