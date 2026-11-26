import SwiftUI
import UniformTypeIdentifiers

struct BackgroundSettingsSheet: View {
    let backgrounds: LauncherBackgrounds
    let instanceID: UUID?
    let instanceName: String?
    @Environment(\.dismiss) private var dismiss
    @State private var scope: BackgroundScope
    @State private var draft: BackgroundStyle?
    @State private var edited = false
    @State private var imported: BackgroundImport?
    @State private var choosingFile = false
    @State private var selection: URL?
    @State private var issue: String?

    init(backgrounds: LauncherBackgrounds, scope: BackgroundScope, instanceID: UUID?, instanceName: String?) {
        self.backgrounds = backgrounds
        self.instanceID = instanceID
        self.instanceName = instanceName
        _scope = State(initialValue: scope)
        _draft = State(initialValue: backgrounds.style(for: scope) ?? backgrounds.inherited(by: scope))
    }

    private var previewStyle: BackgroundStyle? { draft ?? backgrounds.inherited(by: scope) }

    private var scopeDescription: String {
        switch scope {
        case .instance: "用于「" + (instanceName ?? "当前实例") + "」的启动页和编辑页。"
        case .instances: "用于所有实例的启动页和编辑页，单独设置过背景的实例优先使用自己的图片。"
        case .application: "用于主窗口及侧边栏，实例页面可单独设置背景。"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("背景图片").font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                Picker("应用范围", selection: Binding(get: { scope }, set: changeScope)) {
                    if let instanceID { Text("当前实例").tag(BackgroundScope.instance(instanceID)) }
                    Text("所有实例").tag(BackgroundScope.instances)
                    Text("整体界面").tag(BackgroundScope.application)
                }
                .pickerStyle(.segmented)
                .disabled(selection != nil)
                Text(scopeDescription).font(.callout).foregroundStyle(.secondary)
            }
            preview
            HStack {
                Button(previewStyle == nil ? "选择图片" : "更换图片", systemImage: "photo") { choosingFile = true }
                Spacer()
                if draft != nil && (backgrounds.style(for: scope) != nil || edited) {
                    Button(scope == .application ? "恢复默认背景" : "使用上级背景") {
                        draft = nil
                        edited = true
                        issue = nil
                    }.buttonStyle(.link)
                }
            }
            .disabled(selection != nil)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                slider("透明度", key: \.transparency, range: 0...100, unit: "%")
                slider("模糊度", key: \.blur, range: 0...40, unit: " pt")
            }
            .disabled(previewStyle == nil || selection != nil)
            if let issue {
                Label(issue, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary).font(.callout)
            }
            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("应用") {
                    do {
                        try backgrounds.apply(draft, to: scope, imported: imported)
                        dismiss()
                    } catch {
                        issue = "无法保存背景。请重新选择图片或检查可用磁盘空间。"
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!edited || selection != nil)
            }
        }
        .padding(20)
        .frame(width: 490)
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.image]) { result in
            switch result {
            case let .success(url): selection = url
            case let .failure(error):
                if (error as NSError).code != NSUserCancelledError { issue = error.localizedDescription }
            }
        }
        .task(id: selection) {
            guard let selection else { return }
            do {
                let item = try await BackgroundImport.prepare(selection)
                try Task.checkCancellation()
                let old = previewStyle
                draft = BackgroundStyle(imageID: item.id, transparency: old?.transparency ?? 50, blur: old?.blur ?? 0)
                imported = item
                edited = true
                issue = nil
            } catch {
                guard !Task.isCancelled else { return }
                issue = "无法读取这张图片，请选择其他图片。"
            }
            self.selection = nil
        }
    }

    private var preview: some View {
        ZStack {
            Rectangle().fill(.regularMaterial)
            if let style = previewStyle, let file = imported?.id == style.imageID ? imported?.url : backgrounds.url(for: style) {
                BackgroundImageLayer(style: style, url: file, maxPixels: 900, previewScale: 0.5)
            }
            Color.black.opacity(0.5)
            if selection != nil { ProgressView().controlSize(.small) }
            else if previewStyle == nil {
                Label("默认背景", systemImage: "photo").font(.callout).foregroundStyle(.white.opacity(0.8))
            }
        }
        .frame(height: 142)
        .clipShape(.rect(cornerRadius: 8))
        .accessibilityLabel("背景预览")
    }

    private func slider(_ title: String, key: WritableKeyPath<BackgroundStyle, Double>,
                        range: ClosedRange<Double>, unit: String) -> some View {
        let value = Binding<Double>(get: { previewStyle?[keyPath: key] ?? 0 }, set: { newValue in
            guard var style = previewStyle else { return }
            style[keyPath: key] = newValue.rounded()
            draft = style
            edited = true
        })
        return GridRow {
            Text(title)
            Slider(value: value, in: range) { Text(title) }.labelsHidden()
                .accessibilityValue("\(Int(value.wrappedValue))\(unit)")
            Text(verbatim: "\(Int(value.wrappedValue))\(unit)")
                .monospacedDigit().foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
        }
    }

    private func changeScope(_ newScope: BackgroundScope) {
        guard newScope != scope else { return }
        scope = newScope
        // 换范围时带上编辑中的图片 重置则只对原范围生效
        if !edited || draft == nil {
            draft = backgrounds.style(for: scope) ?? backgrounds.inherited(by: scope)
            edited = false
        }
        issue = nil
    }
}
