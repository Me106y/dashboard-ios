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

        let count = multiArray.count
        let pointer = multiArray.dataPointer.bindMemory(to: Int32.self, capacity: count)
        var labels = [UInt8](repeating: 0, count: count)
        for index in 0..<count {
            labels[index] = pointer[index] == 0 ? 0 : 1
        }

        let height = multiArray.shape[1].intValue
        let width = multiArray.shape[2].intValue
        return SegmentationMask(width: width, height: height, labels: labels)
    }
}
