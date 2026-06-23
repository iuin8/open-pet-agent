import AppKit
import Metal
import Live2DBridge

// 工作块 D —— Live2D 模型缩略图生成(设置 picker 预览图)。
//
// Live2D 模型包只带纹理图集(拆散的 mesh 零件,不是可用预览),也不带现成 preview。要真预览图只能
// 把模型离屏渲一帧 → 截图。本生成器:加载模型 → `renderThumbnailInCommandBuffer`(Update 一帧摆好
// 姿势 + DrawModel)渲进 `.shared` 离屏纹理 → 读回 BGRA → 裁掉四周透明边 → 存
// `<model3 同级>/.petagent-thumb.png`。`Live2DModelPackLoader.discover` 读该缓存当 picker 缩略图。
//
// 需 GPU + Cubism metallib(仅装好的 .app 内有)。`@MainActor`:Cubism 全局态非线程安全(桥内
// `@synchronized` 串行,与主线程 display 渲染同源)。
@MainActor
public enum Live2DThumbnailGenerator {

    /// 离屏渲染分辨率(裁剪前)。够大保证缩到 picker 40px 仍清晰。
    private static let renderSize = 256

    /// 缓存文件名(放 model3.json 同级目录,discover 据 model3 URL 找得到)。
    public static let cacheFileName = ".petagent-thumb.png"

    /// model3 同级的缓存缩略图 URL。
    public static func cacheURL(forModel3 model3URL: URL) -> URL {
        model3URL.deletingLastPathComponent().appendingPathComponent(cacheFileName)
    }

    /// 已有缓存则直接返回路径,不重渲(供「仅缺失才生成」)。
    public static func cachedURLIfExists(forModel3 model3URL: URL) -> URL? {
        let url = cacheURL(forModel3: model3URL)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 渲染并缓存。成功返回缓存 URL;模型加载失败 / 无 GPU / 渲染空 → nil。
    @discardableResult
    public static func generateAndCache(model3URL: URL) -> URL? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let model = L2DLive2DModel(model3Path: model3URL.path, device: device)
        else { return nil }

        let n = renderSize
        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: n, height: n, mipmapped: false)
        colorDesc.usage = [.renderTarget, .shaderRead]
        colorDesc.storageMode = .shared                       // 统一内存:渲染 + CPU 读回
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: n, height: n, mipmapped: false)
        depthDesc.usage = .renderTarget
        depthDesc.storageMode = .private
        guard let color = device.makeTexture(descriptor: colorDesc),
              let depth = device.makeTexture(descriptor: depthDesc),
              let commandBuffer = queue.makeCommandBuffer()
        else { return nil }

        model.renderThumbnail(in: commandBuffer, targetTexture: color, depthTexture: depth,
                              width: Double(n), height: Double(n))
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        var bgra = [UInt8](repeating: 0, count: n * n * 4)
        bgra.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            color.getBytes(base, bytesPerRow: n * 4, from: MTLRegionMake2D(0, 0, n, n), mipmapLevel: 0)
        }

        guard let image = trimmedImage(bgra: bgra, side: n) else { return nil }
        let url = cacheURL(forModel3: model3URL)
        guard writePNG(image, to: url) else { return nil }
        return url
    }

    /// BGRA(premultiplied,row 0 = 顶)→ 裁掉四周透明边的 NSImage。全透明 → nil。
    private static func trimmedImage(bgra: [UInt8], side n: Int) -> NSImage? {
        var minX = n, minY = n, maxX = -1, maxY = -1
        for y in 0..<n {
            for x in 0..<n where bgra[(y * n + x) * 4 + 3] > 8 {   // alpha 字节(BGRA 第 4)
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if y < minY { minY = y }; if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }       // 全透明 = 空渲

        let cropW = maxX - minX + 1, cropH = maxY - minY + 1
        let pad = max(2, min(cropW, cropH) / 20)                   // 轻微留边,不贴死
        let x0 = max(0, minX - pad), y0 = max(0, minY - pad)
        let x1 = min(n - 1, maxX + pad), y1 = min(n - 1, maxY + pad)
        let w = x1 - x0 + 1, h = y1 - y0 + 1

        var cropped = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            let srcRow = (y0 + y) * n * 4
            let dstRow = y * w * 4
            for b in 0..<(w * 4) { cropped[dstRow + b] = bgra[srcRow + x0 * 4 + b] }
        }

        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let provider = CGDataProvider(data: Data(cropped) as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: w * 4, space: cs, bitmapInfo: CGBitmapInfo(rawValue: info),
                               provider: provider, decode: nil, shouldInterpolate: true,
                               intent: .defaultIntent)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: w, height: h))
    }

    private static func writePNG(_ image: NSImage, to url: URL) -> Bool {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return false }
        return (try? png.write(to: url)) != nil
    }
}
