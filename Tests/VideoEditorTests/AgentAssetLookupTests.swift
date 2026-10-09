// 素材库一大，Agent 也得找得到刚生成/刚导入的那个（TC-AG-060 测试里栽过：
// 后台助手查不到新图的 id，步数用光也没放进时间轴）
import XCTest
@testable import VideoEditorLib

@MainActor
final class AgentAssetLookupTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MediaLibrary.shared.resetForTesting()
    }

    /// 素材库是全局单例，塞进去的 60 个不清掉会串到后面的用例（「空素材库」那条）
    override func tearDown() {
        MediaLibrary.shared.resetForTesting()
        super.tearDown()
    }

    private func fill(_ p: ProjectState, count: Int) -> URL {
        var last = URL(fileURLWithPath: "/")
        for i in 0..<count {
            let url = URL(fileURLWithPath: "/tmp/lookup_\(i).png")
            p.mediaAssets.append(MediaAsset(url: url, name: url.lastPathComponent, type: .image))
            last = url
        }
        return last
    }

    /// 超过 40 个时，最新加的那个也要列出来
    func testNewestAssetIsListed() async {
        let p = ProjectState()
        _ = fill(p, count: 60)
        let out = await AgentToolbox.runReadTool("list_assets", args: [:], project: p)?.text ?? ""
        XCTAssertTrue(out.contains("lookup_59.png"), "最新的素材没列出来")
        XCTAssertFalse(out.contains("lookup_0.png"), "最老的应该被挤出前 40 个")
    }

    /// 按文件名找
    func testFindByName() async {
        let p = ProjectState()
        _ = fill(p, count: 60)
        let out = await AgentToolbox.runReadTool("list_assets", args: ["name": "LOOKUP_3.png"], project: p)?.text ?? ""
        XCTAssertTrue(out.contains("lookup_3.png"))
        XCTAssertTrue(out.contains("（1 个"), "只该命中一个：\(out)")
    }

    /// 只有文件路径也能放进时间轴
    func testAddByPath() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lookup_\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let p = ProjectState()
        p.mediaAssets.append(MediaAsset(url: url, name: url.lastPathComponent, type: .image))
        let r = AgentToolbox.runEditTool("add_asset_to_timeline", args: ["path": url.path, "time": 0.0], project: p)
        XCTAssertEqual(r?.isError, false, r?.text ?? "")
        let missing = AgentToolbox.runEditTool("add_asset_to_timeline", args: ["path": "/tmp/没有这个.png"], project: p)
        XCTAssertEqual(missing?.isError, true)
    }
}
