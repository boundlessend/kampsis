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

@MainActor @Observable final class AppState {
    var settings: EffectSettings {
        didSet {
            guard settings != oldValue else { return }
            saveSettings(settings, to: store)
            onSettingsChange?(oldValue, settings)
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
    var problem: String?
    var shortcutProblem: String?

    @ObservationIgnored var lidEstimate = LidEstimate.unknown
    @ObservationIgnored var onSettingsChange: ((EffectSettings, EffectSettings) -> Void)?
    @ObservationIgnored private let store: UserDefaults

    init(store: UserDefaults) {
        self.store = store
        let settings = loadSettings(from: store)
        self.settings = settings
        previewAngle = initialPreviewAngle(fadeOutAngle: settings.fadeOutAngle)
    }

    var statusLine: String {
        if !settings.isOn { return String(localized: "Off") }
        if suspended { return String(localized: "Mac is asleep or locked") }
        if !screenAccess { return String(localized: "No screen access") }
        if problem != nil { return String(localized: "Needs attention") }
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
