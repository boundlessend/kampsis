import Foundation
import Testing
@testable import Lidfold

struct MotionTests {
    /// кадры рендера, через которые показанный угол проходит за время `span`
    private func renderedAngles(readings: [LidReading], fps: Double, span: ClosedRange<Double>,
                                fadeOutAngle: Double) -> [(time: Double, angle: Double, progress: Double)] {
        var estimate = LidEstimate.unknown
        var smoother = ProgressSmoother.resting
        var next = 0
        var frames: [(Double, Double, Double)] = []
        for tick in Int(span.lowerBound * fps)...Int(span.upperBound * fps) {
            let moment = Double(tick) / fps
            while next < readings.count, readings[next].time <= moment + 1e-9 {
                estimate = estimate.receiving(readings[next])
                next += 1
            }
            guard let angle = estimate.degrees(at: moment) else { continue }
            smoother = smoother.approaching(foldProgress(angle: angle, fadeOutAngle: fadeOutAngle), at: moment)
            frames.append((moment, angle, smoother.value))
        }
        return frames
    }

    /// датчик шлёт только изменения угла, округлённые до градуса
    private func quantizedReadings(times: [Double], angle: (Double) -> Double) -> [LidReading] {
        var readings: [LidReading] = []
        for time in times {
            let degrees = angle(time).rounded()
            if readings.last?.degrees != degrees { readings.append(LidReading(degrees: degrees, time: time)) }
        }
        return readings
    }

    @Test(arguments: [60.0, 120.0])
    func slowSteppedClosingMovesEveryFrameWithoutJumps(fps: Double) {
        for speed in [0.5, 1, 2, 4, 6, 10] {
            for reportRate in [speed, 10] {
                let times = (0...Int(8 * reportRate)).map { Double($0) / reportRate }
                let readings = quantizedReadings(times: times) { 100 - $0 * speed }
                let frames = renderedAngles(readings: readings, fps: fps, span: 0...8, fadeOutAngle: 110)
                let shown = frames.map { 110 - $0.progress * (110 - fullyFoldedAngle) }
                let steps = zip(shown, shown.dropFirst()).enumerated()
                    .filter { frames[$0.offset].time >= 3 }
                    .map { $0.element.0 - $0.element.1 }
                let context = "\(speed)°/с, \(fps) fps, отчёты \(reportRate) Гц"
                #expect(steps.max()! <= speed / fps * 3, "скачок на ступеньке датчика: \(context)")
                #expect(steps.min()! >= -0.001, "закрытие откатилось назад: \(context)")
                let frozen = Double(steps.filter { abs($0) < 0.001 }.count) / Double(steps.count)
                #expect(frozen < 0.05, "медленное движение замирает между отсчётами: \(context)")
            }
        }
    }

    @Test(arguments: [0.25, 0.5, 1.0, 2.0])
    func glideEndsExactlyAtLastReading(interval: Double) {
        var estimate = LidEstimate.unknown
        for step in 0...6 {
            estimate = estimate.receiving(LidReading(degrees: 100 - Double(step), time: Double(step) * interval))
        }
        let start = 6 * interval
        var previous = estimate.degrees(at: start)!
        let frameCount = Int(120 * (interval + 1))
        for index in stride(from: 1, through: frameCount, by: 1) {
            let angle = estimate.degrees(at: start + Double(index) / 120)!
            #expect(angle >= 94, "угол ушёл дальше последнего отсчёта")
            #expect(angle <= previous + 0.00001)
            previous = angle
        }
        #expect(abs(previous - 94) < 0.00001)
    }

    @Test func coastBridgesTenHertzReportsAndSettles() {
        var estimate = LidEstimate.unknown
        for (degrees, time) in [(120.0, 0.0), (117, 0.1), (114, 0.2)] {
            estimate = estimate.receiving(LidReading(degrees: degrees, time: time))
        }
        #expect(abs(estimate.degrees(at: 0.25)! - 112.5) < 0.01)
        #expect(abs(estimate.degrees(at: 0.29)! - 111.3) < 0.01)
        #expect(abs(estimate.degrees(at: 0.7)! - 114) < 0.01)

        estimate = estimate.receiving(LidReading(degrees: 117, time: 0.3))
        #expect(estimate.degrees(at: 0.35)! > 117, "разворот крышки должен сразу менять направление")

        estimate = estimate.receiving(LidReading(degrees: 100, time: 2))
        #expect(estimate.degrees(at: 2.05)! == 100, "после паузы старая скорость не используется")
    }

    @Test func predictionStaysNearTheSensor() {
        let estimate = LidEstimate.unknown
            .receiving(LidReading(degrees: 90, time: 0))
            .receiving(LidReading(degrees: 20, time: 0.1))
        for tick in 10...100 {
            #expect((16...20).contains(estimate.degrees(at: Double(tick) / 100)!))
        }
    }

    @Test func lateReportDoesNotReverseClosingLid() {
        let estimate = LidEstimate.unknown
            .receiving(LidReading(degrees: 120, time: 0))
            .receiving(LidReading(degrees: 117, time: 0.1))
        var previous = 117.0
        for tick in 1...14 {
            let angle = estimate.degrees(at: 0.1 + Double(tick) / 100)!
            #expect(angle <= previous)
            previous = angle
        }
    }

    /// крышку быстро закрывают до 43°, держат и так же быстро открывают; отчёты с неровным шагом
    @Test(arguments: [60.0, 120.0])
    func fastSweepNeverRecoils(fps: Double) {
        let pattern = [0.097, 0.096, 0.113, 0.095, 0.112]
        var times: [Double] = []
        var time = 10.0
        while time < 16 {
            times.append(time)
            time += pattern[times.count % pattern.count]
        }
        func ease(_ share: Double) -> Double {
            let clamped = share.clamped(to: 0...1)
            return clamped * clamped * (3 - 2 * clamped)
        }
        let readings = quantizedReadings(times: times) { time in
            if time < 13 { return 109 - 66 * ease((time - 10.5) / 2.2) }
            return 43 + 66 * ease((time - 13.4) / 1.8)
        }
        let frames = renderedAngles(readings: readings, fps: fps, span: 10...16, fadeOutAngle: 110)
        for (index, frame) in frames.enumerated() {
            let lastReading = readings.last { $0.time <= frame.time }!
            #expect(abs(frame.angle - lastReading.degrees) <= 4.00001)
            guard index > 0 else { continue }
            let previous = frames[index - 1].progress
            if (11.0...12.5).contains(frame.time) {
                #expect(frame.progress + 0.00001 >= previous, "закрытие откатилось на \(frame.time)")
            }
            if (13.9...15.0).contains(frame.time) {
                #expect(frame.progress - 0.00001 <= previous, "открытие откатилось на \(frame.time)")
            }
        }
    }

    @Test(arguments: [60.0, 120.0])
    func smootherFollowsWithinFiftyMillisecondsWithoutOvershoot(fps: Double) {
        let fiftyMilliseconds = Int(fps / 20)
        var smoother = ProgressSmoother.resting.approaching(0, at: 0)
        for index in stride(from: 1, through: fiftyMilliseconds, by: 1) {
            smoother = smoother.approaching(0.8, at: Double(index) / fps)
            #expect((0...0.8).contains(smoother.value))
        }
        #expect(smoother.value >= 0.76)
        for index in stride(from: 1, through: fiftyMilliseconds, by: 1) {
            smoother = smoother.approaching(0, at: 0.05 + Double(index) / fps)
            #expect(smoother.value >= 0)
        }
        #expect(smoother.value <= 0.04)
    }

    @Test func angleMapsToProgressWithinLimits() {
        #expect(foldProgress(angle: 123, fadeOutAngle: 110) == 0)
        #expect(foldProgress(angle: 110, fadeOutAngle: 110) == 0)
        #expect(abs(foldProgress(angle: 62.5, fadeOutAngle: 110) - 0.5) < 0.001)
        #expect(foldProgress(angle: 15, fadeOutAngle: 110) == 1)
        #expect(foldProgress(angle: 0, fadeOutAngle: 110) == 1)
        #expect(foldProgress(angle: .nan, fadeOutAngle: 110) == 0)
        #expect(foldProgress(angle: 50, fadeOutAngle: 10) == 0)
    }

    @Test func demoFoldsAndReturnsToOpen() {
        #expect(demoProgress(elapsed: 0) == 0)
        #expect(abs(demoProgress(elapsed: demoDuration / 2) - 0.83) < 0.0001)
        #expect(demoProgress(elapsed: demoDuration) < 0.0001)
    }

    @Test func previewUsesSliderOrLiveAngle() {
        #expect(abs(previewProgress(usesLid: false, manualAngle: 59, liveAngle: 100, fadeOutAngle: 80) - 21.0 / 65) < 0.0001)
        #expect(abs(previewProgress(usesLid: true, manualAngle: 59, liveAngle: 55, fadeOutAngle: 80) - 25.0 / 65) < 0.0001)
        #expect(previewProgress(usesLid: true, manualAngle: 20, liveAngle: nil, fadeOutAngle: 80) == 0)
        #expect(initialPreviewAngle(fadeOutAngle: 110) == 80)
    }

    @Test func chimeRingsOncePerNoticeableFold() {
        let sequence: [(Double, Bool)] = [(0, false), (0.02, false), (0, false), (0.4, false), (0.1, false),
                                          (0, true), (0, false), (0.5, false)]
        var latch = ChimeLatch.disarmed
        for (progress, rings) in sequence {
            let result = latch.after(progress: progress)
            #expect(result.rings == rings, "прогресс \(progress)")
            latch = result.latch
        }
        #expect(latch.armed)
        #expect(!ChimeLatch.disarmed.after(progress: 0).rings)
    }

    @Test func choosingLookKeepsBehaviorAndTracksEdits() {
        var current = EffectSettings.standard
        current.isOn = false
        current.chimeOnOpen = true
        current.fadeOutAngle = 80
        for look in Look.allCases {
            var chosen = current.applying(look)
            #expect(chosen.look == look)
            #expect(!chosen.isOn)
            #expect(chosen.chimeOnOpen)
            #expect(chosen.fadeOutAngle == 80)
            #expect(!chosen.isCustomized)
            chosen.blur += 0.05
            #expect(chosen.isCustomized)
            #expect(!chosen.applying(look).isCustomized)
        }
        let reset = current.applying(.matte).resettingAppearance()
        #expect(reset.look == EffectSettings.standard.look)
        #expect(reset.fadeOutAngle == EffectSettings.standard.fadeOutAngle)
        #expect(!reset.isOn)
        #expect(reset.chimeOnOpen)
    }

    @Test func storedValuesAreClamped() {
        var settings = EffectSettings.standard
        settings.fadeOutAngle = 0
        settings.bend = 4
        settings.blur = -3
        settings.dimming = .nan
        let restored = settings.sanitized()
        #expect(restored.fadeOutAngle == 60)
        #expect(restored.bend == 1)
        #expect(restored.blur == 0)
        #expect(restored.dimming == Look.soft.dimming)
    }

    @Test func settingsSurviveRelaunchAndCorruptionFallsBackToStandard() throws {
        let suite = "LidfoldTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(loadSettings(from: defaults) == .standard)
        let custom = EffectSettings.standard.applying(.deep)
        saveSettings(custom, to: defaults)
        #expect(loadSettings(from: defaults) == custom)
        defaults.set(Data("не json".utf8), forKey: "effect-settings")
        #expect(loadSettings(from: defaults) == .standard)
    }
}
