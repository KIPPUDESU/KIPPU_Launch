import SwiftUI

struct DownloadTaskStrip: View {
    @Environment(DownloadCenter.self) private var center

    var body: some View {
        let held = center.active == nil ? center.jobs.first { $0.state == .paused } : nil
        let shown = center.active ?? held
        let paused = center.isPaused || held != nil
        let summary = self.summary
        HStack(spacing: 10) {
            ZStack {
                if shown != nil || paused {
                    Circle().stroke(.secondary.opacity(0.35), lineWidth: 1.5)
                    if let fraction = shown?.displayFraction {
                        Circle().trim(from: 0, to: fraction).rotation(.degrees(-90))
                            .stroke(paused ? Color.secondary : .accentColor,
                                    style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    }
                    Image(systemName: paused ? "pause.fill" : "arrow.down")
                        .font(.system(size: 9, weight: .semibold))
                } else {
                    Image(systemName: "arrow.down.circle").font(.system(size: 16))
                }
            }
            .frame(width: 16, height: 16).frame(width: 20)
            Text("下载任务")
            Spacer(minLength: 4)
            if let summary {
                Text(summary).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            } else {
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("下载任务")
        .accessibilityValue(summary ?? "空闲")
    }

    private var summary: String? {
        if center.isPaused { return "已暂停" }
        if let active = center.active {
            if active.state == .cancelling { return "正在取消" }
            return active.displayFraction.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "处理中"
        }
        let waiting = center.jobs.count { $0.state == .queued }
        if waiting > 0 { return "\(waiting) 项等待" }
        let paused = center.jobs.count { $0.state == .paused }
        if paused > 0 { return "\(paused) 项暂停" }
        let failed = center.jobs.count { $0.state == .failed }
        return failed > 0 ? "\(failed) 项失败" : nil
    }
}

struct DownloadCenterView: View {
    @Environment(DownloadCenter.self) private var center

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let queued = center.jobs.filter { $0.state == .queued }
        let held = center.jobs.filter { $0.state == .paused || ($0.state == .cancelling && center.active !== $0) }
        let finished = center.jobs.reversed().filter { $0.state.finished }
        VStack(spacing: 0) {
            PageHeader(title: "下载任务") {
                if center.isPaused || center.jobs.lazy.filter({ !$0.state.finished }).prefix(2).count > 1 {
                    Button(center.isPaused ? "继续队列" : "暂停队列",
                           systemImage: center.isPaused ? "play.fill" : "pause.fill") {
                        if center.isPaused { center.resume() } else { center.pause() }
                    }
                    .help("控制整条队列，单独暂停的任务会保留暂停状态。")
                }
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    DownloadActivityView()
                    if let job = center.active {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("当前任务").font(.headline)
                            GroupBox {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack(spacing: 12) {
                                        identity(job)
                                        Spacer(minLength: 8)
                                        controls(job)
                                    }
                                    ProgressView(value: job.displayFraction ?? (center.isPaused ? 0 : nil))
                                        .progressViewStyle(.linear)
                                        .tint(center.isPaused ? Color.secondary : .accentColor)
                                        .animation(reduceMotion || center.isPaused || job.state != .running
                                                   ? nil : .linear(duration: 0.20), value: job.displayFraction)
                                        .accessibilityLabel("当前阶段进度")
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(job.stage)
                                        Spacer()
                                        if let fraction = job.displayFraction {
                                            Text(fraction.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
                                        }
                                    }
                                    .font(.callout).foregroundStyle(.secondary)
                                }
                                .padding(6)
                            }
                        }
                    }
                    if !queued.isEmpty { section("等待中", jobs: queued) }
                    if !held.isEmpty { section("已暂停", jobs: held) }
                    if !finished.isEmpty { section("最近任务", jobs: finished, history: true) }
                    if center.jobs.isEmpty {
                        ContentUnavailableView("暂无下载任务", systemImage: "tray.and.arrow.down",
                                               description: Text("在左侧下载分类中选择游戏或资源，即可开始下载。"))
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                }
                .frame(maxWidth: 1100, alignment: .leading)
                .padding(20)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func section(_ title: String, jobs: [DownloadJob], history: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Text("\(jobs.count)").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                if history && jobs.contains(where: { $0.state == .completed }) {
                    Button("清除已完成") {
                        for job in jobs where job.state == .completed { center.remove(job) }
                    }.buttonStyle(.link).controlSize(.small)
                }
            }
            GroupBox {
                VStack(spacing: 0) {
                    ForEach(jobs) { job in
                        if job.id != jobs.first?.id { Divider().padding(.leading, 42) }
                        HStack(spacing: 12) {
                            identity(job)
                            Spacer(minLength: 4)
                            if job.state == .completed {
                                Label(job.result.isEmpty ? "已完成" : job.result, systemImage: "checkmark.circle")
                                    .font(.callout).foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                            } else if history {
                                HStack(spacing: 8) {
                                    if job.state == .cancelled {
                                        Text("已取消").font(.callout).foregroundStyle(.secondary)
                                    }
                                    Button("重试") { center.retry(job) }.disabled(!center.canRetry(job))
                                    Button("移除记录", systemImage: "trash") { center.remove(job) }
                                        .buttonStyle(.borderless).labelStyle(.iconOnly).help("移除记录")
                                }
                            } else { controls(job) }
                        }.padding(.horizontal, 6).padding(.vertical, 6)
                    }
                }
            }
        }
    }

    @ViewBuilder private func controls(_ job: DownloadJob) -> some View {
        if job.state == .cancelling {
            Text("正在取消").font(.callout).foregroundStyle(.secondary)
        } else {
            HStack(spacing: 8) {
                if job.state == .pausing {
                    Text("正在暂停").font(.callout).foregroundStyle(.secondary)
                } else {
                    let paused = job.state == .paused
                    Button(paused ? "继续" : "暂停", systemImage: paused ? "play.fill" : "pause.fill") {
                        if paused { center.resume(job) } else { center.pause(job) }
                    }
                    .help(paused ? "让此任务恢复排队" : "只暂停此任务")
                }
                Button("取消任务", systemImage: "xmark.circle") { center.cancel(job) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    .font(.body).foregroundStyle(.secondary)
                    .accessibilityLabel("取消「\(job.title)」").help("取消此任务")
            }
        }
    }

    private func identity(_ job: DownloadJob) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: job.category.icon).font(.title3)
                .symbolRenderingMode(.hierarchical).foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: job.title).font(.headline)
                Text(verbatim: [job.category.title, job.target].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.callout).foregroundStyle(.secondary)
                if job.state == .paused, let fraction = job.displayFraction {
                    Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                if job.state == .failed {
                    Label(job.result.isEmpty ? "下载失败" : job.result, systemImage: "exclamationmark.circle")
                        .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                }
            }.fixedSize(horizontal: false, vertical: true)
        }
    }
}
