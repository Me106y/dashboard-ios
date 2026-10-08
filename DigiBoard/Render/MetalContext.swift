import Metal
import MetalKit

/// 全局 Metal 资源：设备、命令队列、默认着色器库、渲染管线状态缓存。
final class MetalContext {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let library: MTLLibrary
    let texturePool: TexturePool

    private var pipelineStates: [String: MTLRenderPipelineState] = [:]

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else {
            return nil
        }
        self.device = device
        self.commandQueue = queue
        self.library = library
        self.texturePool = TexturePool(device: device)
    }

    /// 取得（并缓存）一条渲染管线。
    func renderPipelineState(vertex: String,
                             fragment: String,
                             colorFormat: MTLPixelFormat = .bgra8Unorm) throws -> MTLRenderPipelineState {
        let key = "\(vertex)|\(fragment)|\(colorFormat.rawValue)"
        if let cached = pipelineStates[key] { return cached }

        guard let vfn = library.makeFunction(name: vertex),
              let ffn = library.makeFunction(name: fragment) else {
            throw MetalError.missingFunction("\(vertex) / \(fragment)")
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.label = key
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = colorFormat
        let state = try device.makeRenderPipelineState(descriptor: desc)
        pipelineStates[key] = state
        return state
    }
}

enum MetalError: LocalizedError {
    case missingFunction(String)
    case noTexture(String)
    case commandBufferFailed

    var errorDescription: String? {
        switch self {
        case .missingFunction(let n): return "找不到着色器函数: \(n)"
        case .noTexture(let n):       return "阶段缺少纹理: \(n)"
        case .commandBufferFailed:    return "命令缓冲创建失败"
        }
    }
}
