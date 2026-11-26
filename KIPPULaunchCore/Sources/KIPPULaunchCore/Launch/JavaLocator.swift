import Foundation

public struct JavaRuntime: Sendable, Hashable, Identifiable {
    public let executable: URL
    public let home: URL
    public let majorVersion: Int
    public let version: String
    public let architecture: String
    public let origin: Origin

    public var id: String { home.path(percentEncoded: false) }

    public enum Origin: String, Sendable, Codable {
        case system
        case launcherManaged
    }

    public init(executable: URL, home: URL, majorVersion: Int, version: String, architecture: String, origin: Origin) {
        self.executable = executable
        self.home = home
        self.majorVersion = majorVersion
        self.version = version
        self.architecture = architecture
        self.origin = origin
    }

    public var displayName: String {
        "Java \(version) (\(architecture == "arm64" ? "arm64" : "x86_64"))"
    }
}

public enum JavaSelection: Sendable {
    case exact(JavaRuntime)
    case fallback(JavaRuntime, required: Int)
    case noneInstalled
    case noSuitable(required: Int?, available: [Int])
}

public struct JavaLocator: Sendable {
    public var additionalSearchRoots: [URL]

    public init(additionalSearchRoots: [URL] = []) {
        self.additionalSearchRoots = additionalSearchRoots
    }

    public func discoverRuntimes(fileManager: FileManager = .default) -> [JavaRuntime] {
        var homes: [URL] = []

        let fixedRoots = [
            "/Library/Java/JavaVirtualMachines",
            "/System/Library/Java/JavaVirtualMachines",
            "/Library/Internet Plug-Ins/JavaAppletPlugin.plugin/Contents",
        ]
        for path in fixedRoots {
            homes.append(contentsOf: javaHomes(under: URL(fileURLWithPath: path), fileManager: fileManager))
        }

        let userRoot = fileManager.homeDirectoryForCurrentUser
            .appending(path: "Library/Java/JavaVirtualMachines", directoryHint: .isDirectory)
        homes.append(contentsOf: javaHomes(under: userRoot, fileManager: fileManager))

        for prefix in ["/opt/homebrew/opt", "/usr/local/opt"] {
            homes.append(contentsOf: homebrewJavaHomes(under: URL(fileURLWithPath: prefix), fileManager: fileManager))
        }

        homes.append(contentsOf: additionalSearchRoots)

        var seen = Set<String>()
        var runtimes: [JavaRuntime] = []
        for home in homes {
            let key = PathNormalization.normalized(home)
            guard seen.insert(key).inserted else { continue }
            if let runtime = inspect(home: home, fileManager: fileManager) {
                runtimes.append(runtime)
            }
        }

        return runtimes.sorted {
            $0.majorVersion != $1.majorVersion ? $0.majorVersion > $1.majorVersion : $0.version > $1.version
        }
    }

    private func javaHomes(under root: URL, fileManager: FileManager) -> [URL] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: root.path(percentEncoded: false)) else {
            return []
        }
        var homes: [URL] = []
        for name in names.sorted() where !name.hasPrefix(".") {
            let candidate = root.appending(path: name, directoryHint: .isDirectory)
            let nested = candidate.appending(path: "Contents/Home", directoryHint: .isDirectory)
            if fileManager.isExecutableFile(atPath: nested.appending(path: "bin/java").path(percentEncoded: false)) {
                homes.append(nested)
            } else if fileManager.isExecutableFile(atPath: candidate.appending(path: "bin/java").path(percentEncoded: false)) {
                // 旧式 Java 插件直接以 Contents 为主目录
                homes.append(candidate)
            }
        }
        return homes
    }

    private func homebrewJavaHomes(under prefix: URL, fileManager: FileManager) -> [URL] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: prefix.path(percentEncoded: false)) else {
            return []
        }
        var homes: [URL] = []
        for name in names.sorted() where name.hasPrefix("openjdk") {
            let home = prefix
                .appending(path: name, directoryHint: .isDirectory)
                .appending(path: "libexec/openjdk.jdk/Contents/Home", directoryHint: .isDirectory)
            if fileManager.isExecutableFile(atPath: home.appending(path: "bin/java").path(percentEncoded: false)) {
                homes.append(home)
            }
        }
        return homes
    }

    public func runtime(at url: URL) -> JavaRuntime? {
        let fileManager = FileManager.default
        var home = url
        if url.lastPathComponent == "java" {
            home = url.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        } else if fileManager.fileExists(atPath: url.appending(path: "Contents/Home/bin/java").path) {
            home = url.appending(path: "Contents/Home")
        }
        return inspect(home: home, fileManager: fileManager)
    }

    private func inspect(home: URL, fileManager: FileManager) -> JavaRuntime? {
        let executable = home.appending(path: "bin/java")
        guard fileManager.isExecutableFile(atPath: executable.path(percentEncoded: false)) else { return nil }

        let releaseURL = home.appending(path: "release")
        guard let text = try? String(contentsOf: releaseURL, encoding: .utf8),
              let version = Self.releaseValue("JAVA_VERSION", in: text)
        else {
            return inspectByRunningJava(executable: executable, home: home)
        }

        guard let major = Self.majorVersion(from: version) else { return nil }
        return JavaRuntime(
            executable: executable,
            home: home,
            majorVersion: major,
            version: version,
            architecture: Self.releaseValue("OS_ARCH", in: text).map(Self.normalizeArchitecture) ?? "unknown",
            origin: .system
        )
    }

    private func inspectByRunningJava(executable: URL, home: URL) -> JavaRuntime? {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-version"]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8),
              let version = Self.versionFromBanner(output),
              let major = Self.majorVersion(from: version)
        else { return nil }

        return JavaRuntime(
            executable: executable,
            home: home,
            majorVersion: major,
            version: version,
            architecture: output.contains("aarch64") || output.contains("arm64") ? "arm64" : "x86_64",
            origin: .system
        )
    }

    /// 未指定主版本时优先选择原生架构中最新的运行时
    public func select(
        requiredMajor: Int?,
        hostArchitecture: String,
        from runtimes: [JavaRuntime]
    ) -> JavaSelection {
        guard !runtimes.isEmpty else { return .noneInstalled }

        func sorted(_ candidates: [JavaRuntime], preferringHigherMajor: Bool) -> [JavaRuntime] {
            candidates.sorted { lhs, rhs in
                let lhsNative = lhs.architecture == hostArchitecture
                let rhsNative = rhs.architecture == hostArchitecture
                if lhsNative != rhsNative { return lhsNative }

                if lhs.majorVersion != rhs.majorVersion {
                    return preferringHigherMajor
                        ? lhs.majorVersion > rhs.majorVersion
                        : lhs.majorVersion < rhs.majorVersion
                }
                return lhs.version > rhs.version
            }
        }

        guard let requiredMajor else {
            guard let best = sorted(runtimes, preferringHigherMajor: true).first else {
                return .noneInstalled
            }
            return .exact(best)
        }

        let exact = runtimes.filter { $0.majorVersion == requiredMajor }
        if let chosen = sorted(exact, preferringHigherMajor: true).first {
            return .exact(chosen)
        }

        let higher = runtimes.filter { $0.majorVersion > requiredMajor }
        if let chosen = sorted(higher, preferringHigherMajor: false).first {
            return .fallback(chosen, required: requiredMajor)
        }

        return .noSuitable(required: requiredMajor, available: runtimes.map(\.majorVersion))
    }

    static func releaseValue(_ key: String, in text: String) -> String? {
        for line in text.split(separator: "\n") {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let name = line[line.startIndex..<separator].trimmingCharacters(in: .whitespaces)
            guard name == key else { continue }
            return line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }

    static func majorVersion(from version: String) -> Int? {
        let parts = version.split(separator: ".").map(String.init)
        guard let first = parts.first, let leading = Int(first) else { return nil }
        // Java 8 及更早的版本号以 1 开头
        if leading == 1 {
            guard parts.count >= 2, let second = Int(parts[1]) else { return 1 }
            return second
        }
        return leading
    }

    static func normalizeArchitecture(_ raw: String) -> String {
        switch raw.lowercased() {
        case "aarch64", "arm64": "arm64"
        default: "x86_64"
        }
    }

    static func versionFromBanner(_ output: String) -> String? {
        guard let firstQuote = output.firstIndex(of: "\"") else { return nil }
        let rest = output[output.index(after: firstQuote)...]
        guard let secondQuote = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[rest.startIndex..<secondQuote])
    }
}
