import Metal

/// 纹理池：按 `TextureSpec` 复用纹理，避免上游「每个阶段各占一张全分辨率纹理」的开销。
final class TexturePool {
    private let device: MTLDevice
    private var free: [TextureSpec: [MTLTexture]] = [:]

    private(set) var allocationCount = 0
    private(set) var reuseCount = 0

    init(device: MTLDevice) {
        self.device = device
    }

    /// 取出一张满足 spec 的纹理；池中没有就新建。
    func obtain(_ spec: TextureSpec) -> MTLTexture? {
        if var bucket = free[spec], let tex = bucket.popLast() {
            free[spec] = bucket
            reuseCount += 1
            return tex
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: spec.pixelFormat,
            width: max(spec.width, 1),
            height: max(spec.height, 1),
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        if spec.renderTarget { desc.usage.insert(.renderTarget) }
        if spec.cpuWritable { desc.storageMode = .shared } else { desc.storageMode = .private }
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        tex.label = "pool \(spec.width)x\(spec.height) fmt=\(spec.pixelFormat.rawValue)"
        allocationCount += 1
        return tex
    }

    /// 归还一张纹理（persistent 的留在外面不回收）。
    func recycle(_ spec: TextureSpec, _ texture: MTLTexture) {
        guard !spec.persistent else { return }
        free[spec, default: []].append(texture)
    }

    /// 借出但未归还的纹理（persistent）也一并清掉引用，重新按需分配。
    func removeAll() {
        free.removeAll()
    }
}
