import Foundation

public enum GameLaunchError: Error, LocalizedError {
    case alreadyRunning(instanceName: String, processIdentifiers: [Int32])
    case logFileUnavailable(path: String)
    case spawnFailed(reason: String)
    case nativesExtractionFailed(archive: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .alreadyRunning(name, pids):
            "「\(name)」已经在运行（进程 \(pids.map(String.init).joined(separator: ", "))）。"
                + "同时开两个会让存档损坏，请先关掉它。"
        case let .logFileUnavailable(path):
            "无法建立日志文件：\(path)"
        case let .spawnFailed(reason):
            "启动失败：\(reason)"
        case let .nativesExtractionFailed(archive, reason):
            "解压 \(archive) 失败：\(reason)"
        }
    }
}

public struct GameLauncher: Sendable {
    public final class Session: @unchecked Sendable {
        public let instanceID: UUID
        public let processIdentifier: Int32
        public let logFile: URL

        private let process: Process
        private let lock = NSLock()
        private var forced = false

        fileprivate init(instanceID: UUID, process: Process, logFile: URL) {
            self.instanceID = instanceID
            self.process = process
            self.processIdentifier = process.processIdentifier
            self.logFile = logFile
        }

        @discardableResult public func forceQuit() -> Bool {
            lock.withLock {
                guard process.isRunning, kill(processIdentifier, SIGKILL) == 0 else { return false }
                forced = true
                return true
            }
        }

        fileprivate func exitReason() -> GameExit {
            lock.withLock {
                let status = process.terminationStatus
                guard process.terminationReason == .uncaughtSignal else { return .exited(status) }
                return forced && status == SIGKILL ? .stoppedByPlayer : .signalled(status)
            }
        }
    }

    public init() {}

    /// 日志回调在后台线程执行
    public func launch(
        plan: LaunchPlan,
        instanceID: UUID,
        instanceName: String,
        logFile: URL,
        librariesRoot: URL,
        onOutput: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> Session {
        try launch(plan: plan, instanceID: instanceID, instanceName: instanceName, logFile: logFile,
                   librariesRoot: librariesRoot, onOutput: onOutput, onTermination: { onExit($0.code) })
    }

    public func launch(
        plan: LaunchPlan, instanceID: UUID, instanceName: String, logFile: URL, librariesRoot: URL,
        onOutput: (@Sendable (String) -> Void)? = nil,
        onTermination: @escaping @Sendable (GameExit) -> Void
    ) throws -> Session {
        let occupied = RunningGameDetector().processIdentifiers(
            usingGameDirectory: plan.workingDirectory.path(percentEncoded: false)
        )
        if !occupied.isEmpty {
            throw GameLaunchError.alreadyRunning(instanceName: instanceName, processIdentifiers: occupied)
        }

        try prepareNatives(plan, librariesRoot: librariesRoot)

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard fileManager.createFile(atPath: logFile.path(percentEncoded: false), contents: nil) else {
            throw GameLaunchError.logFileUnavailable(path: logFile.path(percentEncoded: false))
        }

        let process = Process()
        process.executableURL = plan.javaExecutable
        process.arguments = plan.arguments
        process.currentDirectoryURL = plan.workingDirectory
        if !plan.environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(plan.environment) { _, new in new }
        }
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let logHandle = try FileHandle(forWritingTo: logFile)
        do {
            try process.run()
        } catch {
            try? logHandle.close()
            throw GameLaunchError.spawnFailed(reason: error.localizedDescription)
        }

        let session = Session(instanceID: instanceID, process: process, logFile: logFile)
        // 读完管道再报告退出 否则可能漏掉最后几行崩溃日志
        DispatchQueue.global(qos: .utility).async {
            let reader = pipe.fileHandleForReading
            var pending = Data()
            logHandle.write(Data(("— 已启动，进程 \(session.processIdentifier) —\n").utf8))
            func drainChunk() -> Bool {
                let chunk = reader.availableData
                guard !chunk.isEmpty else { return false }
                logHandle.write(chunk)
                if let onOutput {
                    let parts = chunk.split(separator: 0x0A, omittingEmptySubsequences: false)
                    for part in parts.dropLast() {
                        pending.append(part)
                        onOutput(String(decoding: pending, as: UTF8.self))
                        pending.removeAll(keepingCapacity: true)
                    }
                    if let tail = parts.last { pending.append(tail) }
                }
                return true
            }
            // 这个循环可能跑几小时 临时对象要按块释放
            while autoreleasepool(invoking: drainChunk) {}
            if !pending.isEmpty { onOutput?(String(decoding: pending, as: UTF8.self)) }
            process.waitUntilExit()
            let reason = session.exitReason()
            logHandle.write(Data(("\n" + reason.marker + "\n").utf8))
            try? logHandle.close()
            onTermination(reason)
        }
        return session
    }

    private func prepareNatives(_ plan: LaunchPlan, librariesRoot: URL) throws {
        guard !plan.nativeArchives.isEmpty else { return }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: plan.nativesDirectory, withIntermediateDirectories: true)

        for archive in plan.nativeArchives {
            let jar = archive.fallbackFile ?? librariesRoot.appending(path: archive.relativePath)
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            var arguments = ["-o", "-q", jar.path(percentEncoded: false), "-d", plan.nativesDirectory.path(percentEncoded: false)]
            for excluded in archive.excludes {
                arguments.append(contentsOf: ["-x", "\(excluded)*"])
            }
            unzip.arguments = arguments
            unzip.standardOutput = FileHandle.nullDevice
            unzip.standardError = FileHandle.nullDevice

            do {
                try unzip.run()
            } catch {
                throw GameLaunchError.nativesExtractionFailed(
                    archive: archive.relativePath,
                    reason: error.localizedDescription
                )
            }
            unzip.waitUntilExit()
            guard unzip.terminationStatus == 0 else {
                throw GameLaunchError.nativesExtractionFailed(
                    archive: archive.relativePath,
                    reason: "unzip 退出码 \(unzip.terminationStatus)"
                )
            }
        }
    }
}
