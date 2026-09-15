import Foundation
import os

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

/// всё, что пользователь настраивает в эффекте
struct EffectSettings: Codable, Equatable, Sendable {
    var isOn: Bool
    var look: Look
    var bend: Double
    var blur: Double
    var dimming: Double
    var fadeOutAngle: Double
    var chimeOnOpen: Bool

    static let fadeOutRange: ClosedRange<Double> = 60...135

    static let standard = EffectSettings(
        isOn: true, look: .soft, bend: Look.soft.bend, blur: Look.soft.blur,
        dimming: Look.soft.dimming, fadeOutAngle: 110, chimeOnOpen: false
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

    /// стандартный вид эффекта с сохранением включённости и звука
    func resettingAppearance() -> EffectSettings {
        var next = EffectSettings.standard
        next.isOn = isOn
        next.chimeOnOpen = chimeOnOpen
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
        return next
    }
}

private let settingsKey = "effect-settings"
private let settingsLog = Logger(subsystem: "io.github.boundlessend.lidfold", category: "settings")

/// читает настройки; при первом запуске или повреждённой записи возвращает стандартные и пишет в лог
func loadSettings(from defaults: UserDefaults) -> EffectSettings {
    guard let data = defaults.data(forKey: settingsKey) else { return .standard }
    do {
        return try JSONDecoder().decode(EffectSettings.self, from: data).sanitized()
    } catch {
        settingsLog.error("stored settings unreadable, using standard: \(error.localizedDescription, privacy: .public)")
        return .standard
    }
}

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
