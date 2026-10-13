import AVFoundation
import Metal
import XCTest
@testable import DigiBoard

/// 调试模式新增能力的测试：非循环播放的「放完一次」语义、报告汇总口径、
/// 以及「处理后的视频」确实能编码成文件。
final class DebugRunTests: XCTestCase {

    private var device: MTLDevice!
    private var tempDir: URL!

    override func setUpWithError() throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DebugRunTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - 非循环播放

    /// `loops: false`：放完停在最后一帧、只回调一次；`rewindAndRestart()` 后能再放一遍。
    func testNonLoopingSourceFinishesExactlyOnce() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "sample_whiteboard", withExtension: "mp4"),
                                "内置测试视频缺失")
        let source = try VideoFrameSource(url: url, device: device, loops: false)
        XCTAssertGreaterThan(source.estimatedFrames, 0, "应当能估算出总帧数（进度条用）")

        let finished = expectation(description: "播放结束回调")
        source.onFinished = { finished.fulfill() }

        // 推进到明显超过总帧数，确认会停下来
        let limit = source.estimatedFrames + 120
        for _ in 0..<limit { source.advance() }

        wait(for: [finished], timeout: 15)
        XCTAssertTrue(source.isFinished)
        XCTAssertGreaterThan(source.decodedFrames, 0)

        // 结束后继续推进不应再解码（停在终帧）
        let framesAtFinish = source.decodedFrames
        for _ in 0..<30 { source.advance() }
        XCTAssertEqual(source.decodedFrames, framesAtFinish, "放完后不应继续解码")
        XCTAssertNotNil(source.currentTexture, "终帧纹理应当还在")

        // 重播：解码计数清零，能继续出帧
        source.rewindAndRestart()
        XCTAssertFalse(source.isFinished)
        source.advance()
        source.advance()
        XCTAssertGreaterThan(source.decodedFrames, 0)
    }

    /// 默认（`loops = true`）行为不变：不会置 finished。
    func testLoopingSourceNeverFinishes() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "sample_whiteboard", withExtension: "mp4"))
        let source = try VideoFrameSource(url: url, device: device)
        let limit = source.estimatedFrames + 60
        for _ in 0..<limit { source.advance() }
        XCTAssertFalse(source.isFinished, "循环模式不应结束")
        XCTAssertGreaterThan(source.loopCount, 1, "到尾部应重开 reader")
    }

    // MARK: - 报告汇总

    func testReportSummaries() {
        let samples = [
            MetricSample(time: 0.0, fps: 10, frameMillis: 4, inferenceMillis: 8,
                         residentMB: 100, availableMB: 900, cpuPercent: 20,
                         thermalLevel: 0, batteryLevel: 0.90, drainPercentPerHour: -1),
            MetricSample(time: 0.5, fps: 20, frameMillis: 6, inferenceMillis: 10,
                         residentMB: 120, availableMB: 880, cpuPercent: 40,
                         thermalLevel: 1, batteryLevel: 0.89, drainPercentPerHour: -1),
            MetricSample(time: 1.0, fps: 30, frameMillis: 8, inferenceMillis: 12,
                         residentMB: 110, availableMB: 890, cpuPercent: 60,
                         thermalLevel: 0, batteryLevel: 0.88, drainPercentPerHour: 4),
        ]
        let report = RunReport(title: "t.mp4", resolution: CGSize(width: 640, height: 360),
                               duration: 1.0, frames: 3, samples: samples)

        XCTAssertEqual(report.meanFPS, 20, accuracy: 0.001)
        XCTAssertEqual(report.minFPS, 10, accuracy: 0.001)
        XCTAssertEqual(report.maxFPS, 30, accuracy: 0.001)
        XCTAssertEqual(report.meanFrameMillis, 6, accuracy: 0.001)
        XCTAssertEqual(report.peakMemoryMB, 120, accuracy: 0.001)
        XCTAssertEqual(report.startMemoryMB, 100, accuracy: 0.001)
        XCTAssertEqual(report.memoryGrowthMB, 10, accuracy: 0.001)
        XCTAssertEqual(report.peakCPU, 60, accuracy: 0.001)
        XCTAssertEqual(report.maxThermalLevel, 1)
        XCTAssertEqual(report.maxThermalText, "偏热")
        XCTAssertTrue(report.hasBattery)
        XCTAssertEqual(report.batteryStart, 0.90, accuracy: 0.001)
        XCTAssertEqual(report.batteryEnd, 0.88, accuracy: 0.001)
        XCTAssertEqual(report.drainPercentPerHour, 4, accuracy: 0.001)

        // 分位数：3 个样本的 5% 分位落在最小值附近
        XCTAssertEqual(RunReport.percentile([10, 20, 30], 0.05), 11, accuracy: 0.001)
        XCTAssertEqual(RunReport.percentile([10, 20, 30], 0.5), 20, accuracy: 0.001)
        XCTAssertEqual(RunReport.percentile([], 0.5), 0, accuracy: 0.001)

        XCTAssertTrue(report.csv().hasPrefix("time_s,fps"))
    }

    /// 电量不可用时报告不应崩，且 `hasBattery` 为 false。
    func testReportWithoutBattery() {
        let samples = [
            MetricSample(time: 0, fps: 30, frameMillis: 5, inferenceMillis: 9,
                         residentMB: 100, availableMB: -1, cpuPercent: 30,
                         thermalLevel: 0, batteryLevel: -1, drainPercentPerHour: -1),
        ]
        let report = RunReport(title: "", resolution: .zero, duration: 0, frames: 0, samples: samples)
        XCTAssertFalse(report.hasBattery)
        XCTAssertEqual(report.batteryStart, -1)
        XCTAssertEqual(report.drainPercentPerHour, -1)
    }

    // MARK: - 处理后的视频编码

    /// 逐帧写入后应当得到一个非空的视频文件，且帧被真正编码进去。
    func testProcessedVideoWriterProducesFile() throws {
        let size = CGSize(width: 64, height: 48)
        let writer = try ProcessedVideoWriter(size: size, directory: tempDir)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                                  width: Int(size.width),
                                                                  height: Int(size.height),
                                                                  mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var pixels = [UInt8](repeating: 200, count: Int(size.width) * Int(size.height) * 4)
        texture.replace(region: MTLRegionMake2D(0, 0, Int(size.width), Int(size.height)),
                        mipmapLevel: 0, withBytes: &pixels, bytesPerRow: Int(size.width) * 4)

        for _ in 0..<8 { writer.append(texture) }

        let done = expectation(description: "编码结束")
        var produced: URL?
        writer.finish { result in
            if case .success(let url) = result { produced = url }
            done.fulfill()
        }
        wait(for: [done], timeout: 15)

        let url = try XCTUnwrap(produced, "应当产出视频文件")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThan(fileSize, 0, "视频文件不应为空")
        XCTAssertGreaterThanOrEqual(writer.encodedFrames, 1, "至少应编码进 1 帧")
        XCTAssertEqual(writer.encodedFrames + writer.droppedFrames, 8)

        try? FileManager.default.removeItem(at: url)
    }
}
