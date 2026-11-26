import Foundation

public struct VersionCandidate: Sendable, Hashable {
    public let directory: URL
    public let jsonFile: URL
    public let identifier: String
    public let inheritsFrom: String?
    public let mainClass: String?
    public let libraryCount: Int
    public let javaMajorVersion: Int?
    public let javaComponent: String?
    public let jarName: String
    /// 继承父版本的实例目录可以没有客户端 JAR
    public let hasClientJar: Bool
    public let releaseType: String?
    public let identity: PathIdentity
    public let score: Int

    public var name: String { directory.lastPathComponent }
}

public struct VersionScanDiagnostic: Sendable, Hashable {
    public let file: String
    public let reason: String
}

public struct VersionScanOutcome: Sendable {
    public let directory: URL
    public let version: VersionCandidate?
    public let diagnostics: [VersionScanDiagnostic]

    public var isVersion: Bool { version != nil }
}

public struct RootScanOutcome: Sendable {
    public let root: URL
    public let versions: [VersionCandidate]
    public let rejected: [VersionScanOutcome]
}

public struct VersionLocator: Sendable {
    public struct Limits: Sendable {
        public var maxJSONBytes: Int

        public init(maxJSONBytes: Int = 8 << 20) {
            self.maxJSONBytes = maxJSONBytes
        }
    }

    public let limits: Limits

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    public func locate(in directory: URL, fileManager: FileManager = .default) -> VersionScanOutcome {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path(percentEncoded: false), isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return VersionScanOutcome(
                directory: directory,
                version: nil,
                diagnostics: [VersionScanDiagnostic(file: directory.lastPathComponent, reason: "不是目录")]
            )
        }

        let names: [String]
        do {
            names = try entryNames(of: directory, fileManager: fileManager)
        } catch {
            return VersionScanOutcome(
                directory: directory,
                version: nil,
                diagnostics: [VersionScanDiagnostic(file: directory.lastPathComponent, reason: "无法读取目录：\(error.localizedDescription)")]
            )
        }

        let folderName = directory.lastPathComponent
        var diagnostics: [VersionScanDiagnostic] = []
        var candidates: [VersionCandidate] = []

        for name in names.sorted() {
            guard (name as NSString).pathExtension.lowercased() == "json" else { continue }
            let result = autoreleasepool {
                evaluate(jsonFile: directory.appending(path: name), folder: directory,
                         folderName: folderName, fileManager: fileManager)
            }
            switch result {
            case .accepted(let candidate):
                candidates.append(candidate)
            case .rejected(let reason):
                diagnostics.append(VersionScanDiagnostic(file: name, reason: reason))
            }
        }

        let winner = candidates.max { lhs, rhs in
            lhs.score != rhs.score ? lhs.score < rhs.score : lhs.jsonFile.lastPathComponent > rhs.jsonFile.lastPathComponent
        }

        return VersionScanOutcome(directory: directory, version: winner, diagnostics: diagnostics)
    }

    private enum Evaluation {
        case accepted(VersionCandidate)
        case rejected(reason: String)
    }

    private func evaluate(
        jsonFile: URL,
        folder: URL,
        folderName: String,
        fileManager: FileManager
    ) -> Evaluation {
        // 符号链接自身的长度不能用来限制目标 JSON 的大小
        let resolved = jsonFile.resolvingSymlinksInPath()
        let attributes = try? fileManager.attributesOfItem(atPath: resolved.path(percentEncoded: false))
        if let size = attributes?[.size] as? Int {
            guard size <= limits.maxJSONBytes else {
                return .rejected(reason: "文件过大（\(size) 字节，上限 \(limits.maxJSONBytes)）")
            }
        }

        guard let data = try? Data(contentsOf: jsonFile, options: .mappedIfSafe) else {
            return .rejected(reason: "无法读取内容")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            return .rejected(reason: "JSON 语法错误")
        }
        guard let object = root as? [String: Any] else {
            return .rejected(reason: "顶层不是 JSON 对象")
        }

        guard let identifier = object["id"] as? String, !identifier.isEmpty else {
            return .rejected(reason: "没有 id 字段")
        }
        guard TextNormalization.namesMatch(identifier, folderName) else {
            return .rejected(reason: "id「\(identifier)」与文件夹名「\(folderName)」不一致")
        }

        let hasModernArguments = object["arguments"] != nil
        let hasLegacyArguments = (object["minecraftArguments"] as? String)?.isEmpty == false
        guard hasModernArguments || hasLegacyArguments || nonEmptyString(object["inheritsFrom"]) != nil else {
            return .rejected(reason: "既没有 arguments 也没有 minecraftArguments")
        }

        let inheritsFrom = nonEmptyString(object["inheritsFrom"])
        let mainClass = nonEmptyString(object["mainClass"])

        // 继承型版本允许由父版本提供主类
        guard mainClass != nil || inheritsFrom != nil else {
            return .rejected(reason: "没有 mainClass，也没有 inheritsFrom 可继承")
        }

        let libraryCount = (object["libraries"] as? [Any])?.count ?? 0
        guard libraryCount > 0 || inheritsFrom != nil else {
            return .rejected(reason: "libraries 为空，也没有 inheritsFrom 可继承")
        }

        let stem = jsonFile.deletingPathExtension().lastPathComponent
        var score = 0
        if TextNormalization.namesMatch(stem, folderName) { score += 4 }
        if mainClass != nil { score += 2 }
        if libraryCount > 0 { score += 1 }

        let javaVersion = object["javaVersion"] as? [String: Any]
        let jarName = nonEmptyString(object["jar"]) ?? identifier
        let jarExists = FileManager.default.fileExists(
            atPath: folder.appending(path: "\(jarName).jar").path(percentEncoded: false)
        )

        return .accepted(
            VersionCandidate(
                directory: folder,
                jsonFile: jsonFile,
                identifier: identifier,
                inheritsFrom: inheritsFrom,
                mainClass: mainClass,
                libraryCount: libraryCount,
                javaMajorVersion: javaVersion?["majorVersion"] as? Int,
                javaComponent: nonEmptyString(javaVersion?["component"]),
                jarName: jarName,
                hasClientJar: jarExists,
                releaseType: nonEmptyString(object["type"]),
                identity: PathIdentity(of: folder),
                score: score
            )
        )
    }

    public func scan(root: URL, fileManager: FileManager = .default) -> RootScanOutcome {
        guard let names = try? entryNames(of: root, fileManager: fileManager) else {
            return RootScanOutcome(root: root, versions: [], rejected: [])
        }

        var versions: [VersionCandidate] = []
        var rejected: [VersionScanOutcome] = []

        for name in names.sorted() {
            let child = root.appending(path: name, directoryHint: .isDirectory)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: child.path(percentEncoded: false), isDirectory: &isDirectory),
                  isDirectory.boolValue
            else { continue }

            let outcome = locate(in: child, fileManager: fileManager)
            if let version = outcome.version {
                versions.append(version)
            } else {
                rejected.append(outcome)
            }
        }

        return RootScanOutcome(root: root, versions: versions, rejected: rejected)
    }

    private func entryNames(of directory: URL, fileManager: FileManager) throws -> [String] {
        try fileManager
            .contentsOfDirectory(atPath: directory.path(percentEncoded: false))
            .filter { !$0.hasPrefix(".") }
    }

    public func scanForRegistration(at url: URL, fileManager: FileManager = .default) -> RootScanOutcome {
        var versions: [VersionCandidate] = []
        var rejected: [VersionScanOutcome] = []

        let selfOutcome = locate(in: url, fileManager: fileManager)
        if let version = selfOutcome.version {
            versions.append(version)
        }

        for directory in [url, url.appending(path: "versions"), url.appending(path: ".minecraft/versions")] {
            let children = scan(root: directory, fileManager: fileManager)
            versions.append(contentsOf: children.versions)
            rejected.append(contentsOf: children.rejected)
        }

        var seen = Set<PathIdentity>()
        let deduplicated = versions.filter { seen.insert($0.identity).inserted }

        return RootScanOutcome(
            root: url,
            versions: deduplicated.sorted { $0.name < $1.name },
            rejected: rejected
        )
    }
}

private func nonEmptyString(_ value: Any?) -> String? {
    guard let text = value as? String, !text.isEmpty else { return nil }
    return text
}
