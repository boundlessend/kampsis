import Foundation
import os

/// способ получения картинки для сгиба
enum CaptureMode: String, CaseIterable, Identifiable, Sendable {
    case live
    case frozen
    case snapshot

    var id: Self { self }

    var title: String {
        switch self {
        case .live: String(localized: "Live Desktop")
        case .frozen: String(localized: "Freeze at Fold Start")
        case .snapshot: String(localized: "Single Snapshot")
        }
    }

    var summary: String {
        switch self {
        case .live: String(localized: "Prepares capture as the lid moves and keeps the desktop updating during the fold.")
        case .frozen: String(localized: "Prepares capture as the lid moves, then holds the picture and stops the stream when the fold begins.")
        case .snapshot: String(localized: "Takes one picture when the fold begins. No continuous capture; the first picture may take longer.")
        }
    }
}

/// готовый стиль эффекта: задаёт изгиб, размытие и затемнение одним выбором
enum Look: String, Codable, CaseIterable, Identifiable, Sendable {
    case soft
    case deep
    case matte

    var id: Self { self }

    var title: String {
        switch self {
        case .soft: String(localized: "Soft")
        case .deep: String(localized: "Deep")
        case .matte: String(localized: "Matte")
        }
    }

    var summary: String {
        switch self {
        case .soft: String(localized: "Light bend and a little frost")
        case .deep: String(localized: "Deep shade as the lid closes")
        case .matte: String(localized: "Heavily frosted glass")
        }
    }

    var bend: Double {
        switch self {
        case .soft: 0.85
        case .deep: 0.90
        case .matte: 0.65
        }
    }

    var blur: Double {
        switch self {
        case .soft: 0.45
        case .deep: 0.25
        case .matte: 0.90
        }
    }

    var dimming: Double {
        switch self {
        case .soft: 0.35
        case .deep: 0.85
        case .matte: 0.25
        }
    }
}

/// сохраняемые параметры эффекта
struct EffectSettings: Codable, Equatable, Sendable {
    var isOn: Bool
    var look: Look
    var bend: Double
    var blur: Double
    var dimming: Double
    var fadeOutAngle: Double
    /// темп сложения, см. `pacedProgress`
    var pace: Double
    /// насколько смело предугадывать угол между отсчётами датчика, см. `predictionLead`
    var prediction: Double
    var chimeOnOpen: Bool
    var toggleShortcut: ToggleShortcut

    static let fadeOutRange: ClosedRange<Double> = 60...135
    static let paceRange: ClosedRange<Double> = -1...1
    static let predictionRange: ClosedRange<Double> = 0...1

    static let standard = EffectSettings(
        isOn: true, look: .soft, bend: Look.soft.bend, blur: Look.soft.blur,
        dimming: Look.soft.dimming, fadeOutAngle: 60, pace: 0, prediction: 1.0 / 3, chimeOnOpen: false, toggleShortcut: .standard
    )

    /// копия с параметрами выбранного стиля, остальное не трогается
    func applying(_ look: Look) -> EffectSettings {
        var next = self
        next.look = look
        next.bend = look.bend
        next.blur = look.blur
        next.dimming = look.dimming
        return next
    }

    /// пользователь сдвинул хотя бы один ползунок относительно стиля
    var isCustomized: Bool {
        [(bend, look.bend), (blur, look.blur), (dimming, look.dimming)]
            .contains { abs($0.0 - $0.1) > 0.0001 }
    }

    /// стандартный вид эффекта с сохранением включённости, звука и сочетания клавиш
    func resettingAppearance() -> EffectSettings {
        var next = EffectSettings.standard
        next.isOn = isOn
        next.chimeOnOpen = chimeOnOpen
        next.toggleShortcut = toggleShortcut
        return next
    }

    /// значения из хранилища могут быть повреждены: приводим к допустимым диапазонам
    func sanitized() -> EffectSettings {
        func unit(_ value: Double, _ fallback: Double) -> Double {
            value.isFinite ? value.clamped(to: 0...1) : fallback
        }
        var next = self
        next.bend = unit(bend, look.bend)
        next.blur = unit(blur, look.blur)
        next.dimming = unit(dimming, look.dimming)
        next.fadeOutAngle = fadeOutAngle.isFinite
            ? fadeOutAngle.clamped(to: Self.fadeOutRange) : EffectSettings.standard.fadeOutAngle
        next.pace = pace.isFinite ? pace.clamped(to: Self.paceRange) : EffectSettings.standard.pace
        next.prediction = prediction.isFinite ? prediction.clamped(to: Self.predictionRange) : EffectSettings.standard.prediction
        next.toggleShortcut = toggleShortcut.isAcceptable ? toggleShortcut : .standard
        return next
    }
}

private let settingsKey = "effect-settings"
private let settingsLog = Logger(subsystem: "io.github.boundlessend.kampsis", category: "settings")

enum SettingsFailure: LocalizedError {
    case unreadable

    var errorDescription: String? {
        String(localized: "The saved effect settings can’t be read. The effect is off. Reset the effect settings to continue.")
    }
}

/// повреждённая запись остаётся в хранилище до явного сброса пользователем
func loadSettings(from defaults: UserDefaults) throws(SettingsFailure) -> EffectSettings {
    guard defaults.object(forKey: settingsKey) != nil else { return .standard }
    guard let data = defaults.data(forKey: settingsKey) else {
        settingsLog.error("stored effect settings have an invalid type")
        throw .unreadable
    }
    do {
        return try JSONDecoder().decode(EffectSettings.self, from: data).sanitized()
    } catch {
        settingsLog.error("stored effect settings unreadable: code=\((error as NSError).code, privacy: .public)")
        throw .unreadable
    }
}

/// сохраняет параметры эффекта и сообщает в лог об ошибке кодирования
func saveSettings(_ settings: EffectSettings, to defaults: UserDefaults) {
    do {
        defaults.set(try JSONEncoder().encode(settings), forKey: settingsKey)
    } catch {
        settingsLog.error("settings not saved: \(error.localizedDescription, privacy: .public)")
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
