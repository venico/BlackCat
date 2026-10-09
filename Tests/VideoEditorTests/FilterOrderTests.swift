// 滤镜并入图层顺序表之后的链路检查
import XCTest
import AVFoundation
import CoreVideo
@testable import VideoEditorLib

@MainActor
final class FilterOrderTests: XCTestCase {

    func testAddFilterIsSelectableAndOrdered() {
        let p = ProjectState()
        let id = p.addFilter(kind: .comic, at: 0)

        XCTAssertNotNil(p.selectedFilterClip, "加完滤镜属性区就该能找到它")
        XCTAssertEqual(p.selectedFilterClip?.id, id)
        XCTAssertFalse(p.filterTracks.isEmpty, "滤镜轨道该建出来")

        let refs = p.overlayTrackOrder.filter { if case .filter = $0 { return true }; return false }
        XCTAssertEqual(refs.count, 1, "滤镜轨道该登记进图层顺序表")
    }

    func testFilterSitsAboveOtherLayersInBottomUpList() {
        let p = ProjectState()
        p.addTextAtPlayhead(text: "x")
        _ = p.addFilter(kind: .comic, at: 0)

        let layers = p.overlayLayersBottomUp
        guard let fi = layers.firstIndex(where: { if case .filter = $0 { return true }; return false })
        else { return XCTFail("bottomUp 列表里没有滤镜层") }
        guard let ti = layers.firstIndex(where: { if case .text = $0 { return true }; return false })
        else { return XCTFail("bottomUp 列表里没有文字层") }
        XCTAssertGreaterThan(fi, ti, "滤镜排在文字之上，才可能作用到它")
    }

    // 预览重建要把滤镜送进这个项目自己的合成状态，而且预览指令带着这份状态
    func testRebuildFeedsCompositor() async throws {
        let url = try makeTestVideo()
        defer { try? FileManager.default.removeItem(at: url) }

        let p = try await makeProjectWithFilter(url)

        XCTAssertFalse(p.previewCompositor.getFilterTracks().isEmpty,
                       "重建之后合成器该拿到滤镜轨道")
        let instrs = p.playerItem?.videoComposition?.instructions ?? []
        XCTAssertFalse(instrs.isEmpty, "有视频就该有合成指令")
        for i in instrs {
            guard let ci = i as? ColorInstruction else { return XCTFail("预览指令该是 ColorInstruction") }
            XCTAssertTrue(ci.data.live === p.previewCompositor, "指令该带着本项目的合成状态")
            XCTAssertFalse(ci.data.forExport)
        }
    }

    // 两个项目窗口同时开着：后重建的不能盖掉前一个的滤镜（原来是全局共用一份）
    func testTwoProjectsKeepTheirOwnCompositorState() async throws {
        let url = try makeTestVideo()
        defer { try? FileManager.default.removeItem(at: url) }

        let a = try await makeProjectWithFilter(url)
        let b = ProjectState()
        var asset = MediaAsset(url: url, name: "v", type: .video)
        asset.duration = 2
        b.mediaAssets.append(asset)
        b.addToTimelineAt(asset, time: 0)
        b.rebuildTimelinePreview()
        await settle(b)

        XCTAssertFalse(a.previewCompositor.getFilterTracks().isEmpty, "B 重建把 A 的滤镜清掉了")
        XCTAssertTrue(b.previewCompositor.getFilterTracks().isEmpty, "B 没加滤镜却拿到了滤镜")
        XCTAssertFalse(a.previewCompositor === b.previewCompositor)
    }

    // Agent 截时间轴画面走的是预览那份合成（带自定义合成器），要能截出来
    func testTimelineFrameCanBeCaptured() async throws {
        let url = try makeTestVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let p = ProjectState()
        var asset = MediaAsset(url: url, name: "v", type: .video)
        asset.duration = 2
        p.mediaAssets.append(asset)
        p.addToTimelineAt(asset, time: 0)
        p.rebuildTimelinePreview()
        await settle(p)
        XCTAssertNoThrow(try AgentToolbox.renderTimelineFrame(p, at: 1.0), "没滤镜时截不到")

        _ = p.addFilter(kind: .comic, at: 0)
        p.rebuildTimelinePreview()
        await settle(p)
        XCTAssertNoThrow(try AgentToolbox.renderTimelineFrame(p, at: 1.0), "有滤镜时截不到")
    }

    // 视频之后只有图片的那一段也要截得到（原来报「无法打开」：那段视频合成里一帧都没有）
    func testCaptureWhereOnlyAnImageIs() async throws {
        let url = try makeTestVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let png = FileManager.default.temporaryDirectory.appendingPathComponent("red_\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: png) }
        let ctx = CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        try rep.representation(using: .png, properties: [:])!.write(to: png)

        let p = ProjectState()
        var v = MediaAsset(url: url, name: "v", type: .video)
        v.duration = 2
        p.mediaAssets.append(v)
        p.addToTimelineAt(v, time: 0)
        let img = MediaAsset(url: png, name: "red.png", type: .image)
        p.mediaAssets.append(img)
        p.addToTimelineAt(img, time: 2)
        p.rebuildTimelinePreview()
        await settle(p)

        let cg = try AgentToolbox.renderTimelineFrame(p, at: 3.0)
        // 正中间该是图片的红色，不是黑的
        var px = [UInt8](repeating: 0, count: 4)
        let c = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                          space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(cg, in: CGRect(x: -CGFloat(cg.width) / 2, y: -CGFloat(cg.height) / 2,
                              width: CGFloat(cg.width), height: CGFloat(cg.height)))
        XCTAssertGreaterThan(px[0], 150, "截出来的不是图片（中心像素 \(px)）")
    }

    // 调节轨导出要真的调过，而且**黑边不参与**：画面调亮，四周补的黑边还是黑的。
    // 快速导出（只有视频 + 调节）和逐帧导出（还带文字）两条路都要对
    func testAdjustTrackGetsIntoExportFastPath() async throws {
        try await checkAdjustedExport(withText: false)
    }

    func testAdjustTrackGetsIntoExportPerFramePath() async throws {
        try await checkAdjustedExport(withText: true)
    }

    private func checkAdjustedExport(withText: Bool) async throws {
        let url = try makeTestVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let p = ProjectState()
        var asset = MediaAsset(url: url, name: "v", type: .video)
        asset.duration = 2
        p.mediaAssets.append(asset)
        p.addToTimelineAt(asset, time: 0)
        let aid = p.addAdjust(at: 0)
        p.updateAdjustClip(id: aid) { $0.adjust.brightness = 0.5; $0.endTime = 2 }
        if withText {
            // 文字放在角上、很小，不挡中间和左边黑边的取样点
            p.addTextAtPlayhead(text: "x")
            if let tid = p.textTracks.flatMap(\.clips).last?.id {
                p.updateTextClip(id: tid) { $0.startTime = 0; $0.endTime = 2; $0.posX = 0.95; $0.posY = 0.05 }
            }
        }
        // 4:3 的片子导成 16:9，左右会补黑边
        p.exportSettings.resolution = "480p"
        p.exportSettings.aspectRatio = "16:9"

        let out = FileManager.default.temporaryDirectory.appendingPathComponent("adj_\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        _ = try await TimelineExporter().export(p.makeExportInput(outputURL: out)) { _ in }

        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: out))
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let cg = try gen.copyCGImage(at: CMTime(seconds: 1, preferredTimescale: 600), actualTime: nil)
        let center = pixel(cg, x: cg.width / 2, y: cg.height / 2)
        let bar = pixel(cg, x: 4, y: cg.height / 2)
        // 原片是 120 左右的灰，亮度 +0.5 之后应该明显更亮
        XCTAssertGreaterThan(Int(center[0]), 170, "画面没调亮（中心 \(center)）")
        XCTAssertLessThan(Int(bar[0]), 20, "黑边被调灰了（左边 \(bar)）")
    }

    private func pixel(_ cg: CGImage, x: Int, y: Int) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: 4)
        let c = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                          space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(cg, in: CGRect(x: -CGFloat(x), y: -CGFloat(y),
                              width: CGFloat(cg.width), height: CGFloat(cg.height)))
        return px
    }

    // 预览（Agent 截的就是预览那份合成）同样：黑边不跟着调
    func testPreviewBarsStayBlackUnderAdjust() async throws {
        let url = try makeTestVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let p = ProjectState()
        p.previewAspectRatio = "16:9"
        var asset = MediaAsset(url: url, name: "v", type: .video)
        asset.duration = 2
        p.mediaAssets.append(asset)
        p.addToTimelineAt(asset, time: 0)
        let aid = p.addAdjust(at: 0)
        p.updateAdjustClip(id: aid) { $0.adjust.brightness = 0.5; $0.endTime = 2 }
        p.rebuildTimelinePreview()
        await settle(p)
        let cg = try AgentToolbox.renderTimelineFrame(p, at: 1.0)
        let center = pixel(cg, x: cg.width / 2, y: cg.height / 2)
        let bar = pixel(cg, x: 4, y: cg.height / 2)
        XCTAssertGreaterThan(Int(center[0]), 170, "预览画面没调亮（中心 \(center)）")
        XCTAssertLessThan(Int(bar[0]), 20, "预览黑边被调灰了（左边 \(bar)）")
    }

    private func makeProjectWithFilter(_ url: URL) async throws -> ProjectState {
        let p = ProjectState()
        var asset = MediaAsset(url: url, name: "v", type: .video)
        asset.duration = 2
        p.mediaAssets.append(asset)
        p.addToTimelineAt(asset, time: 0)
        _ = p.addFilter(kind: .comic, at: 0)
        p.rebuildTimelinePreview()
        await settle(p)
        return p
    }

    /// 等重建彻底跑完。加片段、加滤镜各自还会排一次 0.15 秒的防抖重建，
    /// 只等当下那一个的话，它可能刚被后来的取消掉、新的那个还没跑完
    private func settle(_ p: ProjectState) async {
        var last: Task<Void, Never>?
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let t = p.rebuildTask else { return }
            await t.value
            if t == last { return }
            last = t
        }
    }

    /// 320x240 两秒纯色片，够走一遍合成链
    private func makeTestVideo() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("filter_test_\(UUID().uuidString).mp4")
        let w = 320, h = 240
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w, AVVideoHeightKey: h])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for i in 0..<20 {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, adaptor.pixelBufferPool!, &pb)
            guard let buf = pb else { throw NSError(domain: "test", code: 1) }
            CVPixelBufferLockBaseAddress(buf, [])
            memset(CVPixelBufferGetBaseAddress(buf), 120,
                   CVPixelBufferGetBytesPerRow(buf) * h)
            CVPixelBufferUnlockBaseAddress(buf, [])
            adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 10))
        }
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        return url
    }
}
