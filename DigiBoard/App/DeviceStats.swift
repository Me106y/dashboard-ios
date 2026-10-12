import Foundation
import UIKit

#if canImport(os)
import os
#endif

/// 运行时资源采样：内存 / 热状态 / 电量 / CPU。
///
/// 目的：在测 FPS 的同时，把移动端部署关心的 memory、thermal、energy 一并采下来，
/// 便于跑长时程压测（30–60 min）时观察 FPS 漂移、内存增长与热降频。
///
/// iOS 没有公开的「单进程能耗」接口，这里用三个可测代理量表示 energy：
///   - `batteryDrainPercentPerHour`：整机电量下降速率（需长时程才有意义）；
///   - `thermalState`：系统热压力档位（nominal / fair / serious / critical）；
///   - `cpuPercent`：本进程 CPU 占用（能耗的主要来源）。
final class DeviceStats {

    struct Sample {
        /// 本进程常驻内存（MB）
        var residentMB: Double = 0
        /// 设备物理内存总量（MB）
        var totalMemoryMB: Double = 0
        /// 系统允许本进程继续申请的可用内存（MB）；不可用时为 -1
        var availableMB: Double = -1
        /// 进程累计 CPU 时间（user + system，秒）
        var cpuSeconds: Double = 0
        /// 自上次采样以来的进程 CPU 占用（%）
        var cpuPercent: Double = 0
        var thermalState: ProcessInfo.ThermalState = .nominal
        /// -1 表示不可用（模拟器或未开启电量监控）
        var batteryLevel: Float = -1
        var batteryState: UIDevice.BatteryState = .unknown
        /// 整机耗电速率（%/小时）；样本不足或不可用时为 -1
        var batteryDrainPercentPerHour: Double = -1
    }

    private(set) var latest = Sample()

    private var lastCPUSeconds: Double = -1
    private var lastSampleTime: CFTimeInterval = 0
    private var firstBatteryLevel: Float = -1
    private var firstBatteryTime: CFTimeInterval = 0

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    var thermalStateText: String {
        switch latest.thermalState {
        case .nominal:  return "正常"
        case .fair:     return "偏热"
        case .serious:  return "过热降频"
        case .critical: return "严重过热"
        @unknown default: return "未知"
        }
    }

    /// 采样一次；建议挂在 0.5–1 s 的统计轮询里调用。
    @discardableResult
    func sample() -> Sample {
        let now = CACurrentMediaTime()
        var s = Sample()
        s.residentMB = Self.residentMemoryMB()
        s.totalMemoryMB = Double(ProcessInfo.processInfo.physicalMemory) / 1024 / 1024
        s.availableMB = Self.availableMemoryMB()
        s.cpuSeconds = Self.cpuSeconds()

        if lastCPUSeconds >= 0, now > lastSampleTime {
            let wall = now - lastSampleTime
            s.cpuPercent = max(0, (s.cpuSeconds - lastCPUSeconds) / wall * 100)
        }
        lastCPUSeconds = s.cpuSeconds
        lastSampleTime = now

        s.thermalState = ProcessInfo.processInfo.thermalState

        let level = UIDevice.current.batteryLevel
        s.batteryLevel = level
        s.batteryState = UIDevice.current.batteryState
        if level >= 0 {
            if firstBatteryLevel < 0 {
                firstBatteryLevel = level
                firstBatteryTime = now
            } else {
                let hours = (now - firstBatteryTime) / 3600
                // 至少累计 ~3 分钟，否则电量分辨率的噪声会淹没信号
                if hours > 0.05 {
                    s.batteryDrainPercentPerHour =
                        Double(firstBatteryLevel - level) / hours * 100
                }
            }
        }

        latest = s
        return s
    }

    // MARK: - 底层取值

    /// 本进程常驻内存（resident size，MB）。
    static func residentMemoryMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_,
                          task_flavor_t(MACH_TASK_BASIC_INFO),
                          $0,
                          &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / 1024 / 1024
    }

    /// 进程累计 CPU 时间（user + system，秒）。
    static func cpuSeconds() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_,
                          task_flavor_t(MACH_TASK_BASIC_INFO),
                          $0,
                          &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let user = Double(info.user_time.seconds)
            + Double(info.user_time.microseconds) / 1_000_000
        let system = Double(info.system_time.seconds)
            + Double(info.system_time.microseconds) / 1_000_000
        return user + system
    }

    /// 系统认为本进程还能申请的可用内存（MB）；不可用时返回 -1。
    static func availableMemoryMB() -> Double {
        #if canImport(os)
        let bytes = os_proc_available_memory()
        return bytes > 0 ? Double(bytes) / 1024 / 1024 : -1
        #else
        return -1
        #endif
    }
}
