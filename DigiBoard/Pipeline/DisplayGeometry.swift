import CoreGraphics
import simd

/// 计算「源纹理 → drawable」的等比适配矩形，并提供坐标换算。
enum DisplayGeometry {
    /// 归一化目标矩形（原点左下，与 NDC 一致）
    static func fitRect(sourceSize: CGSize, drawableSize: CGSize, inset: CGFloat = 0) -> CGRect {
        guard sourceSize.width > 0, sourceSize.height > 0,
              drawableSize.width > 0, drawableSize.height > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        let availableWidth = drawableSize.width * (1 - inset * 2)
        let availableHeight = drawableSize.height * (1 - inset * 2)
        let scale = min(availableWidth / sourceSize.width, availableHeight / sourceSize.height)

        let width = sourceSize.width * scale / drawableSize.width
        let height = sourceSize.height * scale / drawableSize.height
        return CGRect(x: 0.5 - width / 2, y: 0.5 - height / 2, width: width, height: height)
    }

    /// 归一化矩形内的 (u, v)（原点左上，0..1）→ NDC
    static func toNDC(u: Float, v: Float, in rect: CGRect) -> SIMD2<Float> {
        let x = Float(rect.minX) + u * Float(rect.width)
        // 归一化矩形原点在左下，而 uv 的原点在左上，需要翻转 v
        let y = Float(rect.minY) + (1 - v) * Float(rect.height)
        return SIMD2<Float>(x * 2 - 1, y * 2 - 1)
    }

    /// 相机像素坐标 → NDC
    static func toNDC(point: SIMD2<Float>, sourceSize: CGSize, in rect: CGRect) -> SIMD2<Float> {
        let u = Float(point.x) / Float(sourceSize.width)
        let v = Float(point.y) / Float(sourceSize.height)
        return toNDC(u: u, v: v, in: rect)
    }
}
