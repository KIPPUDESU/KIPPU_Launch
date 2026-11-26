import SwiftUI

struct InstanceMemoryPopover: View {
    let memoryMB: Int?
    let globalMB: Int
    let save: (Int?) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Int
    @State private var errorMessage: String?

    init(memoryMB: Int?, globalMB: Int, save: @escaping (Int?) throws -> Void) {
        self.memoryMB = memoryMB
        self.globalMB = globalMB
        self.save = save
        _draft = State(initialValue: min(MemoryAllocationSlider.maximumMB, max(512, memoryMB ?? globalMB)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MemoryAllocationSlider(memoryMB: $draft, title: "实例内存")
            Divider()
            LabeledContent("全局默认", value: MemoryAllocationSlider.formatted(globalMB))
                .foregroundStyle(.secondary)
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            HStack {
                Button("跟随全局") { commit(nil) }
                    .disabled(memoryMB == nil && draft == globalMB)
                Spacer()
                Button("保存") { commit(draft) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 328)
    }

    private func commit(_ value: Int?) {
        do {
            try save(value)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
