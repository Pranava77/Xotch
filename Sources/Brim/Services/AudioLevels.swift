import Accelerate
import AudioToolbox
import CoreAudio
import Foundation
import Observation

/// Real playback levels for the music bars beside the notch, from a Core Audio
/// process tap (macOS 14.2+). Off by default: the first time it runs, macOS asks
/// for permission to record system audio. Nothing is recorded or kept; each
/// buffer is reduced to four numbers and dropped.
///
/// The tap only runs while the music bars are on screen and the setting is on.
/// If macOS denies access the tap hears silence, and the bars fall back to
/// their built-in animation.
@MainActor
@Observable
final class AudioLevels {
    static let shared = AudioLevels()

    enum Status: Equatable {
        case off
        case listening
        /// Running, but only silence arrives while music plays: most likely no permission.
        case silent
        case failed(String)
    }

    private(set) var status: Status = .off
    @ObservationIgnored private var tap: AudioTap?
    @ObservationIgnored private var viewers = 0

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.realAudioLevels)
    }

    /// Four bands (bass to treble), 0...1, or nil when the bars should animate by themselves.
    func current() -> [Float]? {
        guard let tap else { return nil }
        let reading = tap.reading()
        let silentFor = Date().timeIntervalSince(reading.lastSound)
        let newStatus: Status = silentFor > 3 ? .silent : .listening
        if status != newStatus {
            status = newStatus
        }
        return silentFor > 1.5 ? nil : reading.bands
    }

    /// A view that shows levels appeared; the tap runs while any are on screen.
    func acquire() {
        viewers += 1
        update()
    }

    func release() {
        viewers = max(0, viewers - 1)
        update()
    }

    func settingsChanged() {
        update()
    }

    /// Starting and stopping talk to the audio server and can wait on it (for
    /// example while macOS shows its permission prompt), so they run here,
    /// never on the main thread.
    @ObservationIgnored private let control = DispatchQueue(label: "com.pranava.brim.audio-levels.control")

    private func update() {
        let shouldRun = viewers > 0 && isEnabled
        if shouldRun, tap == nil {
            guard #available(macOS 14.2, *) else {
                status = .failed("Needs macOS 14.2 or later.")
                return
            }
            let newTap = AudioTap()
            tap = newTap
            status = .listening
            control.async {
                do {
                    try newTap.start()
                } catch {
                    newTap.stop()
                    let message = error.localizedDescription
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { AudioLevels.shared.startFailed(newTap, message: message) }
                    }
                }
            }
        } else if !shouldRun, let tap {
            self.tap = nil
            control.async { tap.stop() }
        }
        if !isEnabled {
            status = .off
        }
    }

    private func startFailed(_ failed: AudioTap, message: String) {
        guard tap === failed else { return }
        tap = nil
        status = .failed(message)
    }
}

struct AudioTapError: LocalizedError {
    let step: String
    let status: OSStatus
    var errorDescription: String? { "Couldn't \(step) (error \(status))." }
}

/// Owns the tap, a private aggregate device that reads from it, and the
/// analysis. The IO block runs on its own queue; `reading()` is read from the
/// main thread under a lock.
final class AudioTap: @unchecked Sendable {
    struct Reading {
        var bands: [Float]
        var lastSound: Date
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "com.pranava.brim.audio-levels", qos: .userInitiated)
    private let lock = NSLock()
    private var current = Reading(bands: [0, 0, 0, 0], lastSound: .distantPast)
    private var analyzer: SpectrumAnalyzer?

    func reading() -> Reading {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    @available(macOS 14.2, *)
    func start() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "Brim music bars"
        description.muteBehavior = .unmuted
        description.isPrivate = true

        var newTap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &newTap)
        guard status == noErr else { throw AudioTapError(step: "create the audio tap", status: status) }
        tapID = newTap

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        guard status == noErr else { throw AudioTapError(step: "read the audio format", status: status) }
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32 else {
            throw AudioTapError(step: "use the audio format", status: -1)
        }
        let analyzer = SpectrumAnalyzer(sampleRate: format.mSampleRate)
        self.analyzer = analyzer

        var settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Brim music bars",
            kAudioAggregateDeviceUIDKey: "com.pranava.brim.levels.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true],
            ],
        ]
        if let output = Self.defaultOutputUID() {
            settings[kAudioAggregateDeviceMainSubDeviceKey] = output
            settings[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: output]]
        }
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(settings as CFDictionary, &aggregate)
        guard status == noErr else { throw AudioTapError(step: "create the listening device", status: status) }
        aggregateID = aggregate

        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let channels = Int(max(format.mChannelsPerFrame, 1))
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, _, _, _ in
            self?.process(input, interleaved: interleaved, channels: channels)
        }
        guard status == noErr else { throw AudioTapError(step: "start listening", status: status) }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { throw AudioTapError(step: "start listening", status: status) }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown, #available(macOS 14.2, *) {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit {
        stop()
    }

    private func process(_ input: UnsafePointer<AudioBufferList>, interleaved: Bool, channels: Int) {
        guard let analyzer else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, let data = first.mData else { return }
        let samples = data.assumingMemoryBound(to: Float.self)
        let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        // Use the left channel; it's enough for the bars.
        let stride = interleaved ? channels : 1
        guard let bands = analyzer.add(samples, count: count, stride: stride) else { return }
        lock.lock()
        current.bands = bands
        if analyzer.lastPeak > 0.0005 {
            current.lastSound = Date()
        }
        lock.unlock()
    }

    private static func defaultOutputUID() -> String? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else {
            return nil
        }
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr,
              let uid else { return nil }
        return uid.takeRetainedValue() as String
    }
}

/// Turns a stream of samples into four smoothed band levels.
final class SpectrumAnalyzer: @unchecked Sendable {
    static let size = 1024
    /// Band edges in Hz: bass, low mids, high mids, treble.
    private static let edges: [Double] = [40, 250, 1000, 4000, 12000]
    /// Higher bands carry less energy; lift them so the bars move evenly.
    private static let lift: [Float] = [0, 4, 9, 14]

    private let binRanges: [Range<Int>]
    private let window: [Float]
    private let transform: vDSP.DiscreteFourierTransform<Float>?
    private var pending: [Float] = []
    private var levels: [Float] = [0, 0, 0, 0]
    private(set) var lastPeak: Float = 0
    private var skip = false

    init(sampleRate: Double) {
        let binWidth = sampleRate / Double(Self.size)
        let top = Self.size / 2
        binRanges = (0..<4).map { band in
            let low = max(1, Int(Self.edges[band] / binWidth))
            let high = min(top, max(low + 1, Int(Self.edges[band + 1] / binWidth)))
            return low..<high
        }
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: Self.size, isHalfWindow: false)
        transform = try? vDSP.DiscreteFourierTransform(previous: nil, count: Self.size, direction: .forward,
                                                        transformType: .complexComplex, ofType: Float.self)
        pending.reserveCapacity(Self.size * 2)
    }

    /// Returns new levels once a full window has arrived. Every other window
    /// is skipped: about 23 readings a second is plenty for four bars.
    func add(_ samples: UnsafePointer<Float>, count: Int, stride: Int) -> [Float]? {
        var index = 0
        while index < count {
            pending.append(samples[index])
            index += stride
        }
        guard pending.count >= Self.size, let transform else { return nil }
        let frame = Array(pending.prefix(Self.size))
        pending.removeFirst(min(pending.count, Self.size))
        if pending.count > Self.size * 2 {
            pending.removeAll(keepingCapacity: true)
        }
        skip.toggle()
        guard !skip else { return nil }

        lastPeak = vDSP.maximumMagnitude(frame)
        let windowed = vDSP.multiply(frame, window)
        let (real, imaginary) = transform.transform(real: windowed, imaginary: [Float](repeating: 0, count: Self.size))
        let scale = 2 / Float(Self.size)
        for band in 0..<4 {
            var sum: Float = 0
            for bin in binRanges[band] {
                sum += (real[bin] * real[bin] + imaginary[bin] * imaginary[bin]).squareRoot()
            }
            let magnitude = sum / Float(max(binRanges[band].count, 1)) * scale
            let decibels = 20 * log10(magnitude + 1e-7) + Self.lift[band]
            let target = min(max((decibels + 62) / 50, 0), 1)
            // Rise quickly, fall slowly.
            let speed: Float = target > levels[band] ? 0.6 : 0.18
            levels[band] += (target - levels[band]) * speed
        }
        return levels
    }
}
