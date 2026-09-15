import AppKit
import os
import QuartzCore
import ServiceManagement

/// связывает датчик, захват, оверлей и настройки; решения о захвате принимает `planEffect`
@MainActor final class EffectController {
    static let shared = EffectController()

    private static let log = Logger(subsystem: "local.boundlessend.lidfold", category: "effect")
    /// сколько после последнего движения крышки захват ещё держится наготове
    private static let movementGrace = 0.85
    private static let quietRecheckDelay: Duration = .milliseconds(900)
    private static let stopDelay: Duration = .milliseconds(300)
    private static let hideDelay: Duration = .milliseconds(250)
    private static let firstFrameTimeout = 2.0
    private static let demoCaptureTimeout = 3.0

    let state = AppState(store: .standard)
    let sensor = LidReader()
    let updates: UpdateChecker
    private let stream = ScreenStream()
    private let pointer = PointerHider()
    private let chime = ChimePlayer()
    private var shortcut: GlobalShortcut?

    private var launched = false
    private var phase = CapturePhase.idle
    private var captureJob: Task<Void, Never>?
    private var captureSession = 0
    private var scheduledStop: Task<Void, Never>?
    private var scheduledHide: Task<Void, Never>?
    private var quietRecheck: Task<Void, Never>?
    private var demoJob: Task<Void, Never>?
    private var demoValue = 0.0
    private var isOnBeforeDemo: Bool?
    private var captureFailed = false
    private var lastLidMovement = -Double.infinity
    private var chimeLatch = ChimeLatch.disarmed
    private var machineAsleep = false
    private var displayAsleep = false
    private var sessionLocked = false
    private var overlay: (panel: NSPanel, renderer: SheetRenderer)?
    private var presentationLog: PresentationLog?
    private var diagnosticsTarget: URL?
    private var timers: [Timer] = []
    private var observers: [(center: NotificationCenter, token: any NSObjectProtocol)] = []

    private init() {
        let releases = Result { () throws(GitHubReleasesFailure) in
            try GitHubReleases(repository: AppIdentity.releasesRepository, session: .shared)
        }
        updates = UpdateChecker(releases: releases, installedVersion: AppIdentity.version, store: .standard)
    }

    // MARK: действия пользователя

    func start() {
        guard !launched else { return }
        launched = true
        state.screenAccess = CGPreflightScreenCaptureAccess()
        state.launchesAtLogin = SMAppService.mainApp.status == .enabled
        state.problem = metalProblem
        sensor.onReading = { [weak self] reading in self?.receive(reading) }
        sensor.onStatus = { [weak self] status in self?.sensorChanged(status) }
        state.onSettingsChange = { [weak self] old, new in self?.settingsChanged(from: old, to: new) }
        if state.settings.isOn { sensor.start() }
        do {
            shortcut = try GlobalShortcut { [weak self] in self?.toggle() }
        } catch {
            state.shortcutProblem = error.localizedDescription
        }
        observeSystem()
        timers.append(Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshScreenAccess() }
        })
        startDiagnosticsIfRequested()
        updates.start()
        reevaluate()
    }

    func toggle() {
        if state.demoRunning {
            endDemo()
        } else {
            state.settings.isOn.toggle()
        }
    }

    func retry() {
        state.problem = metalProblem
        captureFailed = false
        sensor.stop()
        state.lidEstimate = .unknown
        if state.settings.isOn, !state.suspended { sensor.start() }
        refreshScreenAccess()
        reevaluate()
    }

    func requestScreenAccess() {
        if !CGRequestScreenCaptureAccess() { openScreenCaptureSettings() }
        refreshScreenAccess()
    }

    func openScreenCaptureSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    func explainAccessRecovery() {
        let alert = NSAlert()
        alert.messageText = "Доступ включён, но эффект его не видит"
        alert.informativeText = """
        macOS могла запомнить разрешение для другой копии \(AppIdentity.name).

        1. Откройте раздел «Запись экрана» в настройках конфиденциальности.
        2. Выделите \(AppIdentity.name) и удалите кнопкой «−».
        3. Добавьте установленное приложение кнопкой «+» и включите доступ.
        4. Перезапустите \(AppIdentity.name), если macOS попросит.
        """
        alert.addButton(withTitle: "Открыть настройки")
        alert.addButton(withTitle: "Закрыть")
        if alert.runModal() == .alertFirstButtonReturn { openScreenCaptureSettings() }
    }

    func setOpensAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            state.problem = "Автозапуск не изменился: \(error.localizedDescription)"
        }
        state.launchesAtLogin = SMAppService.mainApp.status == .enabled
        if enabled, SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    func beginDemo() {
        guard state.screenAccess, !state.suspended, !state.demoRunning else { return }
        state.problem = nil
        captureFailed = false
        isOnBeforeDemo = state.settings.isOn
        demoValue = 0
        state.demoRunning = true
        state.settings.isOn = true
        reevaluate()
        demoJob = Task { [weak self] in
            guard let self, await self.waitForCapture() else {
                self?.endDemo()
                return
            }
            let began = CACurrentMediaTime()
            while CACurrentMediaTime() - began < demoDuration {
                self.demoValue = demoProgress(elapsed: CACurrentMediaTime() - began)
                self.reevaluate()
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            }
            self.endDemo()
        }
    }

    /// завершает демонстрацию и возвращает включённость эффекта, какой она была до неё
    func endDemo() {
        guard let wasOn = finishDemo() else { return }
        if wasOn != state.settings.isOn { state.settings.isOn = wasOn }
        reevaluate()
    }

    // MARK: события

    private func receive(_ reading: LidReading) {
        state.lidEstimate = state.lidEstimate.receiving(reading)
        state.measuredAngle = reading.degrees
        lastLidMovement = reading.time
        quietRecheck?.cancel()
        quietRecheck = after(Self.quietRecheckDelay) { $0.reevaluate() }
        let (latch, rings) = chimeLatch.after(progress: readingProgress)
        chimeLatch = latch
        if rings, state.settings.chimeOnOpen, state.settings.isOn, state.overlayShown, !state.demoRunning {
            chime.play()
        }
        reevaluate()
    }

    private func sensorChanged(_ status: SensorStatus) {
        switch status {
        case .reading:
            state.sensorReady = true
            state.sensorNote = "Датчик читается в фоне, 30–120 раз в секунду"
        case let .unavailable(explanation):
            state.sensorReady = false
            state.sensorNote = explanation
            state.measuredAngle = nil
            state.lidEstimate = .unknown
            reevaluate()
        }
    }

    private func settingsChanged(from old: EffectSettings, to new: EffectSettings) {
        if old.isOn != new.isOn {
            if new.isOn {
                if !state.suspended { sensor.start() }
            } else {
                _ = finishDemo()
                sensor.stop()
                state.lidEstimate = .unknown
                chimeLatch = .disarmed
                endCapture()
            }
        }
        reevaluate()
    }

    private func refreshScreenAccess() {
        let granted = CGPreflightScreenCaptureAccess()
        guard granted != state.screenAccess else { return }
        state.screenAccess = granted
        if granted {
            state.problem = nil
            captureFailed = false
        } else {
            endDemo()
            endCapture()
        }
        reevaluate()
    }

    private func applySleepState() {
        state.suspended = machineAsleep || displayAsleep || sessionLocked
        if state.suspended {
            endDemo()
            endCapture()
            sensor.stop()
            chimeLatch = .disarmed
            state.lidEstimate = .unknown
        } else {
            state.problem = metalProblem
            captureFailed = false
            if state.settings.isOn { sensor.start() }
            refreshScreenAccess()
            reevaluate()
        }
    }

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        observe(workspace, NSWorkspace.willSleepNotification) { $0.machineAsleep = true; $0.applySleepState() }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.machineAsleep = false; $0.applySleepState() }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.displayAsleep = true; $0.applySleepState() }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.displayAsleep = false; $0.applySleepState() }
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.sessionLocked = true; $0.applySleepState() }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.sessionLocked = false; $0.applySleepState() }
        observe(.default, NSApplication.didChangeScreenParametersNotification) { controller in
            controller.endCapture()
            _ = controller.after(.milliseconds(400)) { $0.reevaluate() }
        }
        observe(.default, NSApplication.didBecomeActiveNotification) { $0.refreshScreenAccess() }
        observe(.default, NSApplication.willTerminateNotification) { $0.dismissOverlay() }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ react: @escaping @MainActor @Sendable (EffectController) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                react(self)
            }
        }
        observers.append((center, token))
    }

    // MARK: захват и оверлей

    private var metalProblem: String? {
        if case let .failure(error) = MetalStack.shared { return error.localizedDescription }
        return nil
    }

    private var readingProgress: Double {
        if state.demoRunning { return demoValue }
        guard state.settings.isOn, !state.suspended, let angle = state.measuredAngle else { return 0 }
        return foldProgress(angle: angle, fadeOutAngle: state.settings.fadeOutAngle)
    }

    /// для кадра берётся угол, предсказанный между отсчётами датчика
    private func predictedProgress(at time: Double) -> Double {
        if state.demoRunning { return demoValue }
        guard state.settings.isOn, !state.suspended, let angle = state.lidEstimate.degrees(at: time) else { return 0 }
        return foldProgress(angle: angle, fadeOutAngle: state.settings.fadeOutAngle)
    }

    private func reevaluate() {
        guard launched else { return }
        let now = CACurrentMediaTime()
        let snapshot = EffectSnapshot(
            isOn: state.settings.isOn,
            screenAccess: state.screenAccess,
            suspended: state.suspended,
            builtInDisplay: ScreenStream.builtInDisplay() != nil,
            demo: state.demoRunning,
            measuredAngle: state.measuredAngle,
            fadeOutAngle: state.settings.fadeOutAngle,
            progress: readingProgress,
            movedRecently: now - lastLidMovement < Self.movementGrace,
            captureFailed: captureFailed,
            rendererBroken: metalProblem != nil,
            phase: phase,
            stopScheduled: scheduledStop != nil,
            hasFrame: stream.frames.latest != nil,
            overlayShown: state.overlayShown,
            hideScheduled: scheduledHide != nil
        )
        planEffect(snapshot).forEach(perform)
    }

    private func perform(_ command: EffectCommand) {
        switch command {
        case .beginCapture:
            beginCapture()
        case .endCapture:
            endCapture()
        case .scheduleStop:
            scheduledStop = after(Self.stopDelay) { controller in
                controller.scheduledStop = nil
                controller.endCapture()
            }
        case .cancelScheduledStop:
            scheduledStop?.cancel()
            scheduledStop = nil
        case .presentOverlay:
            presentOverlay()
        case .scheduleHide:
            scheduledHide = after(Self.hideDelay) { controller in
                controller.scheduledHide = nil
                if controller.readingProgress <= invisibleProgress { controller.dismissOverlay() }
            }
        case .cancelScheduledHide:
            scheduledHide?.cancel()
            scheduledHide = nil
        }
    }

    private func beginCapture() {
        captureSession += 1
        let session = captureSession
        phase = .starting
        presentationLog = diagnosticsTarget == nil ? nil : PresentationLog()
        captureJob = Task { [weak self] in
            guard let self else { return }
            do {
                let visibleWindows = NSApp.windows.filter { $0.isVisible && $0 !== self.overlay?.panel }
                try await self.stream.start(showing: visibleWindows) { [weak self] message in
                    guard let self, self.captureSession == session else { return }
                    self.failCapture(message)
                }
                try await self.waitForFirstFrame()
                guard self.captureSession == session else { return }
                self.phase = .running
                self.state.capturing = true
                self.captureJob = nil
                self.reevaluate()
            } catch is CancellationError {
                return
            } catch {
                guard self.captureSession == session else { return }
                self.captureJob = nil
                self.failCapture(error.localizedDescription)
            }
        }
    }

    private func endCapture() {
        guard phase != .stopping else { return }
        captureSession += 1
        scheduledStop?.cancel()
        scheduledStop = nil
        let pending = captureJob
        pending?.cancel()
        dismissOverlay()
        phase = .stopping
        state.capturing = false
        captureJob = Task { [weak self] in
            await pending?.value
            guard let self else { return }
            await self.stream.stop()
            self.overlay?.renderer.reset()
            self.captureJob = nil
            self.phase = .idle
            self.reevaluate()
        }
    }

    private func failCapture(_ message: String) {
        Self.log.error("capture failed: \(message, privacy: .public)")
        captureFailed = true
        state.problem = "Не получилось показать рабочий стол: \(message)"
        endDemo()
        endCapture()
    }

    private func waitForFirstFrame() async throws {
        let deadline = CACurrentMediaTime() + Self.firstFrameTimeout
        while stream.frames.latest == nil {
            guard CACurrentMediaTime() < deadline else { throw CaptureFailure.noFrames }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// `false`, если захват не начался вовремя или ожидание отменили
    private func waitForCapture() async -> Bool {
        let deadline = CACurrentMediaTime() + Self.demoCaptureTimeout
        while !state.capturing {
            guard CACurrentMediaTime() < deadline else { return false }
            do { try await Task.sleep(for: .milliseconds(30)) } catch { return false }
        }
        return true
    }

    /// снимает демонстрацию без восстановления включённости; возвращает включённость до неё
    private func finishDemo() -> Bool? {
        demoJob?.cancel()
        demoJob = nil
        guard state.demoRunning, let wasOn = isOnBeforeDemo else { return nil }
        isOnBeforeDemo = nil
        state.demoRunning = false
        demoValue = 0
        chimeLatch = .disarmed
        dismissOverlay()
        return wasOn
    }

    private func presentOverlay() {
        guard let screen = ScreenStream.builtInDisplay(), case let .success(stack) = MetalStack.shared else { return }
        guard let overlay = overlay ?? makeOverlay(stack: stack, frame: screen.frame) else { return }
        self.overlay = overlay
        if overlay.panel.frame != screen.frame { overlay.panel.setFrame(screen.frame, display: true) }
        overlay.renderer.presentationLog = presentationLog
        if !state.overlayShown {
            pointer.engage(over: screen.frame)
            overlay.panel.orderFrontRegardless()
            state.overlayShown = true
        }
        overlay.renderer.wake()
    }

    private func makeOverlay(stack: MetalStack, frame: NSRect) -> (panel: NSPanel, renderer: SheetRenderer)? {
        let renderer: SheetRenderer
        do {
            renderer = try SheetRenderer(stack: stack, frames: stream.frames) { [unowned self] in
                FoldInputs(progress: self.predictedProgress(at: CACurrentMediaTime()),
                                  settings: self.state.settings, fadesIn: true,
                                  reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            }
        } catch {
            failCapture(error.localizedDescription)
            return nil
        }
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "\(AppIdentity.name) overlay"
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = renderer.surface
        return (panel, renderer)
    }

    private func dismissOverlay() {
        scheduledHide?.cancel()
        scheduledHide = nil
        overlay?.panel.orderOut(nil)
        overlay?.renderer.surface.paused = true
        state.overlayShown = false
        pointer.release()
    }

    private func after(_ delay: Duration, _ work: @escaping @MainActor (EffectController) -> Void) -> Task<Void, Never> {
        Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self else { return }
            work(self)
        }
    }

    // MARK: диагностика

    private func startDiagnosticsIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--diagnostics"), arguments.indices.contains(flag + 1) else { return }
        diagnosticsTarget = URL(fileURLWithPath: arguments[flag + 1])
        timers.append(Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.dumpDiagnostics() }
        })
    }

    private func dumpDiagnostics() {
        guard let diagnosticsTarget else { return }
        let report = DiagnosticsReport(
            appVersion: AppIdentity.version,
            buildNumber: AppIdentity.build,
            model: sensor.modelIdentifier,
            macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            angle: state.measuredAngle,
            sensorReady: state.sensorReady,
            sensorNote: state.sensorNote,
            screenAccess: state.screenAccess,
            capturing: state.capturing,
            overlayShown: state.overlayShown,
            pointerHidden: pointer.hiddenByUs,
            isOn: state.settings.isOn,
            demo: state.demoRunning,
            metalReady: metalProblem == nil,
            drawnFrames: overlay?.renderer.drawnFrames ?? 0,
            captureFrame: stream.frames.latest?.number ?? 0,
            status: state.statusLine,
            problem: state.problem,
            shortcutProblem: state.shortcutProblem,
            presentation: presentationLog?.summary()
        )
        do {
            try writeDiagnostics(report, to: diagnosticsTarget)
        } catch {
            Self.log.error("diagnostics not written: path=\(diagnosticsTarget.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }
}
