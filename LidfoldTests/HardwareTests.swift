import Testing
@testable import Lidfold

struct HardwareTests {
    private final class FakeSensor {
        let opens: Bool
        let angle: Double?
        var reads = 0
        var closes = 0

        init(opens: Bool, angle: Double?) {
            self.opens = opens
            self.angle = angle
        }
    }

    private func pick(_ sensors: [FakeSensor]) -> SensorPick<FakeSensor> {
        pickReadableSensor(sensors,
                           open: { $0.opens },
                           readAngle: { sensor in sensor.reads += 1; return sensor.angle },
                           close: { $0.closes += 1 })
    }

    @Test func reportCarriesWholeDegreesInLittleEndian() {
        for degrees in [0, 90, 120, 180] {
            #expect(lidAngle(fromReport: [1, UInt8(degrees), 0]) == Double(degrees))
        }
        #expect(lidAngle(fromReport: [1, 0x0C, 0x00, 0xFF]) == 12)
        #expect(lidAngle(fromReport: [1, 0xE0, 0x2E]) == nil, "значение вне 0…180 не угол")
        #expect(lidAngle(fromReport: [2, 120, 0]) == nil, "другой номер отчёта")
        #expect(lidAngle(fromReport: [1, 120]) == nil, "короткий отчёт")
        #expect(lidAngle(fromReport: []) == nil)
    }

    @Test func busySensorIsSkippedWithoutReading() {
        let blocked = FakeSensor(opens: false, angle: 120)
        let working = FakeSensor(opens: true, angle: 120)
        guard case let .found(device, angle) = pick([blocked, working]) else {
            Issue.record("рабочий датчик не выбран")
            return
        }
        #expect(device === working)
        #expect(angle == 120)
        #expect(blocked.reads == 0)
        #expect(blocked.closes == 0)
    }

    @Test func unreadableSensorIsClosedBeforeTryingNext() {
        let silent = FakeSensor(opens: true, angle: nil)
        let working = FakeSensor(opens: true, angle: 95)
        guard case let .found(device, _) = pick([silent, working]) else {
            Issue.record("рабочий датчик не выбран")
            return
        }
        #expect(device === working)
        #expect(silent.closes == 1)
        #expect(working.closes == 0)
    }

    @Test func noReadableSensorLeavesNothingOpen() {
        let silent = FakeSensor(opens: true, angle: nil)
        guard case .silent = pick([silent]) else {
            Issue.record("ожидался открытый, но немой датчик")
            return
        }
        #expect(silent.closes == 1)
        guard case .busy = pick([FakeSensor(opens: false, angle: 10)]) else {
            Issue.record("ожидался занятый датчик")
            return
        }
        guard case .busy = pick([]) else {
            Issue.record("пустой список не должен дать датчик")
            return
        }
    }

    @Test func productIDAloneDoesNotMakeALidSensor() {
        let otherSPU = HIDTraits(vendorID: appleVendorID, productID: appleSPUProductID, builtIn: true, reportsLidAngle: false)
        #expect(!otherSPU.isLidAngleSource)
        #expect(otherSPU.isOtherSPUSensor)
        #expect(!HIDTraits(vendorID: appleVendorID, productID: appleSPUProductID, builtIn: false, reportsLidAngle: true).isLidAngleSource)
        #expect(HIDTraits(vendorID: appleVendorID, productID: 0x9999, builtIn: true, reportsLidAngle: true).isLidAngleSource)
        #expect(HIDTraits(vendorID: appleVendorID, productID: nil, builtIn: nil, reportsLidAngle: true).isLidAngleSource)
        #expect(!HIDTraits(vendorID: 0x1234, productID: appleSPUProductID, builtIn: true, reportsLidAngle: true).isLidAngleSource)
    }

    @Test(arguments: ["MacBookAir10,1", "MacBookPro17,1", "Mac14,7"])
    func modelsWithoutSensorAreNamed(model: String) {
        #expect(missingSensorExplanation(model: model, sawOtherSPUSensors: false).contains("has no lid angle sensor"))
    }

    @Test func unknownModelsAreNotBlocked() {
        #expect(!missingSensorExplanation(model: "Mac99,1", sawOtherSPUSensors: false).contains("has no lid angle sensor"))
        #expect(missingSensorExplanation(model: "Mac14,2", sawOtherSPUSensors: true).contains("reports the lid angle"))
    }

    @Test func captureKeepsOnlyRealWindowNumbers() {
        #expect(capturableWindowIDs([-1, 0, 42, Int.max, 42, 73]) == [42, 73])
    }

    @Test func presentationSummaryMeasuresRealGapsInBoundedMemory() {
        let log = PresentationLog()
        log.record(0)
        log.record(.nan)
        #expect(log.summary().samples == 0)
        for frame in 0..<1201 { log.record(10 + Double(frame) / 60) }
        let summary = log.summary()
        #expect(summary.frames == 1201)
        #expect(summary.samples == PresentationLog.capacity)
        #expect(abs((summary.framesPerSecond ?? 0) - 60) < 0.001)
        #expect(abs((summary.gapP95Milliseconds ?? 0) - 1000.0 / 60) < 0.001)
    }
}
