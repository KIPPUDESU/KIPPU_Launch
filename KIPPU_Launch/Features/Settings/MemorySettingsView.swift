import Darwin
import Foundation
import SwiftUI

private struct SystemMemory {
    let totalMB = Double(ProcessInfo.processInfo.physicalMemory) / 1_048_576
    var usedMB: Double?

    var availableMB: Double? { usedMB.map { max(0, totalMB - $0) } }

    static func read() -> Self {
        var result = Self()
        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var pageSize: vm_size_t = 0
        guard host_page_size(host, &pageSize) == KERN_SUCCESS else { return result }
        let status = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return result }
        // 压缩页按实际占用统计 可回收的缓存页单独扣除
        let pages = Double(statistics.active_count) + Double(statistics.inactive_count)
            + Double(statistics.wire_count) + Double(statistics.compressor_page_count)
            - Double(statistics.purgeable_count) - Double(statistics.external_page_count)
        result.usedMB = min(result.totalMB, max(0, pages * Double(pageSize) / 1_048_576))
        return result
    }
}

struct MemorySettingsView: View {
    @Binding var memoryMB: Int
    var title = "默认内存"
    @State private var system = SystemMemory.read()
    @State private var windowVisible = false

    private func capacity(_ mb: Double) -> String {
        String(format: "%.1f GB", mb / 1024)
    }

    private var allocation: String {
        MemoryAllocationSlider.formatted(memoryMB)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MemoryAllocationSlider(memoryMB: $memoryMB, title: title)

            Divider()

            HStack {
                Text("设备总内存 \(capacity(system.totalMB))")
                Spacer(minLength: 12)
                if let available = system.availableMB {
                    Text("当前可用 \(capacity(available))")
                        .help("包含可回收缓存，每 2 秒刷新。")
                }
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)

            if let available = system.availableMB, let used = system.usedMB {
                memoryOverview(used: used, available: available)
                if Double(memoryMB) > available {
                    Label("已超出当前可用内存 \(capacity(Double(memoryMB) - available))，建议降低分配量或关闭其他应用。", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("暂时无法读取内存占用，稍后自动重试。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("设置游戏最大堆内存，实例独立设置优先。可用容量含可回收缓存，预计剩余未计入游戏额外开销。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WindowVisibilityObserver(isVisible: $windowVisible))
        .task(id: windowVisible) {
            guard windowVisible else { return }
            memoryMB = min(MemoryAllocationSlider.maximumMB, max(512, memoryMB))
            while !Task.isCancelled {
                system = SystemMemory.read()
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    break
                }
            }
        }
    }

    private func memoryOverview(used: Double, available: Double) -> some View {
        VStack(spacing: 10) {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    Rectangle().fill(Color.secondary.opacity(0.65))
                        .frame(width: geometry.size.width * used / system.totalMB)
                    Rectangle().fill(Color.accentColor)
                        .frame(width: geometry.size.width * min(Double(memoryMB), available) / system.totalMB)
                    Rectangle().fill(Color.secondary.opacity(0.2))
                }
            }
            .frame(height: 8)
            .clipShape(Capsule())
            .accessibilityHidden(true)

            HStack(alignment: .top, spacing: 16) {
                memoryMetric("已占用", value: capacity(used), color: .secondary.opacity(0.65))
                memoryMetric("计划分配", value: allocation, color: .accentColor)
                memoryMetric("预计剩余", value: capacity(max(0, available - Double(memoryMB))), color: .secondary.opacity(0.2))
            }
        }
    }

    private func memoryMetric(_ title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.callout.weight(.medium))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct MemoryAllocationSlider: View {
    @Binding var memoryMB: Int
    let title: String
    static let maximumMB = max(512, Int(ProcessInfo.processInfo.physicalMemory / 1_048_576 / 256) * 256)

    static func formatted(_ mb: Int) -> String {
        (Double(mb) / 1024).formatted(.number.precision(.fractionLength(0...2))) + " GB"
    }

    private var selection: Binding<Double> {
        Binding(
            get: { Double(min(Self.maximumMB, max(512, memoryMB))) },
            set: { memoryMB = min(Self.maximumMB, max(512, Int(($0 / 256).rounded()) * 256)) }
        )
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.headline)
                Spacer()
                Text(Self.formatted(memoryMB))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.tint)
                Text("\(memoryMB) MB")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .monospacedDigit()

            Slider(
                value: selection,
                in: 512...Double(Self.maximumMB),
                label: { Text(title) }
            )
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .accessibilityValue("\(memoryMB) MB")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: adjustMemory(by: 256)
                case .decrement: adjustMemory(by: -256)
                @unknown default: break
                }
            }
            .onKeyPress(.leftArrow) {
                adjustMemory(by: -256)
                return .handled
            }
            .onKeyPress(.rightArrow) {
                adjustMemory(by: 256)
                return .handled
            }

            HStack {
                Text("512 MB")
                Spacer()
                Text("每次调整 256 MB")
                Spacer()
                Text(Self.formatted(Self.maximumMB))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func adjustMemory(by amount: Int) {
        selection.wrappedValue = Double(memoryMB) + Double(amount)
    }
}
