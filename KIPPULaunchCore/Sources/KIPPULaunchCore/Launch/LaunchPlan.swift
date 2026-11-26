import Foundation

public struct WindowResolution: Sendable, Equatable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public enum LaunchPlanError: Error, LocalizedError {
    case missingMainClass(versionID: String)

    public var errorDescription: String? {
        switch self {
        case let .missingMainClass(versionID):
            "版本「\(versionID)」没有 mainClass，且没有父版本可供继承，无法启动。"
        }
    }
}

public struct LaunchPlan: Sendable {
    public var javaExecutable: URL
    public var arguments: [String]
    public var workingDirectory: URL
    public var librariesDirectory: URL
    public var nativesDirectory: URL
    public var nativeArchives: [NativeArchive]
    public var environment: [String: String]

    public var commandLine: [String] {
        [javaExecutable.path(percentEncoded: false)] + arguments
    }

    /// 写日志时使用这份已隐去令牌的命令行
    public var commandLineForDisplay: String {
        var redacted = arguments
        for index in redacted.indices where redacted[index] == "--accessToken" {
            let next = index + 1
            if next < redacted.count { redacted[next] = "<已隐去>" }
        }
        // 外置登录的代理参数也可能包含令牌
        for index in redacted.indices where redacted[index].hasPrefix("-javaagent:") {
            redacted[index] = "-javaagent:<authlib-injector>"
        }
        return ([javaExecutable.lastPathComponent] + redacted)
            .map { $0.contains(" ") ? "'\($0)'" : $0 }
            .joined(separator: " ")
    }
}

public struct LaunchPlanBuilder: Sendable {
    public struct Inputs: Sendable {
        public var version: VersionJSON
        public var clientJar: URL
        public var instanceDirectory: URL
        public var sharedRoot: URL
        var assetsRoot: URL?
        var platformLibrariesFallback: URL?
        var checkResources = false
        public var nativesDirectory: URL
        public var javaExecutable: URL
        public var session: MinecraftSession

        public var memoryMB: Int?
        public var resolution: WindowResolution?
        public var loggingConfiguration: URL?
        public var extraGameArguments: [String] = []
        public var extraJVMArguments: [String] = []
        public var launcherName: String = "KIPPU_Launch"
        public var launcherVersion: String = "1.0"
        public var operatingSystemVersion: OperatingSystemVersion
        public var architecture: String
        public var environment: [String: String] = [:]

        public init(
            version: VersionJSON,
            clientJar: URL,
            instanceDirectory: URL,
            sharedRoot: URL,
            nativesDirectory: URL,
            javaExecutable: URL,
            session: MinecraftSession,
            operatingSystemVersion: OperatingSystemVersion,
            architecture: String
        ) {
            self.version = version
            self.clientJar = clientJar
            self.instanceDirectory = instanceDirectory
            self.sharedRoot = sharedRoot
            self.nativesDirectory = nativesDirectory
            self.javaExecutable = javaExecutable
            self.session = session
            self.operatingSystemVersion = operatingSystemVersion
            self.architecture = architecture
        }
    }

    public init() {}

    public func build(_ inputs: Inputs) throws -> LaunchPlan {
        let version = inputs.version
        let librariesRoot = inputs.sharedRoot.appending(path: "libraries", directoryHint: .isDirectory)
        let assetsRoot = inputs.assetsRoot ?? inputs.sharedRoot.appending(path: "assets", directoryHint: .isDirectory)

        let instancePath = PathNormalization.normalized(inputs.instanceDirectory)
        let nativesPath = PathNormalization.normalized(inputs.nativesDirectory)

        let evaluator = RuleEvaluator(
            osName: "osx",
            osVersion: "\(inputs.operatingSystemVersion.majorVersion).\(inputs.operatingSystemVersion.minorVersion).\(inputs.operatingSystemVersion.patchVersion)",
            osArch: inputs.architecture,
            features: [
                "is_demo_user": false,
                "has_custom_resolution": inputs.resolution != nil,
                "has_quick_plays_support": false,
                "is_quick_play_singleplayer": false,
                "is_quick_play_multiplayer": false,
                "is_quick_play_realms": false,
            ]
        )

        var resolution = LibraryResolver(evaluator: evaluator).resolve(version.libraries ?? [])

        func libraryFile(_ path: String, platformSpecific: Bool) throws -> URL {
            let local = librariesRoot.appending(path: path)
            if platformSpecific, let fallback = inputs.platformLibrariesFallback,
               !FileManager.default.fileExists(atPath: local.path) {
                let other = fallback.appending(path: path)
                if FileManager.default.fileExists(atPath: other.path) { return other }
            }
            if inputs.checkResources && !FileManager.default.fileExists(atPath: local.path) {
                throw InstancePlanningError.resourceMissing(local.path)
            }
            return local
        }

        // 类路径中依赖库在前 客户端 JAR 在后
        let classpathEntries = try resolution.classpathEntries.map { path in
            try PathNormalization.normalized(libraryFile(path, platformSpecific: resolution.platformClasspathEntries.contains(path)))
        } + [PathNormalization.normalized(inputs.clientJar)]
        for index in resolution.nativeArchives.indices {
            let path = resolution.nativeArchives[index].relativePath
            let file = try libraryFile(path, platformSpecific: true)
            if file != librariesRoot.appending(path: path) { resolution.nativeArchives[index].fallbackFile = file }
        }
        let classpath = classpathEntries.joined(separator: ":")
        let librariesRootPath = PathNormalization.normalized(librariesRoot)

        let assetIndexID = version.assetIndex?.id ?? version.assets ?? ""
        if inputs.checkResources, let index = version.assetIndex?.id {
            let file = assetsRoot.appending(path: "indexes/\(index).json")
            if !FileManager.default.fileExists(atPath: file.path) { throw InstancePlanningError.resourceMissing(file.path) }
        }
        let assetsDirectory = assetIndexID == "legacy"
            ? assetsRoot.appending(path: "virtual/legacy", directoryHint: .isDirectory)
            : assetsRoot

        let placeholders = makePlaceholders(
            inputs: inputs,
            assetIndexID: assetIndexID,
            assetsDirectory: PathNormalization.normalized(assetsDirectory),
            instancePath: instancePath,
            nativesPath: nativesPath,
            librariesRootPath: librariesRootPath,
            classpath: classpath
        )

        guard let mainClass = version.mainClass, !mainClass.isEmpty else {
            throw LaunchPlanError.missingMainClass(versionID: version.id)
        }

        let jvmArguments = makeJVMArguments(inputs: inputs, evaluator: evaluator, placeholders: placeholders, classpath: classpath)
        let gameArguments = makeGameArguments(version: version, evaluator: evaluator, placeholders: placeholders)
            + inputs.extraGameArguments

        var arguments: [String] = []
        arguments += inputs.session.extraJVMArguments
        arguments += inputs.extraJVMArguments
        if let memory = inputs.memoryMB, memory > 0 {
            arguments.append("-Xmx\(memory)M")
        }
        arguments += jvmArguments
        if let logging = makeLoggingArgument(version: version, configuration: inputs.loggingConfiguration) {
            arguments.append(logging)
        }
        arguments.append(mainClass)
        arguments += instanceGameArguments(gameArguments, directory: instancePath, modern: version.arguments?.game != nil)

        return LaunchPlan(
            javaExecutable: inputs.javaExecutable,
            arguments: arguments,
            workingDirectory: URL(fileURLWithPath: instancePath, isDirectory: true),
            librariesDirectory: librariesRoot,
            nativesDirectory: inputs.nativesDirectory,
            nativeArchives: resolution.nativeArchives,
            environment: inputs.environment
        )
    }

    private func makePlaceholders(
        inputs: Inputs,
        assetIndexID: String,
        assetsDirectory: String,
        instancePath: String,
        nativesPath: String,
        librariesRootPath: String,
        classpath: String
    ) -> PlaceholderValues {
        let version = inputs.version
        var placeholders = PlaceholderValues()

        placeholders.playerName = inputs.session.playerName
        placeholders.uuid = inputs.session.uuid
        placeholders.accessToken = inputs.session.accessToken
        placeholders.userType = inputs.session.userType
        placeholders.xuid = inputs.session.xuid
        placeholders.clientID = inputs.session.clientID
        placeholders.userProperties = inputs.session.userProperties
        placeholders.sessionID = "token:\(inputs.session.accessToken):\(inputs.session.uuid)"

        placeholders.versionName = version.id
        placeholders.versionType = version.type ?? "release"
        placeholders.gameDirectory = instancePath
        placeholders.assetsRoot = assetsDirectory
        placeholders.assetsIndexName = assetIndexID
        placeholders.gameAssets = assetsDirectory
        placeholders.nativesDirectory = nativesPath
        placeholders.launcherName = inputs.launcherName
        placeholders.launcherVersion = inputs.launcherVersion

        placeholders.classpath = classpath
        placeholders.libraryDirectory = librariesRootPath
        placeholders.classpathSeparator = ":"
        placeholders.primaryJarName = inputs.clientJar.lastPathComponent

        placeholders.resolutionWidth = inputs.resolution.map { String($0.width) }
        placeholders.resolutionHeight = inputs.resolution.map { String($0.height) }

        return placeholders
    }

    private func makeJVMArguments(
        inputs: Inputs,
        evaluator: RuleEvaluator,
        placeholders: PlaceholderValues,
        classpath: String
    ) -> [String] {
        var arguments: [String]

        if let declared = inputs.version.arguments?.jvm, !declared.isEmpty {
            arguments = flatten(declared, evaluator: evaluator)
        } else {
            arguments = [
                "-Djava.library.path=\(placeholders.nativesDirectory)",
                "-cp",
                classpath,
            ]
        }

        // 老版本缺少 LWJGL 在 macOS 上启动所需的主线程参数
        let hasStartOnFirstThread = arguments.contains("-XstartOnFirstThread")
        if evaluator.osName == "osx", !hasStartOnFirstThread {
            arguments.insert("-XstartOnFirstThread", at: 0)
        }

        return placeholders.substituteAll(arguments)
    }

    /// 有些整合包会把作者机器上的游戏目录写进启动参数
    private func instanceGameArguments(_ arguments: [String], directory: String, modern: Bool) -> [String] {
        var result: [String] = []
        var hasDirectory = false
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if argument == "--gameDir" || argument.hasPrefix("--gameDir=") {
                if argument == "--gameDir", index < arguments.count, !arguments[index].hasPrefix("--") {
                    index += 1
                }
                if !hasDirectory {
                    result += ["--gameDir", directory]
                    hasDirectory = true
                }
            } else {
                result.append(argument)
            }
        }
        if modern && !hasDirectory { result += ["--gameDir", directory] }
        return result
    }

    private func makeGameArguments(
        version: VersionJSON,
        evaluator: RuleEvaluator,
        placeholders: PlaceholderValues
    ) -> [String] {
        var arguments: [String]

        if let declared = version.arguments?.game, !declared.isEmpty {
            arguments = flatten(declared, evaluator: evaluator)
        } else if let legacy = version.minecraftArguments, !legacy.isEmpty {
            arguments = legacy.split(separator: " ").map(String.init)
        } else {
            arguments = []
        }

        return placeholders.substituteAll(arguments)
    }

    private func makeLoggingArgument(version: VersionJSON, configuration: URL?) -> String? {
        guard let logging = version.logging?.client, let configuration else { return nil }
        return logging.argument.replacingOccurrences(
            of: "${path}",
            with: configuration.path(percentEncoded: false)
        )
    }

    private func flatten(_ values: [ArgumentValue], evaluator: RuleEvaluator) -> [String] {
        var result: [String] = []
        for value in values {
            switch value {
            case let .plain(text):
                result.append(text)
            case let .conditional(rules, stringOrArray):
                guard evaluator.isAllowed(rules: rules) else { continue }
                result.append(contentsOf: stringOrArray.values)
            }
        }
        return result
    }
}
