import Foundation

public struct RuleEvaluator: Sendable {
    public var osName: String
    public var osVersion: String
    public var osArch: String
    public var features: [String: Bool]

    public init(
        osName: String,
        osVersion: String,
        osArch: String,
        features: [String: Bool] = [:]
    ) {
        self.osName = osName
        self.osVersion = osVersion
        self.osArch = osArch
        self.features = features
    }

    public static func current(
        features: [String: Bool] = [:],
        operatingSystemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> RuleEvaluator {
        RuleEvaluator(
            osName: "osx",
            osVersion: "\(operatingSystemVersion.majorVersion).\(operatingSystemVersion.minorVersion).\(operatingSystemVersion.patchVersion)",
            osArch: HostArchitecture.current,
            features: features
        )
    }

    /// 空规则默认放行 有规则时由最后一个匹配项决定 全部失配则拒绝
    public func isAllowed(rules: [Rule]?) -> Bool {
        guard let rules, !rules.isEmpty else { return true }

        return rules.last(where: matches)?.action == .allow
    }

    public func matches(_ rule: Rule) -> Bool {
        if let os = rule.os, !matchesOperatingSystem(os) { return false }
        guard let required = rule.features else { return true }
        return required.allSatisfy { name, expected in
            (features[name] ?? false) == expected
        }
    }

    private func matchesOperatingSystem(_ os: Rule.OperatingSystem) -> Bool {
        if let name = os.name, !name.isEmpty, name != osName { return false }

        if let pattern = os.version, !pattern.isEmpty {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
            let range = NSRange(osVersion.startIndex..<osVersion.endIndex, in: osVersion)
            guard regex.firstMatch(in: osVersion, range: range) != nil else { return false }
        }

        if let arch = os.arch, !arch.isEmpty, arch != osArch { return false }

        if let range = os.versionRange, !matchesVersionRange(range) { return false }

        return true
    }

    private func matchesVersionRange(_ range: Rule.VersionRange) -> Bool {
        if let min = range.min, compareVersions(osVersion, min) < 0 { return false }
        if let max = range.max, compareVersions(osVersion, max) > 0 { return false }
        return true
    }

    private func compareVersions(_ lhs: String, _ rhs: String) -> Int {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let leftPart = index < left.count ? left[index] : 0
            let rightPart = index < right.count ? right[index] : 0
            if leftPart != rightPart { return leftPart < rightPart ? -1 : 1 }
        }
        return 0
    }
}

public enum HostArchitecture {
    public static var current: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }
}
