import CoreGraphics
import CoreML
import Foundation

/// Core ML 后端（PP-HumanSegV2 portrait，ANE 优先）。
///
/// 模型规格（见 scripts/model-convert/README.md）：
///   输入  image : 256x144 RGB，模型内部已含 Normalize(mean=std=0.5)
///   输出  mask  : [1,144,256] INT32，取值 0/1
final class CoreMLSegmentationProvider: SegmentationProvider {
    private let model: MLModel
    private let imageConstraint: MLImageConstraint
    private var didLogShape = false

    let inputWidth: Int
    let inputHeight: Int

    init(modelURL: URL, computeUnits: MLComputeUnits = .all) throws {
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        self.model = try MLModel(contentsOf: modelURL, configuration: config)

        let description = model.modelDescription
        guard let constraint = description.inputDescriptionsByName["image"]?.imageConstraint else {
            throw SegmentationError.missingImageInput
        }
        self.imageConstraint = constraint
        self.inputWidth = constraint.pixelsWide
        self.inputHeight = constraint.pixelsHigh
    }

    func segment(_ image: CGImage) throws -> SegmentationMask {
        let feature = try MLFeatureValue(cgImage: image,
                                         constraint: imageConstraint,
                                         options: nil)
        let input = try MLDictionaryFeatureProvider(dictionary: ["image": feature])
        let output = try model.prediction(from: input)

        guard let multiArray = output.featureValue(for: "mask")?.multiArrayValue else {
            throw SegmentationError.missingOutput("mask")
        }
        guard multiArray.dataType == .int32 else {
            throw SegmentationError.unexpectedDataType
        }

        let shape = multiArray.shape.map { $0.intValue }
        let strides = multiArray.strides.map { $0.intValue }
        guard shape.count == 3 else { throw SegmentationError.unexpectedDataType }

        let height = shape[1]
        let width = shape[2]
        var labels = [UInt8](repeating: 0, count: width * height)

        // MLMultiArray 不保证连续存储，必须按 strides 索引——直接顺序读 dataPointer
        // 会读到错位的行（现象是「mask 只覆盖一条窄竖条」）。
        // 但逐元素用下标访问会带来 NSNumber 装箱开销（实测推理耗时翻 3 倍），
        // 所以先判断是否连续：连续就走裸指针，不连续才退回逐元素。
        let isContiguous = strides == [height * width, width, 1] && shape[0] == 1
        if isContiguous {
            let pointer = multiArray.dataPointer.bindMemory(to: Int32.self, capacity: width * height)
            for index in 0..<(width * height) {
                labels[index] = pointer[index] == 0 ? 0 : 1
            }
        } else {
            for y in 0..<height {
                let rowBase = y * strides[1]
                for x in 0..<width {
                    labels[y * width + x] = multiArray[rowBase + x * strides[2]].int32Value == 0 ? 0 : 1
                }
            }
        }

        if !didLogShape {
            didLogShape = true
            print("[Segmentation] 输出 shape=\(shape) strides=\(strides)")
        }
        return SegmentationMask(width: width, height: height, labels: labels)
    }
}
