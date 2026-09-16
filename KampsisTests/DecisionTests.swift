import Testing
@testable import Kampsis

struct DecisionTests {
    /// крышка приоткрыта до 80°, всё разрешено, захвата ещё нет
    private let ready = EffectSnapshot(
        isOn: true, screenAccess: true, suspended: false, builtInDisplay: true, demo: false,
        measuredAngle: 80, fadeOutAngle: 110, closingSpeed: 0, progress: foldProgress(angle: 80, fadeOutAngle: 110),
        movedRecently: true, captureFailed: false, rendererBroken: false, phase: .idle,
        stopScheduled: false, hasFrame: false
    )

    private func with(_ change: (inout EffectSnapshot) -> Void) -> EffectSnapshot {
        var snapshot = ready
        change(&snapshot)
        return snapshot
    }

    @Test func closingLidStartsCaptureAtAnyAngle() {
        let resting = with { $0.measuredAngle = 130; $0.fadeOutAngle = 60; $0.progress = 0 }
        #expect(planEffect(resting) == [], "неподвижная крышка вне запаса захват не включает")
        #expect(planEffect(with { $0.measuredAngle = 130; $0.fadeOutAngle = 60; $0.progress = 0; $0.closingSpeed = 20 })
            == [.beginCapture], "крышка пошла вниз: захват прогревается заранее")
        #expect(planEffect(with { $0.measuredAngle = 66; $0.fadeOutAngle = 60; $0.progress = 0 }) == [.beginCapture],
                "в запасе над углом исчезновения захват держится и без движения")
    }

    @Test func captureGatesOverrideDemo() {
        #expect(captureAllowed(ready))
        #expect(!captureAllowed(with { $0.measuredAngle = 123 }))
        #expect(!captureAllowed(with { $0.measuredAngle = 0 }))
        #expect(!captureAllowed(with { $0.measuredAngle = nil }))
        #expect(captureAllowed(with { $0.measuredAngle = nil; $0.demo = true }))
        #expect(!captureAllowed(with { $0.isOn = false; $0.demo = true }))
        #expect(!captureAllowed(with { $0.screenAccess = false; $0.demo = true }))
        #expect(!captureAllowed(with { $0.suspended = true; $0.demo = true }))
        #expect(!captureAllowed(with { $0.builtInDisplay = false; $0.demo = true }))
    }

    @Test func movingLidStartsCaptureOnce() {
        #expect(planEffect(ready) == [.beginCapture])
        #expect(planEffect(with { $0.phase = .starting }) == [])
        #expect(planEffect(with { $0.phase = .stopping }) == [], "новый захват ждёт окончания остановки")
        #expect(planEffect(with { $0.stopScheduled = true; $0.phase = .running }) == [.cancelScheduledStop])
    }

    @Test func overlayAppearsOnlyWithAFrame() {
        let running = with { $0.phase = .running }
        #expect(planEffect(running) == [])
        #expect(planEffect(with { $0.phase = .running; $0.hasFrame = true }) == [.presentOverlay])
    }

    @Test func overlayWaitsTransparentAboveTheThreshold() {
        let justBelow = with {
            $0.phase = .running; $0.hasFrame = true
            $0.measuredAngle = 109; $0.progress = foldProgress(angle: 109, fadeOutAngle: 110)
        }
        #expect(justBelow.progress > invisibleProgress)
        #expect(planEffect(justBelow) == [.presentOverlay])
        #expect(planEffect(with { $0.phase = .running; $0.hasFrame = true; $0.progress = 0 }) == [.prepareOverlay])
    }

    @Test func pausedLidLetsCaptureSettleBeforeStopping() {
        let idleLid = with { $0.phase = .running; $0.measuredAngle = 118; $0.progress = 0; $0.movedRecently = false }
        #expect(planEffect(idleLid) == [.scheduleStop])
        #expect(planEffect(with { $0.phase = .running; $0.measuredAngle = 118; $0.progress = 0; $0.movedRecently = false; $0.stopScheduled = true }) == [])
        #expect(planEffect(with { $0.phase = .running; $0.builtInDisplay = false }) == [.scheduleStop])
        #expect(planEffect(with { $0.phase = .running; $0.rendererBroken = true }) == [.scheduleStop])
        #expect(planEffect(with { $0.phase = .idle; $0.measuredAngle = 118; $0.progress = 0; $0.movedRecently = false }) == [])
    }

    @Test func finalReasonsStopCaptureImmediately() {
        let reasons: [(String, (inout EffectSnapshot) -> Void)] = [
            ("выключен", { $0.isOn = false }),
            ("нет доступа", { $0.screenAccess = false }),
            ("сон", { $0.suspended = true }),
            ("крышка закрыта", { $0.measuredAngle = 3 }),
            ("сбой захвата", { $0.captureFailed = true }),
        ]
        for (reason, change) in reasons {
            for phase in [CapturePhase.starting, .running] {
                let snapshot = with { $0.phase = phase; change(&$0) }
                #expect(planEffect(snapshot) == [.endCapture], "\(reason), фаза \(phase)")
            }
            #expect(planEffect(with { $0.phase = .stopping; change(&$0) }) == [])
        }
    }

    @Test func demoCapturesWithoutLidAngle() {
        #expect(planEffect(with { $0.measuredAngle = nil; $0.movedRecently = false; $0.progress = 0.2; $0.demo = true })
            == [.beginCapture])
    }

    @Test func pointerIsHiddenOnceAndShownOnlyByUs() {
        #expect(pointerAction(hiddenByUs: false, overEffect: true) == .hide)
        #expect(pointerAction(hiddenByUs: true, overEffect: true) == nil)
        #expect(pointerAction(hiddenByUs: true, overEffect: false) == .show)
        #expect(pointerAction(hiddenByUs: false, overEffect: false) == nil, "чужой скрытый курсор не показываем")
    }
}
