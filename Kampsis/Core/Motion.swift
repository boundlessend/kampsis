import Foundation

/// угол, при котором экран считается полностью сложенным
let fullyFoldedAngle = 15.0

/// доля сложения от 0 (эффекта нет) до 1 (экран закрыт) для угла крышки
func foldProgress(angle: Double, fadeOutAngle: Double) -> Double {
    guard angle.isFinite, fadeOutAngle.isFinite, fadeOutAngle > fullyFoldedAngle else { return 0 }
    return ((fadeOutAngle - angle) / (fadeOutAngle - fullyFoldedAngle)).clamped(to: 0...1)
}

/// насколько градусов показанный угол может уходить вперёд последнего отсчёта датчика
func predictionLead(_ prediction: Double) -> Double {
    prediction.clamped(to: EffectSettings.predictionRange) * 12
}

/// темп сложения по ходу крышки: при 0 прогресс линейный, к 1 экран темнеет ближе к закрытию, к -1 раньше
func pacedProgress(_ progress: Double, pace: Double) -> Double {
    pow(progress.clamped(to: 0...1), pow(3, pace))
}

/// прогресс пятисекундной демонстрации: плавно складывается и раскрывается обратно
func demoProgress(elapsed: Double) -> Double {
    let phase = sin(elapsed / demoDuration * .pi)
    return phase * phase * 0.83
}

let demoDuration = 5.0

/// экспоненциально догоняет цель, чтобы кадр не прыгал между отсчётами
struct ProgressSmoother: Equatable, Sendable {
    let value: Double
    let lastTime: Double?

    static let resting = ProgressSmoother(value: 0, lastTime: nil)

    private static let timeConstant = 0.015
    private static let snapDistance = 0.0002

    func approaching(_ target: Double, at time: Double) -> ProgressSmoother {
        let step = lastTime.map { (time - $0).clamped(to: 0...0.1) } ?? 1.0 / 60
        let moved = value + (target - value) * (1 - exp(-step / Self.timeConstant))
        let settled = abs(moved - target) < Self.snapDistance ? target : moved
        return ProgressSmoother(value: settled, lastTime: time)
    }
}

/// звук при открытии: срабатывает один раз после заметного сложения, когда эффект полностью ушёл
struct ChimeLatch: Equatable, Sendable {
    let armed: Bool

    static let disarmed = ChimeLatch(armed: false)

    func after(progress: Double) -> (latch: ChimeLatch, rings: Bool) {
        let armed = armed || progress > 0.08
        if armed, progress <= 0.001 { return (.disarmed, true) }
        return (ChimeLatch(armed: armed), false)
    }
}

struct LidReading: Equatable, Sendable {
    let degrees: Double
    let time: Double
}

/// оценка угла крышки между отсчётами датчика
///
/// датчик отдаёт целые градусы с неровным шагом по времени: медленное движение
/// приходит редкими ступеньками, быстрое идёт отсчётами примерно раз в 100 мс
enum LidEstimate: Equatable, Sendable {
    case unknown
    /// медленное движение: ведём угол от показанного значения к новому отсчёту за длительность интервала
    case glide(from: Double, to: LidReading, duration: Double)
    /// быстрое движение: от отсчёта с учётом скорости и сдвига к уже показанному углу
    case coast(from: LidReading, velocity: Double, lead: Double)

    private enum Tuning {
        static let glideLongestInterval = 2.1
        static let glideShortestInterval = 0.15
        static let glideLargestStep = 1.0
        static let glideContinuation = 0.4
        static let glideStretch = 0.95
        static let staleInterval = 0.25
        static let velocityMemory = 0.25
        static let extrapolationHorizon = 0.1
        static let holdTime = 0.15
        static let decayTime = 0.045
    }

    func degrees(at time: Double, leadLimit: Double) -> Double? {
        switch self {
        case .unknown:
            nil
        case let .glide(start, target, duration):
            Self.glideAngle(start: start, target: target, duration: duration, time: time)
        case let .coast(reading, velocity, lead):
            Self.coastAngle(reading: reading, velocity: velocity, lead: lead, time: time, leadLimit: leadLimit)
        }
    }

    /// скорость закрытия в градусах в секунду; ноль при открытии, медленном движении и устаревшем отсчёте
    func closingSpeed(at time: Double) -> Double {
        guard case let .coast(reading, velocity, _) = self, time - reading.time <= Tuning.staleInterval else { return 0 }
        return max(0, -velocity)
    }

    func receiving(_ reading: LidReading, leadLimit: Double) -> LidEstimate {
        let last: LidReading
        let velocity: Double
        let glideDuration: Double?
        let shown: Double
        switch self {
        case .unknown:
            return .coast(from: reading, velocity: 0, lead: 0)
        case let .glide(start, target, duration):
            (last, velocity, glideDuration) = (target, 0, duration)
            shown = Self.glideAngle(start: start, target: target, duration: duration, time: reading.time)
        case let .coast(from, previousVelocity, lead):
            (last, velocity, glideDuration) = (from, previousVelocity, nil)
            shown = Self.coastAngle(reading: from, velocity: previousVelocity, lead: lead, time: reading.time, leadLimit: leadLimit)
        }
        let interval = reading.time - last.time
        let step = reading.degrees - last.degrees
        guard interval > 0, step != 0 else { return self }

        let stretchedGlide = glideDuration.flatMap { duration in
            interval >= duration * Tuning.glideContinuation ? max(interval, duration * Tuning.glideStretch) : nil
        }
        if interval <= Tuning.glideLongestInterval, abs(step) <= Tuning.glideLargestStep,
           interval >= Tuning.glideShortestInterval || stretchedGlide != nil {
            return .glide(from: shown, to: reading, duration: stretchedGlide ?? interval)
        }

        let rate = step / interval
        if interval > Tuning.staleInterval {
            return .coast(from: reading, velocity: 0, lead: 0)
        }
        if velocity * rate <= 0 {
            return .coast(from: reading, velocity: rate, lead: 0)
        }
        let anchor = rate < 0 ? min(shown, reading.degrees) : max(shown, reading.degrees)
        let blended = velocity * Tuning.velocityMemory + rate * (1 - Tuning.velocityMemory)
        return .coast(from: reading, velocity: blended, lead: anchor - reading.degrees)
    }

    private static func glideAngle(start: Double, target: LidReading, duration: Double, time: Double) -> Double {
        let share = (max(0, time - target.time) / duration).clamped(to: 0...1)
        return (start + (target.degrees - start) * share).clamped(to: 0...180)
    }

    private static func coastAngle(reading: LidReading, velocity: Double, lead: Double, time: Double, leadLimit: Double) -> Double {
        let age = max(0, time - reading.time)
        let ahead = (lead + velocity * min(age, Tuning.extrapolationHorizon))
            .clamped(to: -leadLimit...leadLimit)
        let fade = exp(-max(0, age - Tuning.holdTime) / Tuning.decayTime)
        return (reading.degrees + ahead * fade).clamped(to: 0...180)
    }
}
