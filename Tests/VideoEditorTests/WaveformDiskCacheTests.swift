// 波形硬盘缓存：存进去能原样读回，文件一变就失效
import XCTest
@testable import VideoEditorLib

final class WaveformDiskCacheTests: XCTestCase {

    func testRoundTripAndInvalidateOnChange() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wave_test_\(UUID().uuidString).mp3")
        try Data(repeating: 1, count: 1000).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let w = WaveformData(totalDuration: 12.5, samples: [0, 0.25, 0.5, 1])
        ThumbnailDiskCache.saveWaveform(w, for: url)
        let back = try XCTUnwrap(ThumbnailDiskCache.loadWaveform(for: url), "存了却读不回来")
        XCTAssertEqual(back.totalDuration, 12.5)
        XCTAssertEqual(back.samples, [0, 0.25, 0.5, 1])

        // 文件内容变了（大小变）就不该再认旧缓存
        try Data(repeating: 2, count: 2000).write(to: url)
        XCTAssertNil(ThumbnailDiskCache.loadWaveform(for: url), "文件变了还读到旧波形")
    }
}
