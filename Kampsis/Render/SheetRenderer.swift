import AppKit
import CoreVideo
import Metal
import os
import QuartzCore

private let renderLog = Logger(subsystem: "io.github.boundlessend.kampsis", category: "render")

/// параметры одного кадра эффекта
struct FoldInputs: Equatable, Sendable {
    var progress: Double
    var settings: EffectSettings
    /// оверлей проявляется в первые проценты сложения, превью всегда непрозрачно
    var fadesIn: Bool
    var reduceMotion: Bool
}

/// раскладка совпадает со структурой FoldUniforms в шейдере
private struct FoldUniforms {
    var progress: Float
    var bend: Float
    var blur: Float
    var dimming: Float
    var opacity: Float
    var flatten: Float
    var aspect: Float
    var unused: Float
}

/// кодирует кадр эффекта в буфер команд: фон, два размытия и сетку экрана
@MainActor final class FoldPainter {
    static let sheetVertexCount = 36 * 36 * 6

    private let stack: MetalStack
    let soft: GaussianPass
    let glass: GaussianPass

    init(stack: MetalStack) {
        self.stack = stack
        soft = GaussianPass(device: stack.device, downsample: 1)
        glass = GaussianPass(device: stack.device, downsample: 4)
    }

    func encode(source: any MTLTexture, sourceNumber: UInt64?, inputs: FoldInputs,
                pass: MTLRenderPassDescriptor, command: any MTLCommandBuffer, size: CGSize) -> Bool {
        let progress = Float(pacedProgress(inputs.progress, pace: inputs.settings.pace))
        let spread = progress * Float(inputs.settings.blur) * Float(source.width) / 1600
        let glassSpread = spread * (inputs.settings.look == .matte ? 72 : 54)
        guard let softened = soft.blurred(source, sigma: spread * 8, sourceNumber: sourceNumber, into: command),
              let frosted = glass.blurred(source, sigma: glassSpread, sourceNumber: sourceNumber, into: command),
              let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            soft.forgetCached()
            glass.forgetCached()
            return false
        }
        var uniforms = FoldUniforms(
            progress: progress,
            bend: Float(inputs.settings.bend),
            blur: Float(inputs.settings.blur),
            dimming: Float(inputs.settings.dimming),
            opacity: inputs.fadesIn ? min(1, Float(inputs.progress) / 0.015) : 1,
            flatten: inputs.reduceMotion ? 1 : 0,
            aspect: Float(size.width / max(1, size.height)),
            unused: 0
        )
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<FoldUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FoldUniforms>.stride, index: 0)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentTexture(softened, index: 1)
        encoder.setFragmentTexture(frosted, index: 2)
        encoder.setRenderPipelineState(stack.backdrop)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.setRenderPipelineState(stack.sheet)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: Self.sheetVertexCount)
        encoder.endEncoding()
        return true
    }

    func reset() {
        soft.reset()
        glass.reset()
    }
}

/// кадр захвата на GPU: держит буфер живым, пока текстура в работе
private final class MappedFrame: @unchecked Sendable {
    let pixels: CVPixelBuffer
    let cvTexture: CVMetalTexture
    let texture: any MTLTexture
    let number: UInt64

    init(pixels: CVPixelBuffer, cvTexture: CVMetalTexture, texture: any MTLTexture, number: UInt64) {
        self.pixels = pixels
        self.cvTexture = cvTexture
        self.texture = texture
        self.number = number
    }
}

enum SheetRendererFailure: LocalizedError {
    case textureCache(CVReturn)

    var errorDescription: String? {
        switch self {
        case let .textureCache(code): String(localized: "Couldn’t prepare screen frames for Metal (code \(code)).")
        }
    }
}

/// ведёт поверхность: берёт свежий кадр, сглаживает прогресс и засыпает, когда картинка не меняется
@MainActor final class SheetRenderer {
    /// сколько неизменных кадров ждать, прежде чем остановить display link
    static let idleDelay = 0.15
    static let maximumInFlight = 3

    var inputs: () -> FoldInputs
    var presentationLog: PresentationLog?
    let surface: MetalSurfaceView
    let painter: FoldPainter
    private(set) var drawnFrames = 0

    private let stack: MetalStack
    private let frames: FrameSlot?
    private let textureCache: CVMetalTextureCache?
    private var current: MappedFrame?
    private var smoother = ProgressSmoother.resting
    private var lastDrawn: (inputs: FoldInputs, size: CGSize, frameNumber: UInt64?)?
    private var lastChange = 0.0
    private let inFlight = DispatchSemaphore(value: SheetRenderer.maximumInFlight)

    /// `frames` отсутствует у превью: оно рисует пример рабочего стола
    init(stack: MetalStack, frames: FrameSlot?, inputs: @escaping () -> FoldInputs) throws {
        self.stack = stack
        self.frames = frames
        self.inputs = inputs
        painter = FoldPainter(stack: stack)
        if frames != nil {
            var cache: CVMetalTextureCache?
            let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, stack.device, nil, &cache)
            guard status == kCVReturnSuccess, let cache else { throw SheetRendererFailure.textureCache(status) }
            textureCache = cache
        } else {
            textureCache = nil
        }
        let displayRate = ScreenStream.builtInDisplay()?.maximumFramesPerSecond ?? 60
        surface = MetalSurfaceView(device: stack.device, preferredFramesPerSecond: min(120, displayRate))
        surface.onDrawable = { [weak self] drawable in self?.draw(to: drawable) }
        surface.onVisible = { [weak self] in self?.redraw() }
        surface.onResize = { [weak self] in self?.redraw() }
        frames?.onStore { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.wake() } }
        }
    }

    /// будит display link, если поверхность видна
    func wake() {
        guard surface.paused, surface.isOnScreen else { return }
        surface.paused = false
    }

    func reset() {
        smoother = .resting
        lastDrawn = nil
        current = nil
        painter.reset()
        if let textureCache { CVMetalTextureCacheFlush(textureCache, 0) }
    }

    private func redraw() {
        lastDrawn = nil
        wake()
    }

    private func draw(to drawable: any CAMetalDrawable) {
        guard inFlight.wait(timeout: .now()) == .success else { return }
        var submitted = false
        defer { if !submitted { inFlight.signal() } }

        let now = CACurrentMediaTime()
        let wanted = inputs()
        smoother = smoother.approaching(wanted.progress, at: now)
        var shown = wanted
        shown.progress = Double(Float(smoother.value))
        adoptLatestFrame()
        let size = surface.drawableSize
        let frameNumber = current?.number
        if let lastDrawn, lastDrawn.inputs == shown, lastDrawn.size == size, lastDrawn.frameNumber == frameNumber {
            if now - lastChange >= Self.idleDelay { surface.paused = true }
            return
        }

        let source: (any MTLTexture)?
        let sourceNumber: UInt64?
        if frames == nil {
            (source, sourceNumber) = (stack.sampleDesktop, 0)
        } else {
            (source, sourceNumber) = (current?.texture, frameNumber)
        }
        guard let source, let command = stack.queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        pass.colorAttachments[0].storeAction = .store
        guard painter.encode(source: source, sourceNumber: sourceNumber, inputs: shown,
                             pass: pass, command: command, size: size) else { return }

        let keepAlive = current
        let semaphore = inFlight
        command.addCompletedHandler { _ in
            withExtendedLifetime(keepAlive) {}
            semaphore.signal()
        }
        if let presentationLog {
            drawable.addPresentedHandler { presentationLog.record($0.presentedTime) }
        }
        command.commit()
        drawable.present()
        submitted = true
        lastDrawn = (shown, size, frameNumber)
        lastChange = now
        drawnFrames += 1
    }

    private func adoptLatestFrame() {
        guard let textureCache, let latest = frames?.latest, latest.number != current?.number else { return }
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, latest.pixels, nil, MetalStack.pixelFormat,
            CVPixelBufferGetWidth(latest.pixels), CVPixelBufferGetHeight(latest.pixels), 0, &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else {
            renderLog.warning("capture current not mapped to texture: status=\(status, privacy: .public) frame=\(latest.number, privacy: .public)")
            return
        }
        current = MappedFrame(pixels: latest.pixels, cvTexture: cvTexture, texture: texture, number: latest.number)
    }
}
