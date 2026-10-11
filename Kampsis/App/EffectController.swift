import AppKit
import os
import QuartzCore
import ServiceManagement

/// те же события используются системными наблюдателями и изолированными интеграционными проверками
enum EffectSleepEvent {
    case machineSleeping(Bool)
    case displaySleeping(Bool)
    case sessionLocked(Bool)
}

/// связывает датчик, захват, оверлей и настройки; решения о захвате принимает `planEffect`
@MainActor final class EffectController {
    static let shared = EffectController(store: .standard, stream: ScreenStream())

    private static let log = Logger(subsystem: "io.github.boundlessend.kampsis", category: "effect")
    /// сколько после последнего движения крышки захват ещё держится наготове
    private static let movementGrace = 0.85
    private static let quietRecheckDelay: Duration = .milliseconds(900)
    private static let stopDelay: Duration = .milliseconds(300)
    private static let firstFrameTimeout = 2.0
    private static let demoCaptureTimeout = 26.0
    /// сколько раз подряд поток поднимается заново, прежде чем сбой показывается человеку
    private static let restartLimit = 2
    /// поток, проживший столько, считается здоровым: следующий сбой это новый случай
    private static let healthyCapture = 60.0

    let state: AppState
    let sensor = LidReader()
    let updates: UpdateChecker
    private let stream: any ScreenCapturing
    private let pointer = PointerHider()
    private let chime = ChimePlayer()
    private var shortcut: GlobalShortcut?

    private var launched = false
    private(set) var phase = CapturePhase.idle
    private var captureJob: Task<Void, Never>?
    private var freezeJob: Task<Void, Never>?
    private var captureSession = 0
    private var scheduledStop: Task<Void, Never>?
    private var quietRecheck: Task<Void, Never>?
    private var demoJob: Task<Void, Never>?
    private var demoValue = 0.0
    private var isOnBeforeDemo: Bool?
    private var captureFailed = false
    private var captureStopProblem: (any Error)?
    private var restartsLeft = EffectController.restartLimit
    private var captureRunningSince = Double.infinity
    private var firstFrameMilliseconds: Double?
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

    init(store: UserDefaults, stream: any ScreenCapturing) {
        state = AppState(store: store)
        self.stream = stream
        let releases = Result { () throws(GitHubReleasesFailure) in
            try GitHubReleases(repository: AppIdentity.releasesRepository, session: .shared)
        }
        updates = UpdateChecker(releases: releases, installedVersion: AppIdentity.version, store: store)
    }

    // MARK: действия пользователя

    func start(background: Bool = false) {
        guard !launched else { return }
        launched = true
        state.screenAccess = stream.hasScreenAccess
        refreshLoginStatus()
        state.problem = metalProblem
        sensor.onReading = { [weak self] reading in self?.receive(reading) }
        sensor.onStatus = { [weak self] status in self?.sensorChanged(status) }
        state.onSettingsChange = { [weak self] old, new in self?.settingsChanged(from: old, to: new) }
        state.onCaptureModeChange = { [weak self] in
            guard let self else { return }
            self.state.problem = self.metalProblem
            self.allowCaptureAgain()
            self.endDemo()
            self.endCapture()
            self.state.onCaptureRouteChange?()
        }
        pointer.onProblem = { [weak self] problem in self?.state.pointerProblem = problem }
        state.pointerProblem = state.captureMode == .live ? nil : pointer.backgroundProblem
        if state.settings.isOn { sensor.start() }
        registerShortcut()
        observeSystem()
        timers.append(Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshScreenAccess() }
        })
        startDiagnosticsIfRequested()
        updates.start(background: background)
        reevaluate()
    }

    func toggle() {
        guard state.canUseEffect else { return }
        if state.demoRunning {
            endDemo()
        } else {
            state.settings.isOn.toggle()
        }
    }

    func retry() {
        state.problem = metalProblem
        allowCaptureAgain()
        sensor.stop()
        state.clearSensorReading()
        if state.settings.isOn, !state.suspended { sensor.start() }
        endCapture()
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
        let captureApp = state.usesTerminalCapture ? "Terminal" : AppIdentity.name
        let alert = NSAlert()
        alert.messageText = String(localized: "Access is on, but the effect can’t see it")
        alert.informativeText = String(localized: """
        macOS may have remembered the permission for another copy of \(captureApp).

        1. Open Screen Recording in Privacy & Security settings.
        2. Select \(captureApp) and remove it with the “−” button.
        3. Add the installed app with the “+” button and turn access on.
        4. Restart \(AppIdentity.name) if macOS asks.
        """)
        alert.addButton(withTitle: String(localized: "Open Settings"))
        alert.addButton(withTitle: String(localized: "Close"))
        if alert.runModal() == .alertFirstButtonReturn { openScreenCaptureSettings() }
    }

    func setOpensAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            state.loginProblem = nil
        } catch {
            state.loginProblem = String(localized: "Launch at login didn’t change: \(error.localizedDescription)")
        }
        refreshLoginStatus()
        if enabled, SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    func refreshLoginStatus() {
        let status = SMAppService.mainApp.status
        state.loginNeedsApproval = status == .requiresApproval
        state.launchesAtLogin = status == .enabled || state.loginNeedsApproval
    }

    func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }

    /// освобождает наблюдателей и ждёт остановки текущего захвата
    func stop() async throws {
        launched = false
        updates.stop()
        endDemo()
        quietRecheck?.cancel()
        quietRecheck = nil
        var sensorStopProblem: (any Error)?
        do { try await sensor.stopAndWait() }
        catch { sensorStopProblem = error }
        state.clearSensorReading()
        state.onSettingsChange = nil
        state.onCaptureModeChange = nil
        timers.forEach { $0.invalidate() }
        timers.removeAll()
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        shortcut = nil
        endCapture()
        await captureJob?.value
        overlay?.panel.close()
        overlay = nil
        if let sensorStopProblem { throw sensorStopProblem }
        if let captureStopProblem { throw captureStopProblem }
    }

    func beginDemo() {
        guard state.canUseEffect, state.screenAccess, !state.suspended, !state.demoRunning else { return }
        state.problem = nil
        allowCaptureAgain()
        isOnBeforeDemo = state.settings.isOn
        demoValue = 0
        state.demoRunning = true
        state.settings.isOn = true
        reevaluate()
        demoJob = Task { [weak self] in
            guard let self else { return }
            do { try await self.waitForCapture() }
            catch is CancellationError { return }
            catch {
                self.failCapture(CaptureTrouble(message: error.localizedDescription, recovery: .blocked))
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
        state.lidEstimate = state.lidEstimate.receiving(reading, leadLimit: predictionLead(state.settings.prediction))
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
            state.sensorNote = String(localized: "The sensor is read in the background, 30–120 times per second")
        case let .unavailable(explanation):
            state.sensorReady = false
            state.sensorNote = explanation
            state.measuredAngle = nil
            state.lidEstimate = .unknown
            reevaluate()
        }
    }

    private func settingsChanged(from old: EffectSettings, to new: EffectSettings) {
        if old.toggleShortcut != new.toggleShortcut, !registerShortcut() {
            state.settings.toggleShortcut = old.toggleShortcut
        }
        if old.isOn != new.isOn {
            if new.isOn {
                if !state.suspended { sensor.start() }
            } else {
                _ = finishDemo()
                sensor.stop()
                state.clearSensorReading()
                chimeLatch = .disarmed
                endCapture()
            }
        }
        reevaluate()
    }

    /// действующее сочетание сохраняется, пока новая регистрация не завершилась успешно
    @discardableResult private func registerShortcut() -> Bool {
        if shortcut?.value == state.settings.toggleShortcut { return true }
        do {
            shortcut = try GlobalShortcut(state.settings.toggleShortcut) { [weak self] in self?.toggle() }
            state.shortcutProblem = nil
            return true
        } catch {
            state.shortcutProblem = error.localizedDescription
            return false
        }
    }

    private func refreshScreenAccess() {
        let granted = stream.hasScreenAccess
        guard granted != state.screenAccess else { return }
        state.screenAccess = granted
        if granted {
            state.problem = nil
            allowCaptureAgain()
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
            state.clearSensorReading()
            chimeLatch = .disarmed
            state.lidEstimate = .unknown
        } else {
            state.problem = metalProblem
            allowCaptureAgain()
            if state.settings.isOn { sensor.start() }
            refreshScreenAccess()
            reevaluate()
        }
    }

    func receiveSleepEvent(_ event: EffectSleepEvent) {
        switch event {
        case let .machineSleeping(asleep): machineAsleep = asleep
        case let .displaySleeping(asleep): displayAsleep = asleep
        case let .sessionLocked(locked): sessionLocked = locked
        }
        applySleepState()
    }

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        observe(workspace, NSWorkspace.willSleepNotification) { $0.receiveSleepEvent(.machineSleeping(true)) }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.receiveSleepEvent(.machineSleeping(false)) }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.receiveSleepEvent(.displaySleeping(true)) }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.receiveSleepEvent(.displaySleeping(false)) }
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.receiveSleepEvent(.sessionLocked(true)) }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.receiveSleepEvent(.sessionLocked(false)) }
        observe(.default, NSApplication.didChangeScreenParametersNotification) { controller in
            // список экранов сменился: сбой «нет экрана для захвата» больше не актуален
            controller.allowCaptureAgain()
            controller.endCapture()
            _ = controller.after(.milliseconds(400)) { $0.reevaluate() }
        }
        observe(.default, NSApplication.didBecomeActiveNotification) { $0.refreshScreenAccess(); $0.refreshLoginStatus() }
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
        guard state.settings.isOn, !state.suspended,
              let angle = state.lidEstimate.degrees(at: time, leadLimit: predictionLead(state.settings.prediction)) else { return 0 }
        return foldProgress(angle: angle, fadeOutAngle: state.settings.fadeOutAngle)
    }

    private func reevaluate() {
        guard launched else { return }
        if state.captureMode == .frozen, phase == .running, !stream.isStreaming,
           !state.demoRunning, readingProgress == 0 {
            // новый сгиб должен получить новый кадр, даже если крышка быстро вернулась к порогу
            endCapture()
            return
        }
        let now = CACurrentMediaTime()
        let snapshot = EffectSnapshot(
            isOn: state.settings.isOn && state.settingsProblem == nil,
            screenAccess: state.screenAccess,
            suspended: state.suspended,
            builtInDisplay: ScreenStream.builtInDisplay() != nil,
            demo: state.demoRunning,
            measuredAngle: state.measuredAngle,
            fadeOutAngle: state.settings.fadeOutAngle,
            closingSpeed: state.lidEstimate.closingSpeed(at: now),
            progress: readingProgress,
            movedRecently: now - lastLidMovement < Self.movementGrace,
            captureFailed: captureFailed,
            rendererBroken: metalProblem != nil,
            phase: phase,
            stopScheduled: scheduledStop != nil,
            hasFrame: stream.frames.latest != nil,
            captureMode: state.captureMode
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
        case .prepareOverlay:
            prepareOverlay()
        case .presentOverlay:
            presentOverlay()
        }
    }

    private func beginCapture() {
        guard let mode = state.captureMode else { return }
        let requestedAt = CACurrentMediaTime()
        presentationLog = PresentationLog(requestedAt: requestedAt)
        // прозрачное окно заранее регистрирует приложение для фильтра ScreenCaptureKit при фоновом запуске
        guard orderedOverlay() != nil else { return }
        captureSession += 1
        let session = captureSession
        phase = .starting
        firstFrameMilliseconds = nil
        captureJob = Task { [weak self] in
            guard let self else { return }
            do {
                let visibleWindows = NSApp.windows.filter { $0.isVisible && $0 !== self.overlay?.panel }
                try await self.stream.start(mode: mode, showing: visibleWindows) { [weak self] trouble in
                    guard let self, self.captureSession == session else { return }
                    self.failCapture(trouble)
                }
                try await self.waitForFirstFrame()
                guard self.captureSession == session else { return }
                self.firstFrameMilliseconds = (CACurrentMediaTime() - requestedAt) * 1000
                self.phase = .running
                self.captureRunningSince = CACurrentMediaTime()
                self.state.capturing = true
                self.captureJob = nil
                self.reevaluate()
                self.freezeCaptureIfNeeded()
            } catch is CancellationError {
                return
            } catch {
                guard self.captureSession == session else { return }
                self.captureJob = nil
                self.failCapture(captureTrouble(error))
            }
        }
    }

    private func endCapture() {
        guard phase != .stopping else { return }
        captureStopProblem = nil
        captureSession += 1
        scheduledStop?.cancel()
        scheduledStop = nil
        let pending = captureJob
        pending?.cancel()
        freezeJob?.cancel()
        freezeJob = nil
        dismissOverlay()
        phase = .stopping
        state.capturing = false
        captureJob = Task { [weak self] in
            await pending?.value
            guard let self else { return }
            do { try await self.stream.stop() }
            catch {
                self.captureStopProblem = error
                self.captureFailed = true
                self.state.problem = error.localizedDescription
                Self.log.error("capture stop failed: recovery=blocked message=\(error.localizedDescription, privacy: .public)")
            }
            self.overlay?.renderer.reset()
            self.captureJob = nil
            self.phase = .idle
            self.captureRunningSince = .infinity
            self.reevaluate()
        }
    }

    /// рендер удерживает видимый кадр; дальнейшие кадры потока этому сгибу не нужны
    private func freezeCaptureIfNeeded() {
        guard state.captureMode == .frozen, phase == .running, stream.isStreaming,
              overlay?.renderer.holdsFrozenFrame == true, freezeJob == nil else { return }
        let session = captureSession
        freezeJob = Task { [weak self] in
            guard let self else { return }
            defer { if self.captureSession == session { self.freezeJob = nil } }
            do { try await self.stream.freeze() }
            catch {
                guard self.captureSession == session else { return }
                self.failCapture(CaptureTrouble(message: error.localizedDescription, recovery: .blocked))
            }
        }
    }

    /// сбой захвата: восстановимый поднимается заново, пока не кончились попытки, иначе эффект встаёт до вмешательства
    private func failCapture(_ trouble: CaptureTrouble) {
        if CACurrentMediaTime() - captureRunningSince > Self.healthyCapture { restartsLeft = Self.restartLimit }
        if trouble.recovery == .restart, restartsLeft > 0 {
            restartsLeft -= 1
            Self.log.error("""
            capture restarting: message=\(trouble.message, privacy: .public) \
            attemptsLeft=\(self.restartsLeft, privacy: .public)
            """)
            endCapture()
            return
        }
        Self.log.error("""
        capture failed: message=\(trouble.message, privacy: .public) \
        recovery=\(String(describing: trouble.recovery), privacy: .public)
        """)
        captureFailed = true
        state.problem = String(localized: "Couldn’t show the desktop: \(trouble.message)")
        endDemo()
        endCapture()
    }

    /// разрешает новые попытки захвата: условия изменились, прежний сбой больше ничего не говорит
    private func allowCaptureAgain() {
        captureFailed = false
        restartsLeft = Self.restartLimit
    }

    private func waitForFirstFrame() async throws {
        let deadline = CACurrentMediaTime() + Self.firstFrameTimeout
        while stream.frames.latest == nil {
            guard CACurrentMediaTime() < deadline else { throw CaptureFailure.noFrames }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// ждёт захват с запасом на повторные попытки; отмена отличается от таймаута
    private func waitForCapture() async throws {
        let deadline = CACurrentMediaTime() + Self.demoCaptureTimeout
        while !state.capturing {
            try Task.checkCancellation()
            guard state.demoRunning, !captureFailed else { throw CancellationError() }
            guard CACurrentMediaTime() < deadline else { throw CaptureFailure.noFrames }
            try await Task.sleep(for: .milliseconds(30))
        }
        try Task.checkCancellation()
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

    /// прозрачное окно эффекта остаётся готовым к показу
    private func prepareOverlay() {
        guard let overlay = orderedOverlay() else { return }
        if state.overlayShown {
            pointer.release()
            state.overlayShown = false
        }
        overlay.renderer.wake()
    }

    private func presentOverlay() {
        guard let screen = ScreenStream.builtInDisplay(), let overlay = orderedOverlay() else { return }
        if !state.overlayShown {
            if state.captureMode != .live { pointer.engage(over: screen.frame) }
            state.overlayShown = true
        }
        overlay.renderer.wake()
    }

    /// окно эффекта поверх встроенного экрана; создаётся при первом показе
    private func orderedOverlay() -> (panel: NSPanel, renderer: SheetRenderer)? {
        guard let screen = ScreenStream.builtInDisplay(), case let .success(stack) = MetalStack.shared else { return nil }
        guard let overlay = overlay ?? makeOverlay(stack: stack, frame: screen.frame) else { return nil }
        self.overlay = overlay
        if overlay.panel.frame != screen.frame { overlay.panel.setFrame(screen.frame, display: true) }
        overlay.renderer.presentationLog = presentationLog
        if !overlay.panel.isVisible { overlay.panel.orderFrontRegardless() }
        return overlay
    }

    private func makeOverlay(stack: MetalStack, frame: NSRect) -> (panel: NSPanel, renderer: SheetRenderer)? {
        let renderer: SheetRenderer
        do {
            renderer = try SheetRenderer(stack: stack, frames: stream.frames) { [unowned self] in
                FoldInputs(progress: self.predictedProgress(at: CACurrentMediaTime()),
                                  settings: self.state.settings, isOverlay: true,
                                  reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                                  captureMode: self.state.captureMode)
            }
        } catch {
            // сбой подготовки рендера: перезапуск захвата не поможет
            failCapture(CaptureTrouble(message: error.localizedDescription, recovery: .blocked))
            return nil
        }
        renderer.onFailure = { [weak self] failure in
            self?.failCapture(CaptureTrouble(message: failure.localizedDescription, recovery: .blocked))
        }
        renderer.onFreeze = { [weak self] in self?.freezeCaptureIfNeeded() }
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

    func diagnosticsReport() -> DiagnosticsReport {
        DiagnosticsReport(
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
            pointerProblem: state.pointerProblem,
            loginNeedsApproval: state.loginNeedsApproval,
            loginProblem: state.loginProblem,
            isOn: state.settings.isOn,
            demo: state.demoRunning,
            metalReady: metalProblem == nil,
            drawnFrames: overlay?.renderer.drawnFrames ?? 0,
            captureFrame: stream.frames.latest?.number ?? 0,
            captureMode: state.captureMode?.rawValue,
            launchRoute: state.usesTerminalCapture ? "terminal" : "application",
            terminalLaunchPreferred: !state.showsCaptureIndicator,
            capturePhase: String(describing: phase),
            settingsProblem: state.settingsProblem,
            streaming: stream.isStreaming,
            displayedFrame: overlay?.renderer.displayedFrameNumber,
            firstFrameMilliseconds: firstFrameMilliseconds,
            status: state.statusLine,
            problem: state.problem,
            shortcutProblem: state.shortcutProblem,
            presentation: presentationLog?.summary()
        )
    }

    func copyDiagnostics() throws {
        let text = String(decoding: try diagnosticsData(diagnosticsReport()), as: UTF8.self)
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.writeObjects([text as NSString]) else { throw DiagnosticsFailure.clipboardUnavailable }
    }

    private func dumpDiagnostics() {
        guard let diagnosticsTarget else { return }
        do {
            try writeDiagnostics(diagnosticsReport(), to: diagnosticsTarget)
        } catch {
            Self.log.error("diagnostics not written: path=\(diagnosticsTarget.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }
}
