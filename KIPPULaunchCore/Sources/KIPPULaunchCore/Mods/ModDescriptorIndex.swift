import Foundation

enum ModDescriptorIndex {
    static let names = ["fabric.mod.json", "quilt.mod.json", "META-INF/neoforge.mods.toml", "META-INF/mods.toml", "mcmod.info"]
    private static let namesByLength = Dictionary(grouping: names, by: { $0.utf8.count })

    static func present(in url: URL) -> Set<String>? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        // 带注释的 ZIP 末尾不止 22 字节 交给通用读取器
        guard let length = try? file.seekToEnd(), length >= 22,
              (try? file.seek(toOffset: length - 22)) != nil,
              let end = try? file.read(upToCount: 22), end.count == 22 else { return nil }
        return end.withUnsafeBytes { end in
            guard end.u32(0) == 0x06054b50, end.u32(4) == 0, end.u16(20) == 0 else { return nil }
            let count = end.u16(10), size = end.u32(12), offset = end.u32(16)
            guard count == end.u16(8), count < UInt16.max, size <= 2 * 1024 * 1024,
                  UInt64(offset) + UInt64(size) == length - 22,
                  (try? file.seek(toOffset: UInt64(offset))) != nil,
                  let directory = try? file.read(upToCount: Int(size)), directory.count == size else { return nil }
            return directory.withUnsafeBytes { bytes in
                var found = Set<String>()
                var cursor = 0
                for _ in 0..<count {
                    guard cursor + 46 <= bytes.count, bytes.u32(cursor) == 0x02014b50 else { return nil }
                    let nameLength = Int(bytes.u16(cursor + 28))
                    let nameStart = cursor + 46
                    cursor = nameStart + nameLength + Int(bytes.u16(cursor + 30)) + Int(bytes.u16(cursor + 32))
                    guard cursor <= bytes.count else { return nil }
                    guard let candidates = namesByLength[nameLength] else { continue }
                    let name = bytes[nameStart..<nameStart + nameLength]
                    for candidate in candidates where name.elementsEqual(candidate.utf8) {
                        found.insert(candidate)
                    }
                }
                return cursor == bytes.count ? found : nil
            }
        }
    }
}

private extension UnsafeRawBufferPointer {
    func u16(_ offset: Int) -> UInt16 { UInt16(littleEndian: loadUnaligned(fromByteOffset: offset, as: UInt16.self)) }
    func u32(_ offset: Int) -> UInt32 { UInt32(littleEndian: loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
}
