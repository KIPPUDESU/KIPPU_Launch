import Foundation

public enum InstancePlanningError: Error, LocalizedError {
    case versionUnavailable(instance: String)
    case versionFileUnreadable(name: String)
    case malformedVersionFile(reason: String)
    case parentMissing(String)
    case javaPathUnavailable(String)
    case resourceMissing(String)
    case javaNotInstalled
    case javaUnsuitable(required: Int?, available: [Int])
    case clientJarMissing(name: String)

    public var errorDescription: String? {
        switch self {
        case let .versionUnavailable(instance):
            return "「\(instance)」的版本文件已不可用，可能已被移动或删除。"
        case let .versionFileUnreadable(name):
            return "无法读取版本文件：\(name)"
        case let .malformedVersionFile(reason):
            return "版本文件解析失败：\(reason)"
        case let .javaPathUnavailable(path): return "找不到所选 Java：\(path)"
        case let .resourceMissing(path): return "缺少游戏资源：\(path)"
        case let .parentMissing(parent):
            return "这是一个增量版本（继承自 \(parent)），请先安装或定位父版本。"
        case .javaNotInstalled:
            return "没有找到任何可用的 Java。请先安装 JDK。"
        case let .javaUnsuitable(required, available):
            let wanted = required.map { "Java \($0)" } ?? "所需的 Java"
            let have = available.isEmpty
                ? "（一个都没有）"
                : "已安装 \(available.map(String.init).joined(separator: "、"))"
            return "这个版本需要 \(wanted)，\(have)，没有可用的。"
        case let .clientJarMissing(name):
            return "找不到客户端 jar：\(name)"
        }
    }
}

public struct InstanceLaunchPlanner: Sendable {
    public struct Options: Sendable {
        public var sharedRoot: URL
        public var nativesDirectory: URL
        public var javaRuntimes: [JavaRuntime]
        public var session: MinecraftSession
        public var memoryMB: Int
        public var architecture: String
        public var operatingSystemVersion: OperatingSystemVersion
        public var checkResources = false
        public var extraGameArguments: [String]

        public init(
            sharedRoot: URL,
            nativesDirectory: URL,
            javaRuntimes: [JavaRuntime],
            session: MinecraftSession,
            memoryMB: Int,
            architecture: String,
            operatingSystemVersion: OperatingSystemVersion,
            extraGameArguments: [String] = []
        ) {
            self.sharedRoot = sharedRoot
            self.nativesDirectory = nativesDirectory
            self.javaRuntimes = javaRuntimes
            self.session = session
            self.memoryMB = memoryMB
            self.architecture = architecture
            self.operatingSystemVersion = operatingSystemVersion
            self.extraGameArguments = extraGameArguments
        }
    }

    public struct Resolution: Sendable {
        public let plan: LaunchPlan
        public let javaRuntime: JavaRuntime
        public let warning: String?

        public init(plan: LaunchPlan, javaRuntime: JavaRuntime, warning: String? = nil) {
            self.plan = plan
            self.javaRuntime = javaRuntime
            self.warning = warning
        }
    }

    public init() {}

    public func plan(for instance: InstanceRecord, options: Options) throws -> Resolution {
        let fileManager = FileManager.default
        let instanceDirectory = URL(fileURLWithPath: instance.path, isDirectory: true)

        let outcome = VersionLocator().locate(in: instanceDirectory)
        guard let candidate = outcome.version else {
            throw InstancePlanningError.versionUnavailable(instance: instance.displayName)
        }

        guard let data = try? Data(contentsOf: candidate.jsonFile) else {
            throw InstancePlanningError.versionFileUnreadable(name: candidate.jsonFile.lastPathComponent)
        }
        let child: VersionJSON
        do {
            child = try JSONDecoder().decode(VersionJSON.self, from: data)
        } catch {
            throw InstancePlanningError.malformedVersionFile(reason: error.localizedDescription)
        }

        let versions = instanceDirectory.deletingLastPathComponent()
        let managedRoot = instanceDirectory.appending(path: ".kippu-data")
        let sharedRoot = instance.kind == .managed && fileManager.fileExists(atPath: managedRoot.path)
            ? managedRoot : options.sharedRoot
        let (version, clientJar) = try VersionInheritance.resolve(child, in: instanceDirectory, shared: sharedRoot)
        var runtimes = options.javaRuntimes
        if let path = instance.selectedJavaPath, !path.isEmpty {
            guard let manual = JavaLocator().runtime(at: URL(fileURLWithPath: path)) else {
                throw InstancePlanningError.javaPathUnavailable(path)
            }
            runtimes = [manual]
        }

        let requiredMajor = version.javaVersion?.majorVersion ?? candidate.javaMajorVersion
        let selection = JavaLocator().select(
            requiredMajor: requiredMajor,
            hostArchitecture: options.architecture,
            from: runtimes
        )

        let javaRuntime: JavaRuntime
        var warning: String?
        switch selection {
        case let .exact(runtime):
            javaRuntime = runtime
        case let .fallback(runtime, required):
            javaRuntime = runtime
            warning = "实例要求 Java \(required)，当前选用的是 Java \(runtime.majorVersion)。"
        case .noneInstalled:
            throw InstancePlanningError.javaNotInstalled
        case let .noSuitable(required, available):
            throw InstancePlanningError.javaUnsuitable(required: required, available: available)
        }

        guard fileManager.fileExists(atPath: clientJar.path(percentEncoded: false)) else {
            throw InstancePlanningError.clientJarMissing(name: clientJar.lastPathComponent)
        }

        var inputs = LaunchPlanBuilder.Inputs(
            version: version,
            clientJar: clientJar,
            instanceDirectory: instanceDirectory,
            sharedRoot: sharedRoot,
            nativesDirectory: options.nativesDirectory,
            javaExecutable: javaRuntime.executable,
            session: options.session,
            operatingSystemVersion: options.operatingSystemVersion,
            architecture: options.architecture
        )
        inputs.memoryMB = instance.memoryMB ?? options.memoryMB
        // 解压包把模组放在实例内 运行库和素材则可能放在 versions 的上一级
        if instance.kind == .referenced, TextNormalization.namesMatch(versions.lastPathComponent, "versions") {
            let bundledRoot = versions.deletingLastPathComponent()
            let libraries = bundledRoot.appending(path: "libraries")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: libraries.path, isDirectory: &isDirectory), isDirectory.boolValue {
                inputs.sharedRoot = bundledRoot
                if PathNormalization.normalized(bundledRoot) != PathNormalization.normalized(sharedRoot) {
                    inputs.platformLibrariesFallback = sharedRoot.appending(path: "libraries")
                }
            }
            let assets = bundledRoot.appending(path: "assets")
            let index = version.assetIndex?.id ?? version.assets
            let marker = index.map { assets.appending(path: "indexes/\($0).json") } ?? assets
            inputs.assetsRoot = fileManager.fileExists(atPath: marker.path) ? assets : sharedRoot.appending(path: "assets")
        }
        if let log = version.logging?.client, let url = URL(string: log.file.url) {
            let assets = inputs.assetsRoot ?? sharedRoot.appending(path: "assets")
            let config = assets.appending(path: "log_configs").appending(path: url.lastPathComponent)
            if fileManager.fileExists(atPath: config.path) { inputs.loggingConfiguration = config }
        }
        inputs.checkResources = options.checkResources
        inputs.extraGameArguments = options.extraGameArguments

        return Resolution(
            plan: try LaunchPlanBuilder().build(inputs),
            javaRuntime: javaRuntime,
            warning: warning
        )
    }
}
