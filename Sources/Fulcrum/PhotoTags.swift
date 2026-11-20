import Foundation
import FulcrumCore
import SwiftUI

/// Per-photo favourite flag, labels, and where it has been uploaded.
struct PhotoTags: Codable, Equatable {
    var favorite = false
    var labels: [String] = []
    var uploadedApple: Date?
    var uploadedGoogle: Date?
    /// What was uploaded (edit + format), so a photo edited since counts as new again. Nil on uploads made
    /// before this was recorded, which are treated as out of date.
    var uploadedAppleVersion: String?
    var uploadedGoogleVersion: String?

    var isEmpty: Bool { self == PhotoTags() }
}

extension PhotoTags {
    init(_ s: ShotSidecar) {
        favorite = s.tags.favourite
        labels = s.tags.labels
        uploadedApple = s.uploads.apple?.date
        uploadedAppleVersion = s.uploads.apple?.version
        uploadedGoogle = s.uploads.google?.date
        uploadedGoogleVersion = s.uploads.google?.version
    }

    func apply(to s: inout ShotSidecar) {
        s.tags = ShotSidecar.Tags(favourite: favorite, labels: labels)
        s.uploads.apple = uploadedApple.map { ShotSidecar.Upload(date: $0, version: uploadedAppleVersion) }
        s.uploads.google = uploadedGoogle.map { ShotSidecar.Upload(date: $0, version: uploadedGoogleVersion) }
    }
}

/// Favourites, labels and upload state, stored in each shot's sidecar. Observable so lists redraw on change.
@MainActor
final class TagStore: ObservableObject {
    static let shared = TagStore()
    private init() {}

    func tags(_ file: URL) -> PhotoTags { PhotoTags(ShotStore.shared.sidecar(for: file)) }

    func update(_ file: URL, _ change: (inout PhotoTags) -> Void) {
        var t = tags(file)
        let before = t
        change(&t)
        t.labels = Self.clean(t.labels)
        guard t != before else { return }
        objectWillChange.send()
        let added = t.labels.filter { l in !before.labels.contains(l) }
        if !added.isEmpty { RecentLabels.use(added) }
        ShotStore.shared.update(file) { t.apply(to: &$0) }
    }

    /// Labels used recently, most recent first.
    var knownLabels: [String] { RecentLabels.all }

    static func clean(_ labels: [String]) -> [String] {
        var seen = Set<String>()
        return labels.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}

/// Toolbar popover: add or remove labels on the current photo.
struct LabelsPopover: View {
    let file: URL
    @ObservedObject var tags = TagStore.shared
    @State private var text = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let current = tags.tags(file)
        VStack(alignment: .leading, spacing: 10) {
            Text("Labels").font(.headline)
            Text("Keywords in Apple Photos, albums in Google Photos.").font(.caption).foregroundStyle(.secondary)
            TextField("Add a label and press Return", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit {
                    let parts = text.split(separator: ",").map(String.init)
                    tags.update(file) { $0.labels += parts }
                    text = ""
                }
            if !current.labels.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(current.labels, id: \.self) { l in
                        Button { tags.update(file) { $0.labels.removeAll { $0 == l } } } label: {
                            HStack(spacing: 4) { Text(l); Image(systemName: "xmark").font(.caption2.weight(.bold)) }
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .help("Remove \(l)")
                    }
                }
            }
            let suggestions = tags.knownLabels.filter { k in !current.labels.contains { $0.lowercased() == k.lowercased() } }
                .filter { text.isEmpty || $0.localizedCaseInsensitiveContains(text) }.prefix(12)
            if !suggestions.isEmpty {
                Divider()
                Text("Recent").font(.caption).foregroundStyle(.secondary)
                FlowLayout(spacing: 6) {
                    ForEach(Array(suggestions), id: \.self) { l in
                        Button(l) { tags.update(file) { $0.labels.append(l) } }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { fieldFocused = true }
    }
}

/// Wraps its children onto new lines, like tags.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(bounds.width, subviews) {
            var x = bounds.minX
            for i in row.items {
                let s = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
                x += s.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ maxWidth: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let s = subviews[i].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].items.isEmpty, rows[rows.count - 1].width + spacing + s.width > maxWidth { rows.append(Row()) }
            var r = rows[rows.count - 1]
            r.width += (r.items.isEmpty ? 0 : spacing) + s.width
            r.height = max(r.height, s.height)
            r.items.append(i)
            rows[rows.count - 1] = r
        }
        return rows.filter { !$0.items.isEmpty }
    }
}
