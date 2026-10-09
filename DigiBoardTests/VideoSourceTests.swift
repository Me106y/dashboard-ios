import AVFoundation
import Metal
import XCTest
@testable import DigiBoard

/// 离线视频链路的测试：解码器初始化 + 文件导入。
///
/// 背景：用户反馈「选择完视频后提示『视频解码器初始化失败』」。
/// 根因是文件选择器给的是**安全作用域 URL**且位于临时收件箱——
/// 不开启作用域、不拷贝进沙盒就会读不到文件。
/// 这里把失败路径逐条固定下来，避免以后再退化。
final class VideoSourceTests: XCTestCase {

    private var device: MTLDevice!
    private var tempDir: URL!

    override func setUpWithError() throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoSourceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - 解码器

    /// 内置测试视频应当能正常初始化解码器，并解出 1280x720 的帧
    func testOpensBundledVideo() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "sample_whiteboard", withExtension: "mp4"),
                                "内置测试视频缺失")
        let source = try VideoFrameSource(url: url, device: device)
        XCTAssertEqual(source.resolution.width, 1280, accuracy: 1)
        XCTAssertEqual(source.resolution.height, 720, accuracy: 1)

        // 推进若干帧后应当拿到纹理
        for _ in 0..<3 { source.advance() }
        XCTAssertNotNil(source.currentTexture, "解码若干帧后应当有可用纹理")
    }

    /// 文件不存在 → 报「找不到文件」，而不是笼统的"初始化失败"
    func testMissingFileReportsFileNotFound() {
        let url = tempDir.appendingPathComponent("not_here.mp4")
        XCTAssertThrowsError(try VideoFrameSource(url: url, device: device)) { error in
            guard case VideoSourceError.fileNotFound = error else {
                return XCTFail("期望 fileNotFound，实际 \(error)")
            }
        }
    }

    /// 扩展名是 .mp4 但内容不是视频 → 不应当崩，且给出可读的错误
    func testNonVideoFileReportsUnreadable() throws {
        let url = tempDir.appendingPathComponent("fake.mp4")
        try Data("这不是视频".utf8).write(to: url)

        XCTAssertThrowsError(try VideoFrameSource(url: url, device: device)) { error in
            guard let videoError = error as? VideoSourceError else {
                return XCTFail("期望 VideoSourceError，实际 \(error)")
            }
            switch videoError {
            case .unreadable, .noVideoTrack, .invalidSize:
                break   // 这三种都属于「文件不是可用视频」
            default:
                XCTFail("期望 unreadable / noVideoTrack / invalidSize，实际 \(videoError)")
            }
            XCTAssertFalse(videoError.errorDescription?.isEmpty ?? true, "应当有可读的错误描述")
        }
    }

    // MARK: - 导入

    /// 导入应当把文件拷贝到目标目录，且拷贝后可独立读取
    func testImportCopiesFileIntoDirectory() throws {
        let source = try XCTUnwrap(Bundle.main.url(forResource: "sample_whiteboard", withExtension: "mp4"))
        let destinationDir = tempDir.appendingPathComponent("Videos", isDirectory: true)

        let imported = try BoardViewModel.importVideo(from: source, into: destinationDir)

        XCTAssertEqual(imported.lastPathComponent, "sample_whiteboard.mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.path))
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: imported.path))
        XCTAssertEqual(try Data(contentsOf: imported).count, try Data(contentsOf: source).count)

        // 拷贝出来的文件同样能解出画面
        let videoSource = try VideoFrameSource(url: imported, device: device)
        videoSource.advance()
        XCTAssertNotNil(videoSource.currentTexture)
    }

    /// 同名文件重复导入应当覆盖而不是报错
    func testImportOverwritesExistingFile() throws {
        let source = try XCTUnwrap(Bundle.main.url(forResource: "sample_whiteboard", withExtension: "mp4"))
        let destinationDir = tempDir.appendingPathComponent("Videos", isDirectory: true)

        _ = try BoardViewModel.importVideo(from: source, into: destinationDir)
        let second = try BoardViewModel.importVideo(from: source, into: destinationDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    /// 没有扩展名的文件应当被补上扩展名（文件选择器偶尔会给出无扩展名的 URL）
    func testImportAddsExtensionWhenMissing() throws {
        let source = try XCTUnwrap(Bundle.main.url(forResource: "sample_whiteboard", withExtension: "mp4"))
        let noExt = tempDir.appendingPathComponent("clip_without_extension")
        try FileManager.default.copyItem(at: source, to: noExt)

        let imported = try BoardViewModel.importVideo(from: noExt,
                                                      into: tempDir.appendingPathComponent("Out"))
        XCTAssertFalse((imported.lastPathComponent as NSString).pathExtension.isEmpty,
                       "应当补上扩展名，得到 \(imported.lastPathComponent)")
    }
}
