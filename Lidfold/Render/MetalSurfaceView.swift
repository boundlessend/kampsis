import AppKit
import QuartzCore

/// слой Metal, который получает drawable от CAMetalDisplayLink и спит, пока окно не видно
@MainActor final class MetalSurfaceView: NSView {
    var onDrawable: ((any CAMetalDrawable) -> Void)?
    var onVisible: (() -> Void)?
    var onResize: (() -> Void)?
    var preferredFramesPerSecond: Int {
        didSet { applyFrameRate() }
    }

    private let metalLayer = CAMetalLayer()
    private var link: CAMetalDisplayLink?
    private var occlusionObserver: (any NSObjectProtocol)?

    init(device: any MTLDevice, preferredFramesPerSecond: Int) {
        self.preferredFramesPerSecond = preferredFramesPerSecond
        super.init(frame: .zero)
        metalLayer.device = device
        metalLayer.pixelFormat = MetalStack.pixelFormat
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = false
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("MetalSurfaceView создаётся только кодом") }

    isolated deinit {
        link?.invalidate()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
    }

    override func makeBackingLayer() -> CALayer { metalLayer }

    var drawableSize: CGSize { metalLayer.drawableSize }

    /// пока `true`, кадры не запрашиваются
    var paused: Bool {
        get { link?.isPaused ?? true }
        set { link?.isPaused = newValue }
    }

    var isOnScreen: Bool {
        guard let window else { return false }
        return window.isVisible && window.occlusionState.contains(.visible)
    }

    override func layout() {
        super.layout()
        syncDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncDrawableSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        guard let window else { return }

        syncDrawableSize()
        let link = CAMetalDisplayLink(metalLayer: metalLayer)
        link.delegate = self
        link.preferredFrameLatency = 2
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        self.link = link
        applyFrameRate()
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.visibilityChanged() }
        }
        visibilityChanged()
    }

    private func visibilityChanged() {
        if isOnScreen {
            onVisible?()
        } else {
            paused = true
        }
    }

    private func applyFrameRate() {
        let screenLimit = window?.screen?.maximumFramesPerSecond ?? preferredFramesPerSecond
        let rate = Float(min(preferredFramesPerSecond, screenLimit))
        link?.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
    }

    private func syncDrawableSize() {
        guard let window else { return }
        let scale = window.backingScaleFactor
        metalLayer.contentsScale = scale
        let size = CGSize(width: max(1, (bounds.width * scale).rounded()), height: max(1, (bounds.height * scale).rounded()))
        guard metalLayer.drawableSize != size else { return }
        metalLayer.drawableSize = size
        onResize?()
    }
}

extension MetalSurfaceView: @preconcurrency CAMetalDisplayLinkDelegate {
    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        onDrawable?(update.drawable)
    }
}
