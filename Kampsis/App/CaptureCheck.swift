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

    let arguments = ProcessInfo.processInfo.arguments
    let mode: CaptureMode
    if let index = arguments.firstIndex(of: "--capture-mode") {
        guard arguments.indices.contains(index + 1), let selected = CaptureMode(rawValue: arguments[index + 1]) else {
            print("FAIL: --capture-mode requires live, frozen, or snapshot")
            return 2
        }
        mode = selected
    } else {
        guard let selected = EffectController.shared.state.captureMode else {
            print("FAIL: choose a valid capture mode in General Settings")
            return 2
        }
        mode = selected
    }
    print("capture mode: \(mode.rawValue)")
    // прозрачное окно регистрирует процесс в ScreenCaptureKit без рендера и изображения рабочего стола
    let registration = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
    registration.backgroundColor = .clear
    registration.isOpaque = false
    registration.hasShadow = false
    registration.ignoresMouseEvents = true
    registration.isReleasedWhenClosed = false
    registration.orderFrontRegardless()
    defer { registration.close() }
    let stream = ScreenStream()
    var stoppedWith: CaptureTrouble?
    // насколько кадр доходит позже своей метки времени: положительное значение означает очередь или тормоза
    let lateness = Mutex<[Double]>([])
    stream.frames.onStore { [frames = stream.frames] in
        guard let frame = frames.latest else { return }
        lateness.withLock { $0.append((CACurrentMediaTime() - frame.captureTime) * 1000) }
    }

    let startedAt = CACurrentMediaTime()
    do {
        // своё служебное окно исключается из изображения
        try await stream.start(mode: mode, showing: []) { stoppedWith = $0 }
        let readyAt = CACurrentMediaTime()
        print("capture prepared in \(oneDecimal((readyAt - startedAt) * 1000)) ms, queue depth \(ScreenStream.queueDepth)")

        let deadline = readyAt + firstFrameWait
        while stream.frames.latest == nil, stoppedWith == nil, CACurrentMediaTime() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        guard let first = stream.frames.latest else {
            _ = await stopCaptureCheck(stream)
            if let trouble = stoppedWith {
                print("FAIL capture: \(trouble.message) [\(String(describing: trouble.recovery))]")
            } else {
                print("FAIL: no frame in \(firstFrameWait) s; access may be remembered for another copy of the app")
            }
            return 1
        }
        print("""
        first frame: \(CVPixelBufferGetWidth(first.pixels))x\(CVPixelBufferGetHeight(first.pixels)) \
        \(pixelFormatName(CVPixelBufferGetPixelFormatType(first.pixels))), \
        \(oneDecimal((CACurrentMediaTime() - readyAt) * 1000)) ms after the stream started
        """)

        if mode == .frozen { try await stream.freeze() }
        print("continuous stream: \(stream.isStreaming ? "yes" : "no")")
        if mode != .live {
            print("frames: one picture held without a continuous stream")
            guard await stopCaptureCheck(stream) else { return 1 }
            print("OK")
            return 0
        }
        lateness.withLock { $0.removeAll() }
        let until = CACurrentMediaTime() + measuringWindow
        while stoppedWith == nil, CACurrentMediaTime() < until {
            // смена вывода заставляет ScreenCaptureKit прислать новые кадры
            fputs(".", stdout)
            fflush(stdout)
            try await Task.sleep(for: .milliseconds(50))
        }
        print("")
    } catch is CancellationError {
        _ = await stopCaptureCheck(stream)
        print("CANCELLED: capture check stopped")
        return 1
    } catch {
        _ = await stopCaptureCheck(stream)
        let trouble = captureTrouble(error)
        print("FAIL capture: \(trouble.message) [\(String(describing: trouble.recovery))]")
        return 1
    }
    guard await stopCaptureCheck(stream) else { return 1 }
    if let trouble = stoppedWith {
        print("FAIL capture: \(trouble.message) [\(String(describing: trouble.recovery))]")
        return 1
    }

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

/// миллисекунды с одной цифрой после запятой
private func oneDecimal(_ value: Double) -> String {
    String(format: "%.1f", value)
}

/// четырёхсимвольный код формата пикселей
private func pixelFormatName(_ code: OSType) -> String {
    String([24, 16, 8, 0].map { Character(UnicodeScalar(UInt8(truncatingIfNeeded: code >> $0))) })
}

/// ошибка остановки тоже делает проверку неуспешной, а не теряется при выходе
@MainActor private func stopCaptureCheck(_ stream: ScreenStream) async -> Bool {
    do {
        try await stream.stop()
        return true
    } catch {
        print("FAIL stopping capture: \(error.localizedDescription)")
        return false
    }
}
