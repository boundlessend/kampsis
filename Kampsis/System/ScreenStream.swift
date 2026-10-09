import AppKit
import CoreVideo
import os
import ScreenCaptureKit
import Synchronization

/// кадр экрана с порядковым номером, чтобы рендер отличал новый кадр от уже показанного
/// буфер после захвата только читается; сильная ссылка удерживает его от повторного использования
struct CapturedFrame: @unchecked Sendable {
    let pixels: CVPixelBuffer
    let number: UInt64
    /// момент снимка по часам хоста: разница с `CACurrentMediaTime` даёт возраст кадра
    let captureTime: Double
}

/// хранит только последний кадр: рендеру промежуточные не нужны
final class FrameSlot: Sendable {
    private struct Contents {
        var frame: CapturedFrame?
        var counter: UInt64
        var listener: (@Sendable () -> Void)?
    }

    private let contents = Mutex(Contents(frame: nil, counter: 0, listener: nil))

    var latest: CapturedFrame? { contents.withLock { $0.frame } }

    func onStore(_ listener: @escaping @Sendable () -> Void) {
        contents.withLock { $0.listener = listener }
    }

    func store(_ pixels: CVPixelBuffer, capturedAt captureTime: Double) {
        let listener = contents.withLock { box in
            box.counter &+= 1
            box.frame = CapturedFrame(pixels: pixels, number: box.counter, captureTime: captureTime)
            return box.listener
        }
        listener?()
    }

    func empty() {
        contents.withLock { $0.frame = nil }
    }
}

enum CaptureFailure: LocalizedError {
    case noBuiltInDisplay
    case appNotListed
    case noFrames
    case timedOut(CaptureOperation)
    case stillStopping

    var errorDescription: String? {
        switch self {
        case .noBuiltInDisplay: String(localized: "The built-in display isn’t available right now.")
        case .appNotListed: String(localized: "macOS didn’t allow excluding the app’s windows from capture.")
        case .noFrames: String(localized: "macOS didn’t send a screen image. Check screen recording access and try again.")
        case .timedOut(.displays): String(localized: "macOS didn’t list the displays in time. Click “Check Again”.")
        case .timedOut(.start): String(localized: "macOS didn’t start capture in time. Click “Check Again”.")
        case .timedOut(.snapshot): String(localized: "macOS didn’t return the snapshot in time. Click “Check Again”.")
        case .timedOut(.stop), .stillStopping:
            String(localized: "macOS hasn’t finished stopping capture. Restart Kampsis before trying again.")
        }
    }

    var recovery: CaptureRecovery {
        switch self {
        case .noBuiltInDisplay, .appNotListed, .stillStopping, .timedOut(.stop): .blocked
        case .noFrames, .timedOut: .restart
        }
    }
}

/// что делать после сбоя захвата
enum CaptureRecovery: Equatable, Sendable {
    /// поток уронила система или соединение: новая попытка может помочь
    case restart
    /// пока условия не изменятся, повторять бессмысленно
    case blocked
}

/// разобранный сбой захвата: что сказать человеку и стоит ли пробовать снова
struct CaptureTrouble: LocalizedError, Equatable, Sendable {
    let message: String
    let recovery: CaptureRecovery
    var errorDescription: String? { message }
}

/// разбирает сбой захвата: свои ошибки знают решение сами, у ScreenCaptureKit решение по коду
func captureTrouble(_ error: any Error) -> CaptureTrouble {
    if let trouble = error as? CaptureTrouble { return trouble }
    if let failure = error as? CaptureFailure {
        return CaptureTrouble(message: failure.localizedDescription, recovery: failure.recovery)
    }
    let system = error as NSError
    guard system.domain == SCStreamErrorDomain, let code = SCStreamError.Code(rawValue: system.code) else {
        return CaptureTrouble(message: error.localizedDescription, recovery: .restart)
    }
    return captureTrouble(code, systemMessage: error.localizedDescription)
}

/// сообщение и решение по коду ScreenCaptureKit; незнакомый код идёт с системным описанием
func captureTrouble(_ code: SCStreamError.Code, systemMessage: String) -> CaptureTrouble {
    switch code {
    case .userDeclined, .missingEntitlements:
        CaptureTrouble(message: String(localized: "macOS didn’t allow screen recording."), recovery: .blocked)
    case .userStopped:
        CaptureTrouble(message: String(localized: "Screen capture was stopped from the menu bar."), recovery: .blocked)
    case .noDisplayList, .noWindowList, .noCaptureSource:
        CaptureTrouble(message: String(localized: "macOS has no display to capture right now."), recovery: .blocked)
    case .systemStoppedStream:
        CaptureTrouble(message: String(localized: "macOS stopped the screen capture."), recovery: .restart)
    case .failedToStart, .internalError, .failedApplicationConnectionInvalid,
         .failedApplicationConnectionInterrupted, .failedNoMatchingApplicationContext:
        CaptureTrouble(message: String(localized: "Screen capture didn’t start."), recovery: .restart)
    default:
        CaptureTrouble(message: systemMessage, recovery: .restart)
    }
}

/// номера окон AppKit, пригодные для фильтра захвата
func capturableWindowIDs(_ windowNumbers: [Int]) -> Set<CGWindowID> {
    Set(windowNumbers.compactMap { $0 > 0 ? CGWindowID(exactly: $0) : nil })
}

/// коннектор к ScreenCaptureKit: захватывает только встроенный экран без собственных окон эффекта
@MainActor protocol ScreenCapturing: AnyObject {
    var frames: FrameSlot { get }
    var hasScreenAccess: Bool { get }
    var isStreaming: Bool { get }
    func start(mode: CaptureMode, showing windows: [NSWindow], onStop: @escaping @MainActor @Sendable (CaptureTrouble) -> Void) async throws
    func freeze() async throws
    func stop() async throws
}

@MainActor final class ScreenStream: ScreenCapturing {
    static let startTimeout: Duration = .seconds(4)
    static let stopTimeout: Duration = .seconds(2)
    static let widestCapture: CGFloat = 2560
    static let captureRate: Int32 = 60
    /// глубина очереди кадров; единица не годится: последний кадр остаётся у нас и потоку некуда писать новый
    static let queueDepth = 3

    let frames = FrameSlot()
    var hasScreenAccess: Bool { CGPreflightScreenCaptureAccess() }
    var isStreaming: Bool { session.map { !$0.stopped } ?? false }
    private var session: StreamSession?
    private let queue = DispatchQueue(label: "io.github.boundlessend.kampsis.capture", qos: .userInteractive)

    static func builtInDisplay() -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let id = displayID(of: screen) else { return false }
            return CGDisplayIsBuiltin(id) != 0 && CGDisplayIsActive(id) != 0
        }
    }

    /// окна `showing` остаются на снимке, хотя остальные окна приложения исключены
    func start(mode: CaptureMode, showing windows: [NSWindow], onStop: @escaping @MainActor @Sendable (CaptureTrouble) -> Void) async throws {
        guard session == nil else { throw CaptureFailure.stillStopping }
        let deadline = ContinuousClock.now + Self.startTimeout
        guard let screen = Self.builtInDisplay(), let displayID = Self.displayID(of: screen) else {
            throw CaptureFailure.noBuiltInDisplay
        }
        let keptIDs = capturableWindowIDs(windows.map(\.windowNumber))
        let request = shareableContentRequest()
        let shareable = try await request.wait(until: deadline, operation: .displays).content
        try Task.checkCancellation()
        guard let display = shareable.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureFailure.noBuiltInDisplay
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownApps = shareable.applications.filter { $0.processID == ownPID }
        guard !ownApps.isEmpty else { throw CaptureFailure.appNotListed }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps,
                                     exceptingWindows: shareable.windows.filter { keptIDs.contains($0.windowID) })
        filter.includeMenuBar = true

        if mode == .snapshot {
            let frame = try await snapshotRequest(filter: filter, configuration: Self.configuration(for: screen))
                .wait(until: deadline, operation: .snapshot)
            try Task.checkCancellation()
            frames.store(frame.pixels, capturedAt: frame.captureTime)
            return
        }

        let sessionID = UUID()
        let receiver = FrameReceiver(frames: frames) { [weak self] trouble in
            guard let self, let current = self.session, current.id == sessionID else { return }
            current.systemStopped(trouble)
            onStop(trouble)
        }
        let activeStream = SCStream(filter: filter, configuration: Self.configuration(for: screen), delegate: receiver)
        try activeStream.addStreamOutput(receiver, type: .screen, sampleHandlerQueue: queue)
        let session = StreamSession(id: sessionID, stream: activeStream, receiver: receiver)
        self.session = session
        session.onSettled = { [weak self, weak session] in
            guard let self, let session, self.session === session, session.settled else { return }
            self.session = nil
        }
        do {
            try await session.start(until: deadline)
            try Task.checkCancellation()
        } catch {
            try await stop()
            throw error
        }
    }

    /// callback нужен для собственного срока: async-обёртка SDK может не реагировать на отмену
    private func shareableContentRequest() -> CaptureReply<ShareableContent> {
        let request = CaptureReply<ShareableContent>()
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, error in
            if let error { request.finish(.failure(captureTrouble(error))) }
            else if let content { request.finish(.success(ShareableContent(content: content))) }
            else { request.finish(.failure(captureTrouble(CaptureFailure.noBuiltInDisplay))) }
        }
        return request
    }

    /// поздний ответ не меняет кадры остановленного эффекта
    private func snapshotRequest(filter: SCContentFilter, configuration: SCStreamConfiguration) -> CaptureReply<CapturedFrame> {
        let pending = CaptureReply<CapturedFrame>()
        SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: configuration) { sample, error in
            let result: Result<CapturedFrame, CaptureTrouble>
            if let error {
                result = .failure(captureTrouble(error))
            } else if let pixels = sample?.imageBuffer {
                result = .success(CapturedFrame(pixels: pixels, number: 0, captureTime: CACurrentMediaTime()))
            } else {
                result = .failure(captureTrouble(CaptureFailure.noFrames))
            }
            pending.finish(result)
        }
        return pending
    }

    /// прекращает обновления, но сохраняет кадр для текущего сгиба
    func freeze() async throws {
        if let session { try await session.stop() }
    }

    /// ждёт остановки потока и освобождает последний кадр
    func stop() async throws {
        defer { frames.empty() }
        try await freeze()
    }

    private static func configuration(for screen: NSScreen) -> SCStreamConfiguration {
        let pixelWidth = screen.frame.width * screen.backingScaleFactor
        let scale = min(1, widestCapture / pixelWidth)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(pixelWidth * scale)
        configuration.height = Int(screen.frame.height * screen.backingScaleFactor * scale)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: captureRate)
        configuration.queueDepth = queueDepth
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.captureDynamicRange = .SDR
        // системный курсор остаётся поверх эффекта; снимок не должен содержать его копию
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.captureMicrophone = false
        return configuration
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

private let captureLog = Logger(subsystem: "io.github.boundlessend.kampsis", category: "capture")

/// SDK отдаёт неизменяемые списки; после callback они только читаются главным актором
private struct ShareableContent: @unchecked Sendable {
    let content: SCShareableContent
}

/// владеет одним потоком, включая позднее завершение запуска после отмены
@MainActor private final class StreamSession {
    let id: UUID
    let stream: SCStream
    let receiver: FrameReceiver
    var onSettled: (() -> Void)?
    private var startupFinished = false
    private var startupReply: CaptureReply<Void>?
    private var stoppedBySystem = false
    private var stopReply: CaptureReply<Void>?
    private var stopDeadline: ContinuousClock.Instant?
    private(set) var stopped = false
    var settled: Bool { startupFinished && stopped }

    init(id: UUID, stream: SCStream, receiver: FrameReceiver) {
        self.id = id
        self.stream = stream
        self.receiver = receiver
    }

    func start(until deadline: ContinuousClock.Instant) async throws {
        let reply = CaptureReply<Void>()
        startupReply = reply
        requestStart(reply: reply)
        try await reply.wait(until: deadline, operation: .start)
    }

    private func requestStart(reply: CaptureReply<Void>) {
        stream.startCapture { [self] error in
            Task { @MainActor in
                guard !stoppedBySystem else { return }
                startupFinished = true
                if let error {
                    stopped = true
                    reply.finish(.failure(captureTrouble(error)))
                    onSettled?()
                } else if !reply.finish(.success(())) || stopReply != nil {
                    // первый stop мог завершиться до позднего start: останавливаем именно этот поток ещё раз
                    stopped = false
                    receiver.invalidate()
                    requestStop(reply: CaptureReply<Void>())
                }
            }
        }
    }

    func systemStopped(_ trouble: CaptureTrouble) {
        stoppedBySystem = true
        startupFinished = true
        stopped = true
        receiver.invalidate()
        startupReply?.finish(.failure(trouble))
        stopReply?.finish(.success(()))
        onSettled?()
    }

    func stop() async throws {
        receiver.invalidate()
        if settled { return }
        if stopReply == nil {
            let reply = CaptureReply<Void>()
            stopReply = reply
            stopDeadline = ContinuousClock.now + ScreenStream.stopTimeout
            requestStop(reply: reply)
        }
        guard let reply = stopReply, let deadline = stopDeadline else { preconditionFailure("нет запроса остановки") }
        // очистка ограничена сроком и завершается даже у уже отменённого вызывающего Task
        try await Task { try await reply.wait(until: deadline, operation: .stop) }.value
        guard settled else { throw CaptureFailure.stillStopping }
    }

    private func requestStop(reply: CaptureReply<Void>) {
        stream.stopCapture { [self] error in
            Task { @MainActor in
                if stoppedBySystem {
                    reply.finish(.success(()))
                    return
                }
                if let error {
                    let trouble = CaptureTrouble(message: captureTrouble(error).message, recovery: .blocked)
                    reply.finish(.failure(trouble))
                    captureLog.error("capture stop failed: code=\((error as NSError).code, privacy: .public)")
                } else {
                    stopped = true
                    reply.finish(.success(()))
                    onSettled?()
                }
            }
        }
    }
}

private final class FrameReceiver: NSObject, SCStreamOutput, SCStreamDelegate, Sendable {
    private let frames: FrameSlot
    private let onStop: @MainActor @Sendable (CaptureTrouble) -> Void
    private let active = Mutex(true)

    init(frames: FrameSlot, onStop: @escaping @MainActor @Sendable (CaptureTrouble) -> Void) {
        self.frames = frames
        self.onStop = onStop
    }

    func invalidate() { active.withLock { $0 = false } }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, isComplete(sampleBuffer),
              let pixels = sampleBuffer.imageBuffer else { return }
        active.withLock { enabled in
            if enabled { frames.store(pixels, capturedAt: sampleBuffer.presentationTimeStamp.seconds) }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        guard active.withLock({ $0 }) else { return }
        let trouble = captureTrouble(error)
        captureLog.error("""
        capture stream stopped: recovery=\(String(describing: trouble.recovery), privacy: .public) \
        message=\(trouble.message, privacy: .public) raw=\(error.localizedDescription, privacy: .public)
        """)
        DispatchQueue.main.async { [onStop] in MainActor.assumeIsolated { onStop(trouble) } }
    }

    /// отбрасывает служебные буферы ScreenCaptureKit без нового изображения
    private func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int else { return false }
        return SCFrameStatus(rawValue: raw) == .complete
    }
}
