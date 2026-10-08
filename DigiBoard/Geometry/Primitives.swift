import simd

/// 由两点确定的直线。对应上游 `utils/LineFloat.kt`。
struct LineSegment {
    let start: SIMD2<Float>
    let end: SIMD2<Float>

    init(_ start: SIMD2<Float>, _ end: SIMD2<Float>) {
        self.start = start
        self.end = end
    }

    /// 与上游 `LineFloat.intersect` 完全一致：解 a1x+b1y=c1 与 a2x+b2y=c2。
    func intersect(_ other: LineSegment) -> SIMD2<Float>? {
        let a = start, b = end, c = other.start, d = other.end

        let a1 = b.y - a.y
        let b1 = a.x - b.x
        let c1 = a1 * a.x + b1 * a.y

        let a2 = d.y - c.y
        let b2 = c.x - d.x
        let c2 = a2 * c.x + b2 * c.y

        let determinant = a1 * b2 - a2 * b1
        if determinant == 0 { return nil }   // 平行

        let x = (b2 * c1 - b1 * c2) / determinant
        let y = (a1 * c2 - a2 * c1) / determinant
        return SIMD2<Float>(x, y)
    }

    /// 与 x 轴正方向的夹角，范围 (-π, π]
    var angle: Float { atan2(end.y - start.y, end.x - start.x) }

    /// 角度是否落在 [minAngle, maxAngle] 的任一 2π 等价区间内（对应上游 LinesAngleDiscriminatorStage）
    func matchesAngleRange(min minAngle: Float, max maxAngle: Float) -> Bool {
        let theta = angle
        let twoPi = Float.pi * 2
        return (theta >= minAngle && theta <= maxAngle)
            || (theta >= minAngle + .pi && theta <= maxAngle + .pi)
            || (theta >= minAngle - .pi && theta <= maxAngle - .pi)
            || (theta >= minAngle + twoPi && theta <= maxAngle + twoPi)
    }
}

/// 四边形。对应上游 `utils/QuadFloat.kt`。
struct Quad {
    var a: SIMD2<Float>
    var b: SIMD2<Float>
    var c: SIMD2<Float>
    var d: SIMD2<Float>

    var points: [SIMD2<Float>] { [a, b, c, d] }

    /// 面积 = 两个三角形面积之和（与上游一致）
    var area: Float {
        Geometry.areaOfTriangle(a, b, c) + Geometry.areaOfTriangle(a, c, d)
    }
}

enum Geometry {
    /// 与上游 `areaOfTriangle` 完全一致
    static func areaOfTriangle(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Float {
        abs((a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y)) / 2.0)
    }

    static func distance(_ p: SIMD2<Float>, _ q: SIMD2<Float>) -> Float {
        simd_length(q - p)
    }
}
