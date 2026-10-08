import Metal

/// 纹理规格：纹理池按 (宽, 高, 像素格式, 保留策略, 存储模式) 复用同一批纹理。
struct TextureSpec: Hashable {
    let width: Int
    let height: Int
    let pixelFormat: MTLPixelFormat
    /// 跨帧保留（时序累积、双缓冲等阶段需要），不参与回收。
    let persistent: Bool
    /// 是否作为渲染目标使用。
    let renderTarget: Bool
    /// 需要 CPU 侧写入（图像上传、Core ML 结果回填）→ 用 .shared 存储。
    let cpuWritable: Bool

    init(width: Int,
         height: Int,
         pixelFormat: MTLPixelFormat = .rgba8Unorm,
         persistent: Bool = false,
         renderTarget: Bool = true,
         cpuWritable: Bool = false) {
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        self.persistent = persistent
        self.renderTarget = renderTarget
        self.cpuWritable = cpuWritable
    }

    /// 全屏输出用的 drawable 规格占位（实际尺寸每帧由 MTKView 决定）。
    static let drawable = TextureSpec(width: 0, height: 0, pixelFormat: .bgra8Unorm,
                                      persistent: true, renderTarget: true, cpuWritable: false)
}

/// 纹理句柄：阶段的输入/输出用它表达（决策 D13：显式声明依赖，不靠构造顺序）。
///
/// 句柄是**身份**（按对象引用区分），不是内存。真正的 `MTLTexture` 由 `TexturePool`
/// 每帧按句柄的 `spec` 解析出来。
final class TextureHandle {
    let name: String
    let spec: TextureSpec

    init(_ name: String, _ spec: TextureSpec) {
        self.name = name
        self.spec = spec
    }
}

extension TextureHandle: Hashable {
    static func == (lhs: TextureHandle, rhs: TextureHandle) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
