import KIPPULaunchCore
import SwiftUI
import UniformTypeIdentifiers

struct InstanceSettingsSheet: View {
    let instance: InstanceRecord
    let defaultMemory: Int
    let embedded: Bool
    let runtimes: [JavaRuntime]
    let save: (Int?, String?) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var useDefault: Bool
    @State private var memory: Int
    @State private var java: String
    @State private var choosing = false
    @State private var problem: String?

    init(instance: InstanceRecord, defaultMemory: Int, runtimes: [JavaRuntime], embedded: Bool = false, save: @escaping (Int?, String?) throws -> Void) {
        self.defaultMemory = defaultMemory
        self.embedded = embedded
        self.instance = instance
        self.runtimes = runtimes
        self.save = save
        _useDefault = State(initialValue: instance.memoryMB == nil)
        _memory = State(initialValue: instance.memoryMB ?? defaultMemory)
        _java = State(initialValue: instance.selectedJavaPath ?? "")
    }

    var body: some View {
        VStack(alignment: .leading) {
            if !embedded { Text(instance.displayName).font(.headline).padding() }
            Form {
                if embedded {
                    Section("实例信息") {
                        LabeledContent("Minecraft", value: instance.minecraftVersion ?? instance.versionIdentifier)
                        LabeledContent("加载器", value: [instance.loader.displayName, instance.loaderVersion].compactMap { $0 }.joined(separator: " "))
                        LabeledContent("实例类型", value: instance.kind.isWritable ? "托管实例" : "外部实例")
                        if instance.isMissing { Label("实例目录已缺失", systemImage: "exclamationmark.triangle") }
                        if let major = instance.requiredJavaMajorVersion { LabeledContent("所需 Java", value: "Java \(major)") }
                        InstanceDirectoryRow(path: instance.path, isMissing: instance.isMissing)
                    }
                }
                Section("内存") {
                    Toggle("跟随默认内存", isOn: $useDefault)
                    if !useDefault { MemorySettingsView(memoryMB: $memory, title: "实例内存") }
                    else { LabeledContent("默认分配", value: "\(defaultMemory) MB") }
                }
                Section("Java") {
                    Picker("运行环境", selection: $java) {
                        Text("自动选择").tag("")
                        ForEach(runtimes) { runtime in Text(runtime.displayName).tag(runtime.id) }
                        if !java.isEmpty && !runtimes.contains(where: { $0.id == java }) { Text(java).tag(java) }
                    }
                    Button("选择其他 Java") { choosing = true }
                }
                if let problem { Text(problem).foregroundStyle(.red) }
            }.formStyle(.grouped).scrollContentBackground(.hidden)
            HStack {
                Spacer()
                if !embedded { Button("取消") { dismiss() }.keyboardShortcut(.cancelAction) }
                Button("保存") {
                    do {
                        try save(useDefault ? nil : memory, java.isEmpty ? nil : java)
                        problem = nil
                        if !embedded { dismiss() }
                    } catch {
                        problem = error.localizedDescription
                    }
                }.keyboardShortcut(.defaultAction)
                    .disabled(embedded && (useDefault ? nil : memory) == instance.memoryMB && (java.isEmpty ? nil : java) == instance.selectedJavaPath)
            }.padding()
        }
        .frame(width: embedded ? nil : 480, height: embedded ? nil : 485)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder, .unixExecutable, .bundle]) { result in
            guard case let .success(url) = result else { return }
            guard let runtime = JavaLocator().runtime(at: url) else {
                problem = "请选择 JDK、Java 主目录或 bin/java。"
                return
            }
            java = runtime.id
            problem = nil
        }
    }
}
