import AVFoundation

/// The microphone while you dictate, converted to what Whistle reads: 16 kHz
/// mono floats. It runs only between start and stop, so macOS's orange
/// microphone dot shows only then.
final class MicRecorder: @unchecked Sendable {
    /// Called on the audio thread with each converted chunk, and its loudness (0...1).
    var onAudio: (@Sendable ([Float], Float) -> Void)?

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    static var permission: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func start() throws {
        stop()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let hardware = input.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0,
              let converter = AVAudioConverter(from: hardware, to: Self.format) else {
            throw WhistleEngine.EngineError("No microphone to listen with.")
        }
        self.converter = converter
        input.installTap(onBus: 0, bufferSize: 2048, format: hardware) { [weak self] buffer, _ in
            guard let self, let converter = self.converter else { return }
            let samples = Self.convert(buffer, with: converter)
            guard !samples.isEmpty else { return }
            self.onAudio?(samples, Self.level(samples))
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        converter = nil
    }

    /// Resamples and mixes a buffer down to 16 kHz mono.
    static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> [Float] {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return [] }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    /// Loudness for the bars: RMS on a rough decibel scale, 0 at about -50 dB.
    static func level(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let mean = samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)
        let decibels = 10 * log10(max(mean, 1e-10))
        return min(max((decibels + 50) / 45, 0), 1)
    }
}
