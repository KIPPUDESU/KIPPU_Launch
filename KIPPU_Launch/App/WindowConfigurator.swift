import AppKit
import SwiftUI

enum WindowMetrics {
    static let headerTopPadding: CGFloat = 9

    static let headerBottomPadding: CGFloat = 10

    static let toggleButtonSize: CGFloat = 28

    static let toggleButtonVerticalOffset: CGFloat = -2

    static let toggleLeadingWithSidebar: CGFloat = 12

    static let toggleLeadingWithoutSidebar: CGFloat = 94

    static let sidebarTitleTopPadding: CGFloat = 56

    static let trafficLightOffset = CGPoint(x: 13, y: -8)
}

struct WindowConfigurator: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        let coordinator = context.coordinator
        Task { @MainActor in
            guard let window = view.window else { return }
            coordinator.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        Task { @MainActor in
            guard let window = nsView.window else { return }
            coordinator.attach(to: window)
        }
    }

    @MainActor
    final class Coordinator {
        private weak var window: NSWindow?
        private var trafficLightConstraints: [NSLayoutConstraint] = []

        func attach(to window: NSWindow) {
            guard self.window !== window else { return }
            NSLayoutConstraint.deactivate(trafficLightConstraints)
            trafficLightConstraints.removeAll()
            self.window = window

            window.isMovableByWindowBackground = true
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)

            window.isOpaque = false
            window.backgroundColor = .clear

            installNativeTrafficLightConstraints(on: window)
        }

        private func installNativeTrafficLightConstraints(on window: NSWindow) {
            let types: [NSWindow.ButtonType] = [
                .closeButton,
                .miniaturizeButton,
                .zoomButton,
            ]

            let buttons = types.compactMap { window.standardWindowButton($0) }
            guard buttons.count == types.count else {
                // 标题栏按钮可能晚于窗口创建
                Task { @MainActor [weak self, weak window] in
                    try? await Task.sleep(for: .milliseconds(120))
                    guard let self, let window, self.window === window else { return }
                    self.installNativeTrafficLightConstraints(on: window)
                }
                return
            }

            guard let container = buttons.first?.superview else { return }
            guard buttons.allSatisfy({ $0.superview === container }) else { return }

            guard trafficLightConstraints.isEmpty else { return }

            // 移动标题栏容器会让红绿灯偏离实际点击区域
            for button in buttons {
                button.translatesAutoresizingMaskIntoConstraints = false
            }

            let originals = buttons.map { button in
                (button: button, frame: button.frame)
            }

            for item in originals {
                let button = item.button
                let frame = item.frame
                let targetX = frame.origin.x + WindowMetrics.trafficLightOffset.x
                // AppKit 的按钮坐标从容器底部算起
                let targetTop = container.bounds.height
                    - (frame.origin.y + frame.height)
                    - WindowMetrics.trafficLightOffset.y

                let leading = button.leadingAnchor.constraint(
                    equalTo: container.leadingAnchor,
                    constant: targetX
                )
                let top = button.topAnchor.constraint(
                    equalTo: container.topAnchor,
                    constant: targetTop
                )
                let width = button.widthAnchor.constraint(equalToConstant: frame.width)
                let height = button.heightAnchor.constraint(equalToConstant: frame.height)

                for constraint in [leading, top, width, height] {
                    constraint.priority = .defaultHigh
                    trafficLightConstraints.append(constraint)
                }
            }

            NSLayoutConstraint.activate(trafficLightConstraints)
            container.needsLayout = true
            container.layoutSubtreeIfNeeded()
        }
    }
}
