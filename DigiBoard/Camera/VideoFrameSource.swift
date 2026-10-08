import AVFoundation
import CoreVideo
import Metal

/// 离线视频帧源：把一段本地视频逐帧喂进管线，循环播放。
///
/// 用途：没有相机（模拟器）或需要可复现素材时，用固定视频验证整条管线。
/// 解码出的 `CVPixelBuffer`（BGRA）同样经 `CVMetalTextureCache` 零拷贝成纹理，
/// 与相机路径共用同一个 `FrameSource` 抽象。
final class VideoFrameSource: FrameSource {
    let resolution: CGSize

    private let asset: AVURLAsset
    private let track: AVAssetTrack
    private let textureCache: CVMetalTextureCache
    private let lock = NSLock()

    private var reader: AVAssetReader?
    private var trackOutput: AVAssetReaderTrackOutput?
    private var current: MTLTexture?
    /// CVMetalTexture 必须保活
    private var retained: CVMetalTexture?

    private(set) var decodedFrames = 0
    private(set) var loopCount = 0
    private var didLog = false

    init?(url: URL, device: MTLDevice) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("[Video] 文件不存在: \(url.path)")
            return nil
        }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else {
            print("[Video] CVMetalTextureCache 创建失败")
            return nil
        }

        // AVFoundation 的轨道加载是异步的；这里同步等一次（只在初始化时发生）
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        var loadedTrack: AVAssetTrack?
        var size = CGSize.zero
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                loadedTrack = try await asset.loadTracks(withMediaType: .video).first
                if let track = loadedTrack {
                    let natural = try await track.load(.naturalSize)
                    let transform = try await track.load(.preferredTransform)
                    let transformed = natural.applying(transform)
                    size = CGSize(width: abs(transformed.width), height: abs(transformed.height))
                }
            } catch {
                print("[Video] 轨道加载失败: \(error)")
            }
            semaphore.signal()
        }
        semaphore.wait()

        guard let track = loadedTrack, size.width > 0, size.height > 0 else {
            print("[Video] 视频没有可用的画面轨道")
            return nil
        }

        self.asset = asset
        self.track = track
        self.textureCache = cache
        self.resolution = size
    }

    /// 每帧推进：取下一张样本；到尾部自动重开 reader 循环播放。
    func advance() {
        lock.lock()
        defer { lock.unlock() }

        if trackOutput == nil || reader?.status != .reading {
            restartReader()
        }
        guard let output = trackOutput,
              let sample = output.copyNextSampleBuffer(),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
            restartReader()
            return
        }

        decodedFrames += 1
        publish(pixelBuffer: pixelBuffer)

        if !didLog {
            didLog = true
            print("[Video] 首帧解码成功 \(Int(resolution.width))x\(Int(resolution.height))")
        }
    }

    var currentTexture: MTLTexture? {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    // MARK: - 内部

    private func restartReader() {
        reader?.cancelReading()
        reader = nil
        trackOutput = nil

        guard let newReader = try? AVAssetReader(asset: asset) else {
            print("[Video] AVAssetReader 创建失败")
            return
        }
        // 关键：必须显式要求 Metal 兼容 + IOSurface 后端，
        // 否则 AVAssetReader 给出的 CVPixelBuffer 无法被 CVMetalTextureCache 包装，
        // CVMetalTextureCacheCreateTextureFromImage 会返回 -6660 (kCVReturnError)。
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard newReader.canAdd(output) else {
            print("[Video] 无法添加 track output")
            return
        }
        newReader.add(output)
        guard newReader.startReading() else {
            print("[Video] startReading 失败: \(String(describing: newReader.error))")
            return
        }

        reader = newReader
        trackOutput = output
        loopCount += 1
    }

    private func publish(pixelBuffer: CVPixelBuffer) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0, &cvTexture)
        guard status == kCVReturnSuccess,
              let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else {
            print("[Video] 纹理创建失败 status=\(status)")
            return
        }

        current = texture
        retained = cvTexture
    }
}
