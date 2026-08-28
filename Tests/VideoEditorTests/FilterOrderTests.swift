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

    // 预览重建要把滤镜送进合成器 —— 合成器有条透传快路径只认这份静态存储
    func testRebuildFeedsCompositor() async throws {
        ColorCompositor.setFilterTracks([])
        let url = try makeTestVideo()
        defer { try? FileManager.default.removeItem(at: url) }

        let p = ProjectState()
        var asset = MediaAsset(url: url, name: "v", type: .video)
        asset.duration = 2
        p.mediaAssets.append(asset)
        p.addToTimelineAt(asset, time: 0)
        _ = p.addFilter(kind: .comic, at: 0)
        p.rebuildTimelinePreview()
        await p.rebuildTask?.value   // 重建是异步的，等它跑完再看

        XCTAssertFalse(ColorCompositor.getFilterTracks().isEmpty,
                       "重建之后合成器该拿到滤镜轨道")
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
