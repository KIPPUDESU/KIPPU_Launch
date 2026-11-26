import Foundation
import KIPPULaunchCore
import Observation

struct LaunchFailure: Identifiable {
    let id: UUID
    let instance: InstanceRecord
    let diagnosis: LaunchDiagnosis
    var exitCode: Int32?
    var logFile: URL?
    var folder: URL?
    var update: ModUpdateBackup?

    var summary: String {
        var lines = [instance.displayName, diagnosis.title, diagnosis.explanation]
        if let exitCode, diagnosis.cause != .interrupted { lines.append("退出码 \(exitCode)") }
        if !diagnosis.evidence.isEmpty && diagnosis.evidence != [diagnosis.explanation] {
            lines.append(diagnosis.source)
            lines.append(contentsOf: diagnosis.evidence)
        }
        return lines.joined(separator: "\n")
    }
}

struct GameLogSource: Equatable {
    let file: URL?
    let attempt: UUID?
    let live: Bool
}

@MainActor
@Observable
final class LaunchController {
    @ObservationIgnored weak var downloads: DownloadCenter?
    @ObservationIgnored private var javaScan: Task<[JavaRuntime], Never>?
    private(set) var javaRuntimes: [JavaRuntime] = []
    private var sessions: [UUID: GameLauncher.Session] = [:]
    private(set) var preparing: Set<UUID> = []
    private(set) var visibleLogFile: URL?
    var visibleSession: GameLauncher.Session? { logInstanceID.flatMap { sessions[$0] } }
    var visibleLogSource: GameLogSource {
        GameLogSource(file: visibleLogFile, attempt: logInstanceID.flatMap { attempts[$0]?.id }, live: isLogTargetRunning)
    }
    var didLaunch: ((UUID) -> Void)?
    private(set) var failures: [UUID: LaunchFailure] = [:]
    private struct Attempt {
        let id: UUID
        var file: URL?
    }
    private var attempts: [UUID: Attempt] = [:]
    var visibleFailure: LaunchFailure? { logInstanceID.flatMap { failures[$0] } }
    private(set) var logInstanceName: String?
    private(set) var logInstanceID: UUID?
    private(set) var isShowingLog = false

    var isLogTargetRunning: Bool {
        visibleSession != nil
    }

    var problem: String?

    var accountSessionProvider: (@MainActor () async throws -> MinecraftSession?)?

    var playerName: String {
        didSet { settings.set(playerName, forKey: SettingsKey.playerName.rawValue) }
    }

    var sharedDataRoot: String {
        didSet { settings.set(sharedDataRoot, forKey: SettingsKey.sharedDataRoot.rawValue) }
    }

    var defaultMemoryMB: Int {
        didSet { settings.set(defaultMemoryMB, forKey: SettingsKey.defaultMemoryMB.rawValue) }
    }

    private let settings: UserDefaults
    private let fileManager = FileManager.default
    private let launcher = GameLauncher()

    private let baseURL: URL
    private let logsDirectory: URL
    private let nativesRoot: URL

    init(settings defaults: UserDefaults = .standard, paths: AppPaths? = nil) {
        settings = defaults

        let resolvedBase: URL
        if let paths = paths ?? (try? AppPaths.standard(create: true)) {
            resolvedBase = paths.baseURL
        } else {
            resolvedBase = fileManager.temporaryDirectory
                .appending(path: "KIPPU_Launch-fallback", directoryHint: .isDirectory)
        }
        baseURL = resolvedBase
        logsDirectory = resolvedBase.appending(path: "logs", directoryHint: .isDirectory)
        nativesRoot = resolvedBase.appending(path: "cache/natives", directoryHint: .isDirectory)

        let home = fileManager.homeDirectoryForCurrentUser
        playerName = defaults.string(forKey: SettingsKey.playerName.rawValue)
            ?? home.lastPathComponent
        sharedDataRoot = defaults.string(forKey: SettingsKey.sharedDataRoot.rawValue)
            ?? home.appending(path: "Library/Application Support/minecraft").path(percentEncoded: false)
        defaultMemoryMB = defaults.object(forKey: SettingsKey.defaultMemoryMB.rawValue) as? Int ?? 4096
    }

    private enum SettingsKey: String {
        case playerName, sharedDataRoot, defaultMemoryMB
    }

    func refreshJavaRuntimes() async {
        if let javaScan {
            _ = await javaScan.value
            return
        }
        let locator = JavaLocator(additionalSearchRoots: [baseURL.appending(path: "runtime", directoryHint: .isDirectory)])
        let scan = Task.detached(priority: .utility) { locator.discoverRuntimes() }
        javaScan = scan
        javaRuntimes = await scan.value
        javaScan = nil
    }

    func isRunning(_ instance: InstanceRecord) -> Bool {
        sessions[instance.id] != nil
    }

    func launch(_ instance: InstanceRecord, openLogWindow: Bool = true) async {
        guard sessions[instance.id] == nil, preparing.insert(instance.id).inserted else { return }
        defer { preparing.remove(instance.id) }
        do {
            try downloads?.beginLaunch(instance.id)
        } catch {
            problem = error.localizedDescription
            return
        }
        defer { downloads?.finishLaunch(instance.id) }
        let attempt = UUID()
        attempts[instance.id] = Attempt(id: attempt)
        failures[instance.id] = nil
        problem = nil

        let session: MinecraftSession
        do {
            session = try await accountSessionProvider?() ?? offlineFallbackSession()
        } catch {
            problem = error.localizedDescription
            return
        }

        let resolution: InstanceLaunchPlanner.Resolution
        do {
            resolution = try await resolveLaunch(for: instance, session: session)
        } catch {
            let folder: URL
            if case let .resourceMissing(path) = error as? InstancePlanningError {
                var parent = URL(fileURLWithPath: path).deletingLastPathComponent()
                while !fileManager.fileExists(atPath: parent.path), parent.pathComponents.count > 1 {
                    parent.deleteLastPathComponent()
                }
                folder = parent
            } else {
                folder = URL(fileURLWithPath: instance.path)
            }
            presentPreflight(error, instance: instance, attempt: attempt, folder: folder)
            return
        }

        if let warning = resolution.warning {
            problem = "「\(instance.displayName)」：\(warning)"
        }

        await start(plan: resolution.plan, instance: instance, attempt: attempt, openLogWindow: openLogWindow)
    }

    /// 预检使用离线身份以免刷新账号令牌
    func checkLaunchEnvironment(for instance: InstanceRecord) async throws -> (java: JavaRuntime, warning: String?) {
        await refreshJavaRuntimes()
        try Task.checkCancellation()
        let result = try await resolveLaunch(for: instance, session: offlineFallbackSession())
        return (result.javaRuntime, result.warning)
    }

    private func resolveLaunch(for instance: InstanceRecord, session: MinecraftSession) async throws -> InstanceLaunchPlanner.Resolution {
        // 两种架构的原生库可能同名
        let nativesDirectory = nativesRoot
            .appending(path: instance.id.uuidString, directoryHint: .isDirectory)
            .appending(path: HostArchitecture.current, directoryHint: .isDirectory)

        if let javaScan { javaRuntimes = await javaScan.value }
        var options = InstanceLaunchPlanner.Options(
            sharedRoot: URL(fileURLWithPath: sharedDataRoot, isDirectory: true),
            nativesDirectory: nativesDirectory,
            javaRuntimes: javaRuntimes,
            session: session,
            memoryMB: defaultMemoryMB,
            architecture: HostArchitecture.current,
            operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersion
        )

        options.checkResources = true
        return try await Self.plan(for: instance, options: options)
    }

    @concurrent private static func plan(for instance: InstanceRecord, options: InstanceLaunchPlanner.Options) async throws -> InstanceLaunchPlanner.Resolution {
        try Task.checkCancellation()
        return try InstanceLaunchPlanner().plan(for: instance, options: options)
    }

    private func offlineFallbackSession() -> MinecraftSession {
        MinecraftSession(
            uuid: OfflineUUID.forPlayerName(playerName),
            playerName: playerName,
            accessToken: "0",
            userType: "legacy"
        )
    }

    private func presentPreflight(_ error: any Error, instance: InstanceRecord, attempt: UUID, folder: URL) {
        let diagnosis = LaunchDiagnosis.preflight(error)
        present(LaunchFailure(id: attempt, instance: instance, diagnosis: diagnosis,
                              folder: diagnosis.cause == .java ? nil : folder))
    }

    private func present(_ failure: LaunchFailure) {
        guard attempts[failure.instance.id]?.id == failure.id else { return }
        failures[failure.instance.id] = failure
        if failure.diagnosis.cause == .interrupted && !isShowingLog { return }
        if !isShowingLog || logInstanceID == failure.instance.id {
            visibleLogFile = failure.logFile
            logInstanceID = failure.instance.id
            logInstanceName = failure.instance.displayName
            isShowingLog = true
        }
    }

    private func start(plan: LaunchPlan, instance: InstanceRecord, attempt: UUID, openLogWindow: Bool) async {
        let started = Date()
        let gameDirectory = plan.workingDirectory
        let id = instance.id
        let file = logFile(for: id)
        let (exits, sink) = AsyncStream<GameExit>.makeStream(bufferingPolicy: .bufferingNewest(1))
        do {
            let session = try await Task.detached { [launcher] in
                try launcher.launch(plan: plan, instanceID: id, instanceName: instance.name,
                    logFile: file, librariesRoot: plan.librariesDirectory,
                    onTermination: {
                        sink.yield($0)
                        sink.finish()
                    })
            }.value
            sessions[id] = session
            preparing.remove(id)
            didLaunch?(id)
            attempts[id]?.file = file
            if openLogWindow { showLog(instance) }
            Task {
                for await exit in exits {
                    sessions[id] = nil
                    guard exit.code != 0 else { return }
                    let ended = Date()
                    let diagnosis = await Task.detached(priority: .utility) {
                        LaunchDiagnosis.afterExit(exit, gameDirectory: gameDirectory, started: started,
                                                  ended: ended, output: [], launcherLog: file)
                    }.value
                    guard let diagnosis else { return }
                    var recent: ModUpdateBackup?
                    if diagnosis.cause != .interrupted, let record = try? await InstanceMods(instance: instance).lastUpdate(),
                       record.date <= started, record.date >= (instance.lastLaunchedAt ?? .distantPast) {
                        recent = record
                    }
                    present(LaunchFailure(id: attempt, instance: instance, diagnosis: diagnosis,
                                          exitCode: exit.code, logFile: file, update: recent))
                }
            }
        } catch {
            sink.finish()
            presentPreflight(error, instance: instance, attempt: attempt, folder: plan.workingDirectory)
        }
    }

    private func logFile(for id: UUID) -> URL {
        logsDirectory.appending(path: id.uuidString + ".log")
    }

    private func existingLog(_ instance: InstanceRecord) -> URL? {
        let legacyName = instance.name.components(separatedBy: CharacterSet(charactersIn: "/\\\\:*?\\\"<>|")).joined(separator: "_")
        return [logFile(for: instance.id), logsDirectory.appending(path: legacyName + ".log")]
            .first { fileManager.fileExists(atPath: $0.path) }
    }

    func logSource(for instance: InstanceRecord) -> GameLogSource {
        let attempt = attempts[instance.id]
        // 此时磁盘上的日志可能还是上一次的
        let file = attempt == nil ? existingLog(instance) : attempt?.file
        return GameLogSource(file: file, attempt: attempt?.id, live: isRunning(instance))
    }

    func hasLog(_ instance: InstanceRecord) -> Bool { existingLog(instance) != nil }

    func showLog(_ instance: InstanceRecord) {
        visibleLogFile = failures[instance.id]?.logFile ?? existingLog(instance)
        if attempts[instance.id] == nil, let file = visibleLogFile {
            let id = UUID()
            attempts[instance.id] = Attempt(id: id, file: file)
            Task {
                let diagnosis = await Task.detached(priority: .utility) { () -> LaunchFailure? in
                    guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
                    defer { try? handle.close() }
                    guard let size = try? handle.seekToEnd(),
                          (try? handle.seek(toOffset: size > 512 ? size - 512 : 0)) != nil,
                          let data = try? handle.read(upToCount: 512),
                          let last = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).last,
                          let exit = GameExit(marker: String(last)), exit.code != 0 else { return nil }
                    let ended = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    guard let diagnosis = LaunchDiagnosis.afterExit(exit, gameDirectory: URL(fileURLWithPath: instance.path),
                        started: instance.lastLaunchedAt ?? ended, ended: ended, output: [], launcherLog: file) else { return nil }
                    return LaunchFailure(id: id, instance: instance, diagnosis: diagnosis, exitCode: exit.code, logFile: file)
                }.value
                if let diagnosis, attempts[instance.id]?.id == id { failures[instance.id] = diagnosis }
            }
        }
        logInstanceName = instance.displayName
        logInstanceID = instance.id
        isShowingLog = true
    }

    func logSummary(rows: [GameLogTail.Row]) -> String {
        if let visibleFailure { return visibleFailure.summary }
        let text = rows.map(\.line.text)
        let errors = text.filter { line in
            ["error", "exception", "caused by", "fatal", "状态码"].contains { line.localizedCaseInsensitiveContains($0) }
        }
        return ([logInstanceName ?? "Minecraft"] + (errors.isEmpty ? text.suffix(12) : errors.suffix(15))).joined(separator: "\n")
    }

    func didRollback(_ backupID: UUID, instanceID: UUID) {
        if failures[instanceID]?.update?.id == backupID { failures[instanceID]?.update = nil }
    }

    func dismissLog() { isShowingLog = false }
}
