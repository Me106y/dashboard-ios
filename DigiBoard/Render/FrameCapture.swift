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

    /// 把已经 blit 到 shared 暂存纹理的内容写成 PNG（RGB8）。
    /// blit 由 Renderer 在帧内完成，这里只做回读与编码。
    @discardableResult
    static func write(staging: MTLTexture, to url: URL) -> Bool {
        let width = staging.width
        let height = staging.height
        guard width > 0, height > 0 else { return false }

        let bytesPerRow = width * 4
        var bgra = [UInt8](repeating: 0, count: bytesPerRow * height)
        bgra.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            staging.getBytes(base, bytesPerRow: bytesPerRow,
                             from: MTLRegionMake2D(0, 0, width, height),
                             mipmapLevel: 0)
        }

        // BGRA -> RGBA
        var rgba = bgra
        for index in stride(from: 0, to: rgba.count, by: 4) {
            rgba[index] = bgra[index + 2]
            rgba[index + 2] = bgra[index]
            rgba[index + 3] = 255
        }

        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bitsPerPixel: 32,
                                  bytesPerRow: bytesPerRow,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider,
                                  decode: nil,
                                  shouldInterpolate: false,
                                  intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                                UTType.png.identifier as CFString,
                                                                1, nil) else {
            return false
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
}
