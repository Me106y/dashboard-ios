import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import Metal
import Photos
import QuartzCore

/// 把「处理后的帧」编码成 H.264 视频文件（调试模式用）。
///
/// 数据来源：`Renderer.recordSink` 每帧回调一张 shared 暂存纹理（内容 = 管线最终输出
/// `enhance.final`）。这里回读成 `CVPixelBuffer` 后按真实时间戳写进 `AVAssetWriter`，
/// 因此导出的视频时长与录制过程一致，而不是按某个假定帧率硬凑。
///
/// 纹理行序与 `FrameCapture` 的抓帧完全一致（都直接按行回读），
/// 所以导出的视频朝向 = `DB_CAPTURE` 抓出来的 PNG 朝向，便于互相核对。
final class ProcessedVideoWriter {

    enum WriterError: LocalizedError {
        case invalidSize
        case writerUnavailable
        case startFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidSize:             return "处理结果尺寸无效，无法编码"
            case .writerUnavailable:       return "视频写入器创建失败"
            case .startFailed(let reason): return "视频写入启动失败：\(reason)"
            }
        }
    }

    let url: URL

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    /// 所有写入都串行化：`append` 由渲染回调在 `Renderer.recordQueue` 上调用，
    /// `finish` 必须排在它们之后，否则会丢掉尾部若干帧。
    private let queue = DispatchQueue(label: "com.zhuanz.digiboard.videoWriter", qos: .userInitiated)
    private let startTime: CFTimeInterval

    /// 保护 `isFinished` / `pendingFrames` / `droppedFrames`（跨线程可见）。
    private let stateLock = NSLock()
    private var isFinished = false
    private var pendingFrames = 0
    /// 最多允许多少帧「已接收但还没回读完」；超过就丢帧。
    /// 没有这个上限，长视频录制会把暂存纹理一路堆到内存吃光。
    private let maxPendingFrames = 6

    /// 成功编码进视频的帧数
    private(set) var encodedFrames = 0
    /// 被丢掉的帧数（编码器来不及 / 回读积压 / 像素缓冲池取不到）
    private(set) var droppedFrames = 0

    init(size: CGSize, directory: URL? = nil) throws {
        // H.264 要求偶数边长；向下取偶
        let width = Int(size.width.rounded()) & ~1
        let height = Int(size.height.rounded()) & ~1
        guard width > 0, height > 0 else { throw WriterError.invalidSize }

        let base = directory ?? FileManager.default.temporaryDirectory
        let name = "digiboard-processed-\(Self.timestamp()).mp4"
        let outputURL = base.appendingPathComponent(name)
        // AVAssetWriter 不会覆盖已存在的文件
        try? FileManager.default.removeItem(at: outputURL)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw WriterError.startFailed(error.localizedDescription)
        }

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        // 边播边写：与渲染同一节奏，编码器来不及时的帧会被丢掉并计入 droppedFrames
        input.expectsMediaDataInRealTime = true

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                           sourcePixelBufferAttributes: attributes)

        guard writer.canAdd(input) else { throw WriterError.writerUnavailable }
        writer.add(input)
        guard writer.startWriting() else {
            throw WriterError.startFailed(writer.error?.localizedDescription ?? "未知原因")
        }
        writer.startSession(atSourceTime: .zero)

        self.url = outputURL
        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        self.startTime = CACurrentMediaTime()
    }

    /// 追加一帧。由 `Renderer.recordSink` 调用，可在任意线程进入（内部串行化）。
    func append(_ texture: MTLTexture) {
        stateLock.lock()
        let acceptable = !isFinished && pendingFrames < maxPendingFrames
        if acceptable { pendingFrames += 1 }
        stateLock.unlock()

        guard acceptable else {
            // 计数统一在串行队列上改，避免多线程写同一个属性
            queue.async { [weak self] in self?.droppedFrames += 1 }
            return
        }

        queue.async { [weak self] in
            guard let self else { return }
            defer {
                self.stateLock.lock()
                self.pendingFrames = max(0, self.pendingFrames - 1)
                self.stateLock.unlock()
            }
            guard let pool = self.adaptor.pixelBufferPool else {
                self.droppedFrames += 1
                return
            }
            guard self.input.isReadyForMoreMediaData else {
                self.droppedFrames += 1
                return
            }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess,
                  let pixelBuffer = buffer else {
                self.droppedFrames += 1
                return
            }
            self.fill(pixelBuffer, from: texture)
            let time = CMTime(seconds: CACurrentMediaTime() - self.startTime, preferredTimescale: 600)
            if self.adaptor.append(pixelBuffer, withPresentationTime: time) {
                self.encodedFrames += 1
            } else {
                self.droppedFrames += 1
            }
        }
    }

    /// 收尾并交付文件。必须排在所有已接收的 `append` 之后（同一个串行队列）。
    func finish(completion: @escaping (Result<URL, Error>) -> Void) {
        stateLock.lock()
        let already = isFinished
        isFinished = true
        stateLock.unlock()
        guard !already else { return }

        queue.async { [weak self] in
            guard let self else { return }
            self.input.markAsFinished()
            let url = self.url
            self.writer.finishWriting { [weak self] in
                let status = self?.writer.status
                let error = self?.writer.error
                DispatchQueue.main.async {
                    if status == .completed {
                        completion(.success(url))
                    } else {
                        completion(.failure(error ?? WriterError.writerUnavailable))
                    }
                }
            }
        }
    }

    /// 放弃本次录制并删掉半成品文件（切换模式 / 重播时用）。
    func cancel() {
        stateLock.lock()
        let already = isFinished
        isFinished = true
        stateLock.unlock()
        guard !already else { return }

        queue.async { [weak self] in
            guard let self else { return }
            self.input.markAsFinished()
            self.writer.cancelWriting()
            try? FileManager.default.removeItem(at: self.url)
        }
    }

    // MARK: - 回读

    private func fill(_ pixelBuffer: CVPixelBuffer, from texture: MTLTexture) {
        let width = min(texture.width, CVPixelBufferGetWidth(pixelBuffer))
        let height = min(texture.height, CVPixelBufferGetHeight(pixelBuffer))
        guard width > 0, height > 0 else { return }

        let sourceBytesPerRow = width * 4
        var raw = [UInt8](repeating: 0, count: sourceBytesPerRow * height)
        raw.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            texture.getBytes(base, bytesPerRow: sourceBytesPerRow,
                             from: MTLRegionMake2D(0, 0, width, height),
                             mipmapLevel: 0)
        }

        // 管线最终输出是 rgba8Unorm，像素缓冲是 32BGRA —— 只需要交换 R/B
        let swapRedBlue = texture.pixelFormat == .rgba8Unorm

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let destination = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let destinationBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        raw.withUnsafeBytes { source in
            guard let sourceBase = source.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for y in 0..<height {
                let target = destination.advanced(by: y * destinationBytesPerRow)
                    .assumingMemoryBound(to: UInt8.self)
                let row = sourceBase + y * sourceBytesPerRow
                if swapRedBlue {
                    for x in 0..<width {
                        target[x * 4 + 0] = row[x * 4 + 2]
                        target[x * 4 + 1] = row[x * 4 + 1]
                        target[x * 4 + 2] = row[x * 4 + 0]
                        target[x * 4 + 3] = 255
                    }
                } else {
                    target.update(from: row, count: width * 4)
                }
            }
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }
}

/// 把本地视频存进系统相册（只申请「仅添加」权限）。
enum PhotoLibrarySaver {

    enum SaveError: LocalizedError {
        case notAuthorized
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "没有相册写入权限，请在「设置 → 隐私与安全性 → 照片」里允许"
            case .failed(let reason):
                return "保存到相册失败：\(reason)"
            }
        }
    }

    static func saveVideo(at url: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { completion(.failure(SaveError.notAuthorized)) }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { success, error in
                DispatchQueue.main.async {
                    if success {
                        completion(.success(()))
                    } else {
                        completion(.failure(SaveError.failed(error?.localizedDescription ?? "未知原因")))
                    }
                }
            }
        }
    }
}
