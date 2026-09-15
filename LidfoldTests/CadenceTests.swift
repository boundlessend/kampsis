import AppKit
import CoreVideo
import Metal
import MetalKit
import Testing
@testable import Lidfold

/// плавность на реальном встроенном экране: запускается только на MacBook, анимация закрывает экран на ~10 с
@MainActor @Suite(.serialized) struct CadenceTests {
    private let stack: MetalStack

    init() throws {
        stack = try MetalStack.shared.get()
    }

    private func desktopPixels(width: Int, height: Int) throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                         [kCVPixelBufferMetalCompatibilityKey: true,
                                          kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &created)
        #expect(status == kCVReturnSuccess)
        let buffer = try #require(created)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let context = try #require(CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                             bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                 | CGBitmapInfo.byteOrder32Little.rawValue))
        context.draw(try drawSampleDesktop(), in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    /// `freshFrames` имитирует захват 60 кадров в секунду во время анимации
    @Test(arguments: [false, true])
    func overlayPresentsSteadilyAtDisplayRate(freshFrames: Bool) async throws {
        let screen = try #require(ScreenStream.builtInDisplay(), "нужен встроенный экран MacBook")
        let frames = FrameSlot()
        let pixels = try desktopPixels(width: 2560, height: 1662)
        frames.store(pixels)
        let feeder = Task { @MainActor in
            guard freshFrames else { return }
            while !Task.isCancelled {
                frames.store(pixels)
                try await Task.sleep(for: .seconds(1.0 / 60))
            }
        }
        defer { feeder.cancel() }

        let settings = EffectSettings.standard.applying(.matte)
        let began = CACurrentMediaTime()
        let renderer = try SheetRenderer(stack: stack, frames: frames) {
            let phase = sin((CACurrentMediaTime() - began) / 4 * .pi)
            return FoldInputs(progress: 0.1 + 0.8 * phase * phase, settings: settings, fadesIn: true, reduceMotion: false)
        }
        let log = PresentationLog()
        renderer.presentationLog = log
        let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = renderer.surface
        panel.orderFrontRegardless()
        defer { renderer.surface.paused = true; panel.orderOut(nil) }

        let warmUp = CACurrentMediaTime() + 10
        while log.summary().samples < 2, CACurrentMediaTime() < warmUp {
            renderer.wake()
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .seconds(2))
        let before = log.summary().frames
        try await Task.sleep(for: .seconds(6))
        let summary = log.summary()
        let rate = Double(min(renderer.surface.preferredFramesPerSecond, screen.maximumFramesPerSecond))
        print("CADENCE fresh=\(freshFrames) rate=\(rate) \(summary)")
        #expect(summary.frames - before > Int(rate * 6 * 0.9), "кадров меньше 90% от частоты экрана")
        let gapP95 = try #require(summary.gapP95Milliseconds)
        let gapMax = try #require(summary.gapMaxMilliseconds)
        #expect(gapP95 < 1000 / rate * 1.2, "показ кадров дёргается")
        #expect(gapMax < 50, "длинная пауза прячется за средним fps")
    }

    @Test func encodingMovingFrostFitsFrameBudget() throws {
        let desktop = try MTKTextureLoader(device: stack.device).newTexture(
            cgImage: try drawSampleDesktop(), options: [.SRGB: true, .textureUsage: MTLTextureUsage.shaderRead.rawValue])
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: MetalStack.pixelFormat,
                                                                  width: 3456, height: 2234, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = .renderTarget
        let target = try #require(stack.device.makeTexture(descriptor: descriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let painter = FoldPainter(stack: stack)
        let settings = EffectSettings.standard.applying(.matte)
        var encodeMilliseconds: [Double] = []
        for frame in 0..<240 {
            let phase = sin(Double(frame) / 239 * .pi)
            let inputs = FoldInputs(progress: 0.05 + 0.9 * phase * phase, settings: settings, fadesIn: true, reduceMotion: false)
            let encodeStart = CACurrentMediaTime()
            let command = try #require(stack.queue.makeCommandBuffer())
            #expect(painter.encode(source: desktop, sourceNumber: 1, inputs: inputs, pass: pass, command: command,
                                   size: CGSize(width: 3456, height: 2234)))
            encodeMilliseconds.append((CACurrentMediaTime() - encodeStart) * 1000)
            command.commit()
            command.waitUntilCompleted()
            #expect(command.error == nil)
        }
        let ordered = encodeMilliseconds.dropFirst().sorted()
        print("ENCODE cpuP50=\(percentile(ordered, 0.5)) cpuP95=\(percentile(ordered, 0.95)) cpuMax=\(ordered.last!)")
        #expect(percentile(ordered, 0.95) < 8, "подготовка кадра занимает главный поток")
    }
}
