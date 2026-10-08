import CoreGraphics
import Metal

/// 静态图输入。对应上游被注释掉的 `TextureStage`，在 iOS 侧是 P1 的验收入口，
/// 也是 `FrameSource` 抽象（决策 D9）的静态实现。
///
/// 只在图像变更时上传，避免每帧做一次全尺寸 CPU→GPU 拷贝。
final class StillImageStage: TextureProducer {
    let name = "StillImage"
    let inputs: [TextureHandle] = []
    let output: TextureHandle

    private var image: CGImage
    private var dirty = true

    init(image: CGImage, spec: TextureSpec) {
        self.image = image
        self.output = TextureHandle("still.image", spec)
    }

    func update(image: CGImage) {
        self.image = image
        self.dirty = true
    }

    func produce(_ ctx: FrameContext, texture: MTLTexture) throws {
        guard dirty else { return }
        dirty = false

        let width = texture.width
        let height = texture.height
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)

        buffer.withUnsafeMutableBytes { raw -> Void in
            guard let base = raw.baseAddress,
                  let cg = CGContext(data: base,
                                     width: width,
                                     height: height,
                                     bitsPerComponent: 8,
                                     bytesPerRow: bytesPerRow,
                                     space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                         | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
            cg.interpolationQuality = .high
            cg.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        texture.replace(region: MTLRegionMake2D(0, 0, width, height),
                        mipmapLevel: 0,
                        withBytes: buffer,
                        bytesPerRow: bytesPerRow)
    }
}
