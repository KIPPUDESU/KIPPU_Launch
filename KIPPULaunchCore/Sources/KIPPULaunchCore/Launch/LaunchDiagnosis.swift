import Foundation

public struct LaunchDiagnosis: Sendable {
    public enum Cause: Equatable, Sendable { case java, missingDependency, incompatibleMods, launchCheck, interrupted, unknown }

    public let cause: Cause
    public let explanation: String
    public let evidence: [String]
    public let source: String
    public let crashReport: URL?

    public var termination: GameExit?

    public var title: String {
        switch cause {
        case .java: "Java 运行环境不匹配"
        case .missingDependency: "缺少前置模组"
        case .incompatibleMods: "模组版本不兼容"
        case .launchCheck: "启动未完成"
        case .interrupted: termination?.interruption ?? "游戏已终止"
        case .unknown: "尚未定位退出原因"
        }
    }

    public static func preflight(_ error: any Error) -> Self {
        switch error as? InstancePlanningError {
        case .javaNotInstalled, .javaUnsuitable, .javaPathUnavailable:
            Self(cause: .java, explanation: "在实例启动设置中选择可用的 JDK，再重新启动。",
                 evidence: [error.localizedDescription], source: "启动前检查", crashReport: nil)
        default:
            Self(cause: .launchCheck, explanation: "请根据启动器的检查结果处理后重试。", evidence: [error.localizedDescription],
                 source: "启动前检查", crashReport: nil)
        }
    }

    public static func afterExit(code: Int32, gameDirectory: URL, started: Date, ended: Date = Date(), output: [String], launcherLog: URL? = nil) -> Self? {
        afterExit(.exited(code), gameDirectory: gameDirectory, started: started, ended: ended, output: output, launcherLog: launcherLog)
    }

    public static func afterExit(_ exit: GameExit, gameDirectory: URL, started: Date, ended: Date = Date(),
                                 output: [String], launcherLog: URL? = nil) -> Self? {
        let code = exit.code
        guard code != 0 else { return nil }
        let folder = gameDirectory.appending(path: "crash-reports", directoryHint: .isDirectory)
        let reports = (try? FileManager.default.contentsOfDirectory(at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey])) ?? []
        let report = reports.compactMap { url -> (URL, Date)? in
            guard url.lastPathComponent.hasPrefix("crash-"), url.pathExtension == "txt",
                  let date = modificationDate(of: url), date >= started, date <= ended else { return nil }
            return (url, date)
        }.max { $0.1 < $1.1 }?.0

        func interrupted() -> Self {
            Self(cause: .interrupted, explanation: exit.detail, evidence: [exit.marker],
                 source: "进程退出记录", crashReport: report, termination: exit)
        }
        if exit.interruption != nil {
            switch exit {
            case .stoppedByPlayer, .signalled: return interrupted()
            case .exited: break
            }
        }
        var sources: [(String, [String])] = []
        if let report { sources.append((report.lastPathComponent, readExcerpts(report))) }
        sources.append(("启动日志", output))
        if let launcherLog { sources.append(("启动日志", readExcerpts(launcherLog))) }
        let latest = gameDirectory.appending(path: "logs/latest.log")
        if let date = modificationDate(of: latest), date >= started, date <= ended {
            sources.append(("latest.log", readExcerpts(latest)))
        }

        for (source, lines) in sources {
            for (index, line) in lines.enumerated() where eligible(line) {
                let next = index + 1 < lines.count ? lines[index + 1] : ""
                if let finding = match(line, next: next) {
                    return Self(cause: finding.cause, explanation: finding.message, evidence: finding.lines,
                                source: source, crashReport: report)
                }
            }
        }
        if exit.interruption != nil && report == nil { return interrupted() }
        let explanation = "游戏以状态码 \(code) 退出。可查看完整日志，或复制摘要排查。"
        for (source, lines) in sources {
            let errors = lines.reversed().lazy.filter { line in
                eligible(line) && ["exception", "error", "fatal", "description:"].contains { line.localizedCaseInsensitiveContains($0) }
            }.prefix(4)
            if !errors.isEmpty {
                return Self(cause: .unknown, explanation: explanation, evidence: Array(errors.reversed()),
                            source: source, crashReport: report)
            }
        }
        return Self(cause: .unknown, explanation: explanation, evidence: [], source: "启动日志", crashReport: report)
    }

    private static func modificationDate(of url: URL) -> Date? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        return values.contentModificationDate
    }

    private static func readExcerpts(_ url: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let limit = 256 * 1024
        guard let size = try? handle.seekToEnd(), (try? handle.seek(toOffset: 0)) != nil,
              let first = try? handle.read(upToCount: limit) else { return [] }
        func lines(_ data: Data) -> [String] { String(decoding: data, as: UTF8.self).components(separatedBy: "\n") }
        guard size > limit else { return lines(first) }
        let offset = max(UInt64(limit), size - UInt64(limit))
        guard (try? handle.seek(toOffset: offset)) != nil, let last = try? handle.read(upToCount: limit) else { return lines(first) }
        if offset == limit { return lines(first + last) }
        return Array(lines(first).dropLast()) + [""] + lines(last).dropFirst()
    }

    private static func eligible(_ line: String) -> Bool {
        !line.isEmpty && line.utf8.count <= 2048 && !line.contains("[CHAT]") &&
            !["accesstoken", "access_token", "bearer ", "refreshtoken", "refresh_token"].contains { line.localizedCaseInsensitiveContains($0) }
    }

    private typealias Finding = (cause: Cause, message: String, lines: [String])

    private static func match(_ line: String, next: String) -> Finding? {
        if line.contains("UnsupportedClassVersionError"),
           let m = line.firstMatch(of: /class file version (\d+)\.\d+.*?class file versions up to (\d+)\.\d+/),
           let required = Int(m.1), let current = Int(m.2), required > current, current >= 45 {
            return (.java, "当前 Java \(current - 44) 无法加载这段代码，至少需要 Java \(required - 44)。", [line])
        }
        if line.contains("UnsupportedClassVersionError"),
           let m = line.firstMatch(of: /Unsupported major\.minor version (\d+)\.\d+/),
           let required = Int(m.1), required >= 45 {
            return (.java, "当前 Java 无法加载这段代码，至少需要 Java \(required - 44)。", [line])
        }
        guard line.contains("Mod ") else { return nil }
        if let m = line.firstMatch(of: /\bMod ('[^']+' \([\w.-]+\)) \S+ requires (.+?) of (.+?), (.+)/) {
            let mod = fabricName(m.1)
            let required = versionRequirement(m.2)
            let dependency = fabricName(m.3)
            let result = m.4
            if result.hasPrefix("which is missing") {
                return (.missingDependency, "「\(mod)」需要 \(dependency)（\(required)），当前未安装。", [line])
            }
            if let version = result.firstMatch(of: /(?:wrong|different) versions? (?:is|are) present: (.+?)[!.]?$/) {
                let cause: Cause = dependency.contains("(java)") || dependency == "java" ? .java : .incompatibleMods
                return (cause, "「\(mod)」需要 \(dependency)（\(required)），当前版本为 \(version.1)。", [line])
            }
        }
        if let m = line.firstMatch(of: /\bMod ('[^']+' \([\w.-]+\)) \S+ is incompatible with (.+?), but (?:a )?matching versions? (?:is|are) present: (.+?)[!.]?$/) {
            return (.incompatibleMods, "「\(m.1)」与 \(m.2) 冲突，当前版本为 \(m.3)。", [line])
        }
        if let m = line.firstMatch(of: /Mod ID: '([^']+)', Requested by: '([^']+)', Expected range: '([^']+)', Actual version: '([^']+)'/) {
            return dependencyFinding(mod: String(m.2), dependency: String(m.1), required: String(m.3),
                                     actual: String(m.4), lines: [line])
        }
        if eligible(next), let m = line.firstMatch(of: /\bMod ([\w.-]+) requires ([\w.-]+) (.+)/),
           let installed = next.firstMatch(of: /^\s*Currently, ([\w.-]+) is (.+?)\s*$/), installed.1 == m.2 {
            return dependencyFinding(mod: String(m.1), dependency: String(m.2), required: String(m.3),
                                     actual: String(installed.2), lines: [line, next])
        }
        return nil
    }

    private static func fabricName(_ raw: Substring) -> String {
        if let m = raw.wholeMatch(of: /(?:mod )?'([^']+)' \(([\w.-]+)\)/) {
            return m.1 == m.2 ? String(m.1) : "\(m.1) (\(m.2))"
        }
        return String(raw)
    }

    private static func versionRequirement(_ raw: Substring) -> String {
        if raw == "any version" { return "任意版本" }
        if let m = raw.wholeMatch(of: /version (\S+) or later/) { return "\(m.1) 或更高版本" }
        if let m = raw.wholeMatch(of: /version (\S+) or earlier/) { return "\(m.1) 或更早版本" }
        return String(raw)
    }

    private static func dependencyFinding(mod: String, dependency: String, required: String,
                                          actual: String, lines: [String]) -> Finding {
        let missing = ["[missing]", "[none]", "not installed"].contains(actual.lowercased())
        let status = missing ? "当前未安装" : "当前版本为 \(actual)"
        return (missing ? .missingDependency : .incompatibleMods, "「\(mod)」需要 \(dependency)（\(required)），\(status)。", lines)
    }
}
