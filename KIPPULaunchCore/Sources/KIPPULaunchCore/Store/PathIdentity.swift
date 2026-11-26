import Foundation

#if canImport(Darwin)
import Darwin
#endif

public struct PathIdentity: Hashable, Sendable, CustomStringConvertible {
    /// 路径可访问时用设备号和 inode 否则用忽略大小写的路径
    public let canonical: String

    public let url: URL

    public let isInodeBacked: Bool

    public var description: String { canonical }

    /// 通过符号链接打开同一个目录也应得到相同的身份
    public init(of target: URL) {
        let standardized = target.standardizedFileURL
        var info = stat()

        if stat(standardized.path(percentEncoded: false), &info) == 0 {
            self.canonical = "d\(info.st_dev):i\(info.st_ino)"
            self.isInodeBacked = true
        } else {
            self.canonical = "p:" + TextNormalization.caseFold(PathNormalization.normalized(standardized))
            self.isInodeBacked = false
        }
        self.url = standardized
    }

    public static func == (lhs: PathIdentity, rhs: PathIdentity) -> Bool {
        lhs.canonical == rhs.canonical
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(canonical)
    }
}

public enum PathNormalization {
    /// 保留用户选中的符号链接路径
    public static func normalized(_ url: URL) -> String {
        normalized(path: url.standardizedFileURL.path(percentEncoded: false))
    }

    public static func normalized(path: String) -> String {
        var result = path
        while result.count > 1 && result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }
}

public enum TextNormalization {
    public static func caseFold(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.lowercased()
    }

    public static func namesMatch(_ lhs: String, _ rhs: String) -> Bool {
        caseFold(lhs) == caseFold(rhs)
    }
}
