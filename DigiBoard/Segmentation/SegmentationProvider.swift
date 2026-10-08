import CoreGraphics
import Foundation

/// 分割结果：一张 0/1 标签图。
struct SegmentationMask {
    let width: Int
    let height: Int
    /// 行优先，取值 0（背景）/ 1（人像）
    let labels: [UInt8]

    var foregroundRatio: Double {
        guard !labels.isEmpty else { return 0 }
        return Double(labels.reduce(0) { $0 + ($1 > 0 ? 1 : 0) }) / Double(labels.count)
    }
}

/// 分割后端抽象。管线只依赖「输入一张图 → 输出 mask」，与具体推理框架无关
/// （决策 D3：先 Core ML，必要时可替换为 MNN 而不动管线）。
protocol SegmentationProvider: AnyObject {
    /// 模型要求的输入尺寸
    var inputWidth: Int { get }
    var inputHeight: Int { get }
    func segment(_ image: CGImage) throws -> SegmentationMask
}

enum SegmentationError: LocalizedError {
    case missingModel(String)
    case missingImageInput
    case missingOutput(String)
    case unexpectedDataType
    case imageResizeFailed

    var errorDescription: String? {
        switch self {
        case .missingModel(let n):  return "找不到模型资源: \(n)"
        case .missingImageInput:    return "模型没有名为 image 的图像输入"
        case .missingOutput(let n): return "模型没有名为 \(n) 的输出"
        case .unexpectedDataType:   return "输出数据类型不是预期的 int32"
        case .imageResizeFailed:    return "输入图像缩放失败"
        }
    }
}
