import FulcrumCore
import SwiftUI

/// Crop ratios, written landscape-first ("3:2"); the orientation toggle flips them.
struct CropAspect: Identifiable, Hashable {
    let id: String
    let label: String
    let w: Double
    let h: Double

    static let all: [CropAspect] = [
        CropAspect(id: "free", label: "Free", w: 0, h: 0),
        CropAspect(id: "original", label: "Original", w: 0, h: 0),
        CropAspect(id: "1:1", label: "1 : 1  Square", w: 1, h: 1),
        CropAspect(id: "5:4", label: "5 : 4  (8×10)", w: 5, h: 4),
        CropAspect(id: "4:3", label: "4 : 3", w: 4, h: 3),
        CropAspect(id: "7:5", label: "7 : 5  (5×7)", w: 7, h: 5),
        CropAspect(id: "3:2", label: "3 : 2  (35mm, 4×6)", w: 3, h: 2),
        CropAspect(id: "16:9", label: "16 : 9  Widescreen", w: 16, h: 9),
        CropAspect(id: "1.91:1", label: "1.91 : 1  Social landscape", w: 1.91, h: 1),
        CropAspect(id: "65:24", label: "65 : 24  Panoramic", w: 65, h: 24),
    ]

    static func find(_ id: String) -> CropAspect { all.first { $0.id == id } ?? all[0] }

    /// "4:5" → ("5:4", portrait). Stored ids are landscape; portrait ones are written reversed.
    static func parse(_ s: String) -> (id: String, portrait: Bool) {
        if s.hasSuffix("-p") { return (String(s.dropLast(2)), true) }
        return (all.contains { $0.id == s } ? s : "free", false)
    }
    static func encode(_ id: String, portrait: Bool) -> String { portrait && id != "free" && id != "1:1" ? id + "-p" : id }

    /// Pixel aspect (w/h) or nil for free.
    func ratio(portrait: Bool, imageAspect: Double) -> Double? {
        switch id {
        case "free": return nil
        case "original": return portrait == (imageAspect >= 1) ? 1 / imageAspect : imageAspect
        default: return portrait ? h / w : w / h
        }
    }

    func displayLabel(portrait: Bool) -> String {
        guard w > 0, w != h, portrait else { return label }
        let a = id.split(separator: ":")
        return a.count == 2 ? "\(a[1]) : \(a[0])" : label
    }
}

struct CropEditor: View {
    @EnvironmentObject var model: AppModel
    let image: CGImage

    private enum Handle { case move, left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight }
    @State private var active: Handle?
    @State private var startRect = CropRect()
    @State private var startPoint = CGPoint.zero

    private var aspect: CropAspect { CropAspect.find(model.cropAspectID) }
    private var ratio: Double? { aspect.ratio(portrait: model.cropPortrait, imageAspect: k) }
    /// image pixel aspect
    private var k: Double { Double(image.width) / Double(image.height) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            GeometryReader { geo in
                let d = fitRect(in: geo.size)
                let r = model.cropDraft
                let cr = CGRect(x: d.minX + r.x * d.width, y: d.minY + r.y * d.height, width: r.w * d.width, height: r.h * d.height)
                ZStack(alignment: .topLeading) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .frame(width: d.width, height: d.height)
                        .offset(x: d.minX, y: d.minY)
                    // dim outside the crop
                    Path { p in p.addRect(d); p.addRect(cr) }
                        .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
                    // rule of thirds
                    Path { p in
                        for i in 1...2 {
                            let x = cr.minX + cr.width * CGFloat(i) / 3, y = cr.minY + cr.height * CGFloat(i) / 3
                            p.move(to: CGPoint(x: x, y: cr.minY)); p.addLine(to: CGPoint(x: x, y: cr.maxY))
                            p.move(to: CGPoint(x: cr.minX, y: y)); p.addLine(to: CGPoint(x: cr.maxX, y: y))
                        }
                    }
                    .stroke(Color.white.opacity(active == nil ? 0.25 : 0.55), lineWidth: 0.8)
                    Rectangle().path(in: cr).stroke(Color.white, lineWidth: 1.5)
                    handles(cr)
                    Text("\(Int(r.w * Double(model.sourcePixelSize.width))) × \(Int(r.h * Double(model.sourcePixelSize.height)))")
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                        .offset(x: cr.minX + 6, y: cr.maxY + 6)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .local)
                    .onChanged { g in drag(g, d: d, cr: cr) }
                    .onEnded { _ in active = nil })
            }
            .padding(24)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "crop").foregroundStyle(.secondary)
            Picker("Aspect", selection: Binding(get: { model.cropAspectID }, set: { setAspect($0) })) {
                ForEach(CropAspect.all) { a in Text(a.displayLabel(portrait: model.cropPortrait)).tag(a.id) }
            }
            .labelsHidden()
            .frame(width: 220)
            Button {
                model.cropPortrait.toggle(); setAspect(model.cropAspectID)
            } label: {
                Image(systemName: model.cropPortrait ? "rectangle.portrait" : "rectangle")
            }
            .help("Swap portrait / landscape (X)")
            .keyboardShortcut("x", modifiers: [])
            .disabled(model.cropAspectID == "free" || model.cropAspectID == "1:1")
            Button("Reset") { model.cropDraft = CropRect(); model.cropAspectID = "free"; model.cropPortrait = false }
            Spacer()
            Button("Cancel") { model.cancelCrop() }.keyboardShortcut(.cancelAction)
            Button("Done") { model.commitCrop() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
        }
        .controlSize(.regular)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder private func handles(_ cr: CGRect) -> some View {
        let pts = [CGPoint(x: cr.minX, y: cr.minY), CGPoint(x: cr.maxX, y: cr.minY),
                   CGPoint(x: cr.minX, y: cr.maxY), CGPoint(x: cr.maxX, y: cr.maxY)]
        ForEach(0..<4, id: \.self) { i in
            Rectangle().fill(.white).frame(width: 10, height: 10)
                .offset(x: pts[i].x - 5, y: pts[i].y - 5)
        }
        let mids = [CGPoint(x: cr.midX, y: cr.minY), CGPoint(x: cr.midX, y: cr.maxY),
                    CGPoint(x: cr.minX, y: cr.midY), CGPoint(x: cr.maxX, y: cr.midY)]
        ForEach(0..<4, id: \.self) { i in
            Rectangle().fill(.white).frame(width: i < 2 ? 18 : 4, height: i < 2 ? 4 : 18)
                .offset(x: mids[i].x - (i < 2 ? 9 : 2), y: mids[i].y - (i < 2 ? 2 : 9))
        }
    }

    private func fitRect(in s: CGSize) -> CGRect {
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        let sc = min(s.width / iw, s.height / ih)
        let w = iw * sc, h = ih * sc
        return CGRect(x: (s.width - w) / 2, y: (s.height - h) / 2, width: w, height: h)
    }

    private func hit(_ p: CGPoint, _ cr: CGRect) -> Handle? {
        let t: CGFloat = 14
        let nearL = abs(p.x - cr.minX) < t, nearR = abs(p.x - cr.maxX) < t
        let nearT = abs(p.y - cr.minY) < t, nearB = abs(p.y - cr.maxY) < t
        let inX = p.x > cr.minX - t && p.x < cr.maxX + t, inY = p.y > cr.minY - t && p.y < cr.maxY + t
        if nearL && nearT { return .topLeft }
        if nearR && nearT { return .topRight }
        if nearL && nearB { return .bottomLeft }
        if nearR && nearB { return .bottomRight }
        if nearL && inY { return .left }
        if nearR && inY { return .right }
        if nearT && inX { return .top }
        if nearB && inX { return .bottom }
        if cr.contains(p) { return .move }
        return nil
    }

    private func drag(_ g: DragGesture.Value, d: CGRect, cr: CGRect) {
        if active == nil {
            guard let h = hit(g.startLocation, cr) else { return }
            active = h
            startRect = model.cropDraft
            startPoint = g.startLocation
        }
        guard let h = active else { return }
        let p = CGPoint(x: min(max((g.location.x - d.minX) / d.width, 0), 1),
                        y: min(max((g.location.y - d.minY) / d.height, 0), 1))
        var r = startRect
        let minS = 0.03
        // normalised height for a normalised width at the locked ratio
        func hFor(_ w: Double, _ a: Double) -> Double { w * k / a }
        func wFor(_ h: Double, _ a: Double) -> Double { h * a / k }

        switch h {
        case .move:
            let dx = (g.location.x - startPoint.x) / d.width, dy = (g.location.y - startPoint.y) / d.height
            r.x = min(max(startRect.x + dx, 0), 1 - r.w)
            r.y = min(max(startRect.y + dy, 0), 1 - r.h)

        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            let ax = (h == .topLeft || h == .bottomLeft) ? startRect.x + startRect.w : startRect.x
            let ay = (h == .topLeft || h == .topRight) ? startRect.y + startRect.h : startRect.y
            let sx: Double = p.x >= ax ? 1 : -1, sy: Double = p.y >= ay ? 1 : -1
            var w = max(abs(p.x - ax), minS), hh = max(abs(p.y - ay), minS)
            if let a = ratio {
                w = max(w, wFor(hh, a)); hh = hFor(w, a)
                let roomX = sx > 0 ? 1 - ax : ax, roomY = sy > 0 ? 1 - ay : ay
                if w > roomX { w = roomX; hh = hFor(w, a) }
                if hh > roomY { hh = roomY; w = wFor(hh, a) }
            }
            r.w = w; r.h = hh
            r.x = sx > 0 ? ax : ax - w
            r.y = sy > 0 ? ay : ay - hh

        case .left, .right:
            let fixed = h == .left ? startRect.x + startRect.w : startRect.x
            var w = max(h == .left ? fixed - p.x : p.x - fixed, minS)
            r.w = w; r.x = h == .left ? fixed - w : fixed
            if let a = ratio {
                let cy = startRect.y + startRect.h / 2
                var hh = hFor(w, a)
                let maxH = 2 * min(cy, 1 - cy)
                if hh > maxH { hh = maxH; w = wFor(hh, a); r.w = w; r.x = h == .left ? fixed - w : fixed }
                r.h = hh; r.y = cy - hh / 2
            }

        case .top, .bottom:
            let fixed = h == .top ? startRect.y + startRect.h : startRect.y
            var hh = max(h == .top ? fixed - p.y : p.y - fixed, minS)
            r.h = hh; r.y = h == .top ? fixed - hh : fixed
            if let a = ratio {
                let cx = startRect.x + startRect.w / 2
                var w = wFor(hh, a)
                let maxW = 2 * min(cx, 1 - cx)
                if w > maxW { w = maxW; hh = hFor(w, a); r.h = hh; r.y = h == .top ? fixed - hh : fixed }
                r.w = w; r.x = cx - w / 2
            }
        }
        model.cropDraft = clamp(r)
    }

    private func clamp(_ r: CropRect) -> CropRect {
        var r = r
        r.w = min(max(r.w, 0.01), 1); r.h = min(max(r.h, 0.01), 1)
        r.x = min(max(r.x, 0), 1 - r.w); r.y = min(max(r.y, 0), 1 - r.h)
        return r
    }

    /// Picking a ratio: largest crop of that shape, centred on the current crop.
    private func setAspect(_ id: String) {
        model.cropAspectID = id
        guard let a = CropAspect.find(id).ratio(portrait: model.cropPortrait, imageAspect: k) else { return }
        var w = 1.0, h = k / a
        if h > 1 { h = 1; w = a / k }
        let c = model.cropDraft
        let cx = c.x + c.w / 2, cy = c.y + c.h / 2
        model.cropDraft = clamp(CropRect(x: cx - w / 2, y: cy - h / 2, w: w, h: h))
    }
}
