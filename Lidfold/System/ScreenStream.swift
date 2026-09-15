import AppKit
import CoreVideo
import os
import ScreenCaptureKit
import Synchronization

/// кадр экрана с порядковым номером, чтобы рендер отличал новый кадр от уже показанного
struct CapturedFrame: @unchecked Sendable {
    let pixels: CVPixelBuffer
    let number: UInt64
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

    func store(_ pixels: CVPixelBuffer) {
        let listener = contents.withLock { box in
            box.counter &+= 1
            box.frame = CapturedFrame(pixels: pixels, number: box.counter)
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

    var errorDescription: String? {
        switch self {
        case .noBuiltInDisplay: String(localized: "The built-in display isn’t available right now.")
        case .appNotListed: String(localized: "macOS didn’t allow excluding the app’s windows from capture.")
        case .noFrames: String(localized: "macOS didn’t send a screen image. Check screen recording access and try again.")
        }
    }
}

/// номера окон AppKit, пригодные для фильтра захвата
func capturableWindowIDs(_ windowNumbers: [Int]) -> Set<CGWindowID> {
    Set(windowNumbers.compactMap { $0 > 0 ? CGWindowID(exactly: $0) : nil })
}

/// коннектор к ScreenCaptureKit: захватывает только встроенный экран без собственных окон эффекта
@MainActor final class ScreenStream {
    static let widestCapture: CGFloat = 2560
    static let captureRate: Int32 = 60

    let frames = FrameSlot()
    private var activeStream: SCStream?
    private var receiver: FrameReceiver?
    private let queue = DispatchQueue(label: "io.github.boundlessend.lidfold.capture", qos: .userInteractive)

    static func builtInDisplay() -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let id = displayID(of: screen) else { return false }
            return CGDisplayIsBuiltin(id) != 0 && CGDisplayIsActive(id) != 0
        }
    }

    /// окна `showing` остаются на снимке, хотя остальные окна приложения исключены
    func start(showing windows: [NSWindow], onStop: @escaping @MainActor @Sendable (String) -> Void) async throws {
        guard activeStream == nil else { return }
        guard let screen = Self.builtInDisplay(), let displayID = Self.displayID(of: screen) else {
            throw CaptureFailure.noBuiltInDisplay
        }
        let keptIDs = capturableWindowIDs(windows.map(\.windowNumber))
        let shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
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

        let receiver = FrameReceiver(frames: frames, onStop: onStop)
        let activeStream = SCStream(filter: filter, configuration: Self.configuration(for: screen), delegate: receiver)
        try activeStream.addStreamOutput(receiver, type: .screen, sampleHandlerQueue: queue)
        self.activeStream = activeStream
        self.receiver = receiver
        do {
            try await activeStream.startCapture()
            try Task.checkCancellation()
        } catch {
            await stop()
            throw error
        }
    }

    func stop() async {
        if let activeStream {
            do {
                try await activeStream.stopCapture()
            } catch {
                captureLog.warning("capture stream did not stop cleanly: \(error.localizedDescription, privacy: .public)")
            }
        }
        activeStream = nil
        receiver = nil
        frames.empty()
    }

    private static func configuration(for screen: NSScreen) -> SCStreamConfiguration {
        let pixelWidth = screen.frame.width * screen.backingScaleFactor
        let scale = min(1, widestCapture / pixelWidth)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(pixelWidth * scale)
        configuration.height = Int(screen.frame.height * screen.backingScaleFactor * scale)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: captureRate)
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.captureDynamicRange = .SDR
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.captureMicrophone = false
        return configuration
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

private let captureLog = Logger(subsystem: "io.github.boundlessend.lidfold", category: "capture")

private final class FrameReceiver: NSObject, SCStreamOutput, SCStreamDelegate, Sendable {
    private let frames: FrameSlot
    private let onStop: @MainActor @Sendable (String) -> Void

    init(frames: FrameSlot, onStop: @escaping @MainActor @Sendable (String) -> Void) {
        self.frames = frames
        self.onStop = onStop
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, isComplete(sampleBuffer),
              let pixels = sampleBuffer.imageBuffer else { return }
        frames.store(pixels)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let reason = error.localizedDescription
        captureLog.error("capture stream stopped: \(reason, privacy: .public)")
        DispatchQueue.main.async { [onStop] in MainActor.assumeIsolated { onStop(reason) } }
    }

    /// ScreenCaptureKit шлёт и служебные буферы без нового изображения
    private func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int else { return false }
        return SCFrameStatus(rawValue: raw) == .complete
    }
}
