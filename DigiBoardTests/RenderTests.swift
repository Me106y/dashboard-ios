import XCTest
import Metal
@testable import DigiBoard

/// 测试用的最小纹理生产者（无输入）
private final class TestTextureSource: TextureProducer {
    let name = "TestSource"
    let inputs: [TextureHandle] = []
    let output: TextureHandle

    init(output: TextureHandle) { self.output = output }

    func produce(_ ctx: FrameContext, texture: MTLTexture) {}
}

/// 渲染层纯逻辑测试：纹理池复用 + 管线依赖校验规则
final class RenderTests: XCTestCase {

    private var device: MTLDevice!

    override func setUpWithError() throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "测试环境需要 Metal 设备")
    }

    /// 同一 spec 的纹理归还后应被复用，而不是重新分配
    func testTexturePoolReusesTexture() throws {
        let pool = TexturePool(device: device)
        let spec = TextureSpec(width: 64, height: 64, renderTarget: true)

        let first = try XCTUnwrap(pool.obtain(spec))
        XCTAssertEqual(pool.allocationCount, 1)

        pool.recycle(spec, first)
        let second = try XCTUnwrap(pool.obtain(spec))

        XCTAssertTrue(first === second, "归还后的纹理应被复用")
        XCTAssertEqual(pool.allocationCount, 1, "不应再次分配")
        XCTAssertEqual(pool.reuseCount, 1)
    }

    /// persistent 纹理不参与回收
    func testTexturePoolKeepsPersistentTextures() throws {
        let pool = TexturePool(device: device)
        let spec = TextureSpec(width: 32, height: 32, persistent: true)

        let texture = try XCTUnwrap(pool.obtain(spec))
        pool.recycle(spec, texture)

        let again = try XCTUnwrap(pool.obtain(spec))
        XCTAssertFalse(texture === again, "persistent 纹理不应被回收复用")
        XCTAssertEqual(pool.allocationCount, 2)
    }

    /// 句柄是身份：同名不同对象的句柄不算同一个
    func testHandlesUseIdentity() {
        let a = TextureHandle("same", TextureSpec(width: 8, height: 8))
        let b = TextureHandle("same", TextureSpec(width: 8, height: 8))
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(Set([a, b]).count, 2)
    }

    /// 合法图（生产者在前）应当被接受
    func testRendererAcceptsWellFormedGraph() throws {
        let a = TextureHandle("a", TextureSpec(width: 16, height: 16))
        let b = TextureHandle("b", TextureSpec(width: 16, height: 16))

        let renderer = try XCTUnwrap(Renderer(nodes: [
            TestTextureSource(output: a),
            CopyStage(name: "Copy", input: a, output: b),
        ]))
        XCTAssertEqual(renderer.nodes.count, 2)
    }

    /// 反馈边只允许出现在 persistent 纹理上（时序累积的「上一帧」就是这种边）
    func testRendererAllowsPersistentFeedbackEdge() throws {
        let mask = TextureHandle("mask", TextureSpec(width: 16, height: 16))
        let previous = TextureHandle("previous", TextureSpec(width: 16, height: 16, persistent: true))
        let next = TextureHandle("next", TextureSpec(width: 16, height: 16, persistent: true))

        // previous 由排在后面的 CopyStage 产出 —— 合法，因为它是 persistent
        let renderer = try XCTUnwrap(Renderer(nodes: [
            TestTextureSource(output: mask),
            AccumulationStage(mask: mask, previous: previous, output: next),
            CopyStage(name: "Store", input: next, output: previous),
        ]))
        XCTAssertEqual(renderer.nodes.count, 3)
    }
}
