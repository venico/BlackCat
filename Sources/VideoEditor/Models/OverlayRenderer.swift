// OverlayRenderer.swift
//
// 叠加层（图片 / 字幕 / 文字 / 图形 / 复合片段）渲染成 CIImage。
//
// **导出和预览共用这一份**。原先这些函数只长在导出里，预览另有一套用 SwiftUI 画的，
// 于是同一个特效在两边表现不一样 —— 尤其是漩涡这类改变几何的：
// 预览里图片自己扭一遍、视频在合成器里另扭一遍，两份扭曲对不上，
// 图片扭开之后就露出下面没对齐的视频，看着像「效果底下压着一张老图」。
// 导出没这个毛病，因为那边是先把所有图层合成成一帧，再对整帧做特效。
//
// 搬到这里之后，预览也走同一条路：合成器把叠加层画进帧里，特效作用于整帧。

import AVFoundation
import AppKit
import CoreImage
import SwiftUI
import Foundation

enum OverlayRenderer {

    struct SubtitleRenderInfo {
        let tracks: [(track: Track<SubtitleClip>, style: SubtitleStyle)]
        let fontScale: CGFloat
        let bottomMargin: Double
        let lineSpacing: CGFloat
        let renderSize: CGSize

        var hasSubtitles: Bool { !tracks.isEmpty }
    }

    static func composeCompoundOverlays(
        trackID: UUID,
        tracks: [Track<CompoundClip>],
        atTime targetTime: Double,
        onto image: CIImage,
        renderSize: CGSize,
        imageCICache: [URL: CIImage],
        subtitleInfo: SubtitleRenderInfo
    ) -> CIImage {
        guard let track = tracks.first(where: { $0.id == trackID && $0.isVisible }),
              let rawCompound = track.clips.first(where: {
                  $0.startTime <= targetTime && $0.endTime > targetTime
              })
        else { return image }

        var image = image
        let compound = rawCompound.flattened()
        let it = targetTime - compound.startTime + compound.internalStart

        // 按复合片段**自己的** overlayTrackOrder 从底到顶叠，跟预览同一份清单。
        // 原来这里是写死的类型顺序（图片→字幕→文字→图形），预览那边也写死但顺序
        // 还不一样（图片→图形→文字→字幕），于是同一个复合片段预览和成片叠得不同，
        // 两边又都跟进入复合片段编辑后看到的顺序对不上
        let layers = compound.overlayLayersBottomUp
        var subtitleDone = false

        for ref in layers {
            switch ref {
            case .image(let tid):
                if let track = compound.imageTracks.first(where: { $0.id == tid }), track.isVisible,
                   let clip = track.clips.first(where: { $0.startTime <= it && $0.endTime > it }),
                   let overlay = renderImageOverlay(clip: clip, renderSize: renderSize,
                                                    ciCache: imageCICache) {
                    image = overlay.composited(over: image)
                }
            case .subtitle:
                // 多条字幕轨作为一组排版，只在第一条那层整组画出来
                guard !subtitleDone else { break }
                subtitleDone = true
                let cSubTracks = compound.orderedSubtitleTracks
                    .filter(\.isVisible)
                    .map { t in (track: t, style: t.subtitleStyle ?? SubtitleStyle()) }
                if !cSubTracks.isEmpty {
                    let cSubInfo = SubtitleRenderInfo(
                        tracks: cSubTracks, fontScale: subtitleInfo.fontScale,
                        bottomMargin: subtitleInfo.bottomMargin,
                        lineSpacing: subtitleInfo.lineSpacing, renderSize: renderSize)
                    if let overlay = renderSubtitleOverlay(atTime: it, info: cSubInfo) {
                        image = overlay.composited(over: image)
                    }
                }
            case .text(let tid):
                if let track = compound.textTracks.first(where: { $0.id == tid }), track.isVisible,
                   let overlay = renderTextOverlay(atTime: it, clips: track.clips,
                                                   fontScale: subtitleInfo.fontScale,
                                                   renderSize: renderSize) {
                    image = overlay.composited(over: image)
                }
            case .shape(let tid):
                if let track = compound.shapeTracks.first(where: { $0.id == tid }), track.isVisible,
                   let overlay = renderShapeOverlay(atTime: it, clips: track.clips,
                                                    scale: subtitleInfo.fontScale,
                                                    renderSize: renderSize) {
                    image = overlay.composited(over: image)
                }
            case .filter, .adjust, .effect:
                break   // 复合片段内部没有滤镜/调节/特效轨道
            case .compound(let tid):
                // flattened() 已经把嵌套摊平了，正常走不到这条；真有残留就递归处理
                image = composeCompoundOverlays(
                    trackID: tid, tracks: compound.compoundTracks, atTime: it,
                    onto: image, renderSize: renderSize,
                    imageCICache: imageCICache, subtitleInfo: subtitleInfo)
            }
        }

        return image
    }

    /// 应用 preferredTransform 后的尺寸（手机竖拍视频的 naturalSize 是横的）
    static func orientedNaturalSize(raw: CGSize, transform: CGAffineTransform?) -> CGSize {
        guard let tf = transform else { return raw }
        let applied = raw.applying(tf)
        let w = abs(applied.width), h = abs(applied.height)
        return (w > 0 && h > 0) ? CGSize(width: w, height: h) : raw
    }

    static func renderImageOverlay(
        clip: ImageClip, renderSize: CGSize, ciCache: [URL: CIImage]
    ) -> CIImage? {
        guard let url = clip.imageURL,
              // 导出会预先把所有图读进 ciCache；预览这边不预热，缓存里没有就现读。
              // 少了这条兜底，预览里图片图层会整个画不出来
              var ciImg = ciCache[url] ?? loadCI(url) else { return nil }
        let natW = ciImg.extent.width
        let natH = ciImg.extent.height
        guard natW > 0, natH > 0 else { return nil }
        let rw = renderSize.width
        let rh = renderSize.height

        // 裁剪（归一化比例，先对原始图片裁剪）
        let cropL = CGFloat(clip.cropLeft)
        let cropR = CGFloat(clip.cropRight)
        let cropT = CGFloat(clip.cropTop)
        let cropB = CGFloat(clip.cropBottom)
        if cropL > 0.001 || cropR > 0.001 || cropT > 0.001 || cropB > 0.001 {
            let cx = natW * cropL
            let cy = natH * cropB   // CIImage y-up: cropBottom 从底部裁
            let cw = natW * (1 - cropL - cropR)
            let ch = natH * (1 - cropT - cropB)
            guard cw > 0, ch > 0 else { return nil }
            ciImg = ciImg.cropped(to: CGRect(x: cx, y: cy, width: cw, height: ch))
        }

        // 圆角：切在裁剪之后、变换之前，跟预览里 clipShape 的位置对应。
        // 用 CIRoundedRectangleGenerator 生成一张圆角白图当遮罩，
        // 再拿它把图片的四角抠掉
        if clip.corner > 0.01 {
            let box = ciImg.extent
            if box.width > 1, box.height > 1,
               let gen = CIFilter(name: "CIRoundedRectangleGenerator") {
                let r = min(CGFloat(clip.corner), min(box.width, box.height) / 2)
                gen.setValue(CIVector(cgRect: box), forKey: "inputExtent")
                gen.setValue(r, forKey: "inputRadius")
                gen.setValue(CIColor.white, forKey: "inputColor")
                if let mask = gen.outputImage?.cropped(to: box) {
                    ciImg = ciImg.applyingFilter("CIBlendWithAlphaMask", parameters: [
                        kCIInputBackgroundImageKey: CIImage.empty(),
                        kCIInputMaskImageKey: mask
                    ]).cropped(to: box)
                }
            }
        }

        // 整幅画面（未裁剪）的范围。旋转锚点和 fit 尺寸都以它为准，
        // 裁剪只遮住一块、不改变画面的缩放和位置
        let fullExtent = CGRect(x: 0, y: 0, width: natW, height: natH)
        let fullCX = fullExtent.midX, fullCY = fullExtent.midY

        // 镜像 / 旋转：绕**整幅画面**中心，在源坐标里做（跟 ColorCompositor 同一套规则）。
        // 以前是 fit 之后绕画布中心转，预览那边又是绕画面中心，两边对不上；
        // 而且按旋转前的方向 fit 完再转，画面跟画布必然错位
        var mt = CGAffineTransform.identity
        if clip.mirrorH || clip.mirrorV || clip.rotation != 0 {
            mt = CGAffineTransform(translationX: -fullCX, y: -fullCY)
            if clip.mirrorH { mt = mt.concatenating(CGAffineTransform(scaleX: -1, y: 1)) }
            if clip.mirrorV { mt = mt.concatenating(CGAffineTransform(scaleX: 1, y: -1)) }
            let rad = CGFloat(clip.rotation) * .pi / 180
            if abs(rad) > 0.001 { mt = mt.concatenating(CGAffineTransform(rotationAngle: rad)) }
            mt = mt.concatenating(CGAffineTransform(translationX: fullCX, y: fullCY))
            ciImg = ciImg.transformed(by: mt)
        }

        // 旋转后整幅画面占的范围：90°/270° 时宽高互换，fit 据此按新方向适配画布
        let rotFull = fullExtent.applying(mt)

        // 缩放：baseScale 让整幅画面 fit 画布，再乘用户 scaleX/scaleY。
        // **倍率按 `rotatedFitSize` 算，不是按 rotFull** —— 只有正 90°/270° 换宽高，
        // 任意角度按外接矩形算的话画面会随着旋转一起缩放（预览侧同一套规则）
        let fitBasis = rotatedFitSize(fullExtent.size, rotation: clip.rotation)
        let baseScale = min(rw / fitBasis.width, rh / fitBasis.height)
        let sx = baseScale * CGFloat(clip.scaleX)
        let sy = baseScale * CGFloat(clip.scaleY)

        // 位移：offsetX/offsetY 是归一化值（-1...1），0 = 居中
        let centerX = rw / 2 + CGFloat(clip.offsetX) * rw
        let centerY = rh / 2 + CGFloat(clip.offsetY) * rh

        // CIImage 变换：先移到原点 → 缩放 → 移到目标中心
        // CIImage 是 y-up 坐标系
        var t = CGAffineTransform(translationX: -rotFull.origin.x, y: -rotFull.origin.y)   // 归零
        t = t.concatenating(CGAffineTransform(scaleX: sx, y: sy))
        let scaledW = rotFull.width * sx
        let scaledH = rotFull.height * sy
        // CIImage y-up: centerY 需要翻转（renderSize 的 y 轴是 y-down）
        let destX = centerX - scaledW / 2
        let destY = (rh - centerY) - scaledH / 2
        t = t.concatenating(CGAffineTransform(translationX: destX, y: destY))

        ciImg = ciImg.transformed(by: t)

        // 色调调节
        let adj = clip.colorAdjust
        if !adj.isIdentity {
            ciImg = ColorAdjust.apply(ciImg, adj)
        }

        // 描边放在色调之后，颜色才不会被色调调节带跑。strokeW 是画布像素单位，与预览同尺度
        ciImg = ImageStroke.apply(to: ciImg,
                                  width: CGFloat(clip.strokeW),
                                  color: clip.strokeColor,
                                  softness: clip.strokeSoft)

        // 图层自身的不透明度，放在最后（描边也要一起变淡）
        if clip.alpha < 0.999 {
            ciImg = ciImg.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(clip.alpha))
            ])
        }

        // 裁剪到画布范围
        ciImg = ciImg.cropped(to: CGRect(origin: .zero, size: renderSize))

        return ciImg
    }

    static func renderSubtitleOverlay(
        atTime time: Double, info: SubtitleRenderInfo
    ) -> CIImage? {
        // 找出当前时间活跃的字幕
        var activeItems: [(text: String, style: SubtitleStyle)] = []
        for (track, style) in info.tracks {
            if let clip = track.clips.first(where: { $0.startTime <= time && $0.endTime > time }) {
                let text = style.mergeLineBreaks ? mergeBreaks(clip.text) : clip.text
                activeItems.append((text, style))
            }
        }
        guard !activeItems.isEmpty else { return nil }

        let w = Int(info.renderSize.width)
        let h = Int(info.renderSize.height)
        guard w > 0, h > 0 else { return nil }

        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        // 透明背景（默认就是全 0）
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))

        // CGContext 默认 y-up → 翻转为 y-down
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1.0, y: -1.0)

        let scale = info.fontScale
        let padH: CGFloat = 10 * scale, padV: CGFloat = 3 * scale
        let bottomPad = CGFloat(h) * CGFloat(info.bottomMargin) / 100.0

        struct SubLayout {
            let text: String; let style: SubtitleStyle; let ctFont: CTFont
            let layerW: CGFloat; let layerH: CGFloat
            let setter: CTFramesetter
        }

        var layouts: [SubLayout] = []
        for item in activeItems {
            let scaledSize = item.style.fontSize * scale
            var ctFont = CTFontCreateWithName(item.style.fontName as CFString, scaledSize, nil)
            if item.style.bold,
               let bf = CTFontCreateCopyWithSymbolicTraits(ctFont, scaledSize, nil, .boldTrait, .boldTrait) { ctFont = bf }
            if item.style.italic {
                var skew = CGAffineTransform(a: 1, b: 0, c: 0.21, d: 1, tx: 0, ty: 0)
                ctFont = CTFontCreateCopyWithAttributes(ctFont, scaledSize, &skew, nil)
            }

            let tc = NSColor(item.style.textColor).usingColorSpace(.sRGB) ?? .white
            var tr: CGFloat = 1, tg: CGFloat = 1, tb: CGFloat = 1, ta: CGFloat = 1
            tc.getRed(&tr, green: &tg, blue: &tb, alpha: &ta)
            let textCGColor = CGColor(red: tr, green: tg, blue: tb, alpha: ta)

            var alignment: CTTextAlignment
            switch item.style.alignment {
            case "left":  alignment = .left
            case "right": alignment = .right
            default:      alignment = .center
            }
            let ctPS: CTParagraphStyle = withUnsafeBytes(of: &alignment) { ptr in
                var setting = CTParagraphStyleSetting(
                    spec: .alignment,
                    valueSize: MemoryLayout<CTTextAlignment>.size,
                    value: ptr.baseAddress!)
                return CTParagraphStyleCreate(&setting, 1)
            }

            let attrs: [NSAttributedString.Key: Any] = [
                .init(kCTFontAttributeName as String): ctFont,
                .init(kCTForegroundColorAttributeName as String): textCGColor,
                .init(kCTParagraphStyleAttributeName as String): ctPS
            ]
            let attrStr = NSAttributedString(string: item.text, attributes: attrs)
            let setter = CTFramesetterCreateWithAttributedString(attrStr)
            // 层尺寸走 SubtitleStyle.layerSize —— 跟预览共用同一份计算。
            // 预览那边原来靠 SwiftUI 实测高度再异步写回 state，快速拖播放头会出竞态
            let layer = item.style.layerSize(text: item.text, scale: scale, renderWidth: CGFloat(w))
            layouts.append(SubLayout(text: item.text, style: item.style, ctFont: ctFont,
                                     layerW: layer.width, layerH: layer.height, setter: setter))
        }

        var yPos = CGFloat(h) - bottomPad
        for layout in layouts.reversed() {
            yPos -= layout.layerH
            let xOrig = (CGFloat(w) - layout.layerW) / 2

            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 1 * scale, height: 1 * scale),
                          blur: 1 * scale,
                          color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.8))

            if layout.style.backgroundOpacity > 0 {
                let nc = NSColor(layout.style.backgroundColor).usingColorSpace(.sRGB) ?? .black
                var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
                nc.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
                ctx.setFillColor(CGColor(red: br, green: bg, blue: bb,
                                         alpha: CGFloat(layout.style.backgroundOpacity)))
                let bgPath = CGPath(roundedRect: CGRect(x: xOrig, y: yPos, width: layout.layerW, height: layout.layerH),
                                     cornerWidth: 3 * scale, cornerHeight: 3 * scale, transform: nil)
                ctx.addPath(bgPath)
                ctx.fillPath()
            }
            ctx.restoreGState()

            ctx.saveGState()
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1.0, y: -1.0)
            let textRectYUp = CGFloat(h) - yPos - layout.layerH + padV
            let textRect = CGRect(x: xOrig + padH, y: textRectYUp,
                                  width: layout.layerW - padH * 2, height: layout.layerH - padV * 2)
            let ctFrame = CTFramesetterCreateFrame(layout.setter, CFRange(),
                                                    CGPath(rect: textRect, transform: nil), nil)
            CTFrameDraw(ctFrame, ctx)
            ctx.restoreGState()

            yPos -= info.lineSpacing
        }

        guard let cgImage = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cgImage)
    }

    /// 渲染文字图层为透明背景 CIImage overlay（用于 CISourceOverCompositing GPU 合成）
    static func renderTextOverlay(
        atTime time: Double, clips: [TextClip], fontScale: CGFloat, renderSize: CGSize
    ) -> CIImage? {
        let active = clips.filter { $0.startTime <= time && $0.endTime > time }
        guard !active.isEmpty else { return nil }

        let w = Int(renderSize.width)
        let h = Int(renderSize.height)
        guard w > 0, h > 0 else { return nil }

        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1.0, y: -1.0)

        let scale = fontScale

        for clip in active {
            let scaledSize = clip.fontSize * scale
            var ctFont = CTFontCreateWithName(clip.fontName as CFString, scaledSize, nil)
            if clip.bold,
               let bf = CTFontCreateCopyWithSymbolicTraits(ctFont, scaledSize, nil, .boldTrait, .boldTrait) { ctFont = bf }
            if clip.italic {
                var skew = CGAffineTransform(a: 1, b: 0, c: 0.21, d: 1, tx: 0, ty: 0)
                ctFont = CTFontCreateCopyWithAttributes(ctFont, scaledSize, &skew, nil)
            }

            let tc = NSColor(clip.textColor).usingColorSpace(.sRGB) ?? .white
            var tr: CGFloat = 1, tg: CGFloat = 1, tb: CGFloat = 1, ta: CGFloat = 1
            tc.getRed(&tr, green: &tg, blue: &tb, alpha: &ta)
            let textCGColor = CGColor(red: tr, green: tg, blue: tb, alpha: ta)

            var alignment: CTTextAlignment
            switch clip.alignment {
            case "left":  alignment = .left
            case "right": alignment = .right
            default:      alignment = .center
            }
            let ctPS: CTParagraphStyle = withUnsafeBytes(of: &alignment) { ptr in
                var setting = CTParagraphStyleSetting(
                    spec: .alignment,
                    valueSize: MemoryLayout<CTTextAlignment>.size,
                    value: ptr.baseAddress!)
                return CTParagraphStyleCreate(&setting, 1)
            }

            let padH: CGFloat = 10 * scale, padV: CGFloat = 5 * scale
            let maxW = CGFloat(w) * 0.9
            let attrs: [NSAttributedString.Key: Any] = [
                .init(kCTFontAttributeName as String): ctFont,
                .init(kCTForegroundColorAttributeName as String): textCGColor,
                .init(kCTParagraphStyleAttributeName as String): ctPS
            ]
            let attrStr = NSAttributedString(string: clip.text.isEmpty ? " " : clip.text, attributes: attrs)
            let setter = CTFramesetterCreateWithAttributedString(attrStr)
            // 设过文本框宽度就按它换行，没设才按文字自己撑开（跟预览一致）
            let boxW = clip.boxWidth.map { CGFloat($0) * scale }
            let boxH = clip.boxHeight.map { CGFloat($0) * scale }
            let constraint = CGSize(width: boxW ?? (maxW - padH * 2),
                                    height: CGFloat.greatestFiniteMagnitude)
            let textSize = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, constraint, nil)
            let layerW = (boxW ?? ceil(textSize.width)) + padH * 2
            let layerH = (boxH ?? ceil(textSize.height)) + padV * 2

            let centerX = CGFloat(w) * clip.posX
            let centerY = CGFloat(h) * clip.posY
            let xOrig = centerX - layerW / 2
            let yOrig = centerY - layerH / 2

            ctx.saveGState()
            ctx.setAlpha(clip.opacity)

            if clip.rotation != 0 {
                ctx.translateBy(x: centerX, y: centerY)
                ctx.rotate(by: -clip.rotation * .pi / 180)
                ctx.translateBy(x: -centerX, y: -centerY)
            }

            if clip.strokeWidth > 0 {
                let sc = NSColor(clip.strokeColor).usingColorSpace(.sRGB) ?? .black
                var sr: CGFloat = 0, sg: CGFloat = 0, sb: CGFloat = 0, sa: CGFloat = 0
                sc.getRed(&sr, green: &sg, blue: &sb, alpha: &sa)
                let strokeCG = CGColor(red: sr, green: sg, blue: sb, alpha: sa)
                // 柔和度 0 = 硬边；以前 blur 写死成宽度的一半，怎么调都是糊的
                let r = max(0.35, clip.strokeWidth * clip.strokeSoftness) * scale
                let off = max(0.6, clip.strokeWidth) * scale
                ctx.setShadow(offset: CGSize(width: off, height: off), blur: r, color: strokeCG)
            } else {
                ctx.setShadow(offset: CGSize(width: 1 * scale, height: 1 * scale),
                              blur: 1 * scale,
                              color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.6))
            }

            if clip.bgOpacity > 0 {
                let nc = NSColor(clip.bgColor).usingColorSpace(.sRGB) ?? .black
                var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
                nc.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
                ctx.setFillColor(CGColor(red: br, green: bg, blue: bb, alpha: clip.bgOpacity))
                let bgPath = CGPath(roundedRect: CGRect(x: xOrig, y: yOrig, width: layerW, height: layerH),
                                     cornerWidth: 4 * scale, cornerHeight: 4 * scale, transform: nil)
                ctx.addPath(bgPath)
                ctx.fillPath()
            }

            ctx.saveGState()
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1.0, y: -1.0)
            let textRectYUp = CGFloat(h) - yOrig - layerH + padV
            let textRect = CGRect(x: xOrig + padH, y: textRectYUp,
                                  width: layerW - padH * 2, height: layerH - padV * 2)
            let ctFrame = CTFramesetterCreateFrame(setter, CFRange(),
                                                    CGPath(rect: textRect, transform: nil), nil)
            CTFrameDraw(ctFrame, ctx)
            ctx.restoreGState()

            ctx.restoreGState()
        }

        guard let cgImage = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cgImage)
    }

    // MARK: - 图形 overlay 逐帧绘制（导出用，与预览 ShapeOverlay 一致）

    static func renderShapeOverlay(atTime time: Double, clips: [ShapeClip],
                                                scale: CGFloat, renderSize: CGSize) -> CIImage? {
        let active = clips.filter { $0.startTime <= time && $0.endTime > time }
        guard !active.isEmpty else { return nil }
        let w = Int(renderSize.width), h = Int(renderSize.height)
        guard w > 0, h > 0 else { return nil }
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        // 翻转成左上原点，与 posX/posY(0~1) 一致
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)

        func cgc(_ c: Color, _ op: Double) -> CGColor {
            let ns = NSColor(c).usingColorSpace(.sRGB) ?? .white
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            ns.getRed(&r, green: &g, blue: &b, alpha: &a)
            return CGColor(red: r, green: g, blue: b, alpha: a * CGFloat(op))
        }

        let s = Double(scale)
        for clip in active {
            let cx = clip.posX * Double(w)
            let cy = clip.posY * Double(h)
            let sw = max(clip.width * clip.scaleX * s, 1)
            let sh = max(clip.height * clip.scaleY * s, 1)
            ctx.saveGState()
            ctx.setAlpha(CGFloat(clip.opacity))
            if clip.rotation != 0 || clip.mirrorH || clip.mirrorV {
                ctx.translateBy(x: cx, y: cy)
                if clip.mirrorH { ctx.scaleBy(x: -1, y: 1) }
                if clip.mirrorV { ctx.scaleBy(x: 1, y: -1) }
                if clip.rotation != 0 { ctx.rotate(by: CGFloat(clip.rotation * .pi / 180)) }
                ctx.translateBy(x: -cx, y: -cy)
            }
            if clip.shadowEnabled {
                ctx.setShadow(offset: CGSize(width: clip.shadowOffsetX * s, height: clip.shadowOffsetY * s),
                              blur: CGFloat(clip.shadowRadius * s),
                              color: cgc(clip.shadowColor, clip.shadowOpacity))
            }
            let rect = CGRect(x: cx - sw / 2, y: cy - sh / 2, width: sw, height: sh)
            // 裁剪：比例相对整个图形框，跟预览里那层 mask 同一个口径
            if clip.cropTop > 0 || clip.cropBottom > 0 || clip.cropLeft > 0 || clip.cropRight > 0 {
                ctx.clip(to: CGRect(x: rect.minX + rect.width * clip.cropLeft,
                                    y: rect.minY + rect.height * clip.cropTop,
                                    width: rect.width * max(1 - clip.cropLeft - clip.cropRight, 0.01),
                                    height: rect.height * max(1 - clip.cropTop - clip.cropBottom, 0.01)))
            }
            if clip.type == .pen {
                if let pts = clip.penPoints, pts.count >= 2 {
                    let penPath = ShapeGeometry.penPath(points: pts, closed: clip.penClosed, in: rect).cgPath
                    if clip.fillEnabled && clip.effectiveIsClosed {
                        ctx.addPath(penPath); ctx.setFillColor(cgc(clip.fillColor, clip.fillOpacity)); ctx.fillPath()
                    }
                    if clip.strokeEnabled {
                        ctx.addPath(penPath)
                        ctx.setStrokeColor(cgc(clip.strokeColor, clip.strokeOpacity))
                        ctx.setLineWidth(CGFloat(clip.strokeWidth * s))
                        ctx.setLineCap(.round); ctx.setLineJoin(.round)
                        if clip.strokeDashed { ctx.setLineDash(phase: 0, lengths: [clip.strokeWidth * 2.5 * s, clip.strokeWidth * 1.6 * s]) }
                        ctx.strokePath()
                        ctx.setLineDash(phase: 0, lengths: [])
                    }
                }
            } else if !clip.type.isClosed {
                drawShapeLine(ctx: ctx, clip: clip, rect: rect, scale: s, cgc: cgc)
            } else {
                let path: CGPath
                if clip.cornerRadius > 0, let pts = ShapeGeometry.polygonPoints(for: clip.type, in: rect) {
                    path = ShapeGeometry.roundedPolygon(pts, radius: CGFloat(clip.cornerRadius * s)).cgPath
                } else if clip.type == .rectangle && clip.cornerRadius > 0 {
                    let r = CGFloat(min(clip.cornerRadius * s, Double(min(sw, sh)) / 2))
                    path = CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
                } else {
                    path = ShapeGeometry.path(for: clip.type, in: rect).cgPath
                }
                if clip.fillEnabled {
                    ctx.addPath(path); ctx.setFillColor(cgc(clip.fillColor, clip.fillOpacity)); ctx.fillPath()
                }
                if clip.strokeEnabled {
                    ctx.addPath(path)
                    ctx.setStrokeColor(cgc(clip.strokeColor, clip.strokeOpacity))
                    ctx.setLineWidth(CGFloat(clip.strokeWidth * s))
                    ctx.setLineJoin(.round)
                    if clip.strokeDashed { ctx.setLineDash(phase: 0, lengths: [clip.strokeWidth * 2.5 * s, clip.strokeWidth * 1.6 * s]) }
                    ctx.strokePath()
                    ctx.setLineDash(phase: 0, lengths: [])
                }
            }
            ctx.restoreGState()
        }
        guard let cgImage = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cgImage)
    }

    static func mergeBreaks(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.count > 1 else { return text }
        var result = lines[0]
        for i in 1..<lines.count {
            let prev = result.unicodeScalars.last
            let next = lines[i].unicodeScalars.first
            let prevIsCJK = prev.map { $0.value > 0x2E80 } ?? false
            let nextIsCJK = next.map { $0.value > 0x2E80 } ?? false
            result += (prevIsCJK && nextIsCJK) ? lines[i] : " " + lines[i]
        }
        return result
    }

    static func drawShapeLine(ctx: CGContext, clip: ShapeClip, rect: CGRect,
                                           scale: Double, cgc: (Color, Double) -> CGColor) {
        let y = rect.midY
        let sw = max(clip.strokeWidth * scale, 1)
        let col = cgc(clip.strokeColor, clip.strokeOpacity)
        let headLen = min(max(rect.width * 0.42, sw * 3), rect.height * 1.6) * 0.5
        let startInset = clip.capStart == .arrow ? headLen : 0
        let endInset = clip.capEnd == .arrow ? headLen : 0
        ctx.setStrokeColor(col); ctx.setLineWidth(sw); ctx.setLineCap(.butt)
        if clip.strokeDashed { ctx.setLineDash(phase: 0, lengths: [clip.strokeWidth * 2.5 * scale, clip.strokeWidth * 1.6 * scale]) }
        ctx.move(to: CGPoint(x: rect.minX + startInset, y: y))
        ctx.addLine(to: CGPoint(x: rect.maxX - endInset, y: y))
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
        drawCap(ctx: ctx, cap: clip.capStart, at: CGPoint(x: rect.minX, y: y), dir: -1, headLen: headLen, col: col)
        drawCap(ctx: ctx, cap: clip.capEnd,   at: CGPoint(x: rect.maxX, y: y), dir: 1,  headLen: headLen, col: col)
    }

    static func drawCap(ctx: CGContext, cap: LineCapStyle, at pt: CGPoint,
                                     dir: Double, headLen: Double, col: CGColor) {
        switch cap {
        case .none: break
        case .round:
            ctx.setFillColor(col)
            ctx.fillEllipse(in: CGRect(x: pt.x - headLen / 2, y: pt.y - headLen / 2, width: headLen, height: headLen))
        case .square:
            ctx.setFillColor(col)
            ctx.fill(CGRect(x: pt.x - headLen / 2, y: pt.y - headLen / 2, width: headLen, height: headLen))
        case .arrow:
            let wing = headLen * 0.5
            ctx.setFillColor(col)
            ctx.move(to: CGPoint(x: pt.x - dir * headLen, y: pt.y - wing))
            ctx.addLine(to: pt)
            ctx.addLine(to: CGPoint(x: pt.x - dir * headLen, y: pt.y + wing))
            ctx.closePath()
            ctx.fillPath()
        }
    }

    /// 现读一张图并缓存住。预览没有预热流程，靠它兜底
    private static let liveCacheLock = NSLock()
    private static var liveCache: [URL: CIImage] = [:]

    static func loadCI(_ url: URL) -> CIImage? {
        liveCacheLock.lock()
        if let hit = liveCache[url] { liveCacheLock.unlock(); return hit }
        liveCacheLock.unlock()
        guard let img = CIImage(contentsOf: url) else { return nil }
        liveCacheLock.lock()
        liveCache[url] = img
        // 别让它无限涨
        if liveCache.count > 60 { liveCache.removeAll() }
        liveCacheLock.unlock()
        return img
    }

    /// 素材换了/删了要清掉，否则一直拿着旧图
    static func clearLiveCache() {
        liveCacheLock.lock(); liveCache.removeAll(); liveCacheLock.unlock()
    }
}
