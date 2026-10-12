import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

/// 调试期抓帧：把 GPU 纹理回读成 PNG。
///
/// 真机上没有可视控制台、`devicectl` 也不提供截图能力，因此用
/// `DB_CAPTURE=<文件名>` 环境变量触发一次抓帧，写进 App 的 Documents 目录，
/// 再用 `devicectl device copy from --domain-type appDataContainer` 拉回本机分析。
///
/// 走的是「blit 到 shared 暂存纹理再 getBytes」，不改动生产路径的纹理存储模式。
enum FrameCapture {
    static func makeURL(fileName: String) -> URL? {
        guard let documents = FileManager.default.urls(for: .documentDirectory,
                                                      in: .userDomainMask).first else {
            return nil
        }
        return documents.appendingPathComponent(fileName)
    }

    /// 把已经 blit 到 shared 暂存纹理的内容回读成 `CGImage`。
    /// blit 由 Renderer 在帧内完成，这里只做回读与色彩重排（RGB8）。
    ///
    /// 除了写 PNG，另一个用途是喂给 `RestorationMetrics`：拿恢复输出与干净参考帧各回读
    /// 一张，即可算恢复质量的 PSNR / SSIM。
    static func makeImage(from staging: MTLTexture) -> CGImage? {
        let width = staging.width
        let height = staging.height
        guard width > 0, height > 0 else { return nil }

        // 必须按纹理的实际像素格式决定每行字节数：
        // r8Unorm 是每像素 1 字节，按 4 字节读会读到错位数据
        // （表现为「抓出来的 mask 是一条窄竖条」，与真实内容完全不符）。
        let isSingleChannel = staging.pixelFormat == .r8Unorm
        let sourceBytesPerRow = isSingleChannel ? width : width * 4

        var raw = [UInt8](repeating: 0, count: sourceBytesPerRow * height)
        raw.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            staging.getBytes(base, bytesPerRow: sourceBytesPerRow,
                             from: MTLRegionMake2D(0, 0, width, height),
                             mipmapLevel: 0)
        }

        // 统一转成 RGBA
        var rgba = [UInt8](repeating: 0, count: width * 4 * height)
        if isSingleChannel {
            for y in 0..<height {
                for x in 0..<width {
                    let v = raw[y * width + x]
                    let dst = (y * width + x) * 4
                    rgba[dst] = v; rgba[dst + 1] = v; rgba[dst + 2] = v; rgba[dst + 3] = 255
                }
            }
        } else {
            for y in 0..<height {
                for x in 0..<width {
                    let src = (y * width + x) * 4
                    let dst = src
                    rgba[dst] = raw[src + 2]       // BGRA -> RGBA
                    rgba[dst + 1] = raw[src + 1]
                    rgba[dst + 2] = raw[src]
                    rgba[dst + 3] = 255
                }
            }
        }
        let bytesPerRow = width * 4

        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width,
                       height: height,
                       bitsPerComponent: 8,
                       bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    /// 把暂存纹理写成 PNG（调试期抓帧用）。
    @discardableResult
    static func write(staging: MTLTexture, to url: URL) -> Bool {
        guard let image = makeImage(from: staging),
              let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                                UTType.png.identifier as CFString,
                                                                1, nil) else {
            return false
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
}
