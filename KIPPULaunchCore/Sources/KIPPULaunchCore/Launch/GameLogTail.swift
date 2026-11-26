import Foundation

/// 行号会随截断改变 字节偏移用作行标识
public actor GameLogTail {
    public struct Row: Identifiable, Equatable, Sendable {
        public let id: UInt64
        public let line: GameLogLine
    }

    private let file: URL
    private var handle: FileHandle?
    private var nextLine: UInt64 = 0
    private var lastSize: UInt64?
    private var rows: [Row] = []
    private let byteLimit: UInt64 = 512 * 1024
    private let rowLimit = 4000

    public init(file: URL) { self.file = file }

    public func follow(live: Bool, publish: @MainActor @Sendable ([Row]) -> Void) async throws {
        let fileHandle = try FileHandle(forReadingFrom: file)
        handle = fileHandle
        defer { if handle === fileHandle { handle = nil } }
        guard live else {
            defer { try? fileHandle.close() }
            let final = try read(finished: true) ?? rows
            if !Task.isCancelled { await publish(final) }
            return
        }
        let (changes, sink) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fileHandle.fileDescriptor,
            eventMask: [.write, .extend], queue: .global(qos: .utility))
        source.setEventHandler { sink.yield(()) }
        source.setCancelHandler { try? fileHandle.close() }
        source.activate()
        defer {
            source.cancel()
            sink.finish()
        }
        sink.yield(())
        var initial = true
        for await _ in changes {
            try Task.checkCancellation()
            if let snapshot = try read(finished: false) { await publish(snapshot) }
            else if initial { await publish(rows) }
            initial = false
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    /// 游戏运行时先留住末尾的半行 退出后再交给界面
    public func read(finished: Bool) throws -> [Row]? {
        if handle == nil { handle = try FileHandle(forReadingFrom: file) }
        guard let handle else { return nil }
        let size = try handle.seekToEnd()
        if size == lastSize && (!finished || nextLine == size) { return nil }
        if let lastSize, size < lastSize {
            rows.removeAll()
            nextLine = 0
        }
        let cutoff = size > byteLimit ? size - byteLimit : 0
        let start = max(nextLine, cutoff)
        var partialFirstLine = false
        if start > nextLine {
            try handle.seek(toOffset: start - 1)
            partialFirstLine = try handle.read(upToCount: 1)?.first != 10
        } else {
            try handle.seek(toOffset: start)
        }
        let data = try handle.read(upToCount: Int(size - start)) ?? Data()
        lastSize = start + UInt64(data.count)
        return data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> [Row]? in
            let end = finished ? bytes.count : bytes.lastIndex(of: 10).map { $0 + 1 } ?? 0
            guard end > 0 else { return size == 0 ? [] : nil }

            var lines: [Range<Int>] = []
            lines.reserveCapacity(min(rowLimit, bytes.count / 80))
            var cursor = end
            while cursor > 0 && lines.count < rowLimit {
                let lineEnd = cursor
                while cursor > 0 && bytes[cursor - 1] != 10 { cursor -= 1 }
                if cursor < lineEnd { lines.append(cursor..<lineEnd) }
                if cursor > 0 { cursor -= 1 }
            }
            let surviving = rows.firstIndex { $0.id >= cutoff } ?? rows.endIndex
            rows.removeFirst(max(surviving, rows.count + lines.count - rowLimit))
            for range in lines.reversed() {
                let lineEnd = bytes[range.upperBound - 1] == 13 ? range.upperBound - 1 : range.upperBound
                let first = max(range.lowerBound, lineEnd - 16_384)
                let clipped = first > range.lowerBound || (partialFirstLine && first == 0)
                var text = String(decoding: bytes[first..<lineEnd], as: UTF8.self)
                if clipped { text.insert("…", at: text.startIndex) }
                rows.append(Row(id: start + UInt64(range.lowerBound), line: GameLogLine(text, following: rows.last?.line)))
            }
            nextLine = start + UInt64(end)
            return rows
        }
    }
}
