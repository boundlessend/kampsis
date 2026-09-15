import AppKit
import os
import QuartzCore
import SwiftUI

/// живой предпросмотр эффекта на примере рабочего стола
struct PreviewPane: NSViewRepresentable {
    let state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeCoordinator() -> Result<SheetRenderer, any Error> {
        MetalStack.shared.flatMap { stack in
            Result {
                try SheetRenderer(stack: stack, frames: nil) {
                    FoldInputs(progress: 0, settings: .standard, fadesIn: false, reduceMotion: false)
                }
            }
        }
    }

    func makeNSView(context: Context) -> NSView {
        switch context.coordinator {
        case let .success(renderer):
            return renderer.surface
        case let .failure(error):
            let label = NSTextField(wrappingLabelWithString: error.localizedDescription)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            return label
        }
    }

    /// чтение свойств состояния здесь подписывает превью на их изменения
    func updateNSView(_ view: NSView, context: Context) {
        guard case let .success(renderer) = context.coordinator else { return }
        let settings = state.settings
        let usesLid = state.previewUsesLid
        let manualAngle = state.previewAngle
        let measuredAngle = state.measuredAngle
        let reduceMotion = reduceMotion
        renderer.inputs = { [state] in
            let liveAngle = usesLid ? (state.lidEstimate.degrees(at: CACurrentMediaTime()) ?? measuredAngle) : nil
            return FoldInputs(
                progress: previewProgress(usesLid: usesLid, manualAngle: manualAngle,
                                          liveAngle: liveAngle, fadeOutAngle: settings.fadeOutAngle),
                settings: settings, fadesIn: false, reduceMotion: reduceMotion
            )
        }
        renderer.wake()
    }

    static func dismantleNSView(_ view: NSView, coordinator: Result<SheetRenderer, any Error>) {
        guard case let .success(renderer) = coordinator else { return }
        renderer.surface.paused = true
        renderer.reset()
    }
}

enum ThumbnailFailure: LocalizedError {
    case noTarget
    case gpu(String)

    var errorDescription: String? {
        switch self {
        case .noTarget: String(localized: "Couldn’t prepare the style thumbnail.")
        case let .gpu(detail): String(localized: "The style thumbnail failed to render: \(detail)")
        }
    }
}

/// миниатюры стилей рисуются тем же шейдером, что и эффект
@MainActor enum StyleThumbnails {
    static let width = 320
    static let height = 200
    static let progress = 0.32

    private static let log = Logger(subsystem: "io.github.boundlessend.lidfold", category: "thumbnails")
    private static var cache: [Look: NSImage] = [:]

    /// для интерфейса: при сбое пишет в лог и возвращает nil, плитка покажет заглушку
    static func imageOrNil(for look: Look) -> NSImage? {
        do {
            return try image(for: look)
        } catch {
            log.error("thumbnail failed: look=\(look.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func image(for look: Look) throws -> NSImage {
        if let cached = cache[look] { return cached }
        let stack = try MetalStack.shared.get()
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: MetalStack.pixelFormat,
                                                                  width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .renderTarget
        guard let target = stack.device.makeTexture(descriptor: descriptor),
              let command = stack.queue.makeCommandBuffer() else { throw ThumbnailFailure.noTarget }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let inputs = FoldInputs(progress: progress, settings: EffectSettings.standard.applying(look),
                                fadesIn: false, reduceMotion: false)
        guard FoldPainter(stack: stack).encode(source: stack.sampleDesktop, sourceNumber: nil, inputs: inputs, pass: pass,
                                               command: command, size: CGSize(width: width, height: height)) else {
            throw ThumbnailFailure.noTarget
        }
        command.commit()
        command.waitUntilCompleted()
        if let error = command.error { throw ThumbnailFailure.gpu(error.localizedDescription) }
        let image = NSImage(cgImage: try readImage(target), size: NSSize(width: width, height: height))
        cache[look] = image
        return image
    }

    private static func readImage(_ texture: any MTLTexture) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            texture.getBytes(base, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                                      .union(.byteOrder32Little),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw ThumbnailFailure.noTarget
        }
        return image
    }
}
