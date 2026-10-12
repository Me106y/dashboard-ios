import CoreGraphics
import Foundation

/// 恢复质量指标：在 iOS 侧对「恢复后的白板帧」与「无遮挡参考帧」做全参考比较。
///
/// 和 PaddleSeg 侧那套指标的区别（两者不能混用）：
///   - `paddleseg/utils/restoration_metrics.py` 算的是**分割掩膜**上的 PSNR / SSIM，
///     衡量的是分割质量；
///   - 这里算的是**恢复后的图像**对**干净参考图**的 PSNR / SSIM，衡量的是最终恢复
///     效果 —— 也就是论文里「加强最终恢复效果评价」真正要的那组数。
///
/// 前提：参考帧必须是**同一机位、presenter 进场前的干净白板**（论文给 OCR 做
/// baseline 时拍的那张即可）。两图尺寸不同时，会把 `restored` 缩放对齐到参考帧尺寸。
///
/// 纯计算，不依赖 Metal / 摄像头，任何两个 `CGImage` 都能直接跑。
enum RestorationMetrics {

    struct Result {
        /// 峰值信噪比（dB）；两图完全一致时封顶 100
        var psnr: Double
        /// 结构相似度（亮度通道，11×11 高斯窗 σ=1.5）
        var ssim: Double
        var width: Int
        var height: Int
        /// 两图逐像素平均绝对差（0…255），便于快速判断差异量级
        var meanAbsDiff: Double
    }

    static func evaluate(reference: CGImage, restored: CGImage) -> Result? {
        let width = reference.width
        let height = reference.height
        guard width > 0, height > 0 else { return nil }
        guard let refLuma = luma(reference, width: width, height: height),
              let resLuma = luma(restored, width: width, height: height) else {
            return nil
        }
        return Result(psnr: psnr(refLuma, resLuma),
                      ssim: ssim(refLuma, resLuma, width: width, height: height),
                      width: width,
                      height: height,
                      meanAbsDiff: meanAbsDiff(refLuma, resLuma))
    }

    // MARK: - 亮度平面（0…255）

    private static func luma(_ image: CGImage, width: Int, height: Int) -> [Float]? {
        let bytesPerRow = width * 4
        var rgba = [UInt8](repeating: 0, count: bytesPerRow * height)
        return rgba.withUnsafeMutableBytes { buffer -> [Float]? in
            guard let base = buffer.baseAddress,
                  let ctx = CGContext(data: base,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                return nil
            }
            // 尺寸不同时由 CGContext 负责缩放对齐
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            var out = [Float](repeating: 0, count: width * height)
            for i in 0..<(width * height) {
                let r = Float(rgba[i * 4])
                let g = Float(rgba[i * 4 + 1])
                let b = Float(rgba[i * 4 + 2])
                out[i] = 0.299 * r + 0.587 * g + 0.114 * b
            }
            return out
        }
    }

    // MARK: - PSNR / SSIM

    private static func meanAbsDiff(_ a: [Float], _ b: [Float]) -> Double {
        guard !a.isEmpty else { return 0 }
        var sum = 0.0
        for i in 0..<a.count { sum += Double(abs(a[i] - b[i])) }
        return sum / Double(a.count)
    }

    private static func psnr(_ a: [Float], _ b: [Float]) -> Double {
        guard !a.isEmpty else { return 0 }
        var sum = 0.0
        for i in 0..<a.count {
            let d = Double(a[i] - b[i])
            sum += d * d
        }
        let mse = sum / Double(a.count)
        if mse <= 0 { return 100.0 }
        return min(10.0 * log10(255.0 * 255.0 / mse), 100.0)
    }

    private static let window = 11
    private static let sigma = 1.5
    private static let c1 = pow(0.01 * 255.0, 2)
    private static let c2 = pow(0.03 * 255.0, 2)

    private static let kernel: [Float] = {
        var k = [Float](repeating: 0, count: window)
        let center = Double(window - 1) / 2.0
        var sum = 0.0
        for i in 0..<window {
            let x = Double(i) - center
            let v = exp(-(x * x) / (2.0 * sigma * sigma))
            k[i] = Float(v)
            sum += v
        }
        for i in 0..<window { k[i] = Float(Double(k[i]) / sum) }
        return k
    }()

    /// 可分离高斯模糊（边缘钳制），避免整幅图 × 121 抽头的暴力卷积。
    private static func blur(_ src: [Float], width: Int, height: Int) -> [Float] {
        let n = kernel.count
        let half = n / 2
        var tmp = [Float](repeating: 0, count: width * height)
        var out = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                var acc: Float = 0
                for t in 0..<n {
                    var xx = x + t - half
                    if xx < 0 { xx = 0 } else if xx >= width { xx = width - 1 }
                    acc += src[row + xx] * kernel[t]
                }
                tmp[row + x] = acc
            }
        }
        for x in 0..<width {
            for y in 0..<height {
                var acc: Float = 0
                for t in 0..<n {
                    var yy = y + t - half
                    if yy < 0 { yy = 0 } else if yy >= height { yy = height - 1 }
                    acc += tmp[yy * width + x] * kernel[t]
                }
                out[y * width + x] = acc
            }
        }
        return out
    }

    private static func ssim(_ a: [Float], _ b: [Float], width: Int, height: Int) -> Double {
        let muA = blur(a, width: width, height: height)
        let muB = blur(b, width: width, height: height)
        var aa = [Float](repeating: 0, count: a.count)
        var bb = [Float](repeating: 0, count: a.count)
        var ab = [Float](repeating: 0, count: a.count)
        for i in 0..<a.count {
            aa[i] = a[i] * a[i]
            bb[i] = b[i] * b[i]
            ab[i] = a[i] * b[i]
        }
        let muAA = blur(aa, width: width, height: height)
        let muBB = blur(bb, width: width, height: height)
        let muAB = blur(ab, width: width, height: height)

        var total = 0.0
        for i in 0..<a.count {
            let mA = Double(muA[i]), mB = Double(muB[i])
            let varA = Double(muAA[i]) - mA * mA
            let varB = Double(muBB[i]) - mB * mB
            let covAB = Double(muAB[i]) - mA * mB
            let numerator = (2 * mA * mB + c1) * (2 * covAB + c2)
            let denominator = (mA * mA + mB * mB + c1) * (varA + varB + c2)
            total += numerator / denominator
        }
        return total / Double(a.count)
    }
}
