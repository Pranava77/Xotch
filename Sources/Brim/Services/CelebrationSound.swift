import AVFoundation

/// A short cash-register "ka-ching", made in code so Brim ships no sound files:
/// a click for the drawer, then two bell notes that ring out.
@MainActor
enum CelebrationSound {
    private static var player: AVAudioPlayer?

    static func play() {
        if player == nil {
            player = try? AVAudioPlayer(data: wav)
            player?.volume = 0.5
            player?.prepareToPlay()
        }
        player?.currentTime = 0
        player?.play()
    }

    private static let sampleRate = 44_100

    /// 16-bit mono WAV.
    static let wav: Data = {
        let samples = render()
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let byteCount = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + byteCount))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(byteCount))
        for sample in samples {
            append(Int16(max(-1, min(1, sample)) * Float(Int16.max)))
        }
        return data
    }()

    private static func render() -> [Float] {
        let length = Int(Double(sampleRate) * 0.9)
        var samples = [Float](repeating: 0, count: length)
        var noise: UInt32 = 0x2545F491
        // "Ka": 25 ms of filtered noise.
        var smoothed: Float = 0
        for index in 0..<Int(Double(sampleRate) * 0.025) {
            noise ^= noise << 13; noise ^= noise >> 17; noise ^= noise << 5
            let white = Float(noise) / Float(UInt32.max) * 2 - 1
            smoothed += (white - smoothed) * 0.35
            let envelope = 1 - Float(index) / Float(sampleRate) / 0.025
            samples[index] += smoothed * envelope * 0.5
        }
        // "Ching": two bell notes, the second a little later.
        let bells: [(start: Double, frequency: Double, gain: Float)] = [(0.035, 2093, 0.32), (0.11, 2637, 0.28)]
        for bell in bells {
            let start = Int(bell.start * Double(sampleRate))
            for index in start..<length {
                let time = Double(index - start) / Double(sampleRate)
                let decay = Float(exp(-time * 5.5))
                let tone = sin(2 * .pi * bell.frequency * time) + 0.35 * sin(2 * .pi * bell.frequency * 2.76 * time)
                let attack = Float(min(1, time / 0.003))
                samples[index] += Float(tone) * decay * attack * bell.gain
            }
        }
        return samples
    }
}
