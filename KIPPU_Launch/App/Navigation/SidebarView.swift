import KIPPULaunchCore
import SwiftUI

struct SidebarView: View {
    @Environment(\.pixelLength) private var pixelLength
    @FocusState private var focusedRow: SidebarDestination?
    @State private var hoveredRow: SidebarDestination?
    static let width: CGFloat = 236
    private let rowInset: CGFloat = 8

    private static let libraryRows: [SidebarDestination] = [.launchHome, .instances]
    private static let downloadRows = DownloadSection.allCases.map(SidebarDestination.download)
    private static let generalRows: [SidebarDestination] = [.settings, .about]
    private static let navigationOrder = libraryRows + downloadRows + generalRows + [.downloadCenter]

    @Binding var destination: SidebarDestination
    let account: StoredAccount?
    let skinHead: SkinHead?
    let onShowAccounts: () -> Void

    var body: some View {
        GeometryReader { geometry in
            content(rowHeight: geometry.size.height < 600 ? 26 : 30)
        }
        .frame(width: Self.width)
        .background(Color.black.opacity(0.18))
        .scrollDisabled(true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("主导航")
    }

    private func content(rowHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image("AppMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
                Text(AppInfo.displayName)
                    .font(.title3.weight(.semibold))
            }
            .padding(.horizontal, rowInset)
            .padding(.bottom, 8)

            group("账户", headerGap: 8) { accountButton }
            group("资料库") {
                ForEach(Self.libraryRows, id: \.self) { row($0, height: rowHeight) }
            }
            .padding(.top, 10)
            group("下载") {
                ForEach(Self.downloadRows, id: \.self) { row($0, height: rowHeight) }
            }
            .padding(.top, 10)

            Spacer(minLength: 8)

            group("通用") {
                ForEach(Self.generalRows, id: \.self) { row($0, height: rowHeight) }
            }
            Divider().padding(.vertical, 4)
            row(.downloadCenter, height: 30)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .frame(maxHeight: .infinity)
        .padding(.top, WindowMetrics.sidebarTitleTopPadding)
    }

    private var accountButton: some View {
        Button(action: onShowAccounts) {
            HStack(spacing: 10) {
                SkinHeadView(head: skinHead)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account?.displayName ?? "添加账号")
                        .font(.headline)
                        .lineLimit(1)
                    if let detail = account?.detailLine {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, rowInset)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("管理账号")
    }

    private func group(_ title: String, headerGap: CGFloat = 6, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .padding(.leading, rowInset)
                .font(.caption.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            Divider()
                .padding(.top, 2)
                .padding(.bottom, headerGap)
            content()
        }
    }

    private func row(_ item: SidebarDestination, height: CGFloat) -> some View {
        let selected = destination == item
        return Button {
            destination = item
        } label: {
            Group {
                if item == .downloadCenter {
                    DownloadTaskStrip()
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: item.icon)
                            .resizable()
                            .symbolRenderingMode(.monochrome)
                            .scaledToFit()
                            .frame(width: iconWidth(for: item))
                            .frame(width: 20)
                            .accessibilityHidden(true)
                        Text(item.title)
                    }
                }
            }
            .padding(.horizontal, rowInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .background(.primary.opacity(selected ? 0.12 : (hoveredRow == item ? 0.06 : 0)),
                    in: .rect(cornerRadius: 8))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onHover { inside in
            if inside { hoveredRow = item }
            else if hoveredRow == item { hoveredRow = nil }
        }
        .focused($focusedRow, equals: item)
        .onKeyPress(keys: [.upArrow, .downArrow]) { key in
            guard let index = Self.navigationOrder.firstIndex(of: item) else { return .ignored }
            let next = index + (key.key == .upArrow ? -1 : 1)
            if Self.navigationOrder.indices.contains(next) {
                focusedRow = Self.navigationOrder[next]
                destination = Self.navigationOrder[next]
            }
            return .handled
        }
    }

    private func iconWidth(for item: SidebarDestination) -> CGFloat {
        switch item {
        case .download(.game), .download(.mod), .download(.shader): 14 + 2 * pixelLength
        default: 14
        }
    }
}
