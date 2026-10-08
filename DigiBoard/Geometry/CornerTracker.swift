import Foundation
import simd

/// 角点状态：只保留自动检测结果 + 平滑。
///
/// 需求变更：不做「拖动角点手动矫正」与「点击切换视图」两项交互，
/// 因此删除了手动模式、拖拽命中与重置逻辑，管线全自动运行。
final class CornerTracker {
    private(set) var autoCorners: [SIMD2<Float>]?

    private var smoother: PointSmoother?
    private let lock = NSLock()

    init(width: Float, height: Float) {
        // 尚未检测到白板时的兜底四角（内缩 100，横屏坐标系）
        let inset: Float = 100
        autoCorners = [
            SIMD2<Float>(inset, inset),
            SIMD2<Float>(inset, max(height - inset, inset)),
            SIMD2<Float>(max(width - inset, inset), max(height - inset, inset)),
            SIMD2<Float>(max(width - inset, inset), inset),
        ]
    }

    /// 当前四角，顺序 [topLeft, bottomLeft, bottomRight, topRight]，图像像素坐标
    var corners: [SIMD2<Float>] {
        lock.lock(); defer { lock.unlock() }
        return autoCorners ?? []
    }

    /// 自动检测结果（已平滑）；nil 表示本帧没有检测到，沿用上一次结果
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
