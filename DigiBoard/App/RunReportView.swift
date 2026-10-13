import Charts
import SwiftUI

/// 调试模式的运行报告：汇总数字 + 资源曲线 + 保存处理后视频。
struct RunReportView: View {
    let report: RunReport
    let processedVideoURL: URL?
    let reportCSVURL: URL?
    let isSaving: Bool
    let saveMessage: String?
    let onSaveToPhotos: () -> Void
    let onReplay: () -> Void
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    summaryGrid
                    chartCard(title: "帧率 FPS", systemImage: "speedometer", tint: .green) { fpsChart }
                    chartCard(title: "内存 MB", systemImage: "memorychip", tint: .blue) { memoryChart }
                    chartCard(title: "CPU %", systemImage: "cpu", tint: .orange) { cpuChart }
                    if report.hasBattery {
                        chartCard(title: "电量 %", systemImage: "battery.75", tint: .yellow) { batteryChart }
                    }
                    chartCard(title: "热状态", systemImage: "thermometer.medium", tint: .red) { thermalChart }
                    exportSection
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("调试报告")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成", action: onClose)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("重新播放", action: onReplay)
                }
            }
        }
    }

    // MARK: - 标题

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(report.title.isEmpty ? "离线素材" : report.title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(String(format: "%d × %d · 处理 %d 帧 · 时长 %.1f s",
                        Int(report.resolution.width), Int(report.resolution.height),
                        report.frames, report.duration))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 汇总

    private var summaryGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                            GridItem(.flexible(), spacing: 12)],
                  spacing: 12) {
            tile("平均帧率", String(format: "%.1f", report.meanFPS), "fps", .green)
            tile("最低 / 最高", String(format: "%.0f / %.0f", report.minFPS, report.maxFPS), "fps", .green)
            tile("平均帧耗时", String(format: "%.1f", report.meanFrameMillis), "ms", .teal)
            tile("平均分割耗时", String(format: "%.1f", report.meanInferenceMillis), "ms", .teal)
            tile("峰值内存", String(format: "%.0f", report.peakMemoryMB), "MB", .blue)
            tile("内存增长", String(format: "%+.0f", report.memoryGrowthMB), "MB", .blue)
            tile("平均 / 峰值 CPU", String(format: "%.0f / %.0f", report.meanCPU, report.peakCPU), "%", .orange)
            tile("最高热状态", report.maxThermalText, "", .red)
            if report.hasBattery {
                tile("电量 起→止", String(format: "%.0f%% → %.0f%%",
                                         report.batteryStart * 100, report.batteryEnd * 100), "", .yellow)
                tile("耗电速率",
                     report.drainPercentPerHour > 0
                        ? String(format: "%.1f", report.drainPercentPerHour) : "—",
                     "%/h", .yellow)
            }
        }
    }

    private func tile(_ title: String, _ value: String, _ unit: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 19, weight: .semibold).monospacedDigit())
                    .foregroundStyle(tint)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 图表

    private func chartCard<Content: View>(title: String,
                                          systemImage: String,
                                          tint: Color,
                                          @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
            content()
                .frame(height: 140)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var samples: [MetricSample] { report.samples }

    private var fpsChart: some View {
        // 30fps 是部署目标，画一条参考线便于一眼看出有没有守住预算
        Chart {
            RuleMark(y: .value("目标", 30.0))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .foregroundStyle(.secondary)
            ForEach(samples) { sample in
                LineMark(x: .value("时间", sample.time), y: .value("FPS", sample.fps))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.green)
            }
        }
        .chartYScale(domain: 0...max(32, report.maxFPS * 1.15))
        .chartXAxisLabel("秒")
    }

    private var memoryChart: some View {
        Chart(samples) { sample in
            LineMark(x: .value("时间", sample.time), y: .value("内存", sample.residentMB))
                .interpolationMethod(.monotone)
                .foregroundStyle(.blue)
            AreaMark(x: .value("时间", sample.time), y: .value("内存", sample.residentMB))
                .foregroundStyle(.blue.opacity(0.15))
        }
        .chartXAxisLabel("秒")
    }

    private var cpuChart: some View {
        Chart(samples) { sample in
            LineMark(x: .value("时间", sample.time), y: .value("CPU", sample.cpuPercent))
                .interpolationMethod(.monotone)
                .foregroundStyle(.orange)
        }
        .chartXAxisLabel("秒")
    }

    private var batteryChart: some View {
        Chart(samples) { sample in
            if sample.batteryLevel >= 0 {
                LineMark(x: .value("时间", sample.time),
                         y: .value("电量", sample.batteryLevel * 100))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.yellow)
            }
        }
        .chartXAxisLabel("秒")
    }

    private var thermalChart: some View {
        Chart(samples) { sample in
            LineMark(x: .value("时间", sample.time),
                     y: .value("档位", Double(sample.thermalLevel)))
                .interpolationMethod(.stepEnd)
                .foregroundStyle(.red)
        }
        .chartYScale(domain: 0.0...3.0)
        .chartYAxis {
            AxisMarks(values: [0.0, 1.0, 2.0, 3.0]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let level = value.as(Double.self) {
                        Text(ThermalLevel.text(Int(level)))
                            .font(.system(size: 9))
                    }
                }
            }
        }
        .chartXAxisLabel("秒")
    }

    // MARK: - 导出

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("处理后的视频", systemImage: "square.and.arrow.down")
                .font(.subheadline.weight(.semibold))

            if let url = processedVideoURL {
                Text(url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button(action: onSaveToPhotos) {
                    HStack {
                        if isSaving { ProgressView().tint(.white) }
                        Text(isSaving ? "正在保存…" : "保存到相册")
                            .font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving)
            } else {
                Text("本次没有录制处理结果（可在调试面板打开「保存处理后的视频」再跑一遍）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let saveMessage {
                Text(saveMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let csv = reportCSVURL {
                Divider()
                Label("报告明细 \(csv.lastPathComponent)", systemImage: "tablecells")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

#Preview {
    RunReportView(report: RunReport(title: "sample_whiteboard.mp4",
                                    resolution: CGSize(width: 1920, height: 1080),
                                    duration: 7.5,
                                    frames: 225,
                                    samples: (0..<15).map { index in
                                        MetricSample(time: Double(index) * 0.5,
                                                     fps: 30 - Double(index % 3),
                                                     frameMillis: 12,
                                                     inferenceMillis: 8,
                                                     residentMB: 180 + Double(index),
                                                     availableMB: 1200,
                                                     cpuPercent: 40 + Double(index),
                                                     thermalLevel: index > 10 ? 1 : 0,
                                                     batteryLevel: 0.8 - Double(index) * 0.002,
                                                     drainPercentPerHour: 6.5)
                                    }),
                  processedVideoURL: nil,
                  reportCSVURL: nil,
                  isSaving: false,
                  saveMessage: nil,
                  onSaveToPhotos: {},
                  onReplay: {},
                  onClose: {})
}
