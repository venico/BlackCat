import XCTest
import Foundation
@testable import VideoEditorLib

// MARK: - 模型下载链路
//
// 真的去 release 拉 82MB，跑得慢，默认跳过。
// 要验证时加环境变量：BLACKCAT_TEST_DOWNLOAD=1 swift test --filter BiRefNetDownloadTests

final class BiRefNetDownloadTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // 素材库是全局单例，不清一遍的话上个用例导入的素材会串到下个用例
        MediaLibrary.shared.resetForTesting()
    }

    /// 下载源必须是可匿名访问的 —— 主仓库是私有的，早先挂在那儿的地址对外是 404。
    /// 这条只发 range 请求探一下头部，不拉整包，任何时候都该通过
    func testDownloadURLIsPubliclyReachable() async throws {
        for model in BiRefNetModel.allCases {
            try await checkReachable(model)
        }
    }

    private func checkReachable(_ model: BiRefNetModel) async throws {
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
                      "\(model.displayName) 匿名访问应拿到 200/206，实际 \(http.statusCode) —— 仓库可能不是公开的")
        // ZIP 魔数，确认拿到的是压缩包而不是一个 HTML 错误页
        XCTAssertEqual(Array(data.prefix(2)), [0x50, 0x4B], "\(model.displayName) 开头应是 ZIP 魔数 PK")
    }

    /// 完整跑一遍下载 + 解压。会临时挪开已有模型，结束后原样放回
    func testFullDownloadAndUnpack() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BLACKCAT_TEST_DOWNLOAD"] == "1",
                          "设 BLACKCAT_TEST_DOWNLOAD=1 才跑这条")

        let model = BiRefNetModel.lite
        let fm = FileManager.default
        // 已有模型先挪走，确保测的是真下载而不是现成文件
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

        // 解压出来的得是个能用的 mlmodelc 目录
        var isDir: ObjCBool = false
        XCTAssertTrue(fm.fileExists(atPath: model.localURL.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue, "mlmodelc 应该是目录")
        XCTAssertTrue(fm.fileExists(atPath: model.localURL.appendingPathComponent("coremldata.bin").path),
                      "缺 coremldata.bin，解压结果不完整")

        // 解压后的临时目录不该留下垃圾
        let leftovers = (try? fm.contentsOfDirectory(atPath: BiRefNetModel.supportDir.path)) ?? []
        XCTAssertFalse(leftovers.contains { $0.hasPrefix("unzip-") || $0.hasSuffix(".part") },
                       "不该残留临时文件：\(leftovers)")
    }
}
