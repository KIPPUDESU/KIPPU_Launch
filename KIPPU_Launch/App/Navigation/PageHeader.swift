import SwiftUI

struct SidebarChrome: @unchecked Sendable {
    var isVisible: Bool
    /// 这个闭包只在主线程的按钮动作里调用
    var toggle: () -> Void
}

private struct SidebarChromeKey: EnvironmentKey {
    static let defaultValue: SidebarChrome? = nil
}

extension EnvironmentValues {
    var sidebarChrome: SidebarChrome? {
        get { self[SidebarChromeKey.self] }
        set { self[SidebarChromeKey.self] = newValue }
    }
}

struct PageHeader<Trailing: View>: View {
    @Environment(\.sidebarChrome) private var chrome

    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            if let chrome {
                sidebarToggle(chrome)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.leading, 20)
        .padding(.trailing, 20)
        .padding(.top, WindowMetrics.headerTopPadding)
        .padding(.bottom, WindowMetrics.headerBottomPadding)
    }

    private func sidebarToggle(_ chrome: SidebarChrome) -> some View {
        Button(action: chrome.toggle) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: WindowMetrics.toggleButtonSize, height: WindowMetrics.toggleButtonSize)
                .contentShape(Circle())
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        // 外层标题行已经留了 20 点边距
        .padding(.leading, (chrome.isVisible
            ? WindowMetrics.toggleLeadingWithSidebar
            : WindowMetrics.toggleLeadingWithoutSidebar) - 20)
        .offset(y: WindowMetrics.toggleButtonVerticalOffset)
        .help(chrome.isVisible ? "隐藏侧边栏" : "显示侧边栏")
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}
