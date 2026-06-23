import Rendering

// 工作块 D D-4a:把离屏渲染的 Live2D 当前帧 BGRA8 像素 → falling-sand pet occluder 的 alpha 轮廓
// mask(纯函数,无 Metal 依赖 → 可无头单测;真实 GPU 渲染因 metallib 仅在 .app 内,视觉验收靠装好的
// app,见设计 §6.1 D-2.2)。
//
// 约定与 sprite 形象一致(`SpriteSheetPetRenderer.extractAlpha`):**row 0 = 纹理顶 = 屏幕上方**,
// Y 翻转统一在 GPU kernel `fs_rasterize_pet` 内做。取每像素 alpha 字节(0..255 原值,不阈值化 ——
// kernel 自带 alpha>阈值 判定)。
enum Live2DSilhouetteExtractor {

    /// `bgra`:离屏 target 用 `getBytes(bytesPerRow: width*4)` 读出的紧凑 BGRA8 缓冲
    /// (.bgra8Unorm → 内存序 B,G,R,A,alpha 在 byte index 3)。返回 width×height 的 alpha mask。
    /// 缓冲过短(尺寸不符)→ 返回全 0 mask(防越界,occluder 当帧不堆,下帧自愈)。
    static func extract(bgra: [UInt8], width: Int, height: Int) -> PetAlphaMask {
        let w = max(0, width), h = max(0, height)
        var mask = [UInt8](repeating: 0, count: w * h)
        let bytesPerRow = w * 4
        guard w > 0, h > 0, bgra.count >= bytesPerRow * h else {
            return PetAlphaMask(mask: mask, width: w, height: h)
        }
        for y in 0..<h {
            let rowBase = y * bytesPerRow
            for x in 0..<w {
                mask[y * w + x] = bgra[rowBase + x * 4 + 3]
            }
        }
        return PetAlphaMask(mask: mask, width: w, height: h)
    }
}
