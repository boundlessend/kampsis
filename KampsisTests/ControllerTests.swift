import AppKit
import Carbon.HIToolbox
import CoreVideo
import Testing
@testable import Kampsis

/// управляемый коннектор: воспроизводит задержку и отсутствие кадров без изменения разрешений macOS
@MainActor private final class CaptureProbe: ScreenCapturing {
    let frames = FrameSlot()
    let hasScreenAccess = true
    private let begin: @MainActor (FrameSlot) async throws -> Void
    private(set) var starts = 0
    private(set) var stops = 0

    init(begin: @escaping @MainActor (FrameSlot) async throws -> Void) { self.begin = begin }

    func start(showing windows: [NSWindow], onStop: @escaping @MainActor @Sendable (CaptureTrouble) -> Void) async throws {
        starts += 1
        try await begin(frames)
    }

    func stop() async {
        stops += 1
        frames.empty()
    }
}

/// настоящие задачи контроллера, горячие клавиши и оверлей; порядок системных сбоев задаёт коннектор
@MainActor @Suite(.serialized) struct ControllerTests {
    private func withController(capture: CaptureProbe,
                                check: @MainActor (EffectController, UserDefaults) async throws -> Void) async throws {
        let domain = "KampsisControllerTests.\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: domain))
        defer { store.removePersistentDomain(forName: domain) }
        store.set(false, forKey: "automatic-update-checks")
        let controller = EffectController(store: store, stream: capture)
        controller.state.settings.isOn = false
        controller.state.settings.toggleShortcut = ToggleShortcut(keyCode: UInt16(kVK_F18), modifiers: [.command, .control, .shift])
        controller.start()
        do { try await check(controller, store) }
        catch {
            await controller.stop()
            throw error
        }
        await controller.stop()
    }

    private func wait(upTo seconds: Double, until condition: () -> Bool) async throws {
        let deadline = CACurrentMediaTime() + seconds
        while !condition(), CACurrentMediaTime() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(condition(), "контроллер не достиг ожидаемого состояния")
    }

    @Test func stoppingDemoCancelsCaptureBeforeItStarts() async throws {
        let capture = CaptureProbe { _ in try await Task.sleep(for: .seconds(30)) }
        try await withController(capture: capture) { controller, _ in
            controller.beginDemo()
            try await wait(upTo: 2) { capture.starts == 1 }
            controller.endDemo()
            try await wait(upTo: 2) { controller.phase == .idle }
            #expect(!controller.state.demoRunning)
            #expect(!controller.state.settings.isOn)
            #expect(!controller.state.capturing)
            #expect(!controller.state.overlayShown)
            #expect(controller.state.problem == nil)
            #expect(capture.stops > 0)
        }
    }

    @Test func stalledCaptureExplainsTheDemoTimeout() async throws {
        let capture = CaptureProbe { _ in try await Task.sleep(for: .seconds(30)) }
        try await withController(capture: capture) { controller, _ in
            controller.beginDemo()
            try await wait(upTo: 12) { controller.state.problem != nil }
            try await wait(upTo: 2) { controller.phase == .idle }
            #expect(capture.starts == 1)
            #expect(!controller.state.demoRunning)
            #expect(!controller.state.settings.isOn)
            #expect(!controller.state.capturing)
            #expect(capture.stops > 0)
        }
    }

    @Test func missingFramesExhaustRetriesAndExplainDemoFailure() async throws {
        let capture = CaptureProbe { _ in }
        try await withController(capture: capture) { controller, _ in
            controller.beginDemo()
            try await wait(upTo: 12) { controller.state.problem != nil }
            #expect(capture.starts == 3)
            #expect(!controller.state.demoRunning)
            #expect(!controller.state.settings.isOn)
            #expect(!controller.state.capturing)
        }
    }

    @Test(arguments: [false, true])
    func completedDemoRestoresPreviousEffectState(wasOn: Bool) async throws {
        var pixels: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
                                         [kCVPixelBufferMetalCompatibilityKey: true,
                                          kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels)
        #expect(status == kCVReturnSuccess)
        let frame = try #require(pixels)
        CVPixelBufferLockBaseAddress(frame, [])
        let base = try #require(CVPixelBufferGetBaseAddress(frame))
        memset(base, 0, CVPixelBufferGetDataSize(frame))
        CVPixelBufferUnlockBaseAddress(frame, [])
        let capture = CaptureProbe { slot in slot.store(frame, capturedAt: CACurrentMediaTime()) }
        try await withController(capture: capture) { controller, _ in
            controller.state.settings.isOn = wasOn
            controller.beginDemo()
            try await wait(upTo: 8) { !controller.state.demoRunning }
            #expect(controller.state.settings.isOn == wasOn)
            #expect(controller.state.problem == nil)
        }
    }

    @Test func occupiedShortcutLeavesTheWorkingRegistrationAndStoredSettingsIntact() async throws {
        let occupied = ToggleShortcut(keyCode: UInt16(kVK_F19), modifiers: [.command, .control, .shift])
        let blocker = try GlobalShortcut(occupied) {}
        try await withController(capture: CaptureProbe { _ in }) { controller, store in
            let previous = controller.state.settings.toggleShortcut
            controller.state.settings.toggleShortcut = occupied
            #expect(controller.state.settings.toggleShortcut == previous)
            #expect(loadSettings(from: store).toggleShortcut == previous)
            #expect(controller.state.shortcutProblem != nil)
            #expect(throws: ShortcutFailure.self) { try GlobalShortcut(previous) {} }
        }
        withExtendedLifetime(blocker) {}
    }

    @Test func turningEffectOffClearsLivePreview() async throws {
        try await withController(capture: CaptureProbe { _ in }) { controller, _ in
            controller.state.settings.isOn = true
            controller.state.sensorReady = true
            controller.state.measuredAngle = 90
            controller.state.previewUsesLid = true
            controller.state.settings.isOn = false
            #expect(!controller.state.sensorReady)
            #expect(controller.state.measuredAngle == nil)
            #expect(!controller.state.previewUsesLid)
        }
    }
}
