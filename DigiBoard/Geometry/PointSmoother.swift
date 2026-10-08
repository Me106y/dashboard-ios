import simd

/// 加权滑动平均角点平滑。对应上游 `WeightedMovingAveragePointsStage`。
///
/// 权重规则与上游一致：离均值很近（<0.01）的点给 100 倍权重，其余按距离倒数加权，
/// 用于抑制抖动同时保留快速跟随。
final class PointSmoother {
    private let historySize: Int
    private var histories: [[SIMD2<Float>]]
    private var index = 0

    init(initial: [SIMD2<Float>], historySize: Int = 20) {
        self.historySize = historySize
        self.histories = Array(repeating: initial, count: 4).map { corner in
            Array(repeating: corner[0], count: historySize)
        }
        for corner in 0..<4 {
            histories[corner] = Array(repeating: initial[corner], count: historySize)
        }
    }

    func reset(_ points: [SIMD2<Float>]) {
        for corner in 0..<4 {
            histories[corner] = Array(repeating: points[corner], count: historySize)
        }
        index = 0
    }

    func smooth(_ input: [SIMD2<Float>]) -> [SIMD2<Float>] {
        guard input.count == 4 else { return input }
        for corner in 0..<4 {
            histories[corner][index] = input[corner]
        }
        index = (index + 1) % historySize
        return (0..<4).map { weightedAverage(histories[$0]) }
    }

    private func weightedAverage(_ history: [SIMD2<Float>]) -> SIMD2<Float> {
        let count = Float(history.count)
        let mean = history.reduce(SIMD2<Float>.zero, +) / count

        var weightSum: Float = 0
        var sum = SIMD2<Float>.zero
        for point in history {
            let distance = Geometry.distance(point, mean)
            let weight: Float = distance <= 0.01 ? 100 : 1.0 / max(distance, 1e-6)
            sum += point * weight
            weightSum += weight
        }
        let result = sum / max(weightSum, 1e-6)
        return SIMD2<Float>(result.x.rounded(), result.y.rounded())
    }
}
