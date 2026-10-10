// 关键帧（v6.8.0）：插值、编辑写回、打/删、分割后不跑位
import XCTest
import AVFoundation
import CoreImage
@testable import VideoEditorLib

final class KeyframeTests: XCTestCase {

    private func clip(start: Double = 10, end: Double = 20, trim: Double = 0, speed: Double = 1) -> VideoClip {
        var c = VideoClip(assetID: UUID(), startTime: start, endTime: end)
        c.trimStart = trim
        c.speed = speed
        return c
    }

    func testSampleInterpolatesAndHoldsEnds() {
        var kf = ClipKeyframes()
        kf.upsert(.offsetX, at: 0, value: 0, tolerance: 0.01)
        kf.upsert(.offsetX, at: 2, value: 1, tolerance: 0.01)
        XCTAssertEqual(kf.sample(.offsetX, at: -1), 0)
        XCTAssertEqual(kf.sample(.offsetX, at: 1), 0.5)
        XCTAssertEqual(kf.sample(.offsetX, at: 5), 1)
        XCTAssertNil(kf.sample(.offsetY, at: 1))
    }

    func testEditWithoutKeyframesWritesStaticValue() {
        var c = clip()
        c.applyAnimatedEdit(atTimeline: 12) { $0.offsetX = 0.3 }
        XCTAssertEqual(c.offsetX, 0.3)
        XCTAssertNil(c.keyframes)
    }

    func testToggleAndEditWritesKeyframeAtPlayhead() {
        var c = clip()
        c.toggleKeyframe(.offsetX, atTimeline: 10)          // 第一帧：记下当前值 (0,0)
        c.applyAnimatedEdit(atTimeline: 18) { $0.offsetX = 0.4 }   // 播放头在别处改 → 新增一帧
        XCTAssertEqual(c.keyframeTimelineTimes(.offsetX).count, 2)
        XCTAssertEqual(c.offsetX, 0, "有关键帧时静态值不动")
        XCTAssertEqual(c.animated(atTimeline: 14).offsetX, 0.2, accuracy: 1e-9)
        // 只给 X 打了关键帧，同时改 Y → Y 走静态值，不会顺带打上
        c.applyAnimatedEdit(atTimeline: 14) { $0.offsetY = 0.3 }
        XCTAssertFalse(c.keyframes!.has(.offsetY))
        XCTAssertEqual(c.offsetY, 0.3)
        // 在已有帧上再改 → 就地改值，不新增
        c.applyAnimatedEdit(atTimeline: 18.01) { $0.offsetX = 0.6 }
        XCTAssertEqual(c.keyframeTimelineTimes(.offsetX).count, 2)
        XCTAssertEqual(c.animated(atTimeline: 18).offsetX, 0.6, accuracy: 1e-9)
        // 播放头在片段外：关键帧打在片段末尾（不会跑到片段外面去）
        c.applyAnimatedEdit(atTimeline: 25) { $0.offsetX = 0.9 }
        XCTAssertEqual(c.keyframeTimelineTimes(.offsetX).last!, 19.999, accuracy: 1e-6)
    }

    func testRemovingLastKeyframeRestoresValueBeforeKeyframes() {
        var c = clip()
        c.angle = 10
        c.toggleKeyframe(.angle, atTimeline: 12)
        c.applyAnimatedEdit(atTimeline: 12) { $0.angle = 35 }
        c.toggleKeyframe(.angle, atTimeline: 12)            // 删掉唯一一帧
        XCTAssertNil(c.keyframes)
        XCTAssertEqual(c.angleDeg, 10, accuracy: 1e-9, "回到打关键帧之前的值")
    }

    func testKeyframesFollowContentAfterSplit() {
        // 片段 10~20 秒，入点 0；关键帧在 12 秒(0) 和 18 秒(1)
        var c = clip()
        c.toggleKeyframe(.offsetX, atTimeline: 12)
        c.applyAnimatedEdit(atTimeline: 18) { $0.offsetX = 1 }
        let before = c.animated(atTimeline: 16).offsetX
        // 模拟在 15 秒切开后的右半段：起点 15、入点 5（同 splitClip 的写法）
        var right = c
        right.startTime = 15
        right.trimStart = c.trimStart + (15 - c.startTime) * c.speed
        XCTAssertEqual(right.animated(atTimeline: 16).offsetX, before, accuracy: 1e-9)
        XCTAssertEqual(right.keyframeTimelineTimes(.offsetX), [12, 18])
    }

    func testSpeedMapsKeyframeTime() {
        var c = clip(start: 0, end: 10, trim: 4, speed: 2)
        c.toggleKeyframe(.scaleX, atTimeline: 3)
        XCTAssertEqual(c.keyframes!.frames(.scaleX).first!.time, 10, accuracy: 1e-9)  // 4 + 3*2
        XCTAssertEqual(c.keyframeTimelineTimes(.scaleX), [3])
    }

    func testCompositorEntryAppliesKeyframes() {
        var c = clip()
        c.toggleKeyframe(.offsetX, atTimeline: 10)
        c.applyAnimatedEdit(atTimeline: 18) { $0.offsetX = 1; $0.cropLeft = 0.2 }
        var e = CompositorTrackEntry(trackID: 1, userScaleX: 1, userScaleY: 1, userOffsetX: 0, userOffsetY: 0,
                                     cropTop: 0, cropBottom: 0, cropLeft: 0, cropRight: 0, colorAdjust: .identity)
        e.keyframedClip = c
        e.applyKeyframes(at: 14)
        XCTAssertEqual(e.userOffsetX, 0.5, accuracy: 1e-9)
        XCTAssertEqual(e.cropLeft, 0.2, accuracy: 1e-9, "裁剪没打关键帧，走静态值")
    }

    func testCodableRoundTripAndOldFiles() throws {
        var c = clip()
        c.toggleKeyframe(.brightness, atTimeline: 11)
        let data = try JSONEncoder().encode(c)
        XCTAssertEqual(try JSONDecoder().decode(VideoClip.self, from: data), c)
        // 老存档没有这两个字段
        var obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        obj.removeValue(forKey: "keyframes"); obj.removeValue(forKey: "opacity")
        let old = try JSONDecoder().decode(VideoClip.self, from: JSONSerialization.data(withJSONObject: obj))
        XCTAssertNil(old.keyframes)
        XCTAssertEqual(old.alpha, 1)
    }

    func testAngleKeyframesFeedCompositor() {
        var c = clip()
        c.toggleKeyframe(.angle, atTimeline: 10)
        c.applyAnimatedEdit(atTimeline: 18) { $0.angle = 90 }
        var e = CompositorTrackEntry(trackID: 1, userScaleX: 1, userScaleY: 1, userOffsetX: 0, userOffsetY: 0,
                                     cropTop: 0, cropBottom: 0, cropLeft: 0, cropRight: 0, colorAdjust: .identity)
        e.keyframedClip = c
        e.applyKeyframes(at: 14)
        XCTAssertEqual(e.fineAngle, 45, accuracy: 1e-9)
        XCTAssertEqual(e.rotation, 0, "90° 档不受影响，贴合画布的尺寸不跟着变")
    }

    func testAdjustSingleSliderKeyframe() {
        var c = clip()
        c.toggleKeyframe(.brightness, atTimeline: 10)
        c.applyAnimatedEdit(atTimeline: 18) { $0.colorAdjust.brightness = 0.8; $0.colorAdjust.contrast = 0.5 }
        let mid = c.animated(atTimeline: 14).colorAdjust
        XCTAssertEqual(mid.brightness, 0.4, accuracy: 1e-9)
        XCTAssertEqual(mid.contrast, 0.5, accuracy: 1e-9, "对比没打关键帧，直接改静态值")
    }

    func testMoveKeyframesAllPropsTogetherAndClamp() {
        var c = clip()   // 10~20
        c.toggleKeyframe(.offsetX, atTimeline: 12)
        c.toggleKeyframe(.angle, atTimeline: 12)
        c.toggleKeyframe(.offsetX, atTimeline: 16)
        c.moveKeyframes(fromTimeline: 12, toTimeline: 14)
        XCTAssertEqual(c.keyframeTimelineTimes(.offsetX), [14, 16])
        XCTAssertEqual(c.keyframeTimelineTimes(.angle), [14], "同一时刻的各属性一起挪")
        c.moveKeyframes(fromTimeline: 14, toTimeline: 30)       // 拖出片段 → 夹在片段末尾
        XCTAssertEqual(c.keyframeTimelineTimes(.angle).first!, 19.999, accuracy: 1e-6)
        XCTAssertEqual(c.keyframeTimelineTimes(.offsetX).count, 2, "拖过别的帧不会吃掉它")
    }

    func testMultiMoveDoesNotChainAcrossSwappedTimes() {
        var c = clip()   // 10~20
        c.toggleKeyframe(.offsetX, atTimeline: 12)
        c.applyAnimatedEdit(atTimeline: 14) { $0.offsetX = 1 }
        // 两帧同时右移 2 秒：12→14、14→16。12 挪到 14 后不能再被「14→16」认领
        c.moveKeyframes([(from: 12, to: 14), (from: 14, to: 16)])
        XCTAssertEqual(c.keyframeTimelineTimes(.offsetX), [14, 16])
        XCTAssertEqual(c.animated(atTimeline: 16).offsetX, 1, accuracy: 1e-9)
    }

    // MARK: 区间缓动

    func testEasingCurvesHitEndpoints() {
        for e in [KeyframeEasing.linear, .easeIn, .easeOut, .easeInOut, .elastic(0.25), .bounce] {
            XCTAssertEqual(e.apply(0), 0, accuracy: 1e-6)
            XCTAssertEqual(e.apply(1), 1, accuracy: 1e-6)
        }
        XCTAssertEqual(KeyframeEasing.linear.apply(0.3), 0.3, accuracy: 1e-6)
        XCTAssertEqual(KeyframeEasing.easeInOut.apply(0.5), 0.5, accuracy: 1e-4, "对称曲线中点")
        XCTAssertLessThan(KeyframeEasing.easeIn.apply(0.3), 0.3, "缓入开头慢")
        XCTAssertGreaterThan(KeyframeEasing.easeOut.apply(0.3), 0.3, "缓出开头快")
    }

    func testElasticOvershootMatchesAmount() {
        let e = KeyframeEasing.elastic(0.25)
        let peak = stride(from: 0.0, through: 1.0, by: 0.005).map { e.apply($0) }.max()!
        XCTAssertEqual(peak, 1.25, accuracy: 0.03)
    }

    func testSampleUsesSegmentEasingAndSegmentIndex() {
        var c = clip()   // 10~20
        c.toggleKeyframe(.offsetX, atTimeline: 10)
        c.applyAnimatedEdit(atTimeline: 14) { $0.offsetX = 1 }
        c.applyAnimatedEdit(atTimeline: 18) { $0.offsetX = 0 }
        XCTAssertEqual(c.keyframeSegment(.offsetX, atTimeline: 12)?.index, 0)
        XCTAssertEqual(c.keyframeSegment(.offsetX, atTimeline: 14)?.index, 1, "停在帧上算往后那段")
        XCTAssertEqual(c.keyframeSegment(.offsetX, atTimeline: 18)?.index, 1, "停在最后一帧算前面那段")
        XCTAssertNil(c.keyframeSegment(.offsetX, atTimeline: 19))
        var kf = c.keyframes!
        kf.setEasing(.offsetX, index: 0, .easeIn)
        c.keyframes = kf
        XCTAssertLessThan(c.animated(atTimeline: 12).offsetX, 0.5, "第一段缓入，中点还没到一半")
        XCTAssertEqual(c.animated(atTimeline: 16).offsetX, 0.5, accuracy: 1e-9, "第二段仍是线性")
        kf.setEasing(.offsetX, index: 0, .linear)
        XCTAssertNil(kf.frames(.offsetX)[0].easing, "线性不存，省得存档里一堆默认值")
    }

    func testDelayHoldsStartValueThenRunsCurve() {
        var c = clip()   // 10~20
        c.toggleKeyframe(.offsetX, atTimeline: 10)
        c.applyAnimatedEdit(atTimeline: 14) { $0.offsetX = 1 }
        var kf = c.keyframes!
        var e = KeyframeEasing.linear; e.delay = 2
        kf.setEasing(.offsetX, index: 0, e)
        c.keyframes = kf
        XCTAssertEqual(c.animated(atTimeline: 11.5).offsetX, 0, accuracy: 1e-9, "延时内不动")
        XCTAssertEqual(c.animated(atTimeline: 13).offsetX, 0.5, accuracy: 1e-9, "剩下 2 秒走完")
        XCTAssertEqual(c.animated(atTimeline: 14).offsetX, 1, accuracy: 1e-9)
        XCTAssertNotNil(c.keyframes!.frames(.offsetX)[0].easing, "带延时的线性要存下来")
    }

    func testCustomFlagKeepsEasingStored() {
        var kf = ClipKeyframes()
        kf.upsert(.offsetX, at: 0, value: 0, tolerance: 0.01)
        kf.upsert(.offsetX, at: 1, value: 1, tolerance: 0.01)
        var e = KeyframeEasing.linear; e.isCustom = true
        kf.setEasing(.offsetX, index: 0, e)
        XCTAssertEqual(kf.frames(.offsetX)[0].easing?.isCustom, true, "选了自定义，即使值是线性也记住")
    }

    // MARK: 复制 / 粘贴 / 删除

    func testCopyPasteDeleteKeyframesOnProject() {
        let p = ProjectState()
        var c = clip(start: 0, end: 20)
        c.toggleKeyframe(.offsetX, atTimeline: 2)
        c.applyAnimatedEdit(atTimeline: 4) { $0.offsetX = 0.5; $0.angle = 30 }
        c.toggleKeyframe(.angle, atTimeline: 2)
        p.videoTracks[0].clips = [c]

        // 选中 2 秒和 4 秒两个菱形 → 复制 → 贴到 10 秒
        p.selectedKeyframes = [KeyframeSelection(clipID: c.id, time: 2), KeyframeSelection(clipID: c.id, time: 4)]
        XCTAssertTrue(p.copySelectedKeyframes())
        XCTAssertTrue(p.pasteKeyframesNext, "复制关键帧后 ⌘V 要贴关键帧")
        p.currentTime = 10
        XCTAssertTrue(p.pasteKeyframesAtPlayhead())
        let after = p.videoTracks[0].clips[0]
        XCTAssertEqual(after.keyframeTimelineTimes(.offsetX), [2, 4, 10, 12], "保持彼此间距贴过去")
        XCTAssertEqual(after.animated(atTimeline: 12).offsetX, 0.5, accuracy: 1e-9)
        XCTAssertEqual(p.selectedKeyframes.map(\.time), [10, 12], "贴完选中贴上去的那几个")

        // 删除选中（10、12 两处），原来的不动
        XCTAssertTrue(p.deleteSelectedKeyframes())
        XCTAssertEqual(p.videoTracks[0].clips[0].keyframeTimelineTimes(.offsetX), [2, 4])
        XCTAssertFalse(p.deleteSelectedKeyframes(), "没选中关键帧时交给片段删除")
    }

    // MARK: 图片片段

    private func image(start: Double = 10, end: Double = 20) -> ImageClip {
        ImageClip(assetID: UUID(), startTime: start, endTime: end)
    }

    func testImageKeyframesAnimateRotationAndOpacity() {
        var c = image()
        c.toggleKeyframe(.angle, atTimeline: 10)
        c.toggleKeyframe(.opacity, atTimeline: 10)
        c.applyAnimatedEdit(atTimeline: 18) { $0.rotation = 90; $0.opacity = 0.2 }
        let mid = c.animated(atTimeline: 14)
        XCTAssertEqual(mid.rotation, 45, accuracy: 1e-9)
        XCTAssertEqual(mid.alpha, 0.6, accuracy: 1e-9)
        XCTAssertEqual(c.rotation, 0, "静态值不动")
    }

    func testImageKeyframesStayPutAfterLeftTrimAndSplit() {
        var c = image()   // 10~20，关键帧 12→18
        c.toggleKeyframe(.offsetX, atTimeline: 12)
        c.applyAnimatedEdit(atTimeline: 18) { $0.offsetX = 1 }
        let before = c.animated(atTimeline: 15).offsetX
        // 左边裁掉 3 秒（同时间轴拖左边、按播放头裁左边）
        var trimmed = c
        trimmed.shiftKeyframeIn(by: 3); trimmed.startTime = 13
        XCTAssertEqual(trimmed.animated(atTimeline: 15).offsetX, before, accuracy: 1e-9)
        XCTAssertEqual(trimmed.keyframeTimelineTimes(.offsetX), [12, 18])
        // 从 16 秒切开的右半段
        var right = c
        right.shiftKeyframeIn(by: 6); right.startTime = 16
        XCTAssertEqual(right.animated(atTimeline: 17).offsetX, c.animated(atTimeline: 17).offsetX, accuracy: 1e-9)
    }

    func testImageCodableOldFiles() throws {
        var c = image()
        c.toggleKeyframe(.scaleX, atTimeline: 11)
        let data = try JSONEncoder().encode(c)
        XCTAssertEqual(try JSONDecoder().decode(ImageClip.self, from: data), c)
        var obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        obj.removeValue(forKey: "keyframes"); obj.removeValue(forKey: "kfIn")
        let old = try JSONDecoder().decode(ImageClip.self, from: JSONSerialization.data(withJSONObject: obj))
        XCTAssertNil(old.keyframes)
    }

    func testProjectOpsWorkOnImageClips() {
        let p = ProjectState()
        let c = image(start: 0, end: 10)
        p.imageTracks[0].clips = [c]
        p.currentTime = 2
        p.toggleKeyframe(clipID: c.id, prop: .opacity)
        p.currentTime = 6
        p.updateImageClipAnimated(id: c.id) { $0.opacity = 0 }
        var cur = p.imageTracks[0].clips[0]
        XCTAssertEqual(cur.keyframeTimelineTimes(.opacity), [2, 6])
        XCTAssertEqual(cur.animated(atTimeline: 4).alpha, 0.5, accuracy: 1e-9)
        p.setKeyframeEasing(clipID: c.id, prop: .opacity, index: 0, .easeIn)
        cur = p.imageTracks[0].clips[0]
        XCTAssertLessThan(cur.animated(atTimeline: 4).alpha, 1, "有曲线")
        XCTAssertGreaterThan(cur.animated(atTimeline: 4).alpha, 0.5, "缓入：中点还没走到一半")
        p.selectedKeyframes = [KeyframeSelection(clipID: c.id, time: 6)]
        XCTAssertTrue(p.deleteSelectedKeyframes())
        XCTAssertEqual(p.imageTracks[0].clips[0].keyframeTimelineTimes(.opacity), [2])
    }

    // MARK: 文字 / 图形

    func testTextKeyframesFontSizePositionAndCodable() throws {
        var t = TextClip(text: "标题", startTime: 0, endTime: 10)
        t.toggleKeyframe(.fontSize, atTimeline: 2)
        t.toggleKeyframe(.offsetX, atTimeline: 2)
        t.applyAnimatedEdit(atTimeline: 6) { $0.fontSize = 128; $0.posX = 0.9 }
        let mid = t.animated(atTimeline: 4)
        XCTAssertEqual(Double(mid.fontSize), 96, accuracy: 1e-9)
        XCTAssertEqual(mid.posX, 0.7, accuracy: 1e-9)
        XCTAssertNil(t.propValue(.scaleX), "文字的范围框不打关键帧")
        // 手写编解码：关键帧和入点要存得进、读得回
        t.kfIn = 1.5
        let back = try JSONDecoder().decode(TextClip.self, from: JSONEncoder().encode(t))
        XCTAssertEqual(back.keyframes, t.keyframes)
        XCTAssertEqual(back.kfIn, 1.5)
    }

    func testShapeKeyframesScaleRotationAndCodable() throws {
        var s = ShapeClip(type: .rectangle, startTime: 0, endTime: 10)
        s.toggleKeyframe(.scaleX, atTimeline: 0)
        s.toggleKeyframe(.angle, atTimeline: 0)
        s.applyAnimatedEdit(atTimeline: 8) { $0.scaleX = 3; $0.rotation = 180 }
        let mid = s.animated(atTimeline: 4)
        XCTAssertEqual(mid.scaleX, 2, accuracy: 1e-9)
        XCTAssertEqual(mid.rotation, 90, accuracy: 1e-9)
        let back = try JSONDecoder().decode(ShapeClip.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.keyframes, s.keyframes)
    }

    func testTextLeftTrimViaUpdateTextTimeKeepsKeyframes() {
        let p = ProjectState()
        var t = TextClip(text: "x", startTime: 0, endTime: 10)
        t.toggleKeyframe(.opacity, atTimeline: 2)
        t.applyAnimatedEdit(atTimeline: 8) { $0.opacity = 0 }
        p.textTracks = [Track(clips: [t])]
        let before = t.animated(atTimeline: 5).opacity
        p.updateTextTime(id: t.id, start: 3)          // 左边裁掉 3 秒
        let after = p.textTracks[0].clips[0]
        XCTAssertEqual(after.animated(atTimeline: 5).opacity, before, accuracy: 1e-9)
        XCTAssertEqual(after.keyframeTimelineTimes(.opacity), [2, 8])
        p.updateTextTime(id: t.id, start: 4, end: 11)  // 整体平移：入点不动，关键帧跟着片段走
        XCTAssertEqual(p.textTracks[0].clips[0].keyframeTimelineTimes(.opacity), [3, 9])
    }

    func testOverlayRendererEvaluatesKeyframes() {
        // 导出 / 合成器那条路：传进去的是静态片段，画的时候要按时间求值
        var s = ShapeClip(type: .rectangle, startTime: 0, endTime: 10)
        s.toggleKeyframe(.opacity, atTimeline: 0)
        s.applyAnimatedEdit(atTimeline: 10) { $0.opacity = 0 }
        let full = OverlayRenderer.renderShapeOverlay(atTime: 0.01, clips: [s], scale: 1,
                                                      renderSize: CGSize(width: 64, height: 64))
        let gone = OverlayRenderer.renderShapeOverlay(atTime: 9.999, clips: [s], scale: 1,
                                                      renderSize: CGSize(width: 64, height: 64))
        XCTAssertNotNil(full)
        // 末尾几乎全透明：画不出来或画出来是空的都算对
        if let g = gone {
            let ctx = CIContext()
            var px = [UInt8](repeating: 0, count: 4)
            ctx.render(g, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 32, y: 32, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            XCTAssertLessThan(px[3], 10, "末尾不透明度接近 0")
        }
    }

    // MARK: 音量曲线

    func testAudioVolumeKeyframesAndCurvePoints() {
        var a = AudioClip(assetID: UUID(), startTime: 0, endTime: 10)
        a.toggleKeyframe(.volume, atTimeline: 2)          // 1.0
        a.applyAnimatedEdit(atTimeline: 6) { $0.volume = 0 }
        XCTAssertEqual(Double(a.animated(atTimeline: 4).volume), 0.5, accuracy: 1e-6)
        XCTAssertEqual(a.volume, 1, "静态值不动")
        let pts = VolumeCurve.points(for: a, start: 0, duration: 10)!
        XCTAssertEqual(pts.first!.t, 0); XCTAssertEqual(pts.last!.t, 10)
        XCTAssertEqual(Double(pts.first!.v), 1, accuracy: 1e-6)
        XCTAssertEqual(Double(pts.last!.v), 0, accuracy: 1e-6)
        XCTAssertNil(VolumeCurve.points(for: AudioClip(assetID: UUID(), startTime: 0, endTime: 5), start: 0, duration: 5),
                     "没打音量关键帧就照旧用静态音量")
    }

    func testVolumeCurveWritesRampsIntoAudioMix() {
        var v = clip(start: 0, end: 10)                     // 视频片段的音量也能打
        v.toggleKeyframe(.volume, atTimeline: 2)
        v.applyAnimatedEdit(atTimeline: 6) { $0.volume = 0 }
        let pts = VolumeCurve.points(for: v, start: 0, duration: 10)!
        let p = AVMutableAudioMixInputParameters()
        VolumeCurve.apply(p, points: pts, start: 0, duration: 10, fadeIn: 0, fadeOut: 0)
        func gain(at t: Double) -> Float {
            var s: Float = -1, e: Float = -1, r = CMTimeRange.zero
            XCTAssertTrue(p.getVolumeRamp(for: CMTime(seconds: t, preferredTimescale: 44100),
                                          startVolume: &s, endVolume: &e, timeRange: &r))
            let f = Float((t - r.start.seconds) / max(r.duration.seconds, 1e-9))
            return s + (e - s) * f
        }
        XCTAssertEqual(Double(gain(at: 1)), 1, accuracy: 0.02)
        XCTAssertEqual(Double(gain(at: 4)), 0.5, accuracy: 0.02)
        XCTAssertEqual(Double(gain(at: 8)), 0, accuracy: 0.02)
        // 淡入叠在上面：开头 0.5 秒处 = 1 × 0.5
        let q = AVMutableAudioMixInputParameters()
        VolumeCurve.apply(q, points: pts, start: 0, duration: 10, fadeIn: 1, fadeOut: 0)
        var s: Float = 0, e: Float = 0, r = CMTimeRange.zero
        XCTAssertTrue(q.getVolumeRamp(for: CMTime(seconds: 0.5, preferredTimescale: 44100), startVolume: &s, endVolume: &e, timeRange: &r))
        let f = Float((0.5 - r.start.seconds) / r.duration.seconds)
        XCTAssertEqual(Double(s + (e - s) * f), 0.5, accuracy: 0.03)
    }

    func testAudioClipKeyframesSurviveCodable() throws {
        var a = AudioClip(assetID: UUID(), startTime: 0, endTime: 4)
        a.toggleKeyframe(.volume, atTimeline: 1)
        let back = try JSONDecoder().decode(AudioClip.self, from: JSONEncoder().encode(a))
        XCTAssertEqual(back.keyframes, a.keyframes)
    }
}
