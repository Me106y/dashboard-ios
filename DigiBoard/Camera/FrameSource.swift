import CoreGraphics
import CoreVideo
import ImageIO
import Metal
import UIKit

/// 帧源抽象（决策 D9）：管线只依赖"能拿到一帧纹理 + 分辨率"。
/// 相机与静态图都实现它，因此把静态图喂进同一条管线不需要改任何阶段。
protocol FrameSource: AnyObject {
    var currentTexture: MTLTexture? { get }
    var resolution: CGSize { get }
    /// 每个渲染帧推进一次。相机是实时的，无需推进；视频源在这里解码下一帧。
    func advance()
}

extension FrameSource {
    func advance() {}
}

extension CameraFrameSource: FrameSource {}

/// 静态图帧源：模拟器没有相机时用它跑通整条管线，也用于静态图回归验证。
final class StillImageFrameSource: FrameSource {
    let resolution: CGSize

    private var texture: MTLTexture?
    private let lock = NSLock()

    var currentTexture: MTLTexture? {
        lock.lock(); defer { lock.unlock() }
        return texture
    }

    /// - Parameter resourceName: bundle 内的图片名（不含扩展名）
    init?(device: MTLDevice, resourceName: String, extension ext: String = "jpg") {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: ext),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

        let width = image.width
        let height = image.height
        resolution = CGSize(width: width, height: height)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: width,
                                                                  height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        // CGContext 默认原点在左下，这里翻转一次，让 row 0 对应图像顶部
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let context = CGContext(data: base,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                              | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        texture.replace(region: MTLRegionMake2D(0, 0, width, height),
                        mipmapLevel: 0,
                        withBytes: buffer,
                        bytesPerRow: bytesPerRow)
        self.texture = texture
    }
}
