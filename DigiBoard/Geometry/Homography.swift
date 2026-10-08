import simd

/// 单应矩阵求解（替代上游对 OpenCV `getPerspectiveTransform` 的依赖）。
///
/// 我们的透视校正做法比上游更直接：一次性解出「目标归一化坐标 → 源归一化坐标」的
/// 3×3 矩阵，片元着色器逐像素做查表即可，不需要上游那套伪深度顶点插值。
enum Homography {
    /// - Parameters:
    ///   - destination: 目标空间四点（一般取 (0,0),(1,0),(1,1),(0,1)）
    ///   - source: 源空间四点（白板四角在源纹理 uv 空间中的位置）
    /// - Returns: 3×3 矩阵 M，使 M·[dest,1] ∝ [source,1]；无解返回 nil
    static func solve(destination: [SIMD2<Float>], source: [SIMD2<Float>]) -> simd_float3x3? {
        guard destination.count == 4, source.count == 4 else { return nil }

        // 8x8 线性方程组：A · h = b
        var A = [[Double]](repeating: [Double](repeating: 0, count: 8), count: 8)
        var b = [Double](repeating: 0, count: 8)

        for i in 0..<4 {
            let x = Double(destination[i].x), y = Double(destination[i].y)
            let u = Double(source[i].x), v = Double(source[i].y)

            A[i * 2] = [x, y, 1, 0, 0, 0, -x * u, -y * u]
            b[i * 2] = u
            A[i * 2 + 1] = [0, 0, 0, x, y, 1, -x * v, -y * v]
            b[i * 2 + 1] = v
        }

        guard let h = solveLinearSystem(A, b) else { return nil }

        return simd_float3x3(columns: (
            SIMD3<Float>(Float(h[0]), Float(h[3]), Float(h[6])),
            SIMD3<Float>(Float(h[1]), Float(h[4]), Float(h[7])),
            SIMD3<Float>(Float(h[2]), Float(h[5]), 1.0)
        ))
    }

    /// 高斯消元（带部分主元）
    private static func solveLinearSystem(_ matrix: [[Double]], _ rhs: [Double]) -> [Double]? {
        var a = matrix
        var b = rhs
        let n = b.count

        for column in 0..<n {
            var pivot = column
            for row in (column + 1)..<n where abs(a[row][column]) > abs(a[pivot][column]) {
                pivot = row
            }
            guard abs(a[pivot][column]) > 1e-12 else { return nil }
            if pivot != column {
                a.swapAt(pivot, column)
                b.swapAt(pivot, column)
            }
            let diagonal = a[column][column]
            for row in (column + 1)..<n {
                let factor = a[row][column] / diagonal
                guard factor != 0 else { continue }
                for k in column..<n { a[row][k] -= factor * a[column][k] }
                b[row] -= factor * b[column]
            }
        }

        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = b[row]
            for k in (row + 1)..<n { sum -= a[row][k] * x[k] }
            x[row] = sum / a[row][row]
        }
        return x
    }
}
