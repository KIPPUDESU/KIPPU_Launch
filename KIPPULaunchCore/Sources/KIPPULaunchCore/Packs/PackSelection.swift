import Foundation

struct PackSelection {
    let file: URL
    private let kind: PackKind
    private let optifine: Bool
    private let newline: String
    private var lines: [String]
    private var resources: [String] = []
    private var shader = ""
    private var shadersEnabled = true
    private let legacyResourceIDs: Bool

    init(game: URL, kind: PackKind, version: String?) throws {
        self.kind = kind
        let parts = (version ?? "").split(separator: ".")
        legacyResourceIDs = parts.count > 1 && parts[0] == "1" && (Int(parts[1]) ?? 99) < 13
        let fileManager = FileManager.default
        if kind == .resources {
            file = game.appending(path: "options.txt")
        } else {
            let paths = ["config/iris.properties", "config/oculus.properties", "optionsshaders.txt"]
            let files = paths.map { game.appending(path: $0) }.filter { fileManager.fileExists(atPath: $0.path) }
            guard files.count == 1, let selected = files.first else {
                throw InstallError.message(files.isEmpty
                    ? "使用 Iris、Oculus 或 OptiFine 启动一次游戏后，即可在这里切换光影。"
                    : "检测到多份光影配置，请在游戏内选择光影包。")
            }
            file = selected
        }
        optifine = file.lastPathComponent == "optionsshaders.txt"
        let linkedFile = (try? fileManager.destinationOfSymbolicLink(atPath: file.path)) != nil
        let parent = file.deletingLastPathComponent()
        let linkedConfig = parent.lastPathComponent == "config" && (try? fileManager.destinationOfSymbolicLink(atPath: parent.path)) != nil
        guard !linkedFile, !linkedConfig else {
            throw InstallError.message("配置文件指向其他位置，请在游戏内切换。")
        }
        let source: String
        if fileManager.fileExists(atPath: file.path) {
            let attributes = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard attributes.isRegularFile == true, (attributes.fileSize ?? 0) <= 4_194_304 else {
                throw InstallError.message("游戏配置无法读取。")
            }
            source = try String(contentsOf: file, encoding: .utf8)
        } else {
            source = ""
        }
        newline = source.contains("\r\n") ? "\r\n" : "\n"
        lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if kind == .resources {
            guard let raw = value("resourcePacks") else { return }
            guard let values = try? JSONDecoder().decode([String].self, from: Data(raw.utf8)) else {
                throw InstallError.message("options.txt 中的材质包列表无法读取，请在游戏内重新保存设置。")
            }
            resources = values
        } else {
            shader = Self.decodedProperty(value("shaderPack") ?? "")
            shadersEnabled = optifine || value("enableShaders")?.lowercased() != "false"
        }
    }

    private func field(_ key: String, in line: String) -> Substring? {
        if kind == .resources {
            return line.hasPrefix(key + ":") ? line.dropFirst(key.count + 1) : nil
        }
        let text = line[...].trimmingPrefix(while: \.isWhitespace)
        guard text.hasPrefix(key) else { return nil }
        var rest = text.dropFirst(key.count)
        guard let first = rest.first, first == "=" || first == ":" || first.isWhitespace else { return nil }
        rest = rest.trimmingPrefix(while: \.isWhitespace)
        if rest.first == "=" || rest.first == ":" { rest = rest.dropFirst() }
        return rest.trimmingPrefix(while: \.isWhitespace)
    }

    private func value(_ key: String) -> String? {
        for line in lines.reversed() {
            if let value = field(key, in: line) { return String(value) }
        }
        return nil
    }

    func resourceIndex(_ name: String) -> Int? {
        resources.lastIndex { resourceID($0, matches: name) }
    }

    private func resourceID(_ id: String, matches name: String) -> Bool {
        id == "file/" + name || (id == name && (legacyResourceIDs || name.lowercased().hasSuffix(".zip")))
    }

    mutating func swapPriority(_ first: String, _ second: String) throws {
        guard let firstIndex = resourceIndex(first), let secondIndex = resourceIndex(second) else {
            throw InstallError.message("材质包的启用状态已改变，请刷新。")
        }
        resources.swapAt(firstIndex, secondIndex)
        try saveResources()
    }

    private mutating func saveResources() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        replace("resourcePacks", with: String(decoding: try encoder.encode(resources), as: UTF8.self))
        try save()
    }

    private func save() throws {
        try lines.joined(separator: newline).write(to: file, atomically: true, encoding: .utf8)
    }

    func enabled(_ name: String) -> Bool {
        kind == .resources ? resourceIndex(name) != nil
                           : shadersEnabled && shader == name
    }

    mutating func set(_ name: String, enabled: Bool) throws {
        guard self.enabled(name) != enabled else { return }
        if kind == .resources {
            resources = resources.filter { !resourceID($0, matches: name) }
            if enabled { resources.append(legacyResourceIDs ? name : "file/" + name) }
            try saveResources()
            return
        }

        if optifine {
            replace("shaderPack", with: enabled ? Self.encodedProperty(name) : "OFF")
        } else {
            if enabled { replace("shaderPack", with: Self.encodedProperty(name)) }
            replace("enableShaders", with: enabled ? "true" : "false")
        }
        try save()
    }

    private mutating func replace(_ key: String, with value: String) {
        let entry = key + (kind == .resources ? ":" : "=") + value
        if let index = lines.lastIndex(where: { field(key, in: $0) != nil }) {
            lines[index] = entry
        } else {
            lines.insert(entry, at: lines.last == "" ? lines.count - 1 : lines.count)
        }
    }

    private static func encodedProperty(_ name: String) -> String {
        name.utf16.map { unit in
            if unit < 33 || unit > 126 { return String(format: "\\u%04X", unit) }
            return unit == 92 ? "\\\\" : String(UnicodeScalar(unit)!)
        }.joined()
    }

    private static func decodedProperty(_ value: String) -> String {
        let units = Array(value.utf16)
        var decoded: [UInt16] = []
        var cursor = 0
        while cursor < units.count {
            let unit = units[cursor]
            cursor += 1
            guard unit == 92, cursor < units.count else {
                decoded.append(unit)
                continue
            }
            let escaped = units[cursor]
            cursor += 1
            if escaped == 117, cursor + 4 <= units.count,
               let scalar = UInt16(String(decoding: units[cursor..<cursor + 4], as: UTF16.self), radix: 16) {
                decoded.append(scalar)
                cursor += 4
            } else { decoded.append(escaped) }
        }
        return String(decoding: decoded, as: UTF16.self)
    }
}
