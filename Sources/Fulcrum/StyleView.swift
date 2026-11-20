import AppKit
import FulcrumCore
import SwiftUI

struct StyleView: View {
    @State private var summary = StyleSummary([])

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if summary.photos == 0 {
                    Text("No edits logged yet. Every edit is logged automatically a few seconds after you stop moving sliders, and on export.")
                        .foregroundStyle(.secondary)
                } else {
                    habits
                    gradeHues
                    usageTable
                    lists
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 560, minHeight: 520)
        .onAppear(perform: reload)
    }

    private func reload() { summary = StyleSummary(EditLog.shared.entries()) }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Style Patterns").font(.largeTitle.weight(.semibold))
                Text("\(summary.photos) photos · \(summary.entries) logged edits" +
                     (summary.first.map { " · since \($0.prefix(10))" } ?? ""))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { reload() } label: { Image(systemName: "arrow.clockwise") }.help("Reload")
            Button("Copy Summary") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(summary.text, forType: .string)
            }
            Button("Show Log") { NSWorkspace.shared.activateFileViewerSelecting([EditLog.shared.url]) }
        }
    }

    private func stat(_ title: String, _ value: String, _ sub: String = "") -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold).monospacedDigit())
            if !sub.isEmpty { Text(sub).font(.caption2).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.6)))
    }

    private func pct(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }

    private var habits: some View {
        let contrast = summary.usage.first { $0.id == "contrast" }
        let med = summary.medians.isEmpty ? nil : summary.medians.sorted()[summary.medians.count / 2]
        return Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                stat("Black & white", pct(summary.bwShare), summary.bwFilters.first.map { "mostly \($0.0) filter" } ?? "")
                stat("Grain", pct(summary.grainShare), summary.grainShare > 0 ? "avg amount \(Int(summary.grainAverage))" : "")
                stat("Cropped", pct(summary.cropShare), summary.aspects.first.map { "mostly \($0.0)" } ?? "")
            }
            GridRow {
                stat("Contrast", contrast.flatMap { $0.average }.map { String(format: "%+.0f", $0) } ?? "—",
                     contrast.map { "used on \(pct($0.share))" } ?? "")
                stat("Typical median", med.map { "\(Int($0))" } ?? "—", "how bright your photos start")
                stat("Harmony", summary.harmonies.first?.0.capitalized ?? "—", "most used grading mode")
            }
        }
    }

    private var gradeHues: some View {
        HStack(spacing: 24) {
            hueCard("Shadow colour", summary.shadowHues)
            hueCard("Highlight colour", summary.highlightHues)
        }
    }

    private func hueCard(_ title: String, _ hues: [Double]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            if let m = StyleSummary.circularMean(hues) {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 6).fill(Color(hue: m / 360, saturation: 0.7, brightness: 0.85)).frame(width: 40, height: 28)
                    Text("\(Int(m))° average, \(hues.count) photos").font(.callout).foregroundStyle(.secondary)
                }
                HStack(spacing: 2) {
                    ForEach(Array(hues.suffix(30).enumerated()), id: \.offset) { _, h in
                        Rectangle().fill(Color(hue: h / 360, saturation: 0.7, brightness: 0.85)).frame(width: 8, height: 12)
                    }
                }
            } else {
                Text("Not used yet").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var usageTable: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Most-used adjustments").font(.headline)
            Text("Share of photos where each setting differs from default, with its average value.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(summary.usage.prefix(24)) { u in
                HStack {
                    Text(u.id).font(.callout.monospaced()).frame(width: 220, alignment: .leading)
                    GeometryReader { g in
                        RoundedRectangle(cornerRadius: 2).fill(Color.fcOnFill)
                            .frame(width: g.size.width * u.share)
                    }
                    .frame(height: 10)
                    Text(pct(u.share)).monospacedDigit().frame(width: 44, alignment: .trailing)
                    Text(u.average.map { String(format: "%+.1f", $0) } ?? "").monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                }
            }
        }
    }

    private var lists: some View {
        HStack(alignment: .top, spacing: 24) {
            list("Crop ratios", summary.aspects)
            list("Cameras", summary.cameras)
        }
    }

    private func list(_ title: String, _ xs: [(String, Int)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            if xs.isEmpty { Text("—").foregroundStyle(.secondary) }
            ForEach(xs.prefix(8), id: \.0) { x in
                HStack { Text(x.0); Spacer(); Text("\(x.1)").monospacedDigit().foregroundStyle(.secondary) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
