import Foundation
import KIPPULaunchCore
import Observation

@MainActor @Observable
final class DownloadCenter {
    typealias Operation = @MainActor (DownloadJob) async throws -> String

    private final class Run {
        let traffic = DownloadTraffic()
        var worker: Task<Void, Never>?
        var pauseRequest: UUID?
    }

    private(set) var jobs: [DownloadJob] = []
    private(set) var active: DownloadJob?
    private(set) var lastTransfer: DownloadJob?
    private(set) var isPaused = false
    private(set) var revisions: [UUID: Int] = [:]
    @ObservationIgnored private var runs: [UUID: Run] = [:]
    @ObservationIgnored private var operations: [UUID: Operation] = [:]
    @ObservationIgnored private var preparingInstances: Set<UUID> = []
    @ObservationIgnored private var sampling: Task<Void, Never>?

    @discardableResult
    func enqueue(key: String, title: String, category: DownloadSection, target: String, instanceID: UUID? = nil,
                 operation: @escaping Operation) -> DownloadJob {
        if let existing = jobs.first(where: { $0.key == key && !$0.state.finished }) { return existing }
        let job = DownloadJob(key: key, title: title, category: category, target: target, instanceID: instanceID)
        operations[job.id] = operation
        jobs.append(job)
        startNext()
        return job
    }

    func cancel(_ job: DownloadJob) {
        guard !job.state.finished, job.state != .cancelling else { return }
        if let run = runs[job.id] {
            job.state = .cancelling
            run.pauseRequest = nil
            run.worker?.cancel()
        } else {
            job.state = .cancelled
            resetPauseIfEmpty()
        }
    }

    func canRetry(_ job: DownloadJob) -> Bool {
        (job.state == .failed || job.state == .cancelled) && operations[job.id] != nil
            && !jobs.contains { $0.key == job.key && !$0.state.finished }
    }

    func retry(_ job: DownloadJob) {
        guard canRetry(job) else { return }
        jobs.removeAll { $0.id == job.id }
        if lastTransfer === job { lastTransfer = nil }
        job.resetProgress()
        job.state = .queued
        job.result = ""
        jobs.append(job)
        startNext()
    }

    func remove(_ job: DownloadJob) {
        guard job.state.finished else { return }
        operations[job.id] = nil
        if lastTransfer === job { lastTransfer = nil }
        jobs.removeAll { $0.id == job.id }
    }

    var hasPendingJobs: Bool { jobs.contains { !$0.state.finished } }

    func pause(_ job: DownloadJob) {
        if job.state == .queued {
            job.state = .paused
            return
        }
        guard job.state == .running, let run = runs[job.id] else { return }
        job.state = .pausing
        let request = UUID()
        run.pauseRequest = request
        // 暂停请求发出时上一个任务可能还在写实例文件
        run.traffic.pause { [weak self, weak job] in
            Task { @MainActor in
                guard let self, let job, self.active === job, job.state == .pausing,
                      self.runs[job.id]?.pauseRequest == request else { return }
                job.state = .paused
                self.stopSampling(job, paused: true)
                self.active = nil
                self.startNext()
            }
        }
    }

    func resume(_ job: DownloadJob) {
        guard job.state == .paused || job.state == .pausing else { return }
        runs[job.id]?.pauseRequest = nil
        if active === job, let run = runs[job.id] {
            job.state = .running
            if !isPaused {
                run.traffic.resume()
                if sampling == nil { startSampling(job, traffic: run.traffic) }
            }
        } else {
            job.state = .queued
            startNext()
        }
    }

    func pause() {
        guard !isPaused, hasPendingJobs else { return }
        isPaused = true
        if let job = active {
            runs[job.id]?.traffic.pause()
            stopSampling(job, paused: true)
        }
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        if let job = active, job.state == .running, let run = runs[job.id] {
            run.traffic.resume()
            startSampling(job, traffic: run.traffic)
        } else { startNext() }
    }

    private func resetPauseIfEmpty() {
        if !hasPendingJobs { isPaused = false }
    }

    private func startSampling(_ job: DownloadJob, traffic: DownloadTraffic) {
        sampling?.cancel()
        job.beginSampling(at: traffic.byteCounts)
        sampling = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(DownloadJob.sampleInterval))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                job.sample(traffic.byteCounts)
            }
        }
    }

    private func stopSampling(_ job: DownloadJob, paused: Bool = false) {
        sampling?.cancel()
        sampling = nil
        guard let run = runs[job.id] else { return }
        let received = run.traffic.byteCounts
        if paused { job.pauseSampling(at: received) }
        else { job.finishSampling(at: received) }
    }

    func beginLaunch(_ id: UUID) throws {
        guard !jobs.contains(where: { $0.instanceID == id && runs[$0.id] != nil }) else {
            throw InstallError.message("此实例有尚未结束的安装任务，完成或取消后即可启动。")
        }
        guard preparingInstances.insert(id).inserted else {
            throw InstallError.message("此实例正在准备启动。")
        }
    }

    func finishLaunch(_ id: UUID) {
        preparingInstances.remove(id)
        startNext()
    }

    private func startNext() {
        guard !isPaused, active == nil, let job = jobs.first(where: { candidate in
            candidate.state == .queued && !preparingInstances.contains(where: { $0 == candidate.instanceID })
        }), let operation = operations[job.id] else { return }
        active = job
        job.state = .running
        if let run = runs[job.id] {
            run.traffic.resume()
            startSampling(job, traffic: run.traffic)
            return
        }
        job.report("准备下载")
        let run = Run()
        runs[job.id] = run
        startSampling(job, traffic: run.traffic)
        run.worker = Task {
            do {
                let result = try await DownloadTraffic.$current.withValue(run.traffic) {
                    try await DownloadTraffic.checkpoint()
                    return try await operation(job)
                }
                // 暂停请求可能晚于最后一次写盘 此时任务已经完成
                job.result = result
                job.state = .completed
                if let id = job.instanceID { revisions[id, default: 0] += 1 }
                operations[job.id] = nil
            } catch {
                job.state = Task.isCancelled ? .cancelled : .failed
                job.result = Task.isCancelled ? "" : error.localizedDescription
            }
            if active === job {
                stopSampling(job)
                active = nil
            } else {
                job.finishSampling(at: run.traffic.byteCounts)
            }
            if job.bytes > 0 || job.samples.contains(where: { ($0.diskSpeed ?? 0) > 0 }) {
                lastTransfer?.clearChart()
                lastTransfer = job
            } else { job.clearChart() }
            runs[job.id] = nil
            run.worker = nil
            resetPauseIfEmpty()
            startNext()
        }
    }
}
