import AppKit
import CoreVideo
import Metal
import MetalKit
import SwiftUI
import Testing
@testable import Kampsis

/// отрисованный кадр BGRA; в тестах источники серые, поэтому яркость читается из одного канала
private struct RenderedFrame {
    let width: Int
    let height: Int
    let bgra: [UInt8]

    func level(x: Int, y: Int) -> Int { Int(bgra[(y * width + x) * 4]) }
    func alpha(x: Int, y: Int) -> Int { Int(bgra[(y * width + x) * 4 + 3]) }
    func levels(y: Int, xs: some Sequence<Int>) -> [Int] { xs.map { level(x: $0, y: y) } }
    var brightest: Int { stride(from: 0, to: bgra.count, by: 4).lazy.map { Int(bgra[$0]) }.max() ?? 0 }
}

/// наибольшая разница соседних значений
private func largestStep(_ values: [Int]) -> Int {
    zip(values.dropFirst(), values).map { abs($0 - $1) }.max() ?? 0
}

/// контраст Майкельсона: 0 для ровного фона, 1 для чёрно-белых полос
private func contrast(_ values: [Int]) -> Double {
    guard let low = values.min(), let high = values.max() else { return 0 }
    return Double(high - low) / Double(max(1, high + low))
}

/// рендер на настоящем GPU; окна кратко появляются поверх экрана
@MainActor @Suite(.serialized) struct RenderTests {
    private let stack: MetalStack

    init() throws {
        stack = try MetalStack.shared.get()
    }

    // MARK: помощники

    private func grayTexture(width: Int, height: Int, level: (_ x: Int, _ y: Int) -> UInt8) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: MetalStack.pixelFormat,
                                                                  width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        let texture = try #require(stack.device.makeTexture(descriptor: descriptor))
        let pixels: [UInt8] = (0..<height).flatMap { y in
            (0..<width).flatMap { x -> [UInt8] in
                let value = level(x, y)
                return [value, value, value, 255]
            }
        }
        pixels.withUnsafeBytes { raw in
            texture.replace(region: MTLRegion(origin: MTLOrigin(), size: MTLSizeMake(width, height, 1)),
                            mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: width * 4)
        }
        return texture
    }

    private func render(_ source: any MTLTexture, settings: EffectSettings, progress: Double,
                        width: Int, height: Int) throws -> RenderedFrame {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: MetalStack.pixelFormat,
                                                                  width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .renderTarget
        let target = try #require(stack.device.makeTexture(descriptor: descriptor))
        let pass = MTLRenderPassDescriptor()
        let attachment = try #require(pass.colorAttachments[0])
        attachment.texture = target
        attachment.loadAction = .clear
        attachment.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        attachment.storeAction = .store
        let command = try #require(stack.queue.makeCommandBuffer())
        let inputs = FoldInputs(progress: progress, settings: settings, fadesIn: true, reduceMotion: false)
        #expect(FoldPainter(stack: stack).encode(source: source, sourceNumber: nil, inputs: inputs, pass: pass,
                                                 command: command, size: CGSize(width: width, height: height)))
        command.commit()
        command.waitUntilCompleted()
        #expect(command.error == nil)
        var bgra = [UInt8](repeating: 0, count: width * height * 4)
        bgra.withUnsafeMutableBytes { raw in
            target.getBytes(raw.baseAddress!, bytesPerRow: width * 4,
                            from: MTLRegion(origin: MTLOrigin(), size: MTLSizeMake(width, height, 1)), mipmapLevel: 0)
        }
        return RenderedFrame(width: width, height: height, bgra: bgra)
    }

    /// PNG для глазной проверки: $TMPDIR/KampsisRenderTests
    private func keep(_ frame: RenderedFrame, as name: String) throws {
        var bgra = frame.bgra
        let data = try bgra.withUnsafeMutableBytes { raw -> Data in
            let context = try #require(CGContext(
                data: raw.baseAddress, width: frame.width, height: frame.height, bitsPerComponent: 8,
                bytesPerRow: frame.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
            let image = try #require(context.makeImage())
            return try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        }
        let folder = URL.temporaryDirectory.appending(path: "KampsisRenderTests", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appending(path: "\(name).png"))
    }

    private func floatingPanel(with view: NSView) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 180, y: 180, width: 420, height: 263),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.level = .init(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        panel.contentView = view
        panel.orderFrontRegardless()
        return panel
    }

    private func wait(upTo seconds: Double, until condition: () -> Bool) async throws {
        let deadline = CACurrentMediaTime() + seconds
        while !condition(), CACurrentMediaTime() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: миниатюры и превью

    @Test func lookThumbnailsDifferAndAreCached() throws {
        let pixelSets = try Look.allCases.map { look -> Data in
            let image = try StyleThumbnails.image(for: look)
            #expect(image === (try StyleThumbnails.image(for: look)))
            let cgImage = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
            #expect((cgImage.width, cgImage.height) == (StyleThumbnails.width, StyleThumbnails.height))
            let data = try #require(cgImage.dataProvider?.data) as Data
            #expect(Set(data).count > 100, "миниатюра \(look) почти однотонная")
            return data
        }
        #expect(Set(pixelSets).count == Look.allCases.count)
    }

    @Test func idlePreviewStopsDisplayLinkAndWakesOnEdit() async throws {
        var inputs = FoldInputs(progress: 0.32, settings: .standard, fadesIn: false, reduceMotion: false)
        let renderer = try SheetRenderer(stack: stack, frames: nil) { inputs }
        let panel = floatingPanel(with: renderer.surface)
        defer { renderer.surface.paused = true; panel.close() }

        try await wait(upTo: 5) { renderer.wake(); return renderer.drawnFrames > 0 }
        try await Task.sleep(for: .milliseconds(450))
        let idleCount = renderer.drawnFrames
        #expect(idleCount > 0)
        try await Task.sleep(for: .milliseconds(300))
        #expect(renderer.drawnFrames == idleCount)
        #expect(renderer.surface.paused, "неизменное превью должно останавливать display link, а не только пропускать кадры")

        inputs.settings.blur = 0.95
        renderer.wake()
        try await Task.sleep(for: .milliseconds(300))
        #expect(renderer.drawnFrames > idleCount)
    }

    @Test func swiftUIPreviewWakesAfterSliderAndStyleChanges() async throws {
        let suite = "KampsisPreviewTests.\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        let state = AppState(store: store)
        state.settings = EffectSettings.standard.applying(.matte)
        state.previewAngle = 102
        let hosting = NSHostingView(rootView: PreviewPane(state: state).frame(width: 420, height: 263))
        let panel = floatingPanel(with: hosting)
        defer { panel.orderOut(nil); panel.close() }

        func findSurface(_ view: NSView) -> MetalSurfaceView? {
            if let surface = view as? MetalSurfaceView { return surface }
            return view.subviews.lazy.compactMap(findSurface).first
        }
        try await wait(upTo: 5) { findSurface(hosting) != nil }
        let surface = try #require(findSurface(hosting))
        try await wait(upTo: 2) { surface.paused }
        #expect(surface.paused, "после первого кадра превью засыпает")

        let edits: [(String, () -> Void)] = [("угол", { state.previewAngle = 59 }), ("размытие", { state.settings.blur = 0.1 })]
        for (name, edit) in edits {
            edit()
            var woke = false
            try await wait(upTo: 1) { woke = woke || !surface.paused; return woke }
            #expect(woke, "изменение «\(name)» должно будить превью")
            try await wait(upTo: 1.5) { surface.paused }
            #expect(surface.paused, "после изменения «\(name)» превью снова засыпает")
        }
    }

    @Test func newCaptureWakesOverlayButHiddenOverlayStaysAsleep() async throws {
        var created: CVPixelBuffer?
        let attributes = [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 160, 100, kCVPixelFormatType_32BGRA, attributes, &created) == kCVReturnSuccess)
        let pixels = try #require(created)
        let frames = FrameSlot()
        frames.store(pixels, capturedAt: CACurrentMediaTime())
        let renderer = try SheetRenderer(stack: stack, frames: frames) {
            FoldInputs(progress: 0.4, settings: .standard, fadesIn: true, reduceMotion: false)
        }
        let panel = floatingPanel(with: renderer.surface)
        defer { renderer.surface.paused = true; panel.close() }

        try await wait(upTo: 5) { renderer.wake(); return renderer.drawnFrames > 0 }
        try await wait(upTo: 1) { renderer.surface.paused }
        #expect(renderer.surface.paused)
        let beforeCapture = renderer.drawnFrames
        frames.store(pixels, capturedAt: CACurrentMediaTime())
        try await Task.sleep(for: .milliseconds(400))
        #expect(renderer.drawnFrames > beforeCapture, "свежий кадр захвата должен будить display link")
        #expect(renderer.surface.paused)

        panel.orderOut(nil)
        try await Task.sleep(for: .milliseconds(120))
        let whileHidden = renderer.drawnFrames
        frames.store(pixels, capturedAt: CACurrentMediaTime())
        try await Task.sleep(for: .milliseconds(250))
        #expect(renderer.surface.paused)
        #expect(renderer.drawnFrames == whileHidden)
    }

    // MARK: размытие

    @Test func blurReusesResultUntilContentOrRadiusChanges() throws {
        let gradient = try grayTexture(width: 512, height: 320) { x, _ in UInt8(truncatingIfNeeded: x) }
        let pass = GaussianPass(device: stack.device, downsample: 1)
        func blur(version: UInt64?, sigma: Float) throws -> any MTLTexture {
            let command = try #require(stack.queue.makeCommandBuffer())
            let output = try #require(pass.blurred(gradient, sigma: sigma, sourceNumber: version, into: command))
            command.commit()
            command.waitUntilCompleted()
            #expect(command.error == nil)
            return output
        }
        let first = try blur(version: 1, sigma: 4)
        #expect(first === (try blur(version: 1, sigma: 4)))
        #expect(pass.encodedPasses == 1, "тот же кадр и радиус берутся из кеша")
        _ = try blur(version: 1, sigma: 4.01)
        #expect(pass.encodedPasses == 2, "малое изменение радиуса не округляется")
        _ = try blur(version: 2, sigma: 4)
        #expect(pass.encodedPasses == 3, "новый кадр пересчитывается даже в той же текстуре")
        pass.reset()
        _ = try blur(version: 2, sigma: 4)
        #expect(pass.encodedPasses == 4)
        _ = try blur(version: nil, sigma: 4)
        _ = try blur(version: nil, sigma: 4)
        #expect(pass.encodedPasses == 6, "источник без номера версии не кешируется")
        #expect(try blur(version: 3, sigma: 0.1) === gradient, "невидимое размытие отдаёт исходник")
    }

    @Test(arguments: [1, 4])
    func tinyRadiusChangesStillChangePixels(downsample: Int) throws {
        let stripes = try grayTexture(width: 512, height: 320) { x, _ in x % 8 < 4 ? 255 : 0 }
        let pass = GaussianPass(device: stack.device, downsample: downsample)
        let results = try [Float(4), 4.0625, 4.125].map { sigma -> Data in
            let command = try #require(stack.queue.makeCommandBuffer())
            let output = try #require(pass.blurred(stripes, sigma: sigma, sourceNumber: 1, into: command))
            let bytesPerRow = output.width * 8
            let copy = try #require(stack.device.makeBuffer(length: bytesPerRow * output.height, options: .storageModeShared))
            let blit = try #require(command.makeBlitCommandEncoder())
            blit.copy(from: output, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                      sourceSize: MTLSizeMake(output.width, output.height, 1), to: copy, destinationOffset: 0,
                      destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: copy.length)
            blit.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            #expect(command.error == nil)
            return Data(bytes: copy.contents(), count: copy.length)
        }
        #expect(results[0] != results[1])
        #expect(results[1] != results[2])
    }

    // MARK: вид эффекта

    @Test(arguments: [0.25, 0.5, 0.75])
    func sheetEdgesFadeInsteadOfCutting(progress: Double) throws {
        let (width, height) = (1024, 640)
        let white = try grayTexture(width: width, height: height) { _, _ in 255 }
        var settings = EffectSettings.standard
        (settings.bend, settings.blur, settings.dimming) = (1, 0.9, 0.25)
        let frame = try render(white, settings: settings, progress: progress, width: width, height: height)
        let quarter = width / 4
        for share in [0.2, 0.5, 0.8] {
            let y = Int(Double(height) * share)
            let fromLeft = frame.levels(y: y, xs: 0..<quarter)
            let fromRight = frame.levels(y: y, xs: stride(from: width - 1, to: width - 1 - quarter, by: -1))
            for (side, values) in [("слева", fromLeft), ("справа", fromRight)] {
                #expect(Double(largestStep(values)) < Double(values.max() ?? 0) * 0.4,
                        "обрыв края \(side) на высоте \(share), прогресс \(progress)")
            }
        }
        try keep(frame, as: "edge-white-\(Int(progress * 100))")
    }

    @Test(arguments: Look.allCases)
    func whiteDesktopGoesDarkAtClosure(look: Look) throws {
        let white = try grayTexture(width: 512, height: 320) { _, _ in 255 }
        var settings = EffectSettings.standard.applying(look)
        settings.dimming = 0
        let frame = try render(white, settings: settings, progress: 0.98, width: 512, height: 320)
        #expect(frame.brightest <= 8, "\(look) оставляет яркий экран у самого закрытия")
    }

    @Test func frostHidesTopDetailButHingeStaysSharp() throws {
        let (width, height) = (512, 320)
        let stripes = try grayTexture(width: width, height: height) { x, _ in x % 8 < 4 ? 255 : 0 }
        var settings = EffectSettings.standard
        settings.bend = 0
        let frame = try render(stripes, settings: settings, progress: 0.45, width: width, height: height)
        let middle = width / 4..<width * 3 / 4
        #expect(contrast(frame.levels(y: 60, xs: middle)) < 0.12, "вверху полосы должны скрыться под инеем")
        #expect(contrast(frame.levels(y: 305, xs: middle)) > 0.5, "у петли полосы должны читаться")
        try keep(frame, as: "glass-detail")
    }

    @Test func uncoveredBorderIsBlackAndDesktopShowsUnderFrost() throws {
        let (width, height) = (512, 320)
        let white = try render(grayTexture(width: width, height: height) { _, _ in 255 },
                               settings: .standard, progress: 0.5, width: width, height: height)
        let black = try render(grayTexture(width: width, height: height) { _, _ in 0 },
                               settings: .standard, progress: 0.5, width: width, height: height)
        #expect(white.level(x: 2, y: 20) <= 2, "открывшийся край должен быть чёрным, а не серым")
        #expect(white.level(x: width / 2, y: 40) - black.level(x: width / 2, y: 40) > 20,
                "под инеем у верхнего края должен оставаться рабочий стол")
    }

    @Test(arguments: [0.25, 0.5, 0.75, 0.98])
    func overlayIsOpaqueEverywhereAtCaptureSize(progress: Double) throws {
        let (width, height) = (2560, 1600)
        let desktop = try MTKTextureLoader(device: stack.device).newTexture(
            cgImage: drawSampleDesktop(), options: [.SRGB: true, .textureUsage: MTLTextureUsage.shaderRead.rawValue])
        let frame = try render(desktop, settings: .standard, progress: progress, width: width, height: height)
        let seeThrough = stride(from: 3, to: frame.bgra.count, by: 4).lazy.filter { frame.bgra[$0] != 255 }.count
        #expect(seeThrough == 0)
        try keep(frame, as: "desktop-fold-\(Int(progress * 100))")
        if progress == 0.5 {
            try keep(render(desktop, settings: EffectSettings.standard.applying(.matte), progress: progress,
                            width: width, height: height), as: "desktop-matte-50")
        }
    }

    @Test func blurLeavesNoGhostCopiesOfAThinLine() throws {
        let (width, height) = (512, 320)
        let line = try grayTexture(width: width, height: height) { x, _ in abs(x - width / 2) <= 1 ? 255 : 0 }
        var settings = EffectSettings.standard
        (settings.bend, settings.blur, settings.dimming) = (0, 1, 0)
        let frame = try render(line, settings: settings, progress: 0.5, width: width, height: height)
        let falloff = frame.levels(y: 55, xs: width / 2..<width / 2 + 55)
        let rises = zip(falloff.dropFirst(), falloff).filter { $0 > $1 + 3 }
        #expect(rises.isEmpty, "у размытия видны отдельные копии линии: \(falloff)")
        #expect(falloff[0] > 5)
        try keep(frame, as: "line-blur")
    }

    @Test func closedAreaDoesNotSmearDesktopContent() throws {
        let (width, height) = (512, 320)
        var settings = EffectSettings.standard
        (settings.bend, settings.blur, settings.dimming) = (1, 0, 0)
        let empty = try render(grayTexture(width: width, height: height) { _, _ in 0 },
                               settings: settings, progress: 0.9, width: width, height: height)
        let band = try render(grayTexture(width: width, height: height) { _, y in (281...308).contains(y) ? 255 : 0 },
                              settings: settings, progress: 0.9, width: width, height: height)
        let column = width / 2
        let smear = (10..<60).map { abs(band.level(x: column, y: $0) - empty.level(x: column, y: $0)) }.max() ?? 0
        #expect(smear <= 2, "полоса рабочего стола вытянулась в открывшуюся область")
        #expect((0..<height).allSatisfy { band.alpha(x: column, y: $0) == 255 })
        try keep(band, as: "backdrop")
    }
}
