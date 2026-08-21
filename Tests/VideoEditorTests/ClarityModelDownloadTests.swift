// Tests/VideoEditorTests/ClarityModelDownloadTests.swift
import XCTest
import Foundation
@testable import VideoEditorLib

// 模型很小（~20KB），完整下载测试其实很快，但仍默认跳过以避免测试套件产生网络依赖。
// 需要验证时加环境变量：BLACKCAT_TEST_DOWNLOAD=1 swift test --filter ClarityModelDownloadTests

final class ClarityModelDownloadTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // 素材库是全局单例，不清一遍的话上个用例导入的素材会串到下个用例
        MediaLibrary.shared.resetForTesting()
    }

    func testDownloadURLIsPubliclyReachable() async throws {
        for model in ClarityModel.allCases {
            try await checkReachable(model)
        }
    }

    private func checkReachable(_ model: ClarityModel) async throws {
        let urlString = try XCTUnwrap(model.sourceURLs.first, "\(model.displayName) 应该有下载源")
        var request = URLRequest(url: try XCTUnwrap(URL(string: urlString)))
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        request.timeoutInterval = 90

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw XCTSkip("网络不通，跳过：\(error.localizedDescription)")
        }
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertTrue([200, 206].contains(http.statusCode),
                      "\(model.displayName) 匿名访问应拿到 200/206，实际 \(http.statusCode)")
        XCTAssertEqual(Array(data.prefix(2)), [0x50, 0x4B], "\(model.displayName) 开头应是 ZIP 魔数 PK")
    }

    func testFullDownloadAndUnpack() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BLACKCAT_TEST_DOWNLOAD"] == "1",
                          "设 BLACKCAT_TEST_DOWNLOAD=1 才跑这条")

        let model = ClarityModel.x2
        let fm = FileManager.default
        var backup: URL?
        if model.isDownloaded {
            let b = model.localURL.appendingPathExtension("bak-\(UUID().uuidString)")
            try fm.moveItem(at: model.localURL, to: b)
            backup = b
        }
        defer {
            if let b = backup {
                try? fm.removeItem(at: model.localURL)
                try? fm.moveItem(at: b, to: model.localURL)
            }
        }

        XCTAssertFalse(model.isDownloaded, "挪开后应视为未下载")

        var lastPct = 0.0
        try await model.download { pct in lastPct = pct }

        XCTAssertTrue(model.isDownloaded, "下载完应该能检测到模型")
        XCTAssertEqual(lastPct, 1.0, accuracy: 0.001, "进度应走到 100%")

        var isDir: ObjCBool = false
        XCTAssertTrue(fm.fileExists(atPath: model.localURL.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue, "mlmodelc 应该是目录")
        XCTAssertTrue(fm.fileExists(atPath: model.localURL.appendingPathComponent("coremldata.bin").path),
                      "缺 coremldata.bin，解压结果不完整")

        let leftovers = (try? fm.contentsOfDirectory(atPath: ClarityModel.supportDir.path)) ?? []
        XCTAssertFalse(leftovers.contains { $0.hasPrefix("unzip-") || $0.hasSuffix(".part") },
                       "不该残留临时文件：\(leftovers)")
    }
}
