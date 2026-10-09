import Foundation
import Observation

/// данные из Info.plist, без которых сборка считается сломанной
enum AppIdentity {
    static var name: String { infoValue("CFBundleName") }
    static var version: String { infoValue("CFBundleShortVersionString") }
    static var build: String { infoValue("CFBundleVersion") }
    static var releasesRepository: String { infoValue("KampsisReleasesRepository") }

    private static func infoValue(_ key: String) -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            preconditionFailure("в Info.plist нет строкового ключа \(key)")
        }
        return value
    }
}

/// прогресс для окна предпросмотра: с ползунка или с живого угла крышки
func previewProgress(usesLid: Bool, manualAngle: Double, liveAngle: Double?, fadeOutAngle: Double) -> Double {
    guard usesLid else { return foldProgress(angle: manualAngle, fadeOutAngle: fadeOutAngle) }
    guard let liveAngle else { return 0 }
    return foldProgress(angle: liveAngle, fadeOutAngle: fadeOutAngle)
}

/// угол ползунка превью, при котором эффект заметен сразу после запуска
func initialPreviewAngle(fadeOutAngle: Double) -> Double {
    (fadeOutAngle - (fadeOutAngle - fullyFoldedAngle) * 0.32).rounded()
}

/// состояние интерфейса и сохраняемые настройки приложения
@MainActor @Observable final class AppState {
    private static let dockIconKey = "shows-dock-icon"
    private static let menuBarIconKey = "shows-menu-bar-icon"
    private static let captureModeKey = "capture-mode"

    var showsDockIcon: Bool {
        didSet {
            store.set(showsDockIcon, forKey: Self.dockIconKey)
            onDockIconChange?(showsDockIcon)
        }
    }
    var showsMenuBarIcon: Bool {
        didSet { store.set(showsMenuBarIcon, forKey: Self.menuBarIconKey) }
    }
    var showsCaptureIndicator: Bool {
        didSet { store.set(showsCaptureIndicator, forKey: CaptureLaunch.preferenceKey) }
    }
    var captureMode: CaptureMode? {
        didSet {
            guard captureMode != oldValue else { return }
            if let captureMode { store.set(captureMode.rawValue, forKey: Self.captureModeKey) }
            onCaptureModeChange?()
        }
    }
    var captureModeProblem: String? {
        captureMode == nil ? String(localized: "The saved capture mode isn’t recognized. Choose a capture mode to use the effect.") : nil
    }
    let usesTerminalCapture = CaptureLaunch.isTerminalSession
    var captureLaunchPending = false
    var captureLaunchProblem: String?
    var settingsProblem: String?
    var wantsTerminalCapture: Bool { !showsCaptureIndicator && captureMode != nil && captureMode != .snapshot }
    var canUseEffect: Bool { captureMode != nil && settingsProblem == nil && !captureLaunchPending }
    var settings: EffectSettings {
        didSet {
            guard settingsProblem == nil, settings != oldValue else { return }
            onSettingsChange?(oldValue, settings)
            guard settings != oldValue else { return }
            saveSettings(settings, to: store)
        }
    }
    var measuredAngle: Double?
    var sensorReady = false
    var sensorNote = String(localized: "Connecting to the lid sensor…")
    var screenAccess = false
    var capturing = false
    var overlayShown = false
    var suspended = false
    var demoRunning = false
    var previewUsesLid = false
    var previewAngle: Double
    var launchesAtLogin = false
    var loginNeedsApproval = false
    var loginProblem: String?
    var pointerProblem: String?
    var problem: String?
    var shortcutProblem: String?

    /// сбрасывает живое превью вместе с остановкой датчика
    func clearSensorReading() {
        sensorReady = false
        measuredAngle = nil
        lidEstimate = .unknown
        previewUsesLid = false
    }

    @ObservationIgnored var lidEstimate = LidEstimate.unknown
    @ObservationIgnored var onDockIconChange: ((Bool) -> Void)?
    @ObservationIgnored var onCaptureIndicatorChange: ((Bool) -> Void)?
    @ObservationIgnored var onCaptureModeChange: (() -> Void)?
    @ObservationIgnored var onCaptureRouteChange: (() -> Void)?
    @ObservationIgnored var onSettingsChange: ((EffectSettings, EffectSettings) -> Void)?
    @ObservationIgnored private let store: UserDefaults

    init(store: UserDefaults) {
        self.store = store
        showsDockIcon = store.bool(forKey: Self.dockIconKey)
        showsMenuBarIcon = store.object(forKey: Self.menuBarIconKey) == nil || store.bool(forKey: Self.menuBarIconKey)
        if store.object(forKey: Self.captureModeKey) == nil {
            // прежние установки без отдельного ключа использовали Live; их выбор не меняется при обновлении
            let existingSettings = store.object(forKey: "effect-settings") != nil
                || store.object(forKey: "automatic-update-checks") != nil
                || store.object(forKey: Self.dockIconKey) != nil
                || store.object(forKey: Self.menuBarIconKey) != nil
                || store.object(forKey: CaptureLaunch.preferenceKey) != nil
            let initialMode: CaptureMode = existingSettings ? .live : .snapshot
            captureMode = initialMode
            store.set(initialMode.rawValue, forKey: Self.captureModeKey)
        } else {
            captureMode = store.string(forKey: Self.captureModeKey).flatMap(CaptureMode.init(rawValue:))
        }
        showsCaptureIndicator = store.object(forKey: CaptureLaunch.preferenceKey) == nil
            || store.bool(forKey: CaptureLaunch.preferenceKey)
        let restored: EffectSettings
        do {
            restored = try loadSettings(from: store)
        } catch {
            var paused = EffectSettings.standard
            paused.isOn = false
            restored = paused
            settingsProblem = error.localizedDescription
        }
        settings = restored
        previewAngle = initialPreviewAngle(fadeOutAngle: restored.fadeOutAngle)
    }

    /// сброс подтверждён в интерфейсе; эффект остаётся выключенным до отдельного включения
    func resetUnreadableSettings() {
        var paused = EffectSettings.standard
        paused.isOn = false
        settingsProblem = nil
        settings = paused
        saveSettings(paused, to: store)
    }

    var statusLine: String {
        if settingsProblem != nil || captureModeProblem != nil { return String(localized: "Needs attention") }
        if !settings.isOn { return String(localized: "Off") }
        if suspended { return String(localized: "Mac is asleep or locked") }
        if !screenAccess { return String(localized: "No screen access") }
        if problem != nil || captureModeProblem != nil { return String(localized: "Needs attention") }
        if demoRunning { return String(localized: "Demo running") }
        if !sensorReady { return String(localized: "Sensor unavailable") }
        if overlayShown { return String(localized: "Effect on screen") }
        if let measuredAngle, measuredAngle > lidShutAngle, measuredAngle < settings.fadeOutAngle { return String(localized: "Getting ready") }
        return String(localized: "Waiting for the lid to move")
    }

    var toggleTitle: String {
        if demoRunning { return String(localized: "Stop Demo") }
        return settings.isOn ? String(localized: "Turn Effect Off") : String(localized: "Turn Effect On")
    }
}
