import AppKit
import KIPPULaunchCore
import SwiftUI

struct GameLogOutput: View {
    let source: GameLogSource
    let transcript: GameLogTable.Transcript
    @State private var readError: String?
    @State private var windowVisible = false

    var body: some View {
        GameLogTable(transcript: transcript)
            .overlay {
                if let readError {
                    ContentUnavailableView("无法读取游戏日志", systemImage: "doc.text", description: Text(readError))
                }
            }
            .background(WindowVisibilityObserver(isVisible: $windowVisible))
            .onDisappear { transcript.clear() }
            .task(id: windowVisible ? source : nil) {
                guard windowVisible else { return }
                readError = nil
                guard let file = source.file else {
                    transcript.clear()
                    return
                }
                do {
                    try await transcript.follow(file: file, attempt: source.attempt, live: source.live)
                } catch {
                    if !Task.isCancelled {
                        readError = error.localizedDescription
                    }
                }
            }
    }
}

struct GameLogTable: NSViewRepresentable {
    let transcript: Transcript

    func makeCoordinator() -> Transcript { transcript }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 14, left: 0, bottom: 14, right: 0)
        context.coordinator.attach(to: scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {}

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Transcript) {
        coordinator.detach(from: scroll)
    }

    @MainActor final class Transcript: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private(set) var rows: [GameLogTail.Row] = []
        private weak var scroll: NSScrollView?
        private var reader: GameLogTail?
        private var file: URL?
        private var attempt: UUID?

        func follow(file: URL, attempt: UUID?, live: Bool) async throws {
            if reader == nil || self.file != file || self.attempt != attempt {
                clear()
                reader = GameLogTail(file: file)
                self.file = file
                self.attempt = attempt
            }
            guard let reader else { return }
            try await reader.follow(live: live) { snapshot in
                if !Task.isCancelled, self.reader === reader { self.display(snapshot) }
            }
        }

        // SwiftUI 可能在日志面板关闭后继续持有数据源
        func clear() {
            reader = nil
            if let table = scroll?.documentView as? NSTableView {
                table.delegate = nil
                table.dataSource = nil
                scroll?.documentView = nil
            }
            rows = []
        }

        func attach(to scroll: NSScrollView) {
            self.scroll = scroll
            if !rows.isEmpty { display(rows) }
        }

        func detach(from view: NSScrollView) {
            guard scroll === view else { return }
            view.documentView = nil
            scroll = nil
        }

        private func makeTable(in scroll: NSScrollView) -> NSTableView {
            let table = NSTableView(frame: NSRect(origin: .zero, size: scroll.contentSize))
            table.autoresizingMask = [.width]
            table.style = .plain
            table.headerView = nil
            table.backgroundColor = .clear
            table.selectionHighlightStyle = .none
            table.intercellSpacing = NSSize(width: 0, height: 1)
            table.usesAutomaticRowHeights = true
            table.rowHeight = ceil(LogCell.font.ascender - LogCell.font.descender)
            table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
            let column = NSTableColumn(identifier: .init("log"))
            column.width = max(column.minWidth, scroll.contentSize.width)
            column.resizingMask = .autoresizingMask
            table.addTableColumn(column)
            table.delegate = self
            table.dataSource = self
            table.setAccessibilityLabel("游戏日志")
            scroll.documentView = table
            return table
        }

        private func display(_ next: [GameLogTail.Row]) {
            let old = rows
            rows = next
            guard let scroll else { return }
            let existing = scroll.documentView as? NSTableView
            let table = existing ?? makeTable(in: scroll)
            if existing != nil, !old.isEmpty, next.starts(with: old) {
                guard next.count != old.count else { return }
                table.noteNumberOfRowsChanged()
            } else {
                // 第一行被移除后所有可见行号都变了
                table.reloadData()
            }
            if !next.isEmpty { table.scrollRowToVisible(next.count - 1) }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let cell = tableView.makeView(withIdentifier: LogCell.reuseID, owner: nil) as? LogCell ?? LogCell()
            cell.display(rows[row].line)
            return cell
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
    }
}

@MainActor private final class LogCell: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("gameLogLine")
    static let font = NSFont.monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular)
    private static let bold = NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .bold)
    private static let error = NSColor(Color.red.mix(with: .primary, by: 0.2))
    private static let warning = NSColor(Color.orange.mix(with: .primary, by: 0.35))
    private static let success = NSColor(Color.green.mix(with: .primary, by: 0.3))
    private static let info = NSColor(Color.blue.mix(with: .primary, by: 0.2))

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseID
        let field = NSTextField(wrappingLabelWithString: "")
        field.isSelectable = true
        field.maximumNumberOfLines = 0
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            field.topAnchor.constraint(equalTo: topAnchor),
            field.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func display(_ line: GameLogLine) {
        let color: NSColor = switch line.level {
        case .error, .fatal: Self.error
        case .warning: Self.warning
        case .success: Self.success
        case .debug, .trace: .secondaryLabelColor
        case .info, .plain: .labelColor
        }
        let text = NSMutableAttributedString(string: line.text, attributes: [.font: Self.font, .foregroundColor: color])
        if let label = line.levelLabel {
            let range = NSRange(label, in: line.text)
            text.addAttribute(.font, value: Self.bold, range: range)
            if line.level == .info { text.addAttribute(.foregroundColor, value: Self.info, range: range) }
        }
        textField?.attributedStringValue = text
    }
}
