import Darwin
import Foundation
import IOKit
import IOKit.ps
import Observation

struct BatteryInfo: Equatable {
    var percent: Int
    var isCharging: Bool
    var onPower: Bool
    /// Minutes, when macOS has an estimate.
    var minutesLeft: Int?
    var health: Double?
    var cycles: Int?
}

struct StatsSnapshot: Equatable {
    var cpu: Double
    var memoryUsed: Double
    var memoryTotal: Double
    var download: Double
    var upload: Double
    var diskFree: Double
    var diskTotal: Double
    var battery: BatteryInfo?
}

/// CPU, memory, network, disk and battery. Samples every 2 seconds, and only
/// while a view showing them is on screen.
@MainActor
@Observable
final class StatsService {
    static let shared = StatsService()

    private(set) var snapshot: StatsSnapshot?
    private(set) var cpuHistory: [Double] = []
    private(set) var networkHistory: [Double] = []

    @ObservationIgnored private let host = mach_host_self()
    @ObservationIgnored private var previousTicks: [UInt32]?
    @ObservationIgnored private var previousNetwork: (received: UInt64, sent: UInt64, at: Date)?
    @ObservationIgnored private var batteryHealth: (health: Double?, cycles: Int?)?
    @ObservationIgnored private var sampleCount = 0
    /// Called after each sample; the notch HUD uses it to redraw.
    @ObservationIgnored var onSample: (() -> Void)?
    @ObservationIgnored private lazy var gate = VisibilityGate(interval: .seconds(2)) { [weak self] in
        self?.sample()
    }

    func whileVisible() async {
        await gate.whileVisible()
    }

    private func sample() {
        let cpu = cpuUsage() ?? snapshot?.cpu ?? 0
        let (used, total) = memory()
        let (download, upload) = networkRates()
        // Disk and battery change slowly and cost more to read: every 10 seconds.
        let slow = sampleCount % 5 == 0 || snapshot == nil
        sampleCount += 1
        let (free, capacity) = slow ? disk() : (snapshot?.diskFree ?? 0, snapshot?.diskTotal ?? 0)
        snapshot = StatsSnapshot(cpu: cpu, memoryUsed: used, memoryTotal: total,
                                 download: download, upload: upload,
                                 diskFree: free, diskTotal: capacity,
                                 battery: slow ? battery() : snapshot?.battery)
        cpuHistory = Array((cpuHistory + [cpu]).suffix(30))
        networkHistory = Array((networkHistory + [download + upload]).suffix(30))
        onSample?()
    }

    /// Network history scaled to 0...1 for the sparkline.
    var normalizedNetworkHistory: [Double] {
        let peak = max(networkHistory.max() ?? 0, 64_000)
        return networkHistory.map { $0 / peak }
    }

    #if DEBUG
    func sampleNow() {
        sample()
    }

    func withSample(_ body: () -> Void) {
        let saved = (snapshot, cpuHistory, networkHistory)
        snapshot = StatsSnapshot(cpu: 0.23, memoryUsed: 11.2e9, memoryTotal: 18e9,
                                 download: 1_250_000, upload: 84_000, diskFree: 212e9, diskTotal: 494e9,
                                 battery: BatteryInfo(percent: 76, isCharging: false, onPower: false,
                                                      minutesLeft: 312, health: 0.93, cycles: 148))
        cpuHistory = (0..<30).map { 0.2 + 0.12 * sin(Double($0) / 2.5) + (($0 % 7 == 0) ? 0.2 : 0) }
        networkHistory = (0..<30).map { 400_000 + 900_000 * abs(sin(Double($0) / 4)) }
        body()
        (snapshot, cpuHistory, networkHistory) = saved
    }
    #endif

    // MARK: - Readers

    private func cpuUsage() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        // user, system, idle, nice
        let ticks = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
        defer { previousTicks = ticks }
        guard let previous = previousTicks else { return nil }
        return Self.cpuUsage(from: previous, to: ticks)
    }

    /// Share of non-idle time between two samples. Each counter is 32-bit and
    /// wraps (after about four weeks on a 16-core Mac), so deltas wrap too.
    nonisolated static func cpuUsage(from old: [UInt32], to new: [UInt32]) -> Double? {
        guard old.count == 4, new.count == 4 else { return nil }
        let delta = zip(new, old).map { UInt64($0 &- $1) }
        let busy = delta[0] + delta[1] + delta[3]
        let total = busy + delta[2]
        guard total > 0 else { return nil }
        return Double(busy) / Double(total)
    }

    private func memory() -> (used: Double, total: Double) {
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, total) }
        let page = Double(getpagesize())
        // Matches Activity Monitor's "Memory Used": app memory + wired + compressed.
        let appPages = Double(stats.internal_page_count) - Double(stats.purgeable_count)
        let used = (appPages + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page
        return (min(used, total), total)
    }

    private func networkRates() -> (download: Double, upload: Double) {
        var received: UInt64 = 0, sent: UInt64 = 0
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return (0, 0) }
        defer { freeifaddrs(addresses) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  String(cString: interface.ifa_name).hasPrefix("en"),
                  let data = interface.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            received += UInt64(data.pointee.ifi_ibytes)
            sent += UInt64(data.pointee.ifi_obytes)
        }
        let now = Date()
        defer { previousNetwork = (received, sent, now) }
        guard let previous = previousNetwork else { return (0, 0) }
        let seconds = max(now.timeIntervalSince(previous.at), 0.5)
        // The kernel's counters are 32-bit and wrap around.
        func delta(_ current: UInt64, _ old: UInt64) -> Double {
            current >= old ? Double(current - old) : Double(current + (1 << 32) - old)
        }
        return (delta(received, previous.received) / seconds, delta(sent, previous.sent) / seconds)
    }

    private func disk() -> (free: Double, total: Double) {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys)
        return (Double(values?.volumeAvailableCapacityForImportantUsage ?? 0),
                Double(values?.volumeTotalCapacity ?? 0))
    }

    private func battery() -> BatteryInfo? {
        let blob = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(blob).takeRetainedValue() as [CFTypeRef]
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            let minutes = description[kIOPSTimeToEmptyKey] as? Int
            if batteryHealth == nil {
                batteryHealth = readBatteryHealth()
            }
            return BatteryInfo(percent: Int((Double(current) / Double(maximum) * 100).rounded()),
                               isCharging: description[kIOPSIsChargingKey] as? Bool ?? false,
                               onPower: (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue,
                               minutesLeft: (minutes ?? -1) > 0 ? minutes : nil,
                               health: batteryHealth?.health,
                               cycles: batteryHealth?.cycles)
        }
        return nil
    }

    private func readBatteryHealth() -> (health: Double?, cycles: Int?) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return (nil, nil) }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue() as? [String: Any] else { return (nil, nil) }
        let maxCapacity = dictionary["AppleRawMaxCapacity"] as? Int ?? dictionary["NominalChargeCapacity"] as? Int
        let design = dictionary["DesignCapacity"] as? Int
        let health = maxCapacity.flatMap { max in design.map { min(Double(max) / Double($0), 1) } }
        return (health, dictionary["CycleCount"] as? Int)
    }
}
