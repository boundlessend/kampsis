import Foundation

let appleVendorID = 0x05AC
/// продукт Apple SPU: под ним живут и датчик крышки, и другие сенсоры
let appleSPUProductID = 0x8104
/// HID usage page «датчики» и usage, под которым macOS отдаёт угол крышки
let sensorUsagePage = 0x20
let lidAngleUsage = 0x8A

/// угол из feature-отчёта №1: байт номера отчёта и 16-битное значение в градусах, little-endian
func lidAngle(fromReport bytes: [UInt8]) -> Double? {
    guard bytes.count >= 3, bytes[0] == 1 else { return nil }
    let degrees = Int(bytes[1]) | Int(bytes[2]) << 8
    return (0...180).contains(degrees) ? Double(degrees) : nil
}

/// свойства HID-устройства, по которым решаем, что это датчик крышки
struct HIDTraits: Equatable, Sendable {
    let vendorID: Int?
    let productID: Int?
    let builtIn: Bool?
    let reportsLidAngle: Bool

    /// номер продукта сам по себе не доказывает датчик: нужен usage угла крышки
    var isLidAngleSource: Bool {
        vendorID == appleVendorID && builtIn != false && reportsLidAngle
    }

    var isOtherSPUSensor: Bool {
        vendorID == appleVendorID && productID == appleSPUProductID && !reportsLidAngle
    }
}

enum SensorPick<Device> {
    case found(Device, angle: Double)
    /// устройство открылось, но корректного угла не дало
    case silent
    /// ни одно устройство не открылось
    case busy
}

/// первое устройство, которое открылось и вернуло корректный угол; остальные открытые закрываются
func pickReadableSensor<Device>(
    _ devices: [Device],
    open: (Device) -> Bool,
    readAngle: (Device) -> Double?,
    close: (Device) -> Void
) -> SensorPick<Device> {
    var openedAny = false
    for device in devices where open(device) {
        openedAny = true
        if let angle = readAngle(device) { return .found(device, angle: angle) }
        close(device)
    }
    return openedAny ? .silent : .busy
}

/// модели, в которых датчика угла нет физически
private let modelsWithoutLidAngle = [
    "MacBookAir10,1": String(localized: "MacBook Air with M1"),
    "MacBookPro17,1": String(localized: "13″ MacBook Pro with M1"),
    "Mac14,7": String(localized: "13″ MacBook Pro with M2"),
]

/// объяснение для пользователя, почему угол крышки недоступен
func missingSensorExplanation(model: String, sawOtherSPUSensors: Bool) -> String {
    if let name = modelsWithoutLidAngle[model] {
        return String(localized: "The \(name) has no lid angle sensor, so the effect can’t follow the lid. Preview and demo still work.")
    }
    if sawOtherSPUSensors {
        return String(localized: "Apple sensors are visible on this Mac, but none of them reports the lid angle. Send diagnostics from the \(model) to help check compatibility.")
    }
    return String(localized: "Lid angle sensor not found (\(model)). If this model has one, click “Check Again” after the Mac wakes.")
}
