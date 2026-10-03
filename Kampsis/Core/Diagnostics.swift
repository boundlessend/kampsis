import Foundation
import Synchronization

/// плавность показа кадров по фактическим моментам вывода на экран
struct PresentationSummary: Codable, Equatable, Sendable {
    let frames: Int
    let samples: Int
    let seconds: Double?
    let framesPerSecond: Double?
    let gapP95Milliseconds: Double?
    let gapMaxMilliseconds: Double?
}

/// значение из отсортированного непустого массива на заданной доле
func percentile(_ sorted: [Double], _ share: Double) -> Double {
    sorted[Int(Double(sorted.count - 1) * share)]
}

/// частота показа и интервалы между кадрами по ограниченной выборке
func summarizePresentation(times: [Double], totalFrames: Int) -> PresentationSummary {
    let ordered = Set(times).sorted()
    guard ordered.count > 1, let first = ordered.first, let last = ordered.last, last > first else {
        return PresentationSummary(frames: totalFrames, samples: ordered.count, seconds: nil,
                                   framesPerSecond: nil, gapP95Milliseconds: nil, gapMaxMilliseconds: nil)
    }
    let gaps = zip(ordered, ordered.dropFirst()).map { ($1 - $0) * 1000 }.sorted()
    return PresentationSummary(
        frames: totalFrames,
        samples: ordered.count,
        seconds: last - first,
        framesPerSecond: Double(ordered.count - 1) / (last - first),
        gapP95Milliseconds: percentile(gaps, 0.95),
        gapMaxMilliseconds: gaps.last
    )
}

/// кольцевой журнал моментов показа; пишется из обработчиков Metal с любых потоков
final class PresentationLog: Sendable {
    static let capacity = 1024

    private struct Ring {
        var times: [Double]
        var next: Int
        var total: Int
    }

    private let ring = Mutex(Ring(times: [], next: 0, total: 0))

    func record(_ time: Double) {
        guard time.isFinite, time > 0 else { return }
        ring.withLock { ring in
            if ring.times.count < Self.capacity {
                ring.times.append(time)
            } else {
                ring.times[ring.next] = time
            }
            ring.next = (ring.next + 1) % Self.capacity
            ring.total += 1
        }
    }

    func summary() -> PresentationSummary {
        let (times, total) = ring.withLock { ($0.times, $0.total) }
        return summarizePresentation(times: times, totalFrames: total)
    }
}

/// снимок состояния для ручной проверки на железе, пишется по флагу --diagnostics
struct DiagnosticsReport: Codable, Sendable {
    let appVersion: String
    let buildNumber: String
    let model: String
    let macOS: String
    let angle: Double?
    let sensorReady: Bool
    let sensorNote: String
    let screenAccess: Bool
    let capturing: Bool
    let overlayShown: Bool
    let pointerHidden: Bool
    let isOn: Bool
    let demo: Bool
    let metalReady: Bool
    let drawnFrames: Int
    let captureFrame: UInt64
    let status: String
    let problem: String?
    let shortcutProblem: String?
    let presentation: PresentationSummary?
}

/// атомарно заменяет файл диагностики без сохранения изображения экрана
func writeDiagnostics(_ report: DiagnosticsReport, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(report).write(to: url, options: .atomic)
}
