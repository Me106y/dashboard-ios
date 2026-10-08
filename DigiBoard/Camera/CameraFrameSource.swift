import AVFoundation
import CoreVideo
import Metal
import UIKit

/// 相机帧源（决策 D6 / D9）：`AVCaptureSession` + `AVCaptureVideoDataOutput`，
/// 像素格式 `32BGRA`，经 `CVMetalTextureCache` **零拷贝**变成 `MTLTexture`。
///
/// 采集规格：1920×1080 @ 30fps，wants 横屏（决策 D7 / D8：v1 锁横屏，不预先降分辨率）。
final class CameraFrameSource: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case unauthorized
        case configuring
        case running
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var resolution = CGSize.zero

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "com.zhuanz.digiboard.camera.session")
    private let outputQueue = DispatchQueue(label: "com.zhuanz.digiboard.camera.output",
                                            qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let lock = NSLock()

    private var textureCache: CVMetalTextureCache?
    private var texture: MTLTexture?
    /// CVMetalTexture 必须保活，否则 MTLTexture 会失效
    private var retainedTexture: CVMetalTexture?

    /// 视频旋转角：横屏使用 90°（后摄传感器相对竖屏旋转 90°）
    var videoRotationAngle: CGFloat = 90

    init(device: MTLDevice) {
        super.init()
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        if status == kCVReturnSuccess {
            textureCache = cache
        } else {
            state = .failed("CVMetalTextureCache 创建失败 (\(status))")
        }
    }

    deinit {
        if let cache = textureCache {
            CVMetalTextureCacheFlush(cache, 0)
        }
    }

    /// 最近一帧的纹理（渲染线程读取）
    var currentTexture: MTLTexture? {
        lock.lock(); defer { lock.unlock() }
        return texture
    }

    // MARK: - 生命周期

    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                self.configureAndRun()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    if granted {
                        self.configureAndRun()
                    } else {
                        DispatchQueue.main.async { self.state = .unauthorized }
                    }
                }
            default:
                DispatchQueue.main.async { self.state = .unauthorized }
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
            DispatchQueue.main.async { self.state = .idle }
        }
    }

    private func configureAndRun() {
        guard !session.isRunning else { return }
        DispatchQueue.main.async { self.state = .configuring }

        session.beginConfiguration()
        session.sessionPreset = .hd1920x1080

        do {
            // 输入
            if session.inputs.isEmpty {
                guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                           for: .video,
                                                           position: .back) else {
                    throw CameraError.noDevice
                }
                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input) else { throw CameraError.cannotAddInput }
                session.addInput(input)

                // 尽量固定 30fps
                try? device.lockForConfiguration()
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
                device.unlockForConfiguration()
            }

            // 输出
            if session.outputs.isEmpty {
                videoOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
                videoOutput.alwaysDiscardsLateVideoFrames = true
                videoOutput.setSampleBufferDelegate(self, queue: outputQueue)
                guard session.canAddOutput(videoOutput) else { throw CameraError.cannotAddOutput }
                session.addOutput(videoOutput)
            }

            // 横屏：直接把缓冲区旋正，避免着色器里做朝向数学
            if let connection = videoOutput.connection(with: .video) {
                if connection.isVideoRotationAngleSupported(videoRotationAngle) {
                    connection.videoRotationAngle = videoRotationAngle
                }
                if connection.isVideoMirroringSupported {
                    connection.isVideoMirrored = false
                }
            }

            session.commitConfiguration()
            session.startRunning()
            DispatchQueue.main.async { self.state = .running }
        } catch {
            session.commitConfiguration()
            let message = (error as? CameraError)?.errorDescription ?? error.localizedDescription
            DispatchQueue.main.async { self.state = .failed(message) }
        }
    }

    private func publish(pixelBuffer: CVPixelBuffer) {
        guard let cache = textureCache else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        )
        guard status == kCVReturnSuccess,
              let cvTexture,
              let metalTexture = CVMetalTextureGetTexture(cvTexture) else { return }

        lock.lock()
        texture = metalTexture
        retainedTexture = cvTexture
        lock.unlock()

        let size = CGSize(width: width, height: height)
        if resolution != size {
            DispatchQueue.main.async { self.resolution = size }
        }
    }
}

extension CameraFrameSource: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        publish(pixelBuffer: pixelBuffer)
    }
}

enum CameraError: LocalizedError {
    case noDevice
    case cannotAddInput
    case cannotAddOutput

    var errorDescription: String? {
        switch self {
        case .noDevice:      return "找不到可用的后置摄像头"
        case .cannotAddInput:  return "无法添加相机输入"
        case .cannotAddOutput: return "无法添加视频输出"
        }
    }
}
