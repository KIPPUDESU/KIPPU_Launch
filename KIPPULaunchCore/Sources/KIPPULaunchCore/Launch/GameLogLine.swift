import Foundation

public struct GameLogLine: Equatable, Sendable {
    public enum Level: String, Sendable {
        case info = "INFO", debug = "DEBUG", trace = "TRACE", warning = "WARN"
        case error = "ERROR", fatal = "FATAL", success, plain
    }

    public let text: String
    public private(set) var level: Level = .plain
    public private(set) var levelLabel: Range<String.Index>?
    private var continuesXML = false

    public init(_ text: String, following previous: Self? = nil) {
        self.text = text
        let line = text[...].trimmingPrefix(while: { $0 == " " || $0 == "\t" })

        if text.hasPrefix("— ") {
            if let exit = GameExit(marker: text) {
                level = exit.interruption != nil ? .warning : (exit.code == 0 ? .success : .error)
                return
            }
            if text.hasPrefix("— 已启动，进程 ") {
                level = .success
                return
            }
        }

        // 原版 Log4j 可将一个事件拆成多行 XML
        if line.hasPrefix("<log4j:Event "), let end = line.firstIndex(of: ">"),
           let match = line[..<end].firstMatch(of: /\slevel="(INFO|WARN|ERROR|FATAL|DEBUG|TRACE)"/) {
            setLevel(match.1)
            continuesXML = !line.contains("</log4j:Event>") && !line[..<end].hasSuffix("/")
            return
        }
        if let previous, previous.continuesXML {
            level = previous.level
            continuesXML = !line.contains("</log4j:Event>")
            return
        }

        if line.hasPrefix("[") {
            if let token = Self.bracketedLevel(in: line) { setLevel(token) }
        } else if line.first?.isNumber == true,
                  let match = line.prefixMatch(of: /\d{4}-\d\d-\d\d[ T]\d\d:\d\d:\d\d[\d.,:+Z-]*\s+(?:[\w.-]+\s+)?(INFO|WARN|ERROR|FATAL|DEBUG|TRACE)\b/) {
            setLevel(match.1)
        } else if let match = line.prefixMatch(of: /(INFO|WARN|WARNING|ERROR|Error|FATAL|DEBUG|TRACE)(?=[:\s]|$)/) {
            setLevel(match.1)
        } else if line.hasPrefix("at ") {
            level = previous?.level ?? .plain
        } else if line.hasPrefix("Caused by:") || line.hasPrefix("Suppressed:") || line.hasPrefix("Exception in thread ")
                    || ((line.contains("Exception") || line.contains("Error")) &&
                        line.prefixMatch(of: /(?:[\w$]+\.)+[\w$]*(?:Exception|Error)(?=[:\s]|$)/) != nil) {
            level = previous?.level == .warning ? .warning : .error
        } else if line.hasPrefix("... "), line.prefixMatch(of: /\.\.\. \d+ (?:more|common frames omitted)/) != nil {
            level = previous?.level ?? .plain
        }
    }

    private static func bracketedLevel(in line: Substring) -> Substring? {
        let field = line.dropFirst()
        guard let end = field.firstIndex(of: "]") else { return nil }
        var header = field[..<end]
        if header.first?.isNumber == true, !header.contains("/") {
            let remainder = field.suffix(from: field.index(after: end)).trimmingPrefix(while: { $0.isWhitespace })
            guard remainder.first == "[", let levelEnd = remainder.firstIndex(of: "]") else { return nil }
            header = remainder[remainder.index(after: remainder.startIndex)..<levelEnd]
        }
        guard let slash = header.lastIndex(of: "/") else { return header }
        return header.suffix(from: header.index(after: slash))
    }

    private mutating func setLevel(_ token: Substring) {
        switch token {
        case "WARNING": level = .warning
        case "Error": level = .error
        default:
            guard let parsed = Level(rawValue: String(token)), parsed != .plain, parsed != .success else { return }
            level = parsed
        }
        levelLabel = token.startIndex..<token.endIndex
    }

    public static func exitCode(in text: String) -> Int32? {
        GameExit(marker: text)?.code
    }
}
