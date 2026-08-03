// Tests/VideoEditorTests/ClarityFrameIOTests.swift
import XCTest
@testable import VideoEditorLib

final class ClarityFrameIOTests: XCTestCase {

    /// 用 ffmpeg 的 testsrc 生成一个 2 秒、10fps、带静音音轨的测试视频，不依赖任何外部素材
    private func makeTestVideo() throws -> URL {
        guard let ff = ProjectState.findFFmpeg() else { throw XCTSkip("找不到 ffmpeg") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("frameio_test_\(UUID().uuidString).mp4")
        let p = Process()
        p.executableURL = ff
        p.arguments = ["-hide_banner", "-loglevel", "error", "-y",
                       "-f", "lavfi", "-i", "testsrc=size=320x240:rate=10:duration=2",
                       "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo",
                       "-t", "2", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac",
                       url.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw XCTSkip("测试视频生成失败") }
        return url
    }

    func testExtractFramesProducesExpectedCount() throws {
        let video = try makeTestVideo()
        defer { try? FileManager.default.removeItem(at: video) }
        let outDir = FileManager.default.temporaryDirectory.appendingPathComponent("frameio_extract_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outDir) }

        let frames = try ClarityFrameIO.extractFrames(url: video, trimStart: 0, duration: 2,
                                                      frameRate: 10, outputDir: outDir)
        // 2 秒 * 10fps，允许 ±1 帧的边界误差
        print("[TEST] Extracted frames count: \(frames.count)")
        XCTAssertTrue((19...21).contains(frames.count), "应该抽出约 20 帧，实际 \(frames.count)")
    }

    func testEncodeFramesRoundTrip() throws {
        let video = try makeTestVideo()
        defer { try? FileManager.default.removeItem(at: video) }
        let frameDir = FileManager.default.temporaryDirectory.appendingPathComponent("frameio_roundtrip_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: frameDir) }
        let frames = try ClarityFrameIO.extractFrames(url: video, trimStart: 0, duration: 2,
                                                      frameRate: 10, outputDir: frameDir)
        XCTAssertFalse(frames.isEmpty)

        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent("frameio_out_\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: outURL) }
        try ClarityFrameIO.encodeFrames(frameDir: frameDir, frameRate: 10,
                                        audioSourceURL: video, audioTrimStart: 0, audioDuration: 2,
                                        outputURL: outURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outURL.path))
        let size = (try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? Int) ?? 0
        print("[TEST] Output file size: \(size) bytes, Extracted frames: \(frames.count)")
        XCTAssertGreaterThan(size ?? 0, 1000, "输出文件应该有实际内容，不是空文件")
    }
}
