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
    var progress: Double
    var movedRecently: Bool
    var captureFailed: Bool
    var rendererBroken: Bool
    var phase: CapturePhase
    var stopScheduled: Bool
    var hasFrame: Bool
    var overlayShown: Bool
    var hideScheduled: Bool
}

enum EffectCommand: Equatable, Sendable {
    case beginCapture
    case endCapture
    case scheduleStop
    case cancelScheduledStop
    case presentOverlay
    case scheduleHide
    case cancelScheduledHide
}

/// ниже этого угла крышка считается закрытой
let lidShutAngle = 5.0
/// запас над углом исчезновения, в котором захват ещё держится
let captureAngleMargin = 8.0
/// прогресс, ниже которого эффект невидим
let invisibleProgress = 0.001

/// захват допустим: эффект включён, доступ есть, Mac не спит и крышка в рабочем диапазоне
func captureAllowed(_ snapshot: EffectSnapshot) -> Bool {
    guard snapshot.isOn, snapshot.screenAccess, !snapshot.suspended, snapshot.builtInDisplay else { return false }
    if snapshot.demo { return true }
    guard let angle = snapshot.measuredAngle, angle.isFinite else { return false }
    return angle > lidShutAngle && angle < snapshot.fadeOutAngle + captureAngleMargin
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
        if snapshot.progress > invisibleProgress, snapshot.hasFrame {
            if snapshot.hideScheduled { commands.append(.cancelScheduledHide) }
            commands.append(.presentOverlay)
        } else if snapshot.progress <= invisibleProgress, snapshot.overlayShown, !snapshot.hideScheduled {
            commands.append(.scheduleHide)
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
