import AppKit
import CoreVideo
import QuartzCore
import Synchronization

/// сколько ждать первый кадр
private let firstFrameWait = 2.0
/// сколько собирать кадры для оценки потока
private let measuringWindow = 1.0

/// проверка захвата из командной строки: приложение без окон ловит кадры и печатает формат, частоту и запоздание
/// запускается как `Kampsis.app/Contents/MacOS/Kampsis --capture-check`
@MainActor func runCaptureCheck() async -> Int32 {
    print("Kampsis \(AppIdentity.version) (\(AppIdentity.build)), bundle \(Bundle.main.bundleIdentifier ?? "unknown")")
    print("screen recording access: \(CGPreflightScreenCaptureAccess() ? "granted" : "missing")")
    guard let screen = ScreenStream.builtInDisplay() else {
        print("FAIL: no active built-in display")
        return 1
    }
    print("""
    built-in display: \(Int(screen.frame.width))x\(Int(screen.frame.height)) points \
    at \(screen.backingScaleFactor)x, \(screen.maximumFramesPerSecond) Hz
    """)

    let stream = ScreenStream()
    // насколько кадр доходит позже своей метки времени: положительное значение означает очередь или тормоза
    let lateness = Mutex<[Double]>([])
    stream.frames.onStore { [frames = stream.frames] in
        guard let frame = frames.latest else { return }
        lateness.withLock { $0.append((CACurrentMediaTime() - frame.captureTime) * 1000) }
    }

    let startedAt = CACurrentMediaTime()
    do {
        // окон у приложения нет: так проверяется, что macOS перечисляет его в SCShareableContent
        try await stream.start(showing: []) { trouble in
            print("stream stopped: \(trouble.message) [\(String(describing: trouble.recovery))]")
        }
    } catch {
        let trouble = captureTrouble(error)
        print("FAIL start: \(trouble.message) [\(String(describing: trouble.recovery))]")
        return 1
    }
    let readyAt = CACurrentMediaTime()
    print("stream started in \(oneDecimal((readyAt - startedAt) * 1000)) ms, queue depth \(ScreenStream.queueDepth)")

    let deadline = readyAt + firstFrameWait
    while stream.frames.latest == nil, CACurrentMediaTime() < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
    guard let first = stream.frames.latest else {
        await stream.stop()
        print("FAIL: no frame in \(firstFrameWait) s; access may be remembered for another copy of the app")
        return 1
    }
    print("""
    first frame: \(CVPixelBufferGetWidth(first.pixels))x\(CVPixelBufferGetHeight(first.pixels)) \
    \(pixelFormatName(CVPixelBufferGetPixelFormatType(first.pixels))), \
    \(oneDecimal((CACurrentMediaTime() - readyAt) * 1000)) ms after the stream started
    """)

    lateness.withLock { $0.removeAll() }
    let until = CACurrentMediaTime() + measuringWindow
    while CACurrentMediaTime() < until {
        // ScreenCaptureKit присылает кадр только на изменение экрана, поэтому проверка сама шевелит вывод
        fputs(".", stdout)
        fflush(stdout)
        try? await Task.sleep(for: .milliseconds(50))
    }
    print("")
    await stream.stop()

    let measured = lateness.withLock { $0 }.sorted()
    guard let slowest = measured.last else {
        // ScreenCaptureKit молчит, пока картинка не меняется: это не сбой, просто мерить нечего
        print("frames: none in \(measuringWindow) s, nothing on screen changed")
        print("OK")
        return 0
    }
    print("frames: \(measured.count) in \(measuringWindow) s of screen changes")
    print("""
    frame behind its own timestamp: p50 \(oneDecimal(percentile(measured, 0.5))) ms, \
    max \(oneDecimal(slowest)) ms
    """)
    print("OK")
    return 0
}

/// одна цифра после запятой: читать миллисекунды с длинным хвостом неудобно
private func oneDecimal(_ value: Double) -> String {
    String(format: "%.1f", value)
}

/// четырёхсимвольный код формата пикселей
private func pixelFormatName(_ code: OSType) -> String {
    String([24, 16, 8, 0].map { Character(UnicodeScalar(UInt8(truncatingIfNeeded: code >> $0))) })
}
