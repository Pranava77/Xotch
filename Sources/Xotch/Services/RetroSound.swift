import AVFoundation
import Foundation

// Arcade sound effects, made from nothing: square, triangle and noise waves
// with a short envelope, the way a game console's sound chip made them. Every
// effect is worked out in code, so there are no audio files to bundle or license.

enum RetroCue: String, CaseIterable, Sendable {
    case open, close, switchModule, tick, complete, delete, pin, timerDone, celebrate
}

/// One note of a cue.
struct RetroNote: Sendable {
    enum Wave: Sendable {
        /// A square wave; `duty` 0.125, 0.25 and 0.5 are the classic three timbres.
        case pulse(duty: Double)
        case triangle
        /// Hiss, stepped so its pitch can be chosen; `from`/`to` set the step rate.
        case noise
    }

    var wave: Wave
    /// Pitch in Hz at the start and end of the note. Different values make a sweep.
    var from: Double
    var to: Double
    var seconds: Double
    var gain: Double = 1
    /// Silence after the note, before the next.
    var rest: Double = 0

    static func tone(_ hz: Double, _ seconds: Double, duty: Double = 0.25, gain: Double = 1,
                     rest: Double = 0) -> RetroNote {
        RetroNote(wave: .pulse(duty: duty), from: hz, to: hz, seconds: seconds, gain: gain, rest: rest)
    }

    static func sweep(_ from: Double, _ to: Double, _ seconds: Double, duty: Double = 0.5,
                      gain: Double = 1) -> RetroNote {
        RetroNote(wave: .pulse(duty: duty), from: from, to: to, seconds: seconds, gain: gain)
    }
}

/// Pure sound design: no audio hardware, so it can be tested and rendered anywhere.
enum RetroSynth {
    static let sampleRate = 44_100.0
    /// Highest sample value a cue may reach. Effects are short and repeated, so
    /// they stay well below full scale.
    static let peak: Float = 0.6

    static func notes(for cue: RetroCue) -> [RetroNote] {
        switch cue {
        case .open:
            [.sweep(330, 660, 0.09)]
        case .close:
            [.sweep(660, 330, 0.08)]
        case .switchModule:
            [.tone(880, 0.03, duty: 0.5, gain: 0.8)]
        case .tick:
            [.tone(1200, 0.025, duty: 0.125)]
        case .complete:
            // C5 E5 G5, then a longer C6: the coin.
            [.tone(523, 0.06), .tone(659, 0.06), .tone(784, 0.06), .tone(1047, 0.16, duty: 0.5)]
        case .delete:
            [.sweep(500, 120, 0.12, duty: 0.25),
             RetroNote(wave: .noise, from: 6000, to: 2000, seconds: 0.06, gain: 0.5)]
        case .pin:
            [.tone(700, 0.04, duty: 0.5, rest: 0.015), .tone(900, 0.05, duty: 0.5)]
        case .timerDone:
            [.tone(784, 0.09), .tone(988, 0.09), .tone(1175, 0.09), .tone(988, 0.09, rest: 0.05),
             .tone(1175, 0.09), .tone(1568, 0.28, duty: 0.5)]
        case .celebrate:
            // A rising fanfare: G4 C5 E5 G5, held, with a triangle bass underneath at the end.
            [.tone(392, 0.09), .tone(523, 0.09), .tone(659, 0.09), .tone(784, 0.30, duty: 0.5),
             RetroNote(wave: .triangle, from: 196, to: 196, seconds: 0.25, gain: 0.9)]
        }
    }

    /// The samples for a cue, mono, at `sampleRate`.
    static func render(_ cue: RetroCue) -> [Float] {
        var out: [Float] = []
        var noiseState: UInt32 = 0x1234_5678
        for note in notes(for: cue) {
            let count = max(1, Int(note.seconds * sampleRate))
            var phase = 0.0
            var held: Float = 0
            var untilStep = 0.0
            for index in 0..<count {
                let progress = Double(index) / Double(count)
                let hz = note.from + (note.to - note.from) * progress
                var value: Float
                switch note.wave {
                case .pulse(let duty):
                    value = phase < duty ? 1 : -1
                case .triangle:
                    value = Float(4 * abs(phase - 0.5) - 1)
                case .noise:
                    if untilStep <= 0 {
                        noiseState ^= noiseState << 13
                        noiseState ^= noiseState >> 17
                        noiseState ^= noiseState << 5
                        held = Float(noiseState % 2001) / 1000 - 1
                        untilSteps(&untilStep, hz: hz)
                    }
                    untilStep -= 1
                    value = held
                }
                phase += hz / sampleRate
                phase -= phase.rounded(.down)

                // A short attack and release stop clicks; the body fades gently,
                // which is what makes a blip sound plucked and not held.
                let seconds = Double(index) / sampleRate
                let attack = min(1, seconds / 0.002)
                let release = min(1, (note.seconds - seconds) / 0.008)
                let body = 1 - 0.45 * progress
                out.append(value * Float(note.gain * attack * max(0, release) * body))
            }
            out.append(contentsOf: [Float](repeating: 0, count: Int(note.rest * sampleRate)))
        }
        let top = out.map(abs).max() ?? 0
        if top > 0 {
            let scale = peak / top
            for index in out.indices { out[index] *= scale }
        }
        return out
    }

    private static func untilSteps(_ remaining: inout Double, hz: Double) {
        remaining = max(1, sampleRate / max(hz, 1))
    }
}

/// Plays the cues, and only when the setting is on.
@MainActor
final class RetroSound {
    static let shared = RetroSound()

    /// `force` skips the setting, for the debug command and Settings' preview.
    static func play(_ cue: RetroCue, force: Bool = false) {
        shared.play(cue, force: force)
    }

    private let engine = AVAudioEngine()
    private let format = AVAudioFormat(standardFormatWithSampleRate: RetroSynth.sampleRate, channels: 1)!
    private var players: [AVAudioPlayerNode] = []
    private var busy: [Bool] = []
    private var buffers: [RetroCue: AVAudioPCMBuffer] = [:]
    private var idleTask: Task<Void, Never>?
    private static let voices = 4

    private func play(_ cue: RetroCue, force: Bool) {
        guard force || AppSettings.retroSounds else { return }
        buildIfNeeded()
        guard let buffer = buffer(for: cue), startEngine() else { return }
        // A free voice, or the oldest one cut off: quick repeats never queue up.
        let index = busy.firstIndex(of: false) ?? 0
        let player = players[index]
        player.stop()
        player.volume = Float(min(max(AppSettings.retroSoundVolume, 0), 1))
        busy[index] = true
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.busy[index] = false }
        }
        player.play()
        scheduleIdleStop()
    }

    private func buildIfNeeded() {
        guard players.isEmpty else { return }
        for _ in 0..<Self.voices {
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            players.append(player)
            busy.append(false)
        }
    }

    private func buffer(for cue: RetroCue) -> AVAudioPCMBuffer? {
        if let cached = buffers[cue] { return cached }
        let samples = RetroSynth.render(cue)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        for (index, sample) in samples.enumerated() { channel[index] = sample }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        buffers[cue] = buffer
        return buffer
    }

    /// The engine starts on the first sound, and starts again if the output
    /// device changed underneath it.
    private func startEngine() -> Bool {
        if engine.isRunning { return true }
        do {
            try engine.start()
            return true
        } catch {
            return false
        }
    }

    /// Let the audio hardware go back to sleep when nothing has played for a while.
    private func scheduleIdleStop() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self else { return }
            if !busy.contains(true) { engine.stop() }
        }
    }

    var isEngineRunning: Bool { engine.isRunning }
}
