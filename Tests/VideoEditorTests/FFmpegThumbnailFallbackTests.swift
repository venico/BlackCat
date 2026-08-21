import XCTest
import Foundation
import AVFoundation
import CoreMedia
@testable import VideoEditorLib

// MARK: - ffmpeg 抽帧兜底
//
// 家里机器上 AVFoundation 对本进程整体拒绝解码（-11821 Cannot Decode，
// 普通 H.264 也失败），缩略图全空白。兜底改用内置 ffmpeg 抽帧。
// 本机 AVFoundation 是好的，没法真实复现 -11821，所以直接验证 ffmpeg
// 两个抽帧函数本身 —— 兜底路径的接线由代码审查保证。

final class FFmpegThumbnailFallbackTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // 素材库是全局单例，不清一遍的话上个用例导入的素材会串到下个用例
        MediaLibrary.shared.resetForTesting()
    }

    /// 用 AVAssetWriter 造一个真实可解码的小视频（纯色帧 H.264）
    private func makeTestVideo(seconds: Double = 2.0, fps: Int = 10,
                               width: Int = 320, height: Int = 240) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ffthumb_test_\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let total = Int(seconds * Double(fps))
        for i in 0..<total {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, adaptor.pixelBufferPool!, &pb)
            guard let buf = pb else { throw NSError(domain: "test", code: 1) }
            CVPixelBufferLockBaseAddress(buf, [])
            if let base = CVPixelBufferGetBaseAddress(buf) {
                // 每帧换个颜色，抽出来的帧不至于全黑难分辨
                memset(base, Int32((i * 37) % 255), CVPixelBufferGetDataSize(buf))
            }
            CVPixelBufferUnlockBaseAddress(buf, [])
            adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        guard writer.status == .completed else {
            throw writer.error ?? NSError(domain: "test", code: 2)
        }
        return url
    }

    /// 封面单帧：能抽出来，且按 force_original_aspect_ratio 缩进框内
    func testSingleFrameExtraction() throws {
        try XCTSkipUnless(ProjectState.findFFmpeg() != nil, "没有 ffmpeg，跳过")
        let video = try makeTestVideo()
        defer { try? FileManager.default.removeItem(at: video) }

        let img = ProjectState.ffmpegSingleFrame(url: video, maxSize: 400)
        let cover = try XCTUnwrap(img, "ffmpeg 应能抽出封面帧")
        XCTAssertGreaterThan(cover.size.width, 0)
        // 320x240 源，maxSize 400 → 不放大也不超框
        XCTAssertLessThanOrEqual(cover.size.width, 400)
        XCTAssertLessThanOrEqual(cover.size.height, 400)
    }

    /// 时间轴条：帧数和时间标注要跟 interval 对上
    func testFrameStripExtraction() throws {
        try XCTSkipUnless(ProjectState.findFFmpeg() != nil, "没有 ffmpeg，跳过")
        let video = try makeTestVideo(seconds: 2.0)
        defer { try? FileManager.default.removeItem(at: video) }

        let frames = ProjectState.ffmpegFrameStrip(url: video, interval: 0.5)
        // 2s / 0.5s ≈ 4 帧（首帧在 0），fps 滤镜边界上可能差一帧
        XCTAssertGreaterThanOrEqual(frames.count, 3, "2s 视频 0.5s 间隔至少 3 帧，实际 \(frames.count)")
        XCTAssertLessThanOrEqual(frames.count, 5)
        // 时间标注：第 i 帧 = i * interval，且严格递增
        for (i, f) in frames.enumerated() {
            XCTAssertEqual(f.time, Double(i) * 0.5, accuracy: 0.001)
        }
        // 帧尺寸缩进 160x104 框
        for f in frames {
            XCTAssertLessThanOrEqual(f.image.size.width, 160)
            XCTAssertLessThanOrEqual(f.image.size.height, 104)
        }
    }

    /// 坏文件两个函数都要干净地返回空，不能抛异常或卡死
    func testCorruptFileReturnsEmpty() throws {
        try XCTSkipUnless(ProjectState.findFFmpeg() != nil, "没有 ffmpeg，跳过")
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("ffbad_\(UUID().uuidString).mp4")
        try Data("这不是视频".utf8).write(to: bogus)
        defer { try? FileManager.default.removeItem(at: bogus) }

        XCTAssertNil(ProjectState.ffmpegSingleFrame(url: bogus, maxSize: 400))
        XCTAssertTrue(ProjectState.ffmpegFrameStrip(url: bogus, interval: 0.5).isEmpty)
    }

    /// interval 非法时直接返回空，防止 fps 滤镜除零
    func testInvalidIntervalReturnsEmpty() throws {
        let video = FileManager.default.temporaryDirectory
            .appendingPathComponent("whatever.mp4")
        XCTAssertTrue(ProjectState.ffmpegFrameStrip(url: video, interval: 0).isEmpty)
        XCTAssertTrue(ProjectState.ffmpegFrameStrip(url: video, interval: -1).isEmpty)
    }
}
