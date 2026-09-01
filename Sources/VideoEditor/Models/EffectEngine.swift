// EffectEngine.swift
//
// 特效的类型表和渲染。跟滤镜（FilterEngine）分开：滤镜只改颜色、参数只有强度；
// 特效大多带尺寸（半径、格子大小）和位置（中心点），得按画面尺寸换算。
//
// **尺寸参数一律归一化存 0~1**，渲染时才乘画面宽度 —— 存像素值的话，
// 半径 10 在 1080p 上很明显，到 4K 就几乎看不见，换个分辨率导出效果就变了。

import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

enum EffectKind: String, Codable, CaseIterable {
    // 模糊
    case gaussianBlur, motionBlur, zoomBlur, bokeh
    // 风格化
    case pixellate, crystallize, pointillize, bloom, gloom
    // 线条
    case edges, edgeWork, lineOverlay
    // 半调网点
    case cmykHalftone, dotScreen, lineScreen, circularScreen, hatchedScreen
    // 扭曲
    case twirl, vortex, bump, pinch, hole, circleSplash, lightTunnel
    // 锐化 / 降噪
    case unsharpMask, noiseReduction

    var label: String {
        switch self {
        case .gaussianBlur: return "高斯模糊"
        case .motionBlur:   return "动感模糊"
        case .zoomBlur:     return "缩放模糊"
        case .bokeh:        return "散景"
        case .pixellate:    return "像素化"
        case .crystallize:  return "晶格"
        case .pointillize:  return "点画"
        case .bloom:        return "辉光"
        case .gloom:        return "暗辉"
        case .edges:        return "边缘"
        case .edgeWork:     return "线稿"
        case .lineOverlay:  return "素描"
        case .cmykHalftone: return "彩色半调"
        case .dotScreen:    return "点网屏"
        case .lineScreen:   return "线网屏"
        case .circularScreen: return "圆网屏"
        case .hatchedScreen:  return "交叉线"
        case .twirl:        return "旋转扭曲"
        case .vortex:       return "漩涡"
        case .bump:         return "凸起"
        case .pinch:        return "挤压"
        case .hole:         return "黑洞"
        case .circleSplash: return "圆形飞溅"
        case .lightTunnel:  return "光隧道"
        case .unsharpMask:  return "锐化"
        case .noiseReduction: return "降噪"
        }
    }

    var filterName: String {
        switch self {
        case .gaussianBlur: return "CIGaussianBlur"
        case .motionBlur:   return "CIMotionBlur"
        case .zoomBlur:     return "CIZoomBlur"
        case .bokeh:        return "CIBokehBlur"
        case .pixellate:    return "CIPixellate"
        case .crystallize:  return "CICrystallize"
        case .pointillize:  return "CIPointillize"
        case .bloom:        return "CIBloom"
        case .gloom:        return "CIGloom"
        case .edges:        return "CIEdges"
        case .edgeWork:     return "CIEdgeWork"
        case .lineOverlay:  return "CILineOverlay"
        case .cmykHalftone: return "CICMYKHalftone"
        case .dotScreen:    return "CIDotScreen"
        case .lineScreen:   return "CILineScreen"
        case .circularScreen: return "CICircularScreen"
        case .hatchedScreen:  return "CIHatchedScreen"
        case .twirl:        return "CITwirlDistortion"
        case .vortex:       return "CIVortexDistortion"
        case .bump:         return "CIBumpDistortion"
        case .pinch:        return "CIPinchDistortion"
        case .hole:         return "CIHoleDistortion"
        case .circleSplash: return "CICircleSplashDistortion"
        case .lightTunnel:  return "CILightTunnel"
        case .unsharpMask:  return "CIUnsharpMask"
        case .noiseReduction: return "CINoiseReduction"
        }
    }

    /// 主参数（`amount` 0~1）满值时，对应画面宽度的多少倍。
    /// nil = 这个特效没有尺寸参数
    var amountScale: Double? {
        switch self {
        case .gaussianBlur, .bokeh:   return 0.05
        case .motionBlur:             return 0.06
        case .zoomBlur:               return 0.10
        case .pixellate, .crystallize, .pointillize: return 0.06
        case .bloom, .gloom:          return 0.04
        case .edgeWork:               return 0.01
        case .cmykHalftone, .dotScreen, .lineScreen,
             .circularScreen, .hatchedScreen:        return 0.03
        // 扭曲类的半径要够大才看得出来：满值 = 一整个画面宽
        case .twirl, .vortex, .bump, .pinch, .hole:  return 1.0
        // 这两个是反的（见 EffectEngine.raw），量程另算
        case .circleSplash, .lightTunnel:            return 0.35
        case .unsharpMask:            return 0.01
        case .edges, .lineOverlay, .noiseReduction:  return nil
        }
    }

    /// 主参数的默认值
    var defaultAmount: Double {
        switch self {
        // 漩涡的半径要铺满画面才够看：半径半屏时只改动 14%，铺满能到 42%
        case .vortex: return 1.0
        case .twirl, .bump, .pinch, .hole, .circleSplash, .lightTunnel: return 0.5
        case .edgeWork, .unsharpMask: return 0.4
        default: return 0.3
        }
    }

    /// 角度的默认值。旋转和漩涡角度为 0 就是「不转」，等于没效果，
    /// 所以这两个必须带一个初始角度
    var defaultAngle: Double {
        switch self {
        case .twirl:  return 180
        case .vortex: return 3600
        case .motionBlur: return 0
        default: return 0
        }
    }

    /// 角度的取值范围。
    ///
    /// 漩涡的角度是「总共转多少圈」，实测 90° 根本看不出来、要 360° 往上才明显，
    /// 所以它的量程比别的大得多；方向类（动感模糊、网屏倾角）一圈就够
    var angleRange: ClosedRange<Double> {
        switch self {
        // 漩涡要**很大**的角度才看得出来：实测在 1920 宽的画面上，
        // 720° 只改动 14% 的画面，2160° 到 42%，5400° 才有 69%
        case .vortex: return 0...7200
        case .twirl:  return 0...720
        default:      return 0...360
        }
    }

    /// 用不用角度（动感模糊的方向、网屏的倾角）
    var usesAngle: Bool {
        switch self {
        case .motionBlur, .cmykHalftone, .dotScreen, .lineScreen,
             .circularScreen, .hatchedScreen, .twirl, .vortex, .lightTunnel:
            return true
        default: return false
        }
    }

    /// 用不用中心点（扭曲类和以某点为中心铺开的那些）
    var usesCenter: Bool {
        switch self {
        case .zoomBlur, .pixellate, .crystallize, .pointillize,
             .cmykHalftone, .dotScreen, .lineScreen, .circularScreen, .hatchedScreen,
             .twirl, .vortex, .bump, .pinch, .hole, .circleSplash, .lightTunnel:
            return true
        default: return false
        }
    }

    /// 要不要先把边缘像素向外延伸。向外采样的那些（模糊、辉光、锐化）都要，
    /// 否则贴着图层边界的一圈会跟外面的透明混在一起
    var needsEdgeClamp: Bool {
        switch self {
        case .gaussianBlur, .motionBlur, .zoomBlur, .bokeh,
             .bloom, .gloom, .unsharpMask, .noiseReduction, .edgeWork:
            return true
        default: return false
        }
    }

    /// 会改变几何形状的那些。这类套在叠加层上要留意：图片会被推得离开原位
    var isGeometric: Bool {
        switch self {
        case .twirl, .vortex, .bump, .pinch, .hole, .circleSplash, .lightTunnel:
            return true
        default: return false
        }
    }
}

struct EffectClip: Identifiable, Equatable, Codable {
    var id = UUID()
    var kind: EffectKind = .gaussianBlur
    var startTime: Double
    var endTime: Double
    var duration: Double { endTime - startTime }
    /// 强度 0~1。跟滤镜一样靠原图和结果混合
    var intensity: Double = 1
    /// 主参数 0~1，渲染时按 `kind.amountScale` 换算成像素
    var amount: Double = 0.3
    /// 角度，度
    var angle: Double = 0
    /// 中心点，0~1 的画面坐标
    var centerX: Double = 0.5
    var centerY: Double = 0.5

    var name: String { kind.label }

    enum CodingKeys: String, CodingKey {
        case id, kind, startTime, endTime, intensity, amount, angle, centerX, centerY
    }
    init(kind: EffectKind = .gaussianBlur, startTime: Double, endTime: Double) {
        self.kind = kind; self.startTime = startTime; self.endTime = endTime
        self.amount = kind.defaultAmount
        self.angle = kind.defaultAngle
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = (try? c.decode(EffectKind.self, forKey: .kind)) ?? .gaussianBlur
        startTime = try c.decode(Double.self, forKey: .startTime)
        endTime = try c.decode(Double.self, forKey: .endTime)
        intensity = (try? c.decode(Double.self, forKey: .intensity)) ?? 1
        amount = (try? c.decode(Double.self, forKey: .amount)) ?? kind.defaultAmount
        angle = (try? c.decode(Double.self, forKey: .angle)) ?? kind.defaultAngle
        centerX = (try? c.decode(Double.self, forKey: .centerX)) ?? 0.5
        centerY = (try? c.decode(Double.self, forKey: .centerY)) ?? 0.5
    }
}

enum EffectEngine {

    /// 某一时刻该生效的特效全套上。多条轨道从下往上依次套
    static func apply(_ image: CIImage, tracks: [Track<EffectClip>],
                      at time: Double, renderSize: CGSize) -> CIImage {
        var out = image
        for track in tracks where track.isVisible {
            for clip in track.clips where clip.startTime <= time && clip.endTime > time {
                out = apply(clip, to: out, renderSize: renderSize)
            }
        }
        return out
    }

    /// 套一段特效。强度用原图和结果按比例混合，跟滤镜同一套做法
    static func apply(_ clip: EffectClip, to image: CIImage, renderSize: CGSize) -> CIImage {
        let strength = min(max(clip.intensity, 0), 1)
        guard strength > 0.001 else { return image }
        let box = image.extent
        guard let raw = raw(clip, image, renderSize: renderSize) else { return image }
        // 模糊、扭曲这些会把画面撑出原来的框，裁回去才不会越叠越大。
        // 反过来，挤压这类会把画面往里收，边上露出一圈空白。
        // **补空白要用边缘像素向外延伸，不能拿原图垫** ——
        // 垫原图等于在效果底下又铺了一张没扭曲的画面，实测挤压的效果
        // 会从改动 77% 的画面掉到只剩 6%
        var filtered = raw.cropped(to: box)
        if filtered.extent != box {
            filtered = raw.clampedToExtent().cropped(to: box)
        }
        guard strength < 0.999 else { return filtered }
        guard let mixed = CIFilter(name: "CIMix", parameters: [
            kCIInputImageKey: filtered,
            kCIInputBackgroundImageKey: image.cropped(to: box),
            "inputAmount": strength
        ])?.outputImage else { return filtered }
        return mixed.cropped(to: box)
    }

    /// 给 CALayer.filters 用的滤镜链。叠加层（图片/文字/图形是 SwiftUI 画的）
    /// 靠它拿到跟视频画面一致的效果
    static func ciFilters(for clip: EffectClip, renderSize: CGSize) -> [CIFilter] {
        guard let f = configured(clip, renderSize: renderSize) else { return [] }
        // 模糊那几个要向外采样，而图层边界之外是透明的 ——
        // 不先把边缘像素向四周延伸，上下边缘就会跟透明混成一片，看着像没糊。
        // 视频那条链走的是整帧 CIImage，本来就没这个问题
        if clip.kind.needsEdgeClamp, let clamp = CIFilter(name: "CIAffineClamp") {
            clamp.setValue(CGAffineTransform.identity, forKey: "inputTransform")
            return [clamp, f]
        }
        return [f]
    }

    private static func raw(_ clip: EffectClip, _ image: CIImage, renderSize: CGSize) -> CIImage? {
        guard let f = configured(clip, renderSize: renderSize) else { return nil }
        f.setValue(image, forKey: kCIInputImageKey)
        return f.outputImage
    }

    /// 按 clip 把参数都配好的滤镜（不含输入图）
    private static func configured(_ clip: EffectClip, renderSize: CGSize) -> CIFilter? {
        guard let f = CIFilter(name: clip.kind.filterName) else { return nil }

        let w = max(renderSize.width, 1)
        let amt = min(max(clip.amount, 0), 1)

        // 主参数。不同滤镜叫法不同，但含义都是「尺寸」，统一按画面宽度换算
        if let scale = clip.kind.amountScale {
            var px = amt * scale * Double(w)
            // 圆形飞溅和光隧道是「把半径内的画面向外拉伸铺满」：
            // 半径越大，留在原地没被拉伸的部分越多，效果反而越弱 ——
            // 实测半径到画面一半就完全看不出变化了。
            // 这里把主参数反过来映射，滑块往右才仍旧是「效果更强」
            if clip.kind == .circleSplash || clip.kind == .lightTunnel {
                px = (1.0 - amt * 0.92) * scale * Double(w)
            }
            for key in ["inputRadius", "inputScale", "inputWidth", "inputAmount"]
            where f.inputKeys.contains(key) {
                // CIBumpDistortion / CIPinchDistortion 的 inputScale 是形变量不是尺寸，
                // 它跟半径是两个东西，这里只喂给半径，形变量另外给
                if key == "inputScale", clip.kind == .bump || clip.kind == .pinch { continue }
                f.setValue(px, forKey: key)
                break
            }
            if clip.kind == .bump || clip.kind == .pinch {
                f.setValue(px, forKey: "inputRadius")
                // 形变量 -1~1，用强度来控制方向和大小
                if f.inputKeys.contains("inputScale") {
                    f.setValue(clip.kind == .pinch ? amt : amt * 1.5, forKey: "inputScale")
                }
            }
        }
        // 没有尺寸参数的那几个，主参数当强度用
        if clip.kind == .edges, f.inputKeys.contains(kCIInputIntensityKey) {
            f.setValue(amt * 10, forKey: kCIInputIntensityKey)
        }
        if clip.kind == .noiseReduction {
            f.setValue(amt * 0.1, forKey: "inputNoiseLevel")
            f.setValue(0.4, forKey: "inputSharpness")
        }
        // 辉光和锐化除了半径还有自己的强度
        if clip.kind == .bloom || clip.kind == .gloom || clip.kind == .unsharpMask,
           f.inputKeys.contains(kCIInputIntensityKey) {
            f.setValue(1.0, forKey: kCIInputIntensityKey)
        }

        if clip.kind.usesAngle, f.inputKeys.contains(kCIInputAngleKey) {
            f.setValue(clip.angle * .pi / 180.0, forKey: kCIInputAngleKey)
        }
        if clip.kind == .lightTunnel, f.inputKeys.contains("inputRotation") {
            f.setValue(clip.angle * .pi / 180.0, forKey: "inputRotation")
        }
        if clip.kind.usesCenter, f.inputKeys.contains(kCIInputCenterKey) {
            // 中心点存的是 0~1 的画面坐标，**y 轴要翻过来** ——
            // Core Image 的原点在左下角，界面上是左上角
            f.setValue(CIVector(x: clip.centerX * Double(renderSize.width),
                                y: (1 - clip.centerY) * Double(renderSize.height)),
                       forKey: kCIInputCenterKey)
        }
        return f
    }
}
