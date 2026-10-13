import AVFoundation
import CoreVideo
import Metal

/// 离线视频帧源：把一段本地视频逐帧喂进管线。
///
/// 两种播放方式：
/// - `loops = true`（默认）：到尾部自动重开 reader 循环播放，「离线视频」模式用；
/// - `loops = false`：放完停在最后一帧并回调 `onFinished`，「调试模式」用——
///   调试模式要的是「跑完一遍 → 出报告」，循环会让它永远跑不到终点。
///
/// 用途：没有相机（模拟器）或需要可复现素材时，用固定视频验证整条管线。
/// 解码出的 `CVPixelBuffer`（BGRA）同样经 `CVMetalTextureCache` 零拷贝成纹理，
/// 与相机路径共用同一个 `FrameSource` 抽象。
/// 视频源初始化失败的具体原因（便于给出可操作的提示）
enum VideoSourceError: LocalizedError {
    case fileNotFound(String)
    case textureCacheFailed
    case permissionDenied
    case unreadable
    case noVideoTrack
    case invalidSize

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let name): return "找不到文件 \(name)"
        case .textureCacheFailed:     return "Metal 纹理缓存创建失败"
        case .permissionDenied:       return "没有读取该文件的权限"
        case .unreadable:             return "文件无法读取（可能不是视频，或已被系统清理）"
        case .noVideoTrack:           return "文件里没有画面轨道（可能只有音频）"
        case .invalidSize:            return "视频尺寸无效"
        }
    }
}

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
    /// 非循环播放到尾部后置为 true；此后 `advance()` 变成空操作，停在最后一帧
    private(set) var isFinished = false
    /// 视频总帧数（按时长 × 标称帧率估算），用于调试模式的进度条；拿不到时为 0
    private(set) var estimatedFrames = 0
    private var didLog = false

    /// 是否循环播放（默认 true，保持既有行为）
    private let loops: Bool
    /// 非循环播放到尾部时的回调。在主线程调用，且只调用一次。
    var onFinished: (() -> Void)?

    init(url: URL, device: MTLDevice, loops: Bool = true) throws {
        // isReadableFile 比 fileExists 更能反映「拿不到安全作用域」这类问题
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VideoSourceError.fileNotFound(url.lastPathComponent)
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw VideoSourceError.permissionDenied
        }

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else {
            throw VideoSourceError.textureCacheFailed
        }

        // AVFoundation 的轨道加载是异步的；这里同步等一次（只在初始化时发生）
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        var loadedTrack: AVAssetTrack?
        var size = CGSize.zero
        var frameEstimate = 0
        var loadError: Error?
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                loadedTrack = try await asset.loadTracks(withMediaType: .video).first
                if let track = loadedTrack {
                    let natural = try await track.load(.naturalSize)
                    let transform = try await track.load(.preferredTransform)
                    let transformed = natural.applying(transform)
                    size = CGSize(width: abs(transformed.width), height: abs(transformed.height))

                    // 进度条用的总帧数：时长 × 标称帧率（29.97fps 这类也能算）
                    let rate = try await track.load(.nominalFrameRate)
                    let duration = try await asset.load(.duration)
                    let seconds = duration.seconds
                    if rate > 0, seconds.isFinite, seconds > 0 {
                        frameEstimate = max(1, Int((seconds * Double(rate)).rounded()))
                    }
                }
            } catch {
                loadError = error
            }
            semaphore.signal()
        }
        semaphore.wait()

        if let loadError {
            print("[Video] 轨道加载失败: \(loadError)")
            throw VideoSourceError.unreadable
        }
        guard let track = loadedTrack else {
            throw VideoSourceError.noVideoTrack
        }
        guard size.width > 0, size.height > 0 else {
            throw VideoSourceError.invalidSize
        }

        self.asset = asset
        self.track = track
        self.textureCache = cache
        self.resolution = size
        self.loops = loops
        self.estimatedFrames = frameEstimate
    }

    /// 每帧推进：取下一张样本。
    /// 循环模式下到尾部自动重开 reader；非循环模式下到尾部标记结束并回调 `onFinished`。
    func advance() {
        lock.lock()
        defer { lock.unlock() }

        // 已放完：停在最后一帧，不再解码（调试模式靠这个「冻结」在终帧）
        guard !isFinished else { return }

        if trackOutput == nil || reader?.status != .reading {
            restartReader()
        }
        guard let output = trackOutput,
              let sample = output.copyNextSampleBuffer(),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
            if loops {
                restartReader()
            } else if decodedFrames > 0 {
                finishLocked()
            } else {
                // 一帧都没解出来就失败：不要立刻判定「播放结束」，
                // 否则调试模式会在第一帧就弹出一份空报告
                print("[Video] 首帧解码失败（reader 状态 \(String(describing: reader?.status))）")
            }
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

    /// 从头再放一遍（调试模式的「重新播放」）。
    ///
    /// 调用方需要同时重建管线：`AccumulationStage` / `stored` 这些持久纹理里
    /// 还留着上一轮的时序状态，只重置解码器会让第二遍从「上一轮的残留」开始。
    func rewindAndRestart() {
        lock.lock()
        defer { lock.unlock() }
        isFinished = false
        decodedFrames = 0
        loopCount = 0
        restartReader()
    }

    // MARK: - 内部

    /// 非循环播放到尾部：只标记一次，并在主线程回调。
    ///
    /// 注意：必须在持有 `lock` 时调用（`advance()` 已持锁），
    /// 回调本身 dispatch 到主线程，不会在锁内执行用户代码。
    private func finishLocked() {
        guard !isFinished else { return }
        isFinished = true
        reader?.cancelReading()
        reader = nil
        trackOutput = nil
        let callback = onFinished
        DispatchQueue.main.async { callback?() }
    }

    /// 重开 reader。**调用前必须持有 `lock`**（`advance()` / `rewindAndRestart()` 都持锁）。
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
