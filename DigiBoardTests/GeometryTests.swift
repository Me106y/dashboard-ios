import XCTest
import simd
@testable import DigiBoard

/// 纯逻辑单元测试（决策 D14 延伸：只测几何 / 单应 / 纹理池，着色器靠逐级调试视图人工验证）
final class GeometryTests: XCTestCase {

    // MARK: - 单应矩阵

    /// 目标 uv 四角 → 源空间任意四边形，再用矩阵反查四个角，必须回到原点
    func testHomographyRoundTripOnCorners() throws {
        let destination: [SIMD2<Float>] = [
            SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1),
        ]
        let source: [SIMD2<Float>] = [
            SIMD2(0.2, 0.1), SIMD2(0.9, 0.2), SIMD2(0.8, 0.85), SIMD2(0.1, 0.75),
        ]

        let matrix = try XCTUnwrap(Homography.solve(destination: destination, source: source))

        for (index, expected) in source.enumerated() {
            let p = SIMD3<Float>(destination[index].x, destination[index].y, 1)
            let q = matrix * p
            let actual = SIMD2<Float>(q.x / q.z, q.y / q.z)
            XCTAssertEqual(actual.x, expected.x, accuracy: 1e-3, "角点 \(index) x 不匹配")
            XCTAssertEqual(actual.y, expected.y, accuracy: 1e-3, "角点 \(index) y 不匹配")
        }
    }

    /// 单位映射（目标与源相同）应当得到单位矩阵的效果
    func testHomographyIdentity() throws {
        let corners: [SIMD2<Float>] = [
            SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1),
        ]
        let matrix = try XCTUnwrap(Homography.solve(destination: corners, source: corners))
        let p = SIMD3<Float>(0.3, 0.7, 1)
        let q = matrix * p
        XCTAssertEqual(q.x / q.z, 0.3, accuracy: 1e-4)
        XCTAssertEqual(q.y / q.z, 0.7, accuracy: 1e-4)
    }

    // MARK: - 最大四边形

    /// 已知矩形：应当被识别，并按 [TL, BL, BR, TR] 重排
    func testBiggestQuadFindsRectangle() throws {
        // 两条水平线 y=10 / y=90，两条竖直线 x=20 / x=120
        let horizontal = [LineSegment(SIMD2(0, 10), SIMD2(200, 10)),
                          LineSegment(SIMD2(0, 90), SIMD2(200, 90))]
        let vertical = [LineSegment(SIMD2(20, 0), SIMD2(20, 200)),
                        LineSegment(SIMD2(120, 0), SIMD2(120, 200))]

        let quad = try XCTUnwrap(BiggestQuadFinder.find(horizontal: horizontal,
                                                       vertical: vertical,
                                                       fallback: []))
        XCTAssertEqual(quad.count, 4)
        XCTAssertEqual(quad[0].x, 20, accuracy: 0.5)   // topLeft
        XCTAssertEqual(quad[0].y, 10, accuracy: 0.5)
        XCTAssertEqual(quad[2].x, 120, accuracy: 0.5)  // bottomRight
        XCTAssertEqual(quad[2].y, 90, accuracy: 0.5)
        XCTAssertEqual(quad[1].x, 20, accuracy: 0.5)   // bottomLeft
        XCTAssertEqual(quad[3].x, 120, accuracy: 0.5)  // topRight
    }

    /// 角度不合理的四边形（例如极端平行四边形）应当被拒绝
    func testQuadRejectsBadAngles() {
        let degenerate = Quad(a: SIMD2(0, 0), b: SIMD2(10, 1), c: SIMD2(210, 0), d: SIMD2(200, -1))
        XCTAssertFalse(BiggestQuadFinder.isReasonable(degenerate))
    }

    /// 直线交点（含平行情形）
    func testLineIntersection() {
        let a = LineSegment(SIMD2(0, 0), SIMD2(10, 10))
        let b = LineSegment(SIMD2(0, 10), SIMD2(10, 0))
        let point = a.intersect(b)
        XCTAssertEqual(point?.x ?? -1, 5, accuracy: 1e-4)
        XCTAssertEqual(point?.y ?? -1, 5, accuracy: 1e-4)

        let parallel = LineSegment(SIMD2(0, 0), SIMD2(10, 0))
        let parallel2 = LineSegment(SIMD2(0, 5), SIMD2(10, 5))
        XCTAssertNil(parallel.intersect(parallel2))
    }

    // MARK: - 霍夫直线

    /// 在合成边缘图上画一条水平长线，应当被检测出来
    func testHoughDetectsHorizontalLine() {
        let width = 160, height = 100
        var edges = [UInt8](repeating: 0, count: width * height * 4)
        for x in 10..<150 {
            let index = (50 * width + x) * 4
            edges[index] = 255
        }

        var parameters = HoughLineDetector.Parameters.upstreamDefault
        parameters.threshold = 60     // 合成图线长 140，降低阈值以适配测试尺寸
        let lines = HoughLineDetector.detect(edges: edges, width: width, height: height,
                                             parameters: parameters)

        XCTAssertFalse(lines.isEmpty, "应当至少检出一条直线")
        // 检出的直线里应有一条接近水平（角度接近 0 或 π）
        let hasHorizontal = lines.contains { line in
            let angle = abs(line.angle)
            return angle < 0.1 || abs(angle - .pi) < 0.1
        }
        XCTAssertTrue(hasHorizontal, "应当检出一条接近水平的直线")
    }

    /// 空白边缘图不应产生任何直线
    func testHoughOnEmptyImage() {
        let edges = [UInt8](repeating: 0, count: 64 * 64 * 4)
        let lines = HoughLineDetector.detect(edges: edges, width: 64, height: 64)
        XCTAssertTrue(lines.isEmpty)
    }

    /// 角度判别：接近水平的线落在 A 区间、接近竖直的线落在 B 区间
    func testAngleDiscrimination() {
        let horizontal = LineSegment(SIMD2(0, 0), SIMD2(100, 5))
        let vertical = LineSegment(SIMD2(0, 0), SIMD2(5, 100))
        XCTAssertTrue(horizontal.matchesAngleRange(min: -.pi / 4, max: .pi / 4))
        XCTAssertFalse(horizontal.matchesAngleRange(min: .pi / 4, max: 3 * .pi / 4))
        XCTAssertTrue(vertical.matchesAngleRange(min: .pi / 4, max: 3 * .pi / 4))
    }

    // MARK: - 角点平滑

    /// 静态输入下平滑结果应当收敛到该值
    func testSmootherConverges() {
        let target: [SIMD2<Float>] = [
            SIMD2(10, 20), SIMD2(10, 80), SIMD2(90, 80), SIMD2(90, 20),
        ]
        let smoother = PointSmoother(initial: target, historySize: 20)
        var result = target
        for _ in 0..<40 { result = smoother.smooth(target) }
        for index in 0..<4 {
            XCTAssertEqual(result[index].x, target[index].x, accuracy: 1.0)
            XCTAssertEqual(result[index].y, target[index].y, accuracy: 1.0)
        }
    }

    // MARK: - 着色器参数内存布局

    /// Swift 结构体必须与 .metal 中的定义逐字节一致，否则 uniform 会错位
    func testShaderParamsLayoutMatchesMetal() {
        XCTAssertEqual(MemoryLayout<GaussianParams>.size, 40,
                       "GaussianParams 必须与 Filters.metal 的 6×float + 2×float2 对齐")
        XCTAssertEqual(MemoryLayout<CannyParams>.size, 16,
                       "CannyParams 必须与 Filters.metal 的 2×float + float2 对齐")
    }
}
