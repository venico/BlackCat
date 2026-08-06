// 带进度的下载。这块踩过两个坑，测试就是钉住它们别再回去：
//   1. 逐字节读（URLSession.bytes）慢到没法用
//   2. async download 的 task 级 delegate 收不到进度回调
// 第 2 条尤其阴——不报错，只是进度条一直 0%，下完直接跳完成。
import XCTest
@testable import VideoEditorLib

final class DownloadProgressTests: XCTestCase {

    /// 用模型仓库里一个真实的小文件（2.5MB），够触发多次进度回调又不拖慢测试
    private let sampleURL = URL(string:
        "https://github.com/venico/blackcat-models/releases/download/clarity-pro-v1/RealCUGAN_up4x.mlmodelc.zip")!

    func testProgressCallbackActuallyFires() async throws {
        var samples: [Double] = []
        let lock = NSLock()

        var req = URLRequest(url: sampleURL)
        req.setValue("BlackCat/test", forHTTPHeaderField: "User-Agent")
        let (tmp, resp) = try await DownloadProgress.download(req) { p in
            lock.lock(); samples.append(p); lock.unlock()
        }
        defer { try? FileManager.default.removeItem(at: tmp) }

        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 200)

        // 核心断言：回调必须真的被调用过。之前用 task 级 delegate 时这里是 0 次，
        // 而下载本身是成功的——所以只测「下载成功」抓不到这个 bug
        XCTAssertFalse(samples.isEmpty, "进度回调一次都没触发——进度条会一直停在 0%")
        XCTAssertGreaterThan(samples.count, 1, "只回调一次等于没有进度，用户看不到过程")

        // 单调不减，且最终接近 1
        for (a, b) in zip(samples, samples.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b, a, "进度不能往回退")
        }
        XCTAssertGreaterThan(samples.last ?? 0, 0.9, "结束时进度该接近 100%")
        XCTAssertTrue(samples.allSatisfy { $0 >= 0 && $0 <= 1 }, "进度必须落在 0…1")
    }

    func testDownloadedFileSurvivesTheCallback() async throws {
        // didFinishDownloadingTo 的临时文件在回调返回后会被系统删掉，
        // 必须在回调内搬走。这条测的就是搬走这一步没漏
        var req = URLRequest(url: sampleURL)
        req.setValue("BlackCat/test", forHTTPHeaderField: "User-Agent")
        let (tmp, _) = try await DownloadProgress.download(req) { _ in }
        defer { try? FileManager.default.removeItem(at: tmp) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.path),
                      "下载完的文件应该还在——没在回调里搬走的话这里就已经没了")
        let size = (try FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size, 1_000_000, "文件大小不对，可能只拿到了个空壳")
    }

    func testBadURLReportsErrorNotHang() async {
        let bad = URL(string: "https://github.com/venico/blackcat-models/releases/download/nope/none.zip")!
        var req = URLRequest(url: bad)
        req.setValue("BlackCat/test", forHTTPHeaderField: "User-Agent")
        do {
            let (tmp, resp) = try await DownloadProgress.download(req) { _ in }
            defer { try? FileManager.default.removeItem(at: tmp) }
            // GitHub 对不存在的资产返回 404，不抛错——调用方靠状态码判断
            XCTAssertNotEqual((resp as? HTTPURLResponse)?.statusCode, 200,
                              "不存在的地址不该返回 200")
        } catch {
            // 抛错也是可接受的结果，只要不是卡住不返回
        }
    }
}
