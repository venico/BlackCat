import XCTest
@testable import VideoEditorLib

/// 「清晰度提升」点下去立刻插的那条呼吸占位轨道的生命周期
final class ClarityPlaceholderTests: XCTestCase {

    /// 取消时必须把占位轨道整条撤掉，不能在时间轴上留一条空轨道
    @MainActor
    func testCancelRemovesPlaceholderTrack() {
        let p = ProjectState()
        let track = Track<VideoClip>(clips: [], label: "占位")
        p.videoTracks.append(track)
        p.videoSectionOrder.append(.video(track.id))
        let clipID = UUID()
        p.placeholderClipIDs.insert(clipID)
        p.clarityPlaceholderTrackID = track.id
        p.clarityPlaceholderClipID = clipID
        p.clarityEnhanceState = .inferring(0.4)

        let before = p.videoTracks.count
        p.cancelClarityEnhance()

        XCTAssertEqual(p.videoTracks.count, before - 1, "占位轨道应被移除")
        XCTAssertFalse(p.videoTracks.contains { $0.id == track.id })
        XCTAssertFalse(p.videoSectionOrder.contains { $0.trackID == track.id },
                       "轨道顺序表里也不能留下悬空引用")
        XCTAssertFalse(p.placeholderClipIDs.contains(clipID), "呼吸标记要摘掉")
        XCTAssertNil(p.clarityPlaceholderTrackID)
        XCTAssertNil(p.clarityPlaceholderClipID)
    }

    /// 没有占位时取消不能误伤别的轨道
    @MainActor
    func testCancelWithoutPlaceholderLeavesTracksAlone() {
        let p = ProjectState()
        let keep = Track<VideoClip>(clips: [], label: "别动我")
        p.videoTracks.append(keep)
        p.videoSectionOrder.append(.video(keep.id))
        let before = p.videoTracks.count

        p.cancelClarityEnhance()

        XCTAssertEqual(p.videoTracks.count, before)
        XCTAssertTrue(p.videoTracks.contains { $0.id == keep.id })
    }

    /// 占位片段带着 placeholderClipIDs 标记，UI 才会让它呼吸
    @MainActor
    func testPlaceholderMarkDrivesBreathing() {
        let p = ProjectState()
        let clipID = UUID()
        XCTAssertFalse(p.placeholderClipIDs.contains(clipID))
        p.placeholderClipIDs.insert(clipID)
        XCTAssertTrue(p.placeholderClipIDs.contains(clipID),
                      "VideoClipView 靠这个集合判断要不要呼吸")
    }
}
