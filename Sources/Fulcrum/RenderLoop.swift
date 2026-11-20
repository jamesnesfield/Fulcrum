import FulcrumCore
import QuartzCore

/// Where finished frames go. The render thread sets the layer's contents directly, so a busy
/// main thread (inspector redraws) can't hold back the image.
final class DisplaySink: @unchecked Sendable {
    private let lock = NSLock()
    private weak var layer: CALayer?
    private var showingBefore = false

    func attach(_ layer: CALayer) { lock.lock(); self.layer = layer; lock.unlock() }

    func setShowingBefore(_ v: Bool) { lock.lock(); showingBefore = v; lock.unlock() }

    /// Called on the render thread.
    func show(_ surface: IOSurfaceRef) {
        lock.lock()
        let l = showingBefore ? nil : layer
        lock.unlock()
        guard let l else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        l.contents = surface
        CATransaction.commit()
        CATransaction.flush()
    }
}

/// Renders on its own queue, always picking up the newest request, without waiting for the main thread.
final class RenderLoop: @unchecked Sendable {
    struct Job {
        let renderer: Renderer
        let generation: Int
        let settings: EditSettings
        let overlay: UUID?
        let ranges: Bool
        let cropping: Bool
        let draft: Bool
        let tick: Int
    }
    struct Result {
        let job: Job
        var display: Renderer.Display?
        var preview: CGImage?
        var analysis: AnalysisResult?
        var error: Error?
        var shownAt: CFAbsoluteTime
    }

    private let queue: DispatchQueue
    private let sink: DisplaySink
    private let lock = NSLock()
    private var pending: Job?
    private var running = false
    private var lastAnalysis: (gen: Int, a: AnalysisResult)?
    private let deliver: (Result) -> Void

    init(queue: DispatchQueue, sink: DisplaySink, deliver: @escaping (Result) -> Void) {
        self.queue = queue; self.sink = sink; self.deliver = deliver
    }

    func submit(_ job: Job) {
        lock.lock()
        pending = job
        let start = !running
        running = true
        lock.unlock()
        if start { queue.async { self.drain() } }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let job = pending else { running = false; lock.unlock(); return }
            pending = nil
            lock.unlock()

            var r = Result(job: job, shownAt: 0)
            do {
                if job.cropping {
                    let p = try job.renderer.renderPreview(job.settings, overlayMask: job.overlay, showRanges: job.ranges)
                    r.preview = p.image; r.analysis = p.analysis
                } else {
                    let prev = lastAnalysis.flatMap { $0.gen == job.generation ? $0.a : nil }
                    let d = try job.renderer.renderDisplay(job.settings, overlayMask: job.overlay, showRanges: job.ranges,
                                                           draft: job.draft && prev != nil, previous: prev)
                    sink.show(d.surface)
                    r.display = d; r.analysis = d.analysis
                }
                if let a = r.analysis { lastAnalysis = (job.generation, a) }
            } catch {
                r.error = error
            }
            r.shownAt = CFAbsoluteTimeGetCurrent()
            deliver(r)
        }
    }
}
