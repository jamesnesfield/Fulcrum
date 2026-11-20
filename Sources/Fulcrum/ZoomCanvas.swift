import AppKit
import FulcrumCore
import SwiftUI

/// Keeps the photo centred when it's smaller than the window.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return r }
        if r.width > doc.frame.width { r.origin.x = (doc.frame.width - r.width) / 2 }
        if r.height > doc.frame.height { r.origin.y = (doc.frame.height - r.height) / 2 }
        return r
    }
}

/// Document view: 1 point = 1 preview pixel. Holds the preview layer plus a sharper full-res tile on top,
/// and, in split mode, the before image masked to the left of a draggable vertical divider.
final class PhotoDocumentView: NSView {
    let imageLayer = CALayer()
    let detailLayer = CALayer()
    let beforeLayer = CALayer()
    private let beforeMask = CALayer()
    private let dividerLayer = CALayer()
    private let vignetteLayer = CAShapeLayer()
    private let vignetteMidLayer = CAShapeLayer()      // half strength: solid
    private let vignetteFeatherLayer = CAShapeLayer()  // where it starts and where it's full: dashed
    private let vignetteClip = CALayer()               // keeps the rings on the photo
    /// The vignette's settings, to draw its boundary around the handle.
    var vignetteShape: Vignette? { didSet { if vignetteShape != oldValue { layoutVignette() } } }
    var onDoubleClick: (() -> Void)?
    var onVignetteMove: ((CGPoint) -> Void)?
    var onVignetteReset: (() -> Void)?
    /// The vignette's centre as 0–1 of the photo from the top-left, or nil to hide the handle.
    var vignetteCentre: CGPoint? { didSet { if !draggingVignette, vignetteCentre != oldValue { layoutVignette() } } }
    private var draggingVignette = false
    private var dragStart: NSPoint?

    /// Divider position as a fraction of the visible part of the photo (0 = left edge, 1 = right edge).
    var splitFraction: CGFloat = 0.5
    var splitActive = false { didSet { if splitActive != oldValue { layoutSplit() } } }
    private var draggingSplit = false
    private var dividerX: CGFloat = 0   // in document coordinates

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(imageLayer)
        layer?.addSublayer(detailLayer)
        layer?.addSublayer(beforeLayer)
        layer?.addSublayer(dividerLayer)
        vignetteClip.masksToBounds = true
        vignetteClip.addSublayer(vignetteFeatherLayer)
        vignetteClip.addSublayer(vignetteMidLayer)
        layer?.addSublayer(vignetteClip)
        layer?.addSublayer(vignetteLayer)
        for l in [vignetteMidLayer, vignetteFeatherLayer] {
            l.fillColor = nil
            l.strokeColor = NSColor.fcEngraving.cgColor
            l.shadowColor = NSColor.black.cgColor
            l.shadowOpacity = 0.6
            l.shadowRadius = 1.5
            l.shadowOffset = .zero
            l.isHidden = true
        }
        vignetteMidLayer.opacity = 0.75
        vignetteFeatherLayer.opacity = 0.4
        // Vignette centre: an engraved ring with four ticks, a constant 32 pt on screen.
        let ring = CGMutablePath()
        ring.addEllipse(in: CGRect(x: 6, y: 6, width: 20, height: 20))
        for (dx, dy) in [(0.0, -1.0), (1, 0), (0, 1), (-1, 0)] {
            ring.move(to: CGPoint(x: 16 + dx * 12, y: 16 + dy * 12))
            ring.addLine(to: CGPoint(x: 16 + dx * 16, y: 16 + dy * 16))
        }
        ring.addEllipse(in: CGRect(x: 14.5, y: 14.5, width: 3, height: 3))
        vignetteLayer.bounds = CGRect(x: 0, y: 0, width: 32, height: 32)
        vignetteLayer.path = ring
        vignetteLayer.fillColor = nil
        vignetteLayer.strokeColor = NSColor.fcEngraving.cgColor
        vignetteLayer.lineWidth = 1.5
        vignetteLayer.shadowColor = NSColor.black.cgColor
        vignetteLayer.shadowOpacity = 0.7
        vignetteLayer.shadowRadius = 2
        vignetteLayer.shadowOffset = CGSize(width: 0, height: 1)
        vignetteLayer.isHidden = true
        beforeLayer.magnificationFilter = .linear
        beforeLayer.minificationFilter = .trilinear
        beforeMask.backgroundColor = NSColor.black.cgColor
        beforeLayer.mask = beforeMask
        dividerLayer.backgroundColor = NSColor.fcEngraving.cgColor
        dividerLayer.shadowColor = NSColor.black.cgColor
        dividerLayer.shadowOpacity = 0.6
        dividerLayer.shadowRadius = 2
        dividerLayer.shadowOffset = .zero
        for l in [beforeLayer, dividerLayer] { l.isHidden = true }
        imageLayer.magnificationFilter = .linear
        imageLayer.minificationFilter = .trilinear
        detailLayer.magnificationFilter = .nearest     // at deep zoom, show real pixels
        imageLayer.shadowColor = NSColor.black.cgColor
        imageLayer.shadowOpacity = 0.5
        imageLayer.shadowRadius = 12
        imageLayer.shadowOffset = .zero
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        CATransaction.commit()
        layoutSplit()
        layoutVignette()
    }

    /// Places the vignette handle; it stays the same size on screen at any zoom.
    func layoutVignette() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let c = vignetteCentre, bounds.width > 0 else {
            for l in [vignetteLayer, vignetteMidLayer, vignetteFeatherLayer] { l.isHidden = true }
            return
        }
        vignetteLayer.isHidden = false
        vignetteLayer.position = CGPoint(x: c.x * bounds.width, y: c.y * bounds.height)
        vignetteLayer.transform = CATransform3DMakeScale(1 / magnification, 1 / magnification, 1)
        drawVignetteBoundary(c)
        window?.invalidateCursorRects(for: self)
    }

    /// The vignette's boundary around the handle: a solid ring where it is half strength, and dashed
    /// rings where it starts and where it reaches full strength. Hairlines at any zoom.
    private func drawVignetteBoundary(_ c: CGPoint) {
        guard let v = vignetteShape else {
            vignetteMidLayer.isHidden = true; vignetteFeatherLayer.isHidden = true; return
        }
        vignetteClip.frame = bounds
        let b = v.boundaries(in: bounds.size)
        let p = CGPoint(x: c.x * bounds.width, y: c.y * bounds.height)
        func ellipse(_ s: CGSize) -> CGRect { CGRect(x: p.x - s.width, y: p.y - s.height, width: s.width * 2, height: s.height * 2) }
        let m = magnification
        vignetteMidLayer.path = CGPath(ellipseIn: ellipse(b.mid), transform: nil)
        let feather = CGMutablePath()
        if b.start.width > 1 { feather.addEllipse(in: ellipse(b.start)) }
        feather.addEllipse(in: ellipse(b.full))
        vignetteFeatherLayer.path = feather
        vignetteMidLayer.lineWidth = 1 / m
        vignetteFeatherLayer.lineWidth = 1 / m
        vignetteFeatherLayer.lineDashPattern = [NSNumber(value: Double(4 / m)), NSNumber(value: Double(4 / m))]
        vignetteMidLayer.isHidden = false
        vignetteFeatherLayer.isHidden = false
    }

    private var vignetteHitRect: CGRect? {
        guard let c = vignetteCentre else { return nil }
        let r = 18 / magnification
        return CGRect(x: c.x * bounds.width - r, y: c.y * bounds.height - r, width: r * 2, height: r * 2)
    }

    private var magnification: CGFloat { max(enclosingScrollView?.magnification ?? 1, 0.0001) }

    /// The part of the photo currently on screen, in document coordinates.
    private var visiblePhoto: CGRect {
        guard let clip = enclosingScrollView?.contentView else { return bounds }
        let v = clip.bounds.intersection(bounds)
        return v.isNull || v.width < 1 ? bounds : v
    }

    /// Positions the before mask and divider. Called on scroll, zoom, resize and drag.
    func layoutSplit() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let on = splitActive && bounds.width > 0
        for l in [beforeLayer, dividerLayer] { l.isHidden = !on }
        guard on else { window?.invalidateCursorRects(for: self); return }
        let vis = visiblePhoto
        let m = magnification
        dividerX = vis.minX + min(max(splitFraction, 0), 1) * vis.width
        beforeLayer.frame = bounds
        beforeMask.frame = CGRect(x: 0, y: 0, width: dividerX, height: bounds.height)
        // Keep the divider a constant on-screen width whatever the zoom; the whole line is the handle.
        let line = 2 / m
        dividerLayer.frame = CGRect(x: dividerX - line / 2, y: 0, width: line, height: bounds.height)
        window?.invalidateCursorRects(for: self)
    }

    private var dividerHitRect: CGRect {
        let slop = 12 / magnification
        return CGRect(x: dividerX - slop, y: bounds.minY, width: slop * 2, height: bounds.height)
    }

    override func resetCursorRects() {
        if splitActive { addCursorRect(dividerHitRect, cursor: .resizeLeftRight) }
        if let r = vignetteHitRect { addCursorRect(r, cursor: .openHand) }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let r = vignetteHitRect, r.contains(p) {
            if event.clickCount == 2 { onVignetteReset?(); return }
            draggingVignette = true
            NSCursor.closedHand.push()
            return
        }
        if splitActive, dividerHitRect.contains(p) {
            draggingSplit = true
            NSCursor.resizeLeftRight.push()
            return
        }
        if event.clickCount == 2 { onDoubleClick?(); return }
        dragStart = event.locationInWindow
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        if draggingVignette {
            let p = convert(event.locationInWindow, from: nil)
            let c = CGPoint(x: min(max(p.x / max(bounds.width, 1), 0), 1), y: min(max(p.y / max(bounds.height, 1), 0), 1))
            vignetteCentre = c
            CATransaction.begin(); CATransaction.setDisableActions(true)
            vignetteLayer.position = CGPoint(x: c.x * bounds.width, y: c.y * bounds.height)
            drawVignetteBoundary(c)
            CATransaction.commit()
            onVignetteMove?(c)
            return
        }
        if draggingSplit {
            let p = convert(event.locationInWindow, from: nil)
            let vis = visiblePhoto
            splitFraction = min(max((p.x - vis.minX) / max(vis.width, 1), 0), 1)
            layoutSplit()
            return
        }
        guard let start = dragStart, let clip = enclosingScrollView?.contentView else { return }
        let now = event.locationInWindow
        let m = enclosingScrollView?.magnification ?? 1
        var o = clip.bounds.origin
        o.x -= (now.x - start.x) / m
        o.y += (now.y - start.y) / m
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: o, size: clip.bounds.size)).origin)
        enclosingScrollView?.reflectScrolledClipView(clip)
        dragStart = now
    }

    override func mouseUp(with event: NSEvent) {
        if draggingVignette { draggingVignette = false; NSCursor.pop(); layoutVignette(); return }
        if draggingSplit { draggingSplit = false; NSCursor.pop(); return }
        if dragStart != nil { NSCursor.pop() }
        dragStart = nil
    }
}

struct ZoomCanvas: NSViewRepresentable {
    let content: AnyObject             // IOSurface frame (or CGImage for the before view)
    let showingBefore: Bool
    let splitBefore: CGImage?          // when set, show before/after split with this as the before
    let sink: DisplaySink
    let logicalSize: CGSize            // full-quality preview size; drafts are stretched to fill it
    let detail: AppModel.DetailTile?
    let fullPixelSize: CGSize          // edited output at full resolution
    let resetToken: AnyHashable        // changes when a different photo / crop is shown → zoom to fit
    let onNeedDetail: (CGRect, CGSize) -> Void
    /// Zoom as screen pixels per full-resolution pixel (1 = 100%), and whether the photo is fitted.
    var onZoom: (Double, Bool) -> Void = { _, _ in }
    /// Vignette centre handle (0–1 from top-left) or nil; dragging it reports new positions.
    var vignetteCentre: CGPoint? = nil
    var vignetteShape: Vignette? = nil
    var onVignetteMove: (CGPoint) -> Void = { _ in }
    var onVignetteReset: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSScrollView()
        sv.contentView = CenteringClipView()
        sv.drawsBackground = false
        sv.contentView.drawsBackground = false
        sv.hasHorizontalScroller = true
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        sv.scrollerStyle = .overlay
        sv.allowsMagnification = true
        sv.maxMagnification = 16
        let doc = PhotoDocumentView(frame: .zero)
        sv.documentView = doc
        sv.contentView.postsBoundsChangedNotifications = true
        sv.postsFrameChangedNotifications = true
        let c = context.coordinator
        c.scrollView = sv
        c.doc = doc
        sink.attach(doc.imageLayer)
        doc.onDoubleClick = { [weak c] in c?.toggleZoom() }
        NotificationCenter.default.addObserver(c, selector: #selector(Coordinator.boundsChanged),
                                               name: NSView.boundsDidChangeNotification, object: sv.contentView)
        NotificationCenter.default.addObserver(c, selector: #selector(Coordinator.frameChanged),
                                               name: NSView.frameDidChangeNotification, object: sv)
        NotificationCenter.default.addObserver(c, selector: #selector(Coordinator.magnifyEnded),
                                               name: NSScrollView.didEndLiveMagnifyNotification, object: sv)
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        guard let doc = c.doc else { return }
        let size = logicalSize
        let sizeChanged = doc.frame.size != size
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if sizeChanged { doc.frame = CGRect(origin: .zero, size: size) }
        sink.setShowingBefore(showingBefore)
        doc.imageLayer.contents = content
        doc.beforeLayer.contents = splitBefore
        doc.splitActive = splitBefore != nil
        doc.onVignetteMove = onVignetteMove
        doc.onVignetteReset = onVignetteReset
        doc.vignetteShape = vignetteShape
        doc.vignetteCentre = vignetteCentre
        if let d = detail {
            doc.detailLayer.isHidden = false
            doc.detailLayer.contents = d.image
            doc.detailLayer.frame = CGRect(x: d.region.minX * size.width, y: d.region.minY * size.height,
                                           width: d.region.width * size.width, height: d.region.height * size.height)
        } else {
            doc.detailLayer.isHidden = true
            doc.detailLayer.contents = nil
        }
        CATransaction.commit()
        if c.resetToken != resetToken || sizeChanged {
            c.resetToken = resetToken
            c.isFit = true
        }
        c.updateFit()
        if detail == nil { c.scheduleDetail() }
    }

    final class Coordinator: NSObject {
        var parent: ZoomCanvas?
        weak var scrollView: NSScrollView?
        weak var doc: PhotoDocumentView?
        var resetToken: AnyHashable?
        var isFit = true
        private var detailTimer: Timer?
        private var lastZoom: (Double, Bool)?

        /// Reports zoom to SwiftUI after the current update, and only when the shown figure changes.
        func reportZoom() {
            guard let sv = scrollView, let doc, let p = parent, p.fullPixelSize.width > 0, doc.frame.width > 0 else { return }
            let backing = sv.window?.backingScaleFactor ?? 2
            let z = Double(sv.magnification * backing * doc.frame.width / p.fullPixelSize.width)
            let zoom = (z * 100).rounded() / 100, fit = isFit
            if let l = lastZoom, abs(l.0 - zoom) < 0.005, l.1 == fit { return }
            lastZoom = (zoom, fit)
            DispatchQueue.main.async { p.onZoom(zoom, fit) }
        }

        var fitMagnification: CGFloat {
            guard let sv = scrollView, let doc, doc.frame.width > 0 else { return 1 }
            let v = sv.contentView.frame.size
            return max(0.01, min((v.width - 48) / doc.frame.width, (v.height - 48) / doc.frame.height))
        }

        func updateFit() {
            guard let sv = scrollView else { return }
            let fit = fitMagnification
            sv.minMagnification = min(fit, 1)
            if isFit, abs(sv.magnification - fit) > 0.0001 { sv.magnification = fit }
            reportZoom()
        }

        /// Double-click: fit ↔ 100% (one full-resolution pixel per screen pixel), centred on the click.
        func toggleZoom() {
            guard let sv = scrollView, let doc, let p = parent else { return }
            if isFit {
                let backing = sv.window?.backingScaleFactor ?? 2
                let actual = (p.fullPixelSize.width / max(doc.frame.width, 1)) / backing
                let target = max(actual, fitMagnification * 2)
                let mouse = sv.window.map { doc.convert($0.mouseLocationOutsideOfEventStream, from: nil) }
                    ?? CGPoint(x: doc.bounds.midX, y: doc.bounds.midY)
                isFit = false
                sv.animator().setMagnification(min(target, sv.maxMagnification), centeredAt: mouse)
            } else {
                isFit = true
                sv.animator().magnification = fitMagnification
            }
            scheduleDetail()
        }

        @objc func boundsChanged() { doc?.layoutSplit(); doc?.layoutVignette(); reportZoom(); scheduleDetail() }
        @objc func frameChanged() { updateFit(); doc?.layoutSplit(); scheduleDetail() }
        @objc func magnifyEnded() {
            guard let sv = scrollView else { return }
            isFit = sv.magnification <= fitMagnification * 1.02
            if isFit { sv.animator().magnification = fitMagnification }
            reportZoom()
            scheduleDetail()
        }

        func scheduleDetail() {
            detailTimer?.invalidate()
            detailTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in self?.requestDetail() }
        }

        /// When the screen shows more pixels than the preview has, fetch the visible region at full resolution.
        private func requestDetail() {
            guard let sv = scrollView, let doc, let p = parent, doc.frame.width > 0 else { return }
            let backing = sv.window?.backingScaleFactor ?? 2
            let screenPxPerPreviewPx = sv.magnification * backing
            let fullPxPerPreviewPx = p.fullPixelSize.width / doc.frame.width
            guard screenPxPerPreviewPx > 1.15, fullPxPerPreviewPx > 1.15 else { return }
            let visible = sv.contentView.bounds.intersection(doc.bounds)
            guard visible.width > 1, visible.height > 1 else { return }
            // Pad a little so small pans don't immediately expose the soft preview.
            let pad = visible.insetBy(dx: -visible.width * 0.15, dy: -visible.height * 0.15).intersection(doc.bounds)
            let region = CGRect(x: pad.minX / doc.frame.width, y: pad.minY / doc.frame.height,
                                width: pad.width / doc.frame.width, height: pad.height / doc.frame.height)
            let px = CGSize(width: min(pad.width * screenPxPerPreviewPx, 5000), height: min(pad.height * screenPxPerPreviewPx, 5000))
            if let d = p.detail, d.region.contains(region.insetBy(dx: region.width * 0.1, dy: region.height * 0.1)),
               CGFloat(d.image.width) >= px.width * 0.8 || CGFloat(d.image.width) >= region.width * p.fullPixelSize.width * 0.98 {
                return   // current tile already covers this view sharply enough
            }
            p.onNeedDetail(region, px)
        }
    }
}
