import Foundation
import IOKit.hid
import QuartzCore
import os

enum SensorStatus: Equatable, Sendable {
    case reading
    case unavailable(String)
}

private let sensorLog = Logger(subsystem: "io.github.boundlessend.lidfold", category: "lid-sensor")

/// коннектор к датчику угла крышки: опрос идёт в фоне, результаты приходят на главный поток
@MainActor final class LidReader {
    let modelIdentifier = hardwareModel()
    var onReading: ((LidReading) -> Void)?
    var onStatus: ((SensorStatus) -> Void)?
    private var poller: LidPoller?
    private var session = 0

    func start() {
        guard poller == nil else { return }
        session += 1
        let current = session
        let poller = LidPoller(
            model: modelIdentifier,
            deliverReading: { [weak self] reading in
                guard let self, self.session == current else { return }
                self.onReading?(reading)
            },
            deliverStatus: { [weak self] status in
                guard let self, self.session == current else { return }
                self.onStatus?(status)
            }
        )
        self.poller = poller
        poller.begin()
    }

    func stop() {
        session += 1
        poller?.end()
        poller = nil
    }
}

/// опрос HID-устройства; всё изменяемое состояние трогается только на своей очереди
private final class LidPoller: @unchecked Sendable {
    private static let movingPeriod = 1.0 / 120
    private static let idlePeriod = 1.0 / 30
    private static let movementWindow = 0.5
    private static let missesBeforeFailure = 10

    private let queue = DispatchQueue(label: "io.github.boundlessend.lidfold.lid", qos: .userInteractive)
    private let model: String
    private let deliverReading: @MainActor @Sendable (LidReading) -> Void
    private let deliverStatus: @MainActor @Sendable (SensorStatus) -> Void
    private var hidDevice: IOHIDDevice?
    private var pollTimer: DispatchSourceTimer?
    private var lastDegrees: Double?
    private var lastChange = 0.0
    private var period = LidPoller.idlePeriod
    private var misses = 0

    init(model: String,
         deliverReading: @escaping @MainActor @Sendable (LidReading) -> Void,
         deliverStatus: @escaping @MainActor @Sendable (SensorStatus) -> Void) {
        self.model = model
        self.deliverReading = deliverReading
        self.deliverStatus = deliverStatus
    }

    func begin() { queue.async { self.connect() } }
    func end() { queue.async { self.disconnect() } }

    private func connect() {
        let devices = discoverHIDDevices()
        let described = devices.map { ($0, hidTraits(of: $0)) }
        let lidSources = described.filter { $0.1.isLidAngleSource }.map(\.0)
        guard !lidSources.isEmpty else {
            fail(missingSensorExplanation(model: model, sawOtherSPUSensors: described.contains { $0.1.isOtherSPUSensor }))
            return
        }
        let pick = pickReadableSensor(lidSources,
            open: { IOHIDDeviceOpen($0, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess },
            readAngle: readLidAngle,
            close: { IOHIDDeviceClose($0, IOOptionBits(kIOHIDOptionsTypeNone)) })
        switch pick {
        case .busy:
            fail(String(localized: "Couldn’t open the lid sensor. Quit other apps that read the lid angle, then click “Check Again”."))
        case .silent:
            fail(String(localized: "The lid sensor opened but isn’t reporting a valid angle. Click “Check Again”."))
        case let .found(hidDevice, angle):
            self.hidDevice = hidDevice
            lastDegrees = angle
            let first = LidReading(degrees: angle, time: CACurrentMediaTime())
            onMain { [deliverStatus, deliverReading] in
                deliverStatus(.reading)
                deliverReading(first)
            }
            let pollTimer = DispatchSource.makeTimerSource(queue: queue)
            pollTimer.setEventHandler { [weak self] in self?.poll() }
            pollTimer.schedule(deadline: .now(), repeating: period, leeway: .milliseconds(1))
            self.pollTimer = pollTimer
            pollTimer.resume()
        }
    }

    private func poll() {
        guard let hidDevice else { return }
        guard let angle = readLidAngle(hidDevice) else {
            misses += 1
            if misses >= Self.missesBeforeFailure {
                fail(String(localized: "The sensor stopped reporting the lid angle. Click “Check Again”."))
            }
            return
        }
        misses = 0
        let now = CACurrentMediaTime()
        if angle != lastDegrees {
            lastDegrees = angle
            lastChange = now
            let reading = LidReading(degrees: angle, time: now)
            onMain { [deliverReading] in deliverReading(reading) }
        }
        let wanted = now - lastChange < Self.movementWindow ? Self.movingPeriod : Self.idlePeriod
        if wanted != period {
            period = wanted
            pollTimer?.schedule(deadline: .now() + wanted, repeating: wanted, leeway: .milliseconds(1))
        }
    }

    private func fail(_ explanation: String) {
        sensorLog.warning("lid sensor unavailable: \(explanation, privacy: .public)")
        disconnect()
        onMain { [deliverStatus] in deliverStatus(.unavailable(explanation)) }
    }

    private func disconnect() {
        pollTimer?.cancel()
        pollTimer = nil
        if let hidDevice { IOHIDDeviceClose(hidDevice, IOOptionBits(kIOHIDOptionsTypeNone)) }
        hidDevice = nil
    }

    private func onMain(_ work: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
    }
}

private func readLidAngle(_ hidDevice: IOHIDDevice) -> Double? {
    var buffer = [UInt8](repeating: 0, count: 8)
    var length = CFIndex(buffer.count)
    guard IOHIDDeviceGetReport(hidDevice, kIOHIDReportTypeFeature, 1, &buffer, &length) == kIOReturnSuccess else {
        return nil
    }
    return lidAngle(fromReport: Array(buffer.prefix(max(0, length))))
}

private func hidTraits(of hidDevice: IOHIDDevice) -> HIDTraits {
    func numeric(_ key: String) -> NSNumber? {
        IOHIDDeviceGetProperty(hidDevice, key as CFString) as? NSNumber
    }
    let primaryUsageMatches = numeric(kIOHIDPrimaryUsagePageKey)?.intValue == sensorUsagePage
        && numeric(kIOHIDPrimaryUsageKey)?.intValue == lidAngleUsage
    return HIDTraits(
        vendorID: numeric(kIOHIDVendorIDKey)?.intValue,
        productID: numeric(kIOHIDProductIDKey)?.intValue,
        builtIn: numeric(kIOHIDBuiltInKey)?.boolValue,
        reportsLidAngle: IOHIDDeviceConformsTo(hidDevice, UInt32(sensorUsagePage), UInt32(lidAngleUsage)) || primaryUsageMatches
    )
}

/// кандидаты из HID-менеджера и напрямую из сервисов SPU: часть датчиков менеджер не отдаёт
private func discoverHIDDevices() -> [IOHIDDevice] {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    let matching: [[String: Int]] = [
        [kIOHIDVendorIDKey: appleVendorID, kIOHIDDeviceUsagePageKey: sensorUsagePage, kIOHIDDeviceUsageKey: lidAngleUsage],
        [kIOHIDVendorIDKey: appleVendorID, kIOHIDProductIDKey: appleSPUProductID],
    ]
    IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
    let managed = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>).map(Array.init) ?? []

    var byRegistryID: [UInt64: IOHIDDevice] = [:]
    for hidDevice in managed + spuHIDDevices() {
        var entryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(hidDevice), &entryID) == KERN_SUCCESS else { continue }
        byRegistryID[entryID] = byRegistryID[entryID] ?? hidDevice
    }
    return byRegistryID.sorted { $0.key < $1.key }.map(\.value)
}

private func spuHIDDevices() -> [IOHIDDevice] {
    var matches: io_iterator_t = 0
    let result = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDevice"), &matches)
    guard result == KERN_SUCCESS else {
        sensorLog.warning("SPU services not listed: kern_return=\(result, privacy: .public)")
        return []
    }
    defer { IOObjectRelease(matches) }
    var devices: [IOHIDDevice] = []
    var service = IOIteratorNext(matches)
    while service != 0 {
        if let hidDevice = IOHIDDeviceCreate(kCFAllocatorDefault, service) { devices.append(hidDevice) }
        IOObjectRelease(service)
        service = IOIteratorNext(matches)
    }
    return devices
}

/// идентификатор модели Mac, например Mac17,3
func hardwareModel() -> String {
    var size = 0
    guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return String(localized: "unknown model") }
    var raw = [UInt8](repeating: 0, count: size)
    guard sysctlbyname("hw.model", &raw, &size, nil, 0) == 0 else { return String(localized: "unknown model") }
    return String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
}
