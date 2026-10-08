import Foundation

/// 霍夫直线检测。替代上游对 OpenCV `Imgproc.HoughLines` 的调用（决策 D5）。
///
/// 参数与上游调用点保持一致：
///   rhoResolution 1.0、thetaResolution π/180、threshold 150、
///   rhoThreshold 15.0、thetaThreshold π/75（用于去重）
struct HoughLineDetector {
    struct Parameters {
        var rhoResolution: Float = 1.0
        var thetaResolution: Float = .pi / 180
        var threshold: Int = 150
        var maxLines: Int = 50
        var rhoThreshold: Float = 15.0
        var thetaThreshold: Float = .pi / 75

        static let upstreamDefault = Parameters()
    }

    /// - Parameter edges: RGBA8 边缘图（只用 r 通道，非 0 视为边缘）
    static func detect(edges: [UInt8],
                       width: Int,
                       height: Int,
                       parameters: Parameters = .upstreamDefault) -> [LineSegment] {
        guard width > 0, height > 0, edges.count >= width * height * 4 else { return [] }

        let diagonal = Int(ceil(sqrt(Double(width * width + height * height))))
        let rhoBins = Int(ceil(Double(2 * diagonal) / Double(parameters.rhoResolution))) + 1
        let thetaBins = max(Int(round(Double.pi / Double(parameters.thetaResolution))), 1)

        // theta 查表
        var cosTable = [Float](repeating: 0, count: thetaBins)
        var sinTable = [Float](repeating: 0, count: thetaBins)
        for t in 0..<thetaBins {
            let theta = Float(t) * parameters.thetaResolution
            cosTable[t] = cos(theta)
            sinTable[t] = sin(theta)
        }

        var accumulator = [UInt16](repeating: 0, count: rhoBins * thetaBins)
        let halfRho = Float(diagonal)

        for y in 0..<height {
            let rowBase = y * width * 4
            for x in 0..<width {
                guard edges[rowBase + x * 4] > 0 else { continue }   // 只看 r 通道
                let fx = Float(x), fy = Float(y)
                for t in 0..<thetaBins {
                    let rho = fx * cosTable[t] + fy * sinTable[t]
                    let bin = Int(round((rho + halfRho) / parameters.rhoResolution))
                    guard bin >= 0, bin < rhoBins else { continue }
                    let index = bin * thetaBins + t
                    if accumulator[index] < UInt16.max { accumulator[index] += 1 }
                }
            }
        }

        // 收集过阈值的峰值
        struct Peak { let rho: Float; let theta: Float; let votes: Int }
        var peaks: [Peak] = []
        for b in 0..<rhoBins {
            for t in 0..<thetaBins {
                let votes = Int(accumulator[b * thetaBins + t])
                guard votes >= parameters.threshold else { continue }
                peaks.append(Peak(rho: Float(b) * parameters.rhoResolution - halfRho,
                                  theta: Float(t) * parameters.thetaResolution,
                                  votes: votes))
            }
        }
        peaks.sort { $0.votes > $1.votes }

        // 去重（对应上游 findDistinctLines / isDistinct）
        var distinct: [Peak] = []
        for peak in peaks {
            let duplicate = distinct.contains { other in
                abs(other.rho - peak.rho) <= parameters.rhoThreshold
                    && abs(other.theta - peak.theta) <= parameters.thetaThreshold
            }
            if !duplicate {
                distinct.append(peak)
                if distinct.count >= parameters.maxLines { break }
            }
        }

        // (rho, theta) -> 两点式直线，构造方式与上游一致
        return distinct.map { peak in
            let directionX = cos(peak.theta)
            let directionY = sin(peak.theta)
            let x0 = directionX * peak.rho
            let y0 = directionY * peak.rho
            let reach: Float = 2000
            let p1 = SIMD2<Float>(x0 + reach * -directionY, y0 + reach * directionX)
            let p2 = SIMD2<Float>(x0 - reach * -directionY, y0 - reach * directionX)
            return LineSegment(p1, p2)
        }
    }
}
