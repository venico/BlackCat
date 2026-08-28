// FilterEngine.swift
//
// 滤镜的实际渲染。预览（ColorCompositor）和导出（ExportSheetView）**共用这一份** ——
// 两边都是在所有画面合成完之后才套滤镜，所以时间段内画面里的所有内容都受影响。
//
// 全部用 Core Image 现成的 CIFilter，不引第三方：系统自带两百多个，
// 而且这两条链本来就跑在 CIImage 上，接进来几乎零成本。

import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

enum FilterEngine {

    /// 把某一时刻该生效的滤镜全套上去。
    ///
    /// 多条轨道 = 叠加，**从下往上依次套**（数组里靠前的先作用），
    /// 跟画面图层的叠放顺序是一个道理
    static func apply(_ image: CIImage, tracks: [Track<FilterClip>], at time: Double) -> CIImage {
        var out = image
        for track in tracks where track.isVisible {
            for clip in track.clips where clip.startTime <= time && clip.endTime > time {
                out = apply(clip, to: out)
            }
        }
        return out
    }


    /// 套一段滤镜。强度靠原图和滤镜结果按比例混合，所有滤镜统一这一个参数
    static func apply(_ clip: FilterClip, to image: CIImage) -> CIImage {
        let strength = min(max(clip.intensity, 0), 1)
        guard strength > 0.001 else { return image }
        guard let filtered = raw(clip, image) else { return image }
        guard strength < 0.999 else { return filtered }

        // 按强度在原图和滤镜结果之间插值。
        // 用 CIMix 而不是 CIDissolveTransition —— 后者是**转场**滤镜，
        // 对输入有额外要求，实测拿不到输出就整个退回满强度，
        // 表现就是「强度滑块怎么拖都没反应」
        let box = image.extent
        let a = image.cropped(to: box)
        let b = filtered.cropped(to: box)
        guard let mixed = CIFilter(name: "CIMix", parameters: [
            kCIInputImageKey: b,
            kCIInputBackgroundImageKey: a,
            "inputAmount": strength
        ])?.outputImage else { return b }
        return mixed.cropped(to: box)
    }

    /// 给 CALayer.filters 用的滤镜链。跟 raw() 是同一套参数，
    /// 叠加层（图片/文字/图形是 SwiftUI 画的，不经过合成器）靠它拿到跟视频一致的效果
    static func ciFilters(for clip: FilterClip) -> [CIFilter] {
        func f(_ name: String, _ params: [String: Any] = [:]) -> [CIFilter] {
            guard let filter = CIFilter(name: name) else { return [] }
            for (k, v) in params { filter.setValue(v, forKey: k) }
            return [filter]
        }
        switch clip.kind {
        case .noir:     return f("CIPhotoEffectNoir")
        case .mono:     return f("CIPhotoEffectMono")
        case .tonal:    return f("CIPhotoEffectTonal")
        case .chrome:   return f("CIPhotoEffectChrome")
        case .instant:  return f("CIPhotoEffectInstant")
        case .process:  return f("CIPhotoEffectProcess")
        case .fade:     return f("CIPhotoEffectFade")
        case .transfer: return f("CIPhotoEffectTransfer")
        case .sepia:    return f("CISepiaTone", [kCIInputIntensityKey: 1.0])
        case .cool:
            return f("CIColorMonochrome", [
                kCIInputColorKey: CIColor(red: 0.42, green: 0.62, blue: 0.78),
                kCIInputIntensityKey: 1.0])
        case .posterize: return f("CIColorPosterize", ["inputLevels": 6.0])
        case .comic:     return f("CIComicEffect")
        case .vignette:
            return f("CIVignette", [kCIInputIntensityKey: 1.2, kCIInputRadiusKey: 1.6])
        case .vibrance:
            return f("CIVibrance", ["inputAmount": 1.0])
                 + f("CIColorControls", [kCIInputSaturationKey: 1.15,
                                         kCIInputContrastKey: 1.05])
        case .lut:
            guard let path = clip.lutPath, let cube = LUTCache.shared.cube(at: path) else { return [] }
            return f("CIColorCubeWithColorSpace", [
                "inputCubeDimension": cube.dimension,
                "inputCubeData": cube.data,
                "inputColorSpace": CGColorSpaceCreateDeviceRGB()])
        }
    }

    /// 滤镜本体（不含强度混合）
    private static func raw(_ clip: FilterClip, _ image: CIImage) -> CIImage? {
        switch clip.kind {
        case .noir:
            return image.applyingFilter("CIPhotoEffectNoir")
        case .mono:
            return image.applyingFilter("CIPhotoEffectMono")
        case .tonal:
            return image.applyingFilter("CIPhotoEffectTonal")
        case .chrome:
            return image.applyingFilter("CIPhotoEffectChrome")
        case .instant:
            return image.applyingFilter("CIPhotoEffectInstant")
        case .process:
            return image.applyingFilter("CIPhotoEffectProcess")
        case .fade:
            return image.applyingFilter("CIPhotoEffectFade")
        case .sepia:
            return image.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 1.0])
        case .cool:
            // CIColorMonochrome 是「按一个颜色重新染色」，默认灰的话就跟黑白系重复了，
            // 这里给一个青蓝，跟怀旧那条暖色正好对着
            return image.applyingFilter("CIColorMonochrome", parameters: [
                kCIInputColorKey: CIColor(red: 0.42, green: 0.62, blue: 0.78),
                kCIInputIntensityKey: 1.0
            ])
        case .posterize:
            return image.applyingFilter("CIColorPosterize", parameters: ["inputLevels": 6.0])
        case .comic:
            return image.applyingFilter("CIComicEffect")
        case .transfer:
            return image.applyingFilter("CIPhotoEffectTransfer")
        case .vibrance:
            // 鲜艳 = 自然饱和度往上提一档，再补一点整体饱和
            let v = image.applyingFilter("CIVibrance", parameters: ["inputAmount": 1.0])
            return v.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.15,
                kCIInputContrastKey: 1.05
            ])
        case .vignette:
            return image.applyingFilter("CIVignette", parameters: [
                kCIInputIntensityKey: 1.2,
                kCIInputRadiusKey: 1.6
            ])
        case .lut:
            guard let path = clip.lutPath, let cube = LUTCache.shared.cube(at: path) else { return nil }
            return image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
                "inputCubeDimension": cube.dimension,
                "inputCubeData": cube.data,
                "inputColorSpace": CGColorSpaceCreateDeviceRGB()
            ])
        }
    }
}

// MARK: - LUT

/// 解析好的 .cube 数据。解析一次缓存住 —— 每帧重新读文件太亏
final class LUTCache {
    static let shared = LUTCache()
    private var cache: [String: (dimension: Int, data: Data)] = [:]

    func cube(at path: String) -> (dimension: Int, data: Data)? {
        if let hit = cache[path] { return hit }
        guard let parsed = Self.parseCube(at: path) else { return nil }
        cache[path] = parsed
        return parsed
    }

    /// 解析 Adobe .cube：跳过注释和关键字，读 LUT_3D_SIZE 和之后的 RGB 三元组。
    /// CIColorCube 要的是 RGBA float32、**按 b→g→r 的顺序**排列
    static func parseCube(at path: String) -> (dimension: Int, data: Data)? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var dim = 0
        var values: [Float] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.uppercased().hasPrefix("LUT_3D_SIZE") {
                dim = Int(line.split(separator: " ").last.map(String.init) ?? "") ?? 0
                continue
            }
            // 其余关键字（TITLE、DOMAIN_MIN…）一律跳过
            if line.first?.isLetter == true { continue }
            let parts = line.split(separator: " ").compactMap { Float($0) }
            guard parts.count >= 3 else { continue }
            values.append(contentsOf: [parts[0], parts[1], parts[2], 1.0])
        }
        guard dim > 1, values.count == dim * dim * dim * 4 else { return nil }
        return (dim, Data(bytes: values, count: values.count * MemoryLayout<Float>.size))
    }
}
