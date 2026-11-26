import Foundation

public struct NativeArchive: Sendable, Hashable {
    public let relativePath: String
    public let excludes: [String]
    /// 跨平台整合包可能只在共享缓存中有本机可用的原生库
    var fallbackFile: URL? = nil
}

public struct LibraryResolution: Sendable {
    var platformClasspathEntries: Set<String> = []
    public var classpathEntries: [String]
    /// 新版 LWJGL 自行解压类路径上的原生库
    public var nativeArchives: [NativeArchive]
    public var skippedLibraries: [String]

    public init(classpathEntries: [String] = [], nativeArchives: [NativeArchive] = [], skippedLibraries: [String] = []) {
        self.classpathEntries = classpathEntries
        self.nativeArchives = nativeArchives
        self.skippedLibraries = skippedLibraries
    }
}

public struct LibraryResolver: Sendable {
    public let evaluator: RuleEvaluator

    public init(evaluator: RuleEvaluator) {
        self.evaluator = evaluator
    }

    /// macOS 在规则中写作 osx 在分类器中写作 macos
    private var classifierOSName: String {
        switch evaluator.osName {
        case "osx": "macos"
        default: evaluator.osName
        }
    }

    public func resolve(_ libraries: [Library]) -> LibraryResolution {
        var resolution = LibraryResolution()

        for library in libraries {
            guard evaluator.isAllowed(rules: library.rules) else {
                resolution.skippedLibraries.append(library.name)
                continue
            }

            let parts = library.name.split(separator: ":").map(String.init)
            let classifier = parts.count >= 4 ? parts[3] : nil

            if let classifier, let native = NativeClassifier(classifier) {
                guard matchesHost(native) else {
                    resolution.skippedLibraries.append(library.name)
                    continue
                }
                if let path = relativePath(of: library) {
                    resolution.classpathEntries.append(path)
                    resolution.platformClasspathEntries.insert(path)
                }
                continue
            }

            if let natives = library.natives, let template = natives[evaluator.osName] {
                let key = template.replacingOccurrences(of: "${arch}", with: legacyArchToken)
                if let artifact = library.downloads?.classifiers?[key],
                   let path = artifact.path ?? derivedPath(from: library.name, appendingClassifier: key) {
                    resolution.nativeArchives.append(
                        NativeArchive(relativePath: path, excludes: library.extract?.exclude ?? [])
                    )
                }
                // 旧版库有时只有原生库分类器
                if library.downloads == nil || library.downloads?.artifact != nil, let path = relativePath(of: library) {
                    resolution.classpathEntries.append(path)
                }
                continue
            }

            guard let path = relativePath(of: library) else {
                resolution.skippedLibraries.append(library.name)
                continue
            }
            resolution.classpathEntries.append(path)
            if library.rules?.contains(where: { $0.action == .allow && $0.os?.name == evaluator.osName }) == true {
                resolution.platformClasspathEntries.insert(path)
            }
        }

        return resolution
    }

    struct NativeClassifier {
        let platformOS: String
        let arch: String?

        init?(_ raw: String) {
            let prefix = "natives-"
            guard raw.hasPrefix(prefix) else { return nil }
            let rest = raw.dropFirst(prefix.count)
            let parts = rest.split(separator: "-", maxSplits: 1).map(String.init)
            guard let platformOS = parts.first else { return nil }
            self.platformOS = platformOS
            self.arch = parts.count > 1 ? parts[1] : nil
        }
    }

    func matchesHost(_ native: NativeClassifier) -> Bool {
        guard native.platformOS == classifierOSName else { return false }

        switch (native.arch, evaluator.osArch) {
        case (nil, "arm64"):
            // 没写架构的 macOS 原生库是 Intel 版
            return false
        case (nil, _):
            return true
        case ("arm64", "arm64"):
            return true
        case ("x86_64", "x86_64"), ("x86", "x86_64"):
            return true
        default:
            return false
        }
    }

    private var legacyArchToken: String {
        evaluator.osArch == "x86" ? "32" : "64"
    }

    private func relativePath(of library: Library) -> String? {
        if let path = library.downloads?.artifact?.path, !path.isEmpty {
            return path
        }
        return MavenCoordinate(library.name)?.relativePath
    }

    private func derivedPath(from coordinate: String, appendingClassifier classifier: String) -> String? {
        let parts = coordinate.split(separator: ":").map(String.init)
        guard parts.count >= 3 else { return nil }
        return MavenCoordinate("\(parts[0]):\(parts[1]):\(parts[2]):\(classifier)")?.relativePath
    }
}
