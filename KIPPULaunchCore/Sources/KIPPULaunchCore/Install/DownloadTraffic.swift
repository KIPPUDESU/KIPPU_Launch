import Foundation

public final class DownloadTraffic: @unchecked Sendable {
    @TaskLocal public static var current: DownloadTraffic?
    public struct ByteCounts: Sendable {
        /// 重传的字节也算流量
        public fileprivate(set) var received: Int64 = 0
        /// 重试追上原来的文件偏移后才继续计入进度
        public fileprivate(set) var downloaded: Int64 = 0

        fileprivate mutating func add(_ receivedBytes: Int64, previouslyCredited: Int64) {
            received += receivedBytes
            downloaded += max(0, receivedBytes - previouslyCredited)
        }
    }

    private struct ActiveTransfer {
        let task: URLSessionDownloadTask
        let previouslyCredited: Int64
        var wasPaused: Bool
    }

    private enum Attempt {
        case completed(URL, URLResponse)
        case interrupted(credited: Int64)
    }

    private let lock = NSLock()
    private var finished = ByteCounts()
    private var tasks: [UUID: ActiveTransfer] = [:]

    private var paused = false
    private var onPark: (@Sendable () -> Void)?

    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    public init() {}

    /// whenParked 在持锁时调用 回调不能同步访问此任务
    public func pause(whenParked: (@Sendable () -> Void)? = nil) {
        lock.withLock {
            if !paused {
                paused = true
                for (id, transfer) in tasks {
                    tasks[id]?.wasPaused = true
                    transfer.task.suspend()
                }
            }
            if let whenParked { onPark = whenParked }
            if !tasks.isEmpty || !waiters.isEmpty { notifyParked() }
        }
    }

    private func notifyParked() {
        onPark?()
        onPark = nil
    }

    public func resume() {
        let pending = lock.withLock {
            guard paused else { return [CheckedContinuation<Void, Error>]() }
            paused = false
            onPark = nil
            for transfer in tasks.values { transfer.task.resume() }
            let pending = Array(waiters.values)
            waiters.removeAll()
            return pending
        }
        for waiter in pending { waiter.resume() }
    }

    public static func checkpoint() async throws {
        try Task.checkCancellation()
        guard let traffic = current else { return }
        while traffic.lock.withLock({ traffic.paused }) {
            try await traffic.waitUntilResumed()
            try Task.checkCancellation()
        }
    }

    private func waitUntilResumed() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock {
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else if paused {
                        waiters[id] = continuation
                        notifyParked()
                    }
                    else { continuation.resume() }
                }
            }
        } onCancel: {
            let waiter = self.lock.withLock { self.waiters.removeValue(forKey: id) }
            waiter?.resume(throwing: CancellationError())
        }
    }

    public var byteCounts: ByteCounts {
        lock.withLock {
            tasks.values.reduce(into: finished) { counts, transfer in
                counts.add(max(0, transfer.task.countOfBytesReceived), previouslyCredited: transfer.previouslyCredited)
            }
        }
    }

    public var bytesReceived: Int64 { byteCounts.received }

    static func data(using session: URLSession, request: URLRequest, replayReadOnlyPOST: Bool = false) async throws -> (Data, URLResponse) {
        guard current != nil else { return try await session.data(for: request) }
        let (file, response) = try await download(using: session, request: request, replayReadOnlyPOST: replayReadOnlyPOST)
        defer { try? FileManager.default.removeItem(at: file) }
        return (try Data(contentsOf: file), response)
    }

    static func download(using session: URLSession, request: URLRequest, replayReadOnlyPOST: Bool = false) async throws -> (URL, URLResponse) {
        guard let traffic = current else { return try await session.download(for: request) }
        let method = request.httpMethod ?? "GET"
        let replayable = request.httpBodyStream == nil &&
            (method == "GET" || method == "HEAD" || (method == "POST" && replayReadOnlyPOST))
        var credited: Int64 = 0
        while true {
            try await checkpoint()
            switch try await traffic.transfer(using: session, request: request, credited: credited, replayable: replayable) {
            case let .interrupted(bytes):
                // 暂停期间断开的连接可能在恢复后才报错
                credited = bytes
            case let .completed(file, response):
                do {
                    try await checkpoint()
                    return (file, response)
                } catch {
                    try? FileManager.default.removeItem(at: file)
                    throw error
                }
            }
        }
    }

    private static func isConnectionFailure(_ error: Error?) -> Bool {
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed: return true
        default: return false
        }
    }

    private func transfer(using session: URLSession, request: URLRequest, credited: Int64, replayable: Bool) async throws -> Attempt {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.downloadTask(with: request) { temporaryFile, response, error in
                    let interrupted = self.lock.withLock { () -> Int64? in
                        guard let transfer = self.tasks.removeValue(forKey: id) else { return nil }
                        let bytes = max(0, transfer.task.countOfBytesReceived)
                        self.finished.add(bytes, previouslyCredited: credited)
                        guard replayable, transfer.wasPaused,
                              Self.isConnectionFailure(error) else { return nil }
                        return max(credited, bytes)
                    }
                    if let interrupted {
                        continuation.resume(returning: .interrupted(credited: interrupted))
                        return
                    }
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let temporaryFile, let response else {
                        continuation.resume(throwing: URLError(.badServerResponse))
                        return
                    }
                    do {
                        // 回调一返回 URLSession 就会删除临时文件
                        let file = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
                        try FileManager.default.moveItem(at: temporaryFile, to: file)
                        continuation.resume(returning: .completed(file, response))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                lock.withLock {
                    tasks[id] = ActiveTransfer(task: task, previouslyCredited: credited, wasPaused: paused)
                    if Task.isCancelled { task.cancel() }
                    else if paused { notifyParked() }
                    else { task.resume() }
                }
            }
        } onCancel: {
            let task = self.lock.withLock { self.tasks[id]?.task }
            task?.cancel()
        }
    }
}
