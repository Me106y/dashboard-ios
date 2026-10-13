import CoreGraphics
import Foundation
import QuartzCore

/// 调试模式的一次运行报告：整个播放过程里的资源采样序列 + 汇总统计。
///
/// 采样来源就是「实时视频 / 离线视频」共用的那条 0.5s 轮询（`DeviceStats` + `FrameStats`），
/// 调试模式下多走一步：把每次采样存进 `RunRecorder`，放完后既出汇总数字，也出折线图。
struct MetricSample: Identifiable {
    let id = UUID()
    /// 相对本次运行开始的时间（秒）
    let time: Double
    /// 当前帧率（由帧间隔滚动算出）
    let fps: Double
    /// 上一帧的管线 CPU 耗时（ms）
    let frameMillis: Double
    /// 最近一次分割推理耗时（ms）
    let inferenceMillis: Double
    let residentMB: Double
    let availableMB: Double
    let cpuPercent: Double
    /// 热压力档位：0 正常 / 1 偏热 / 2 过热降频 / 3 严重过热
    let thermalLevel: Int
    /// 电量 0…1，不可用时为 -1
    let batteryLevel: Double
    /// 整机耗电速率（%/小时），样本不足时为 -1
    let drainPercentPerHour: Double
}

/// `ProcessInfo.ThermalState` ↔ 档位 / 文案（报告与图表共用一套口径）。
enum ThermalLevel {
    static func level(of state: ProcessInfo.ThermalState) -> Int {
        switch state {
        case .nominal:  return 0
        case .fair:     return 1
        case .serious:  return 2
        case .critical: return 3
        @unknown default: return 0
        }
    }

    static func text(_ level: Int) -> String {
        switch level {
        case 0:  return "正常"
        case 1:  return "偏热"
        case 2:  return "过热降频"
        case 3:  return "严重过热"
        default: return "未知"
        }
    }
}

struct RunReport {
    /// 素材文件名
    let title: String
    let resolution: CGSize
    /// 本次运行时长（秒），取最后一条采样的时间
    let duration: Double
    /// 实际解码并送进管线的帧数
    let frames: Int
    let samples: [MetricSample]

    // MARK: - 汇总

    private var fpsValues: [Double] { samples.map(\.fps).filter { $0 > 0 } }

    var meanFPS: Double { Self.average(fpsValues) }
    var minFPS: Double { fpsValues.min() ?? 0 }
    var maxFPS: Double { fpsValues.max() ?? 0 }
    var p5FPS: Double { Self.percentile(fpsValues, 0.05) }

    var meanFrameMillis: Double { Self.average(samples.map(\.frameMillis).filter { $0 > 0 }) }
    var meanInferenceMillis: Double { Self.average(samples.map(\.inferenceMillis).filter { $0 > 0 }) }

    var startMemoryMB: Double { samples.first?.residentMB ?? 0 }
    var endMemoryMB: Double { samples.last?.residentMB ?? 0 }
    var peakMemoryMB: Double { samples.map(\.residentMB).max() ?? 0 }
    var memoryGrowthMB: Double { endMemoryMB - startMemoryMB }

    var meanCPU: Double { Self.average(samples.map(\.cpuPercent)) }
    var peakCPU: Double { samples.map(\.cpuPercent).max() ?? 0 }

    var maxThermalLevel: Int { samples.map(\.thermalLevel).max() ?? 0 }
    var maxThermalText: String { ThermalLevel.text(maxThermalLevel) }

    /// 电量不可用（模拟器）时为 -1
    var batteryStart: Double { samples.first(where: { $0.batteryLevel >= 0 })?.batteryLevel ?? -1 }
    var batteryEnd: Double { samples.last(where: { $0.batteryLevel >= 0 })?.batteryLevel ?? -1 }
    var drainPercentPerHour: Double { samples.last(where: { $0.drainPercentPerHour > 0 })?.drainPercentPerHour ?? -1 }
    var hasBattery: Bool { samples.contains { $0.batteryLevel >= 0 } }

    /// 直接落盘用的 CSV（与脚本侧 `eval_restoration_video.py` 的明细表同风格）
    func csv() -> String {
        var lines = ["time_s,fps,frame_ms,inference_ms,resident_mb,available_mb,cpu_percent,thermal,battery_level"]
        for sample in samples {
            lines.append(String(format: "%.2f,%.2f,%.2f,%.2f,%.1f,%.1f,%.1f,%d,%.3f",
                                sample.time, sample.fps, sample.frameMillis, sample.inferenceMillis,
                                sample.residentMB, sample.availableMB, sample.cpuPercent,
                                sample.thermalLevel, sample.batteryLevel))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 小工具

    static func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    /// 线性插值分位数（与 `eval_restoration_video.py` 的口径一致，便于两张表对照）
    static func percentile(_ values: [Double], _ q: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        guard sorted.count > 1 else { return sorted[0] }
        let position = q * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let fraction = position - Double(lower)
        return sorted[lower] * (1 - fraction) + sorted[upper] * fraction
    }
}

/// 运行期间把每次轮询采样攒起来，放完后生成 `RunReport`。
final class RunRecorder {
    private(set) var samples: [MetricSample] = []
    private(set) var isRecording = false
    private var startTime: CFTimeInterval = 0

    func start() {
        samples.removeAll()
        startTime = CACurrentMediaTime()
        isRecording = true
    }

    func stop() {
        isRecording = false
    }

    func append(fps: Double,
                frameMillis: Double,
                inferenceMillis: Double,
                residentMB: Double,
                availableMB: Double,
                cpuPercent: Double,
                thermal: ProcessInfo.ThermalState,
                batteryLevel: Double,
                drainPercentPerHour: Double) {
        guard isRecording else { return }
        samples.append(MetricSample(time: CACurrentMediaTime() - startTime,
                                    fps: fps,
                                    frameMillis: frameMillis,
                                    inferenceMillis: inferenceMillis,
                                    residentMB: residentMB,
                                    availableMB: availableMB,
                                    cpuPercent: cpuPercent,
                                    thermalLevel: ThermalLevel.level(of: thermal),
                                    batteryLevel: batteryLevel,
                                    drainPercentPerHour: drainPercentPerHour))
    }

    func makeReport(title: String, resolution: CGSize, frames: Int) -> RunReport {
        RunReport(title: title,
                  resolution: resolution,
                  duration: samples.last?.time ?? 0,
                  frames: frames,
                  samples: samples)
    }
}
