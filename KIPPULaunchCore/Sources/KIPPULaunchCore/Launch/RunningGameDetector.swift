import Darwin
import Foundation

public struct RunningGameDetector: Sendable {
    public init() {}

    /// 匹配范围包括其他启动器启动的游戏
    public func processIdentifiers(usingGameDirectory gameDirectory: String, fileManager: FileManager = .default) -> [Int32] {
        let target = PathNormalization.normalized(path: gameDirectory)
        guard !target.isEmpty else { return [] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,args="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        // fclose 会关闭描述符 原描述符仍归 FileHandle 所有
        let readDescriptor = dup(pipe.fileHandleForReading.fileDescriptor)
        guard readDescriptor >= 0 else { return [] }
        guard let input = fdopen(readDescriptor, "r") else {
            close(readDescriptor)
            return []
        }
        defer { fclose(input) }
        do {
            try process.run()
        } catch {
            return []
        }

        var bytes: UnsafeMutablePointer<CChar>?
        var capacity = 0
        defer { free(bytes) }
        var identifiers: [Int32] = []
        while true {
            if getline(&bytes, &capacity, input) < 0 {
                if ferror(input) != 0 && errno == EINTR {
                    clearerr(input)
                    continue
                }
                if ferror(input) != 0 && process.isRunning { process.terminate() }
                break
            }
            guard let bytes, strstr(bytes, "--gameDir") != nil else { continue }
            let text = String(cString: bytes).trimmingCharacters(in: .newlines)
            if Self.mentionsGameDirectory(target, in: text), let pid = Self.leadingProcessIdentifier(of: text) {
                identifiers.append(pid)
            }
        }
        process.waitUntilExit()
        return identifiers
    }

    static func mentionsGameDirectory(_ directory: String, in commandLine: String) -> Bool {
        let target = PathNormalization.normalized(path: directory)
        guard !target.isEmpty else { return false }

        var searchStart = commandLine.startIndex
        while let found = commandLine.range(of: "--gameDir", range: searchStart..<commandLine.endIndex) {
            var cursor = found.upperBound
            while cursor < commandLine.endIndex, commandLine[cursor] == " " {
                cursor = commandLine.index(after: cursor)
            }
            let rest = commandLine[cursor...]

            let token = rest.firstIndex(of: " ").map { String(rest[rest.startIndex..<$0]) } ?? String(rest)
            if PathNormalization.normalized(path: token) == target { return true }

            // 路径里可能有空格 只有参数边界才算匹配结束
            if rest.hasPrefix(target) {
                let after = rest.index(rest.startIndex, offsetBy: target.count)
                if after == rest.endIndex || rest[after] == " " { return true }
            }

            searchStart = found.upperBound
        }
        return false
    }

    private static func leadingProcessIdentifier(of line: String) -> Int32? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.prefix { $0.isNumber }
        return Int32(digits)
    }
}
