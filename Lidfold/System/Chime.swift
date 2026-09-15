import AVFoundation
import os

/// короткий мягкий щелчок: два затухающих тона, моно 16 бит
func chimeWAV() -> Data {
    let sampleRate = 24_000
    let length = sampleRate * 80 / 1000
    let samples: [Int16] = (0..<length).map { index in
        let time = Double(index) / Double(sampleRate)
        let envelope = min(1, time / 0.002) * exp(-time * 60)
        let tone = sin(2 * .pi * 1320 * time) + 0.3 * sin(2 * .pi * 1980 * time)
        return Int16((tone * envelope * 2000).rounded())
    }
    let payload = samples.count * MemoryLayout<Int16>.size
    var data = Data()
    func put(_ text: String) { data.append(contentsOf: text.utf8) }
    func put<Value: FixedWidthInteger>(_ value: Value) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    put("RIFF"); put(UInt32(36 + payload)); put("WAVE")
    put("fmt "); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
    put(UInt32(sampleRate)); put(UInt32(sampleRate * 2)); put(UInt16(2)); put(UInt16(16))
    put("data"); put(UInt32(payload))
    samples.forEach { put($0) }
    return data
}

@MainActor final class ChimePlayer {
    private static let log = Logger(subsystem: "io.github.boundlessend.lidfold", category: "chime")
    private let sound = chimeWAV()
    private var player: AVAudioPlayer?

    func play() {
        do {
            let player = try AVAudioPlayer(data: sound)
            self.player = player
            player.play()
        } catch {
            Self.log.error("chime not played: \(error.localizedDescription, privacy: .public)")
        }
    }
}
