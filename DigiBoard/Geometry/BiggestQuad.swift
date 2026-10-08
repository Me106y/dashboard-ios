import simd

/// 从横 / 竖两组直线中找出最大的、透视可校正的四边形。
/// 对应上游 `BiggestQuadStage`（含 `fixupQuad` / `makeQuadConvex` / `isQuadReasonable`）。
enum BiggestQuadFinder {
    struct Result {
        var quad: Quad
        var area: Float
    }

    /// 角点顺序约定（图像坐标 y 向下，与 Metal 一致）：
    /// [0] topLeft, [1] bottomLeft, [2] bottomRight, [3] topRight
    static func find(horizontal: [LineSegment],
                     vertical: [LineSegment],
                     fallback: [SIMD2<Float>]) -> [SIMD2<Float>]? {
        var biggest: Quad?
        var biggestArea: Float = 0

        for i in 0..<horizontal.count {
            for j in (i + 1)..<horizontal.count {
                for k in 0..<vertical.count {
                    for l in (k + 1)..<vertical.count {
                        guard let p1 = horizontal[i].intersect(vertical[k]),
                              let p2 = horizontal[i].intersect(vertical[l]),
                              let p3 = horizontal[j].intersect(vertical[k]),
                              let p4 = horizontal[j].intersect(vertical[l]) else { continue }

                        let quad = makeConvex(Quad(a: p1, b: p2, c: p3, d: p4))
                        let area = quad.area
                        if area > biggestArea {
                            biggestArea = area
                            biggest = quad
                        }
                    }
                }
            }
        }

        guard let rawQuad = biggest, biggestArea > 0 else { return nil }
        // 与上游一致：先判断是否"合理"，再重排角点顺序
        guard isReasonable(rawQuad) else { return nil }
        return fixup(rawQuad).points
    }

    /// 角点角度必须落在 60°~130°（对应上游 isQuadReasonable）
    static func isReasonable(_ quad: Quad) -> Bool {
        let minAngle = Float(60.0 * Double.pi / 180.0)
        let maxAngle = Float(130.0 * Double.pi / 180.0)
        func check(_ center: SIMD2<Float>, _ before: SIMD2<Float>, _ after: SIMD2<Float>) -> Bool {
            let angle = angleBetween(center, before, after)
            return angle >= minAngle && angle <= maxAngle
        }
        return check(quad.a, quad.d, quad.b)
            && check(quad.b, quad.a, quad.c)
            && check(quad.c, quad.b, quad.d)
            && check(quad.d, quad.c, quad.a)
    }

    static func angleBetween(_ center: SIMD2<Float>, _ before: SIMD2<Float>, _ after: SIMD2<Float>) -> Float {
        let v1 = center - before
        let v2 = center - after
        let denominator = simd_length(v1) * simd_length(v2)
        guard denominator > 0 else { return 0 }
        return acos(simd_clamp(simd_dot(v1, v2) / denominator, -1, 1))
    }

    /// 重排为 [topLeft, bottomLeft, bottomRight, topRight]。
    /// 上游用的是 y 向上的坐标系，这里换成 y 向下的图像坐标，判据相应镜像。
    static func fixup(_ quad: Quad) -> Quad {
        var points = quad.points

        func take(_ predicate: (SIMD2<Float>, SIMD2<Float>) -> Bool) -> SIMD2<Float> {
            var best = points[0]
            for p in points where predicate(p, best) { best = p }
            points.removeAll { $0 == best }
            return best
        }

        let topLeft = take { $0.x + $0.y < $1.x + $1.y }
        let bottomRight = take { $0.x + $0.y > $1.x + $1.y }
        let topRight = take { $0.x - $0.y > $1.x - $1.y }
        let bottomLeft = points[0]

        return Quad(a: topLeft, b: bottomLeft, c: bottomRight, d: topRight)
    }

    /// 对应上游 makeQuadConvex：从首点出发依次取最近点，形成不自交的环
    static func makeConvex(_ quad: Quad) -> Quad {
        var points = quad.points
        let a = points.removeFirst()
        let b = takeClosest(to: a, from: &points)
        let c = takeClosest(to: b, from: &points)
        let d = points[0]
        return Quad(a: a, b: b, c: c, d: d)
    }

    private static func takeClosest(to point: SIMD2<Float>, from points: inout [SIMD2<Float>]) -> SIMD2<Float> {
        var bestIndex = 0
        var bestDistance = Float.greatestFiniteMagnitude
        for (index, other) in points.enumerated() {
            let distance = Geometry.distance(point, other)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        return points.remove(at: bestIndex)
    }
}
