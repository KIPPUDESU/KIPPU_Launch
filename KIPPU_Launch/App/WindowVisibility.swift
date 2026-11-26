import AppKit
import SwiftUI

/// isVisible 在窗口被完全遮住时仍可能为真
class WindowVisibilityView: NSView {
    var isWindowVisible: Bool { window?.occlusionState.contains(.visible) == true }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowVisibilityChanged),
                                                   name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
        windowVisibilityChanged()
    }

    @objc func windowVisibilityChanged() {}
}

struct WindowVisibilityObserver: NSViewRepresentable {
    @Binding var isVisible: Bool

    final class Anchor: WindowVisibilityView {
        var report: ((Bool) -> Void)?

        override func windowVisibilityChanged() {
            // 下一轮再写绑定 避开 SwiftUI 正在更新视图的时段
            Task { @MainActor [weak self] in
                guard let self else { return }
                report?(isWindowVisible)
            }
        }
    }

    func makeNSView(context: Context) -> Anchor { Anchor() }

    func updateNSView(_ view: Anchor, context: Context) {
        view.report = { visible in if isVisible != visible { isVisible = visible } }
    }

    static func dismantleNSView(_ view: Anchor, coordinator: Void) {
        view.report = nil
    }
}
