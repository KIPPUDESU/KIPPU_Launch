import AppKit
import Charts
import QuartzCore
import SwiftUI

struct DownloadActivityView: View {
    @Environment(DownloadCenter.self) private var center

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private let metricWidth: CGFloat = 126

    var body: some View {
        let held = center.jobs.first { $0.state == .paused && !$0.samples.isEmpty }
        let job = center.active ?? held ?? center.lastTransfer
        let live = center.active != nil && !center.isPaused
        let paused = center.isPaused || held != nil && center.active == nil
        let samples = job?.samples ?? []
        let canAnimate = live && job?.state == .running && !reduceMotion && scenePhase == .active
        if samples.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    GroupBox {
                        downloadRate(job, live: live)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    GroupBox {
                        diskRate(job, live: live)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                }
                if let job, job.bytes > 0 {
                    summary("已接收", bytes(job.bytes)).font(.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        downloadRate(job, live: live).frame(width: metricWidth, alignment: .leading)
                        TransferPlot(samples: samples, kind: .download, canAnimate: canAnimate)
                    }
                    HStack(spacing: 12) {
                        diskRate(job, live: live).frame(width: metricWidth, alignment: .leading)
                        TransferPlot(samples: samples, kind: .disk, canAnimate: canAnimate)
                    }
                    HStack(spacing: 12) {
                        Color.clear.frame(width: metricWidth, height: 0)
                        HStack {
                            Text("30 秒前")
                            Spacer()
                            Text(live ? "现在" : (paused ? "暂停时" : "结束时"))
                        }
                        .padding(.trailing, TransferPlot.axisWidth)
                        .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(6)
                Divider()
                HStack(spacing: 12) {
                    summary("已接收", bytes(job?.bytes ?? 0))
                    summary("下载峰值", rate(job?.peakSpeed ?? 0))
                    Spacer()
                    if paused {
                        Label("已暂停", systemImage: "pause.circle")
                    } else if live {
                        Text("实时")
                    } else { Text(job == nil ? "空闲" : "上次传输") }
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 4)
            }
            .id(job?.id)
        }
    }

    private func downloadRate(_ job: DownloadJob?, live: Bool) -> some View {
        metric("下载速度", value: rate(live ? job?.speed ?? 0 : 0), icon: "arrow.down.circle", color: .blue)
            .help("最近 1 秒的平均接收速度")
    }

    private func diskRate(_ job: DownloadJob?, live: Bool) -> some View {
        metric("磁盘写入", value: live ? job?.diskSpeed.map(rate) ?? "—" : rate(0),
               icon: "internaldrive", color: .green)
            .help("macOS 记录的启动器进程写入量，按最近 3 秒取平均。")
    }

    private func metric(_ title: String, value: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label {
                Text(title).foregroundStyle(.secondary)
            } icon: {
                Image(systemName: icon).foregroundStyle(color)
            }.font(.subheadline)
            Text(verbatim: value).font(.title3.weight(.semibold)).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private func summary(_ title: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
            Text(verbatim: value).monospacedDigit().foregroundStyle(.primary)
        }.accessibilityElement(children: .combine)
    }
}

@MainActor private let byteFormatter: ByteCountFormatter = {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter
}()

@MainActor private func bytes(_ count: Int64) -> String {
    count == 0 ? "0 B" : byteFormatter.string(fromByteCount: count)
}

@MainActor private func rate(_ value: Double) -> String { bytes(Int64(value)) + "/s" }

/// 磁盘写入峰值可能远高于网速 两张图各用自己的纵轴
private struct TransferPlot: View {
    enum Kind { case download, disk }
    static let axisWidth: CGFloat = 68
    let samples: [DownloadJob.Sample]
    let kind: Kind
    let canAnimate: Bool

    private var ceiling: Double {
        let peak = samples.reduce(0.0) { max($0, kind == .download ? $1.speed : $1.diskSpeedBeforeBoundary ?? 0) }
        guard peak > 0 else { return 1_000_000 }
        let unit = pow(10, floor(log10(peak)))
        let step = [1.0, 2, 2.5, 5, 10].first { $0 * unit >= peak } ?? 10
        return step * unit
    }

    var body: some View {
        let top = ceiling

        HStack(spacing: 0) {
            Grid(ceiling: top)
                .equatable()
                .overlay { ScrollingMarks(samples: samples, kind: kind, ceiling: top, animate: canAnimate) }
                .accessibilityRepresentation { TransferMarks(samples: samples, kind: kind, ceiling: top) }
                .accessibilityLabel(kind == .download ? "最近 30 秒下载速度" : "最近 30 秒磁盘写入速度")

            VStack(alignment: .leading) {
                Text(verbatim: rate(top))
                Spacer(minLength: 0)
                Text("0")
            }
            .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            .padding(.leading, 6)
            .frame(width: Self.axisWidth, alignment: .leading)
        }
        .frame(height: 44)
    }

    private struct Grid: View, Equatable {
        let ceiling: Double

        var body: some View {
            Chart {}
                .chartYScale(domain: 0...ceiling)
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(values: [0, ceiling / 2, ceiling]) { AxisGridLine() }
                }
        }
    }

}

private extension DownloadJob.Sample {
    var barStart: Double { time - interval * 0.84 }
    var baseline: Double { 0 }
    var writeRate: Double { diskSpeedBeforeBoundary ?? 0 }
}

private struct TransferMarks: View {
    let samples: [DownloadJob.Sample]
    let kind: TransferPlot.Kind
    let ceiling: Double
    private let diskStroke = StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)

    var body: some View {
        let end = samples.last?.time ?? 0
        Chart {
            if kind == .download {
                RectanglePlot(samples.filter { $0.interval > 0 },
                              xStart: .value("开始", \.barStart), xEnd: .value("结束", \.time),
                              yStart: .value("基线", \.baseline), yEnd: .value("下载速度", \.speed))
                    .foregroundStyle(Color.blue.gradient)
            } else {
                LinePlot(samples.filter { $0.diskSpeedBeforeBoundary != nil },
                         x: .value("时间", \.time), y: .value("磁盘写入", \.writeRate),
                         series: .value("连续采样", \.segment))
                    .foregroundStyle(.green)
                    .lineStyle(diskStroke)
                ForEach(samples.filter { $0.boundary != nil }) { sample in
                    if case let .pause(previous) = sample.boundary, let previous, previous > 0 {
                        RuleMark(x: .value("暂停", sample.time), yStart: .value("基线", 0),
                                 yEnd: .value("暂停前写入速度", previous))
                            .foregroundStyle(.green)
                            .lineStyle(diskStroke)
                    } else if case let .resume(start) = sample.boundary {
                        RuleMark(xStart: .value("暂停", max(start, end - DownloadJob.chartDuration)),
                                 xEnd: .value("继续", sample.time), y: .value("基线", 0))
                            .foregroundStyle(.green)
                            .lineStyle(diskStroke)
                    }
                }
            }
        }
        .chartXScale(domain: (end - DownloadJob.chartDuration)...end)
        .chartYScale(domain: 0...ceiling)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .transaction { $0.animation = nil }
    }
}

private struct ScrollingMarks: NSViewRepresentable {
    let samples: [DownloadJob.Sample]
    let kind: TransferPlot.Kind
    let ceiling: Double
    let animate: Bool

    func makeNSView(context: Context) -> PlotView { PlotView() }

    func updateNSView(_ view: PlotView, context: Context) {
        view.update(self)
    }

    final class PlotView: WindowVisibilityView {
        private let host = NSHostingView(rootView: TransferMarks(samples: [], kind: .download, ceiling: 1))
        private var previous: ScrollingMarks?
        private var pending: ScrollingMarks?

        override func windowVisibilityChanged() {
            if let pending, isWindowVisible {
                self.pending = nil
                previous = nil
                update(pending)
            }
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = true
            host.wantsLayer = true
            host.sizingOptions = []
            host.frame = bounds
            host.autoresizingMask = [.width, .height]
            addSubview(host)
        }

        required init?(coder: NSCoder) { nil }

        func update(_ next: ScrollingMarks) {
            guard isWindowVisible else {
                pending = next
                return
            }
            pending = nil
            let before = previous
            previous = next
            guard let layer = host.layer else { return }
            if !next.animate { layer.removeAnimation(forKey: "scroll") }
            let last = next.samples.last
            guard before?.samples.last?.time != last?.time || before?.ceiling != next.ceiling ||
                    before?.kind != next.kind else { return }

            // 上一次平移可能还没播完 从屏幕上的位置接着走
            let remainder = layer.presentation()?.transform.m41 ?? 0
            layer.removeAnimation(forKey: "scroll")
            host.rootView = TransferMarks(samples: next.samples, kind: next.kind, ceiling: next.ceiling)

            guard next.animate, let old = before?.samples.last, let last, old.segment == last.segment else { return }
            let interval = last.time - old.time
            guard interval > 0, interval <= DownloadJob.sampleInterval * 2, bounds.width > 0 else { return }
            let scroll = CABasicAnimation(keyPath: "transform.translation.x")
            scroll.fromValue = remainder + interval * bounds.width / DownloadJob.chartDuration
            scroll.toValue = 0
            scroll.duration = DownloadJob.sampleInterval
            scroll.timingFunction = CAMediaTimingFunction(name: .linear)
            layer.add(scroll, forKey: "scroll")
        }
    }
}
