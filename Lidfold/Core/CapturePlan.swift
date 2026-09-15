import Foundation

enum CapturePhase: Equatable, Sendable {
    case idle
    case starting
    case running
    case stopping
}

/// всё, от чего зависит решение о захвате экрана и показе оверлея
struct EffectSnapshot: Equatable, Sendable {
    var isOn: Bool
    var screenAccess: Bool
    var suspended: Bool
    var builtInDisplay: Bool
    var demo: Bool
    var measuredAngle: Double?
    var fadeOutAngle: Double
    var closingSpeed: Double
    var progress: Double
    var movedRecently: Bool
    var captureFailed: Bool
    var rendererBroken: Bool
    var phase: CapturePhase
    var stopScheduled: Bool
    var hasFrame: Bool
}

enum EffectCommand: Equatable, Sendable {
    case beginCapture
    case endCapture
    case scheduleStop
    case cancelScheduledStop
    /// окно эффекта на экране, пока эффект невидим: у только что показанного окна первые кадры теряются
    case prepareOverlay
    case presentOverlay
}

/// ниже этого угла крышка считается закрытой
let lidShutAngle = 5.0
/// запас над углом исчезновения, в котором захват ещё держится
let captureAngleMargin = 8.0
/// за сколько секунд до угла исчезновения начинать захват при быстром закрытии: на Mac17,3 захват
/// запускается до первого кадра за 100-200 мс, а датчик при быстром движении отдаёт угол раз в ~100 мс
let captureStartLead = 0.4
/// прогресс, ниже которого эффект невидим
let invisibleProgress = 0.001

/// захват допустим: эффект включён, доступ есть, Mac не спит и крышка в рабочем диапазоне
func captureAllowed(_ snapshot: EffectSnapshot) -> Bool {
    guard snapshot.isOn, snapshot.screenAccess, !snapshot.suspended, snapshot.builtInDisplay else { return false }
    if snapshot.demo { return true }
    guard let angle = snapshot.measuredAngle, angle.isFinite else { return false }
    return angle > lidShutAngle && angle < snapshot.fadeOutAngle + captureMargin(closingSpeed: snapshot.closingSpeed)
}

/// запас над углом исчезновения: постоянный, а при быстром закрытии растёт, чтобы первый кадр успел до порога
func captureMargin(closingSpeed: Double) -> Double {
    max(captureAngleMargin, closingSpeed * captureStartLead)
}

/// что сделать с захватом и оверлеем в текущем состоянии
func planEffect(_ snapshot: EffectSnapshot) -> [EffectCommand] {
    let needed = snapshot.progress > 0 || snapshot.demo || snapshot.movedRecently
    guard needed, captureAllowed(snapshot), !snapshot.captureFailed, !snapshot.rendererBroken else {
        return planWindDown(snapshot)
    }
    var commands: [EffectCommand] = snapshot.stopScheduled ? [.cancelScheduledStop] : []
    switch snapshot.phase {
    case .idle:
        commands.append(.beginCapture)
    case .starting, .stopping:
        break
    case .running:
        if snapshot.hasFrame {
            commands.append(snapshot.progress > invisibleProgress ? .presentOverlay : .prepareOverlay)
        }
    }
    return commands
}

/// захват больше не нужен: гасим сразу, если причина окончательная, иначе с задержкой на случай возврата крышки
private func planWindDown(_ snapshot: EffectSnapshot) -> [EffectCommand] {
    switch snapshot.phase {
    case .idle, .stopping:
        return []
    case .starting, .running:
        let lidShut = snapshot.measuredAngle.map { $0 <= lidShutAngle } ?? false
        let final = !snapshot.isOn || !snapshot.screenAccess || snapshot.suspended || lidShut || snapshot.captureFailed
        if final { return [.endCapture] }
        return snapshot.stopScheduled ? [] : [.scheduleStop]
    }
}
