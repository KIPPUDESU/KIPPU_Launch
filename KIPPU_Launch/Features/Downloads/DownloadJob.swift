import Darwin
import Foundation
import KIPPULaunchCore
import Observation

/// 采样时刻很少刚好落在窗口起点 两次读数之间按时间折算
struct TransferRateWindow {
    struct Reading {
        let time: TimeInterval
        let received: Int64
        let written: UInt64?
    }

    private var readings: [Reading] = []
    private var diskValidSince: TimeInterval?

    mutating func reset(_ first: Reading) {
        readings = [first]
        diskValidSince = first.written == nil ? nil : first.time
    }

    mutating func append(_ next: Reading) -> (download: Double, disk: Double?) {
        guard let previous = readings.last, next.time > previous.time else { return (0, nil) }
        if let writes = next.written {
            if previous.written.map({ $0 > writes }) ?? true { diskValidSince = next.time }
        } else { diskValidSince = nil }
        readings.append(next)
        let diskStart = next.time - 3
        while readings.count > 2 && readings[1].time <= diskStart { readings.removeFirst() }

        func mean(since start: TimeInterval, delta: (Reading) -> Double) -> Double {
            let boundary = max(start, readings[0].time)
            guard next.time > boundary,
                  let right = readings.indices.dropFirst().first(where: { readings[$0].time >= boundary }) else { return 0 }
            let lower = readings[right - 1], upper = readings[right]
            let fraction = (boundary - lower.time) / (upper.time - lower.time)
            let bytes = delta(lower) * (1 - fraction) + delta(upper) * fraction
            return max(0, bytes / (next.time - boundary))
        }

        let download = mean(since: next.time - 1) { Double(next.received - $0.received) }
        guard let writes = next.written, let diskValidSince, diskValidSince < next.time else { return (download, nil) }
        let disk = mean(since: max(diskStart, diskValidSince)) { reading in
            guard let past = reading.written, past <= writes else { return 0 }
            return Double(writes - past)
        }
        return (download, disk)
    }
}

@MainActor @Observable
final class DownloadJob: Identifiable {
    enum State {
        case queued, running, pausing, paused, cancelling, completed, failed, cancelled
        var finished: Bool { self == .completed || self == .failed || self == .cancelled }
    }

    struct Sample: Identifiable {
        // 暂停时从上一个速率垂直落到零
        enum Boundary {
            case pause(previousDiskSpeed: Double?)
            case resume(pausedSince: TimeInterval)
        }

        let time: TimeInterval
        let interval: TimeInterval
        let speed: Double
        let diskSpeed: Double?
        let segment: Int
        var boundary: Boundary? = nil
        var id: TimeInterval { time }
        var diskSpeedBeforeBoundary: Double? {
            if case let .pause(previous) = boundary { return previous }
            return diskSpeed
        }
    }

    let id = UUID()
    let key: String
    let title: String
    let category: DownloadSection
    let target: String
    let instanceID: UUID?
    var state = State.queued
    private(set) var stage = ""
    private(set) var fraction: Double?
    var result = ""
    private(set) var bytes: Int64 = 0
    private(set) var speed: Double = 0
    private(set) var diskSpeed: Double?
    private(set) var peakSpeed: Double = 0
    private(set) var samples: [Sample] = []
    static let chartDuration: TimeInterval = 30
    static let sampleInterval: TimeInterval = 0.25
    private var downloadedBytes: Int64 = 0
    private var expectedBytes: Int64?
    @ObservationIgnored private var sampleTime: TimeInterval?
    @ObservationIgnored private var rates = TransferRateWindow()
    @ObservationIgnored private var segment = 0

    init(key: String, title: String, category: DownloadSection, target: String, instanceID: UUID?) {
        self.key = key
        self.title = title
        self.category = category
        self.target = target
        self.instanceID = instanceID
    }

    var displayFraction: Double? {
        if let expectedBytes, expectedBytes > 0 {
            return min(1, Double(downloadedBytes) / Double(expectedBytes))
        }
        return fraction
    }

    // 这里读的是整个启动器的写盘量 解压和缓存回写也算在内
    private static func diskWrites() -> UInt64? {
        var usage = rusage_info_v2()
        let status = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V2, $0)
            }
        }
        return status == 0 ? usage.ri_diskio_byteswritten : nil
    }

    func beginSampling(at counts: DownloadTraffic.ByteCounts) {
        let now = ProcessInfo.processInfo.systemUptime
        let written = Self.diskWrites()
        sampleTime = now
        rates.reset(.init(time: now, received: counts.received, written: written))
        diskSpeed = written == nil ? nil : 0
        segment += 1
        if let last = samples.last, case .pause = last.boundary {
            appendSample(Sample(time: now, interval: 0, speed: 0, diskSpeed: 0, segment: segment,
                                boundary: .resume(pausedSince: last.time)))
        }
    }

    func sample(_ counts: DownloadTraffic.ByteCounts) {
        guard let previous = sampleTime else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - previous
        bytes = counts.received
        downloadedBytes = counts.downloaded
        // 最后一次回调可能紧跟上次采样 此时只更新字节数
        guard elapsed >= Self.sampleInterval / 2 else { return }
        let rate = rates.append(.init(time: now, received: counts.received, written: Self.diskWrites()))
        speed = rate.download
        if diskSpeed == nil || rate.disk == nil { segment += 1 }
        diskSpeed = rate.disk
        peakSpeed = max(peakSpeed, speed)
        appendSample(Sample(time: now, interval: elapsed, speed: speed, diskSpeed: diskSpeed, segment: segment))
        sampleTime = now
    }

    private func appendSample(_ sample: Sample) {
        let cutoff = sample.time - Self.chartDuration
        let expired = samples.firstIndex { $0.time >= cutoff } ?? samples.endIndex
        let removed = max(expired, samples.count - 127)
        if removed > 0 { samples.removeFirst(removed) }
        samples.append(sample)
    }

    func pauseSampling(at counts: DownloadTraffic.ByteCounts) {
        guard sampleTime != nil else { return }
        finishSampling(at: counts)
        guard let last = samples.last else { return }
        let now = ProcessInfo.processInfo.systemUptime
        appendSample(Sample(time: max(now, last.time.nextUp), interval: 0, speed: 0,
                            diskSpeed: 0, segment: last.segment, boundary: .pause(previousDiskSpeed: last.diskSpeed)))
    }

    func finishSampling(at counts: DownloadTraffic.ByteCounts) {
        if sampleTime != nil { sample(counts) }
        sampleTime = nil
        bytes = counts.received
        downloadedBytes = counts.downloaded
        speed = 0
        diskSpeed = diskSpeed.map { _ in 0 }
    }

    func clearChart() { samples.removeAll() }

    func resetProgress() {
        samples.removeAll()
        bytes = 0
        downloadedBytes = 0
        peakSpeed = 0
        speed = 0
        diskSpeed = nil
        expectedBytes = nil
        fraction = nil
        stage = ""
    }

    func report(_ label: String, done: Int = 0, total: Int = 0, expectedBytes: Int? = nil) {
        guard !state.finished, state != .cancelling else { return }
        stage = total > 0 ? "\(label) · \(done)/\(total)" : label
        fraction = total > 0 ? min(1, Double(done) / Double(total)) : nil
        self.expectedBytes = expectedBytes.map(Int64.init)
    }
}
