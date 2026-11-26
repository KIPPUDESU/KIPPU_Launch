import Foundation
import zlib

/// 只替换名称对应的字节 保留模组写入的其他 NBT 标签
struct WorldLevelName {
    private let bytes: [UInt8]
    private let nameRange: Range<Int>
    private let hasName: Bool
    let name: String

    init(file: URL) throws {
        guard let input = gzopen(file.path, "rb") else { throw CocoaError(.fileReadUnknown) }
        defer { gzclose(input) }
        var buffer = [UInt8](repeating: 0, count: 65536)
        var bytes: [UInt8] = []
        while true {
            let count = gzread(input, &buffer, UInt32(buffer.count))
            guard count >= 0, bytes.count + Int(count) <= 64 * 1024 * 1024 else { throw Self.invalid }
            if count == 0 {
                var status: Int32 = Z_OK
                _ = gzerror(input, &status)
                guard status == Z_OK || status == Z_STREAM_END else { throw Self.invalid }
                break
            }
            bytes.append(contentsOf: buffer.prefix(Int(count)))
        }
        var reader = Reader(bytes: bytes)
        guard try reader.number(1) == 10 else { throw Self.invalid }
        _ = try reader.stringRange()
        guard let data = try reader.field(named: "Data", type: 10) else { throw Self.invalid }
        reader.offset = data
        if let start = try reader.field(named: "LevelName", type: 8) {
            hasName = true
            let string = try reader.stringRange()
            self.name = Self.javaString(bytes[string])
            nameRange = start..<reader.offset
        } else {
            hasName = false
            name = ""
            nameRange = (reader.offset - 1)..<(reader.offset - 1)
        }
        self.bytes = bytes
    }

    private static var invalid: InstallError { .message("无法读取世界的 level.dat。") }

    // Java 的 writeUTF 把补充字符拆成两个代理码元分别编码
    private static func javaString(_ bytes: ArraySlice<UInt8>) -> String {
        if let plain = String(bytes: bytes, encoding: .utf8) { return plain }
        var codeUnits: [UInt16] = []
        var cursor = bytes.startIndex
        while cursor < bytes.endIndex {
            let first = UInt16(bytes[cursor])
            cursor += 1
            if first < 128 {
                codeUnits.append(first)
            } else if first >> 5 == 6, cursor < bytes.endIndex {
                codeUnits.append((first & 31) << 6 | UInt16(bytes[cursor] & 63))
                cursor += 1
            } else if first >> 4 == 14, cursor + 1 < bytes.endIndex {
                codeUnits.append((first & 15) << 12 | UInt16(bytes[cursor] & 63) << 6 | UInt16(bytes[cursor + 1] & 63))
                cursor += 2
            } else {
                codeUnits.append(0xfffd)
            }
        }
        return String(decoding: codeUnits, as: UTF16.self)
    }

    func write(name: String, to file: URL) throws {
        var text: [UInt8] = []
        for unit in name.utf16 {
            switch unit {
            case 1...0x7f: text.append(UInt8(unit))
            case 0...0x7ff: text += [UInt8(0xc0 | unit >> 6), UInt8(0x80 | unit & 63)]
            default: text += [UInt8(0xe0 | unit >> 12), UInt8(0x80 | (unit >> 6) & 63), UInt8(0x80 | unit & 63)]
            }
        }
        guard text.count <= Int(UInt16.max) else { throw InstallError.message("世界名称太长。") }
        var replacement: [UInt8] = hasName ? [] : [8, 0, 9] + Array("LevelName".utf8)
        replacement += [UInt8(text.count >> 8), UInt8(truncatingIfNeeded: text.count)]
        replacement += text
        var result = bytes
        result.replaceSubrange(nameRange, with: replacement)
        // 这里直接覆写文件 调用方传入的是还原目录里的副本
        guard let output = gzopen(file.path, "wb") else { throw CocoaError(.fileWriteUnknown) }
        let written = result.withUnsafeBytes { gzwrite(output, $0.baseAddress, UInt32($0.count)) }
        let status = gzclose(output)
        guard written == result.count, status == Z_OK else { throw CocoaError(.fileWriteUnknown) }
    }

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0

        mutating func take(_ count: Int) throws -> Range<Int> {
            guard count >= 0, count <= bytes.count - offset else { throw WorldLevelName.invalid }
            let start = offset
            offset += count
            return start..<offset
        }

        mutating func number(_ size: Int) throws -> Int {
            let range = try take(size)
            return bytes[range].reduce(0) { $0 << 8 | Int($1) }
        }

        mutating func stringRange() throws -> Range<Int> {
            let size = try number(2)
            return try take(size)
        }

        mutating func field(named name: String, type: Int) throws -> Int? {
            while true {
                let kind = try number(1)
                if kind == 0 { return nil }
                let key = try stringRange()
                if kind == type, bytes[key].elementsEqual(name.utf8) { return offset }
                try skip(kind, depth: 0)
            }
        }

        mutating func skip(_ kind: Int, depth: Int) throws {
            guard depth < 512 else { throw WorldLevelName.invalid }
            switch kind {
            case 1: _ = try take(1)
            case 2: _ = try take(2)
            case 3, 5: _ = try take(4)
            case 4, 6: _ = try take(8)
            case 7, 11, 12:
                let count = try number(4)
                _ = try take(count * (kind == 7 ? 1 : kind == 11 ? 4 : 8))
            case 8: _ = try stringRange()
            case 9:
                let element = try number(1)
                let count = try number(4)
                guard count <= bytes.count - offset else { throw WorldLevelName.invalid }
                for _ in 0..<count { try skip(element, depth: depth + 1) }
            case 10:
                while true {
                    let child = try number(1)
                    if child == 0 { break }
                    _ = try stringRange()
                    try skip(child, depth: depth + 1)
                }
            default: throw WorldLevelName.invalid
            }
        }
    }
}
