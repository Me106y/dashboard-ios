import Foundation
import simd

/// 角点状态机：在「自动检测」与「手动拖动」两种模式间切换，
/// 对应上游 `SwitchablePointPipeline`（决策 D14：模式由显式控件切换，不再藏在手势里）。
final class CornerTracker {
    enum Mode: String, CaseIterable {
        case auto    = "自动"
        case manual  = "手动"
    }

    private(set) var mode: Mode = .auto
    private(set) var manualCorners: [SIMD2<Float>]
    private(set) var autoCorners: [SIMD2<Float>]?

    private var smoother: PointSmoother?
    private let lock = NSLock()

    init(width: Float, height: Float) {
        // 与上游 DraggablePointsStage 的初始点一致（内缩 100，横屏坐标系）
        let inset: Float = 100
        manualCorners = [
            SIMD2<Float>(inset, inset),                       // topLeft
            SIMD2<Float>(inset, height - inset),              // bottomLeft
            SIMD2<Float>(width - inset, height - inset),      // bottomRight
            SIMD2<Float>(width - inset, inset),               // topRight
        ]
    }

    /// 当前生效的四角：顺序为 [topLeft, bottomLeft, bottomRight, topRight]，图像像素坐标
    var corners: [SIMD2<Float>] {
        lock.lock(); defer { lock.unlock() }
        if mode == .manual { return manualCorners }
        return autoCorners ?? manualCorners
    }

    func setMode(_ newMode: Mode) {
        lock.lock(); defer { lock.unlock() }
        if newMode == .auto, autoCorners == nil {
            // 自动模式还没有结果时，从当前手动角点重新起步，避免跳变
            autoCorners = manualCorners
        }
        mode = newMode
    }

    func resetManual(width: Float, height: Float) {
        lock.lock(); defer { lock.unlock() }
        let inset: Float = 100
        manualCorners = [
            SIMD2<Float>(inset, inset),
            SIMD2<Float>(inset, height - inset),
            SIMD2<Float>(width - inset, height - inset),
            SIMD2<Float>(width - inset, inset),
        ]
        smoother?.reset(manualCorners)
    }

    /// 拖动最近的那个角点（对应上游 `DraggablePointsStage.dragPoint`）
    func dragCorner(near position: SIMD2<Float>, radius: Float = 140) {
        lock.lock(); defer { lock.unlock() }
        mode = .manual

        var closestIndex = -1
        var closestDistance = Float.greatestFiniteMagnitude
        for (index, point) in manualCorners.enumerated() {
            let distance = Geometry.distance(point, position)
            if distance < closestDistance {
                closestDistance = distance
                closestIndex = index
            }
        }
        guard closestIndex >= 0, closestDistance <= radius else { return }
        manualCorners[closestIndex] = position
    }

    /// 自动检测结果（已平滑）；nil 表示本帧没有检测到
    func updateAuto(_ detected: [SIMD2<Float>]?) {
        lock.lock(); defer { lock.unlock() }
        guard let detected, detected.count == 4 else { return }
        if smoother == nil {
            smoother = PointSmoother(initial: detected, historySize: 20)
            autoCorners = detected
        } else {
            autoCorners = smoother?.smooth(detected)
        }
    }
}
