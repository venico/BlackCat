// 时间线标签页（模块：多时间线）
import XCTest
@testable import VideoEditorLib

@MainActor
final class TimelineTabTests: XCTestCase {

    func testTracksAreIsolatedBetweenTabs() {
        let p = ProjectState()
        p.addTextAtPlayhead(text: "第一条")
        let firstCount = p.textTracks.flatMap(\.clips).count
        XCTAssertGreaterThan(firstCount, 0)

        p.addTimelineTab()
        XCTAssertEqual(p.textTracks.flatMap(\.clips).count, 0, "新标签页该是空的")

        p.addTextAtPlayhead(text: "第二条")
        XCTAssertEqual(p.textTracks.flatMap(\.clips).count, 1)

        p.switchToTab(0)
        XCTAssertEqual(p.textTracks.flatMap(\.clips).count, firstCount,
                       "切回来内容该原样还在，两个标签页不该互相影响")
    }

    /// 关闭只收起标签，删除才丢数据
    func testCloseKeepsDataDeleteDoesNot() {
        let p = ProjectState()
        p.addTimelineTab()
        let second = p.tabs[1].id
        XCTAssertEqual(p.tabs.count, 2)

        p.closeTab(id: second)
        XCTAssertEqual(p.tabs.count, 2, "关闭不该删掉时间线")
        XCTAssertFalse(p.tabs[1].isTabOpen)
        XCTAssertEqual(p.openTabs.count, 1)

        p.showAllTabs()
        XCTAssertEqual(p.openTabs.count, 2, "显示所有标签页该把关掉的找回来")

        p.deleteTab(id: second)
        XCTAssertEqual(p.tabs.count, 1, "删除才是真的丢掉")
    }

    /// 最后一条也能删，删完补一条全新的空时间线
    func testDeletingLastTabLeavesAFreshOne() {
        let p = ProjectState()
        p.addTextAtPlayhead(text: "会被删掉")
        let oldID = p.tabs[0].id

        p.deleteTab(id: oldID)
        XCTAssertEqual(p.tabs.count, 1, "删光之后该补一条新的，不能一条都不剩")
        XCTAssertNotEqual(p.tabs[0].id, oldID, "补的是全新的一条")
        XCTAssertTrue(p.textTracks.flatMap(\.clips).isEmpty, "新时间线该是空的")
        // 默认那几条空轨道要在
        XCTAssertEqual(p.videoTracks.count, 1)
        XCTAssertEqual(p.audioTracks.count, 1)
        XCTAssertEqual(p.imageTracks.count, 1)
        XCTAssertEqual(p.subtitleTracks.count, 1)
        XCTAssertEqual(p.textTracks.count, 1)
        XCTAssertEqual(p.shapeTracks.count, 1)
    }

    /// 关掉当前这个，要落到旁边还开着的那个上
    func testClosingActiveTabFallsBackToAnother() {
        let p = ProjectState()
        p.addTimelineTab()
        let active = p.tabs[p.activeTab].id
        p.closeTab(id: active)
        XCTAssertTrue(p.tabs[p.activeTab].isTabOpen, "落点必须是个开着的标签页")
        XCTAssertNotEqual(p.tabs[p.activeTab].id, active)
    }

    /// 切标签页要清掉选中态 —— 那些 id 在新标签页里根本不存在
    func testSwitchingClearsSelection() {
        let p = ProjectState()
        p.addTextAtPlayhead(text: "x")
        p.selectedTextClipID = p.textTracks.flatMap(\.clips).first?.id
        XCTAssertNotNil(p.selectedTextClipID)
        p.addTimelineTab()
        XCTAssertNil(p.selectedTextClipID, "切过去之后选中态该清掉")
    }

    /// 素材库是全项目共享的，不随标签页走
    func testMediaLibraryIsShared() {
        let p = ProjectState()
        let asset = MediaAsset(url: URL(fileURLWithPath: "/tmp/x.mp4"), name: "x", type: .video)
        p.mediaAssets.append(asset)
        p.addTimelineTab()
        XCTAssertTrue(p.mediaAssets.contains { $0.id == asset.id },
                      "换个标签页素材库该还在")
    }

    /// 新建的标签页得能显示出轨道来。
    /// 轨道区是照 overlayTrackOrder / videoSectionOrder 画的，
    /// 这三张表空着的话六条空轨一条都不显示 —— 看着就是「新建的没有轨道」
    func testNewTabHasPopulatedOrderTables() {
        let p = ProjectState()
        p.addTimelineTab()
        XCTAssertFalse(p.overlayTrackOrder.isEmpty, "叠加层顺序表空着，图片/字幕/文字/图形都不会显示")
        XCTAssertFalse(p.videoSectionOrder.isEmpty, "视频顺序表空着，视频轨不显示")
        XCTAssertFalse(p.audioSectionOrder.isEmpty, "音频顺序表空着，音频轨不显示")
    }

    /// 删光之后补出来的那条也一样
    func testFreshTabAfterDeleteHasOrderTables() {
        let p = ProjectState()
        p.deleteTab(id: p.tabs[0].id)
        XCTAssertFalse(p.overlayTrackOrder.isEmpty)
        XCTAssertFalse(p.videoSectionOrder.isEmpty)
        XCTAssertFalse(p.audioSectionOrder.isEmpty)
    }
}
