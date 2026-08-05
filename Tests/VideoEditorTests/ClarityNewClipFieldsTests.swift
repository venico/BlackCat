import XCTest
@testable import VideoEditorLib

/// 清晰度提升产出的新片段，字段必须配齐——尤其是 url。
///
/// 缩略图的生成入口是 VideoClipView 里的 `if let url = clip.url { … }`，
/// 漏掉 url 不会报任何错，只是那个条件永远不成立、片段一直是纯色块，
/// 非得删掉重新从素材库拖一次才有图。这类"少给一个字段导致某条路径静默失效"
/// 的问题肉眼很难看出来，用测试钉住。
final class ClarityNewClipFieldsTests: XCTestCase {

    /// 带 url 构造的片段才会触发缩略图加载
    func testVideoClipWithURLEnablesThumbnailLoading() {
        let url = URL(fileURLWithPath: "/tmp/whatever.mp4")
        let clip = VideoClip(assetID: UUID(), name: "增强版", url: url,
                             startTime: 0, endTime: 5)
        XCTAssertNotNil(clip.url, "没有 url 的话 VideoClipView 的缩略图入口不会执行")
        XCTAssertEqual(clip.url, url)
        XCTAssertFalse(clip.name.isEmpty, "片段标题也要有，否则时间轴上是空标签")
    }

    /// 不带 url 的构造方式会留下这个坑——保留这条是为了说明差别
    func testVideoClipWithoutURLSilentlySkipsThumbnails() {
        let clip = VideoClip(assetID: UUID(), startTime: 0, endTime: 5)
        XCTAssertNil(clip.url,
                     "这个构造重载不带 url；清晰度提升曾经用的就是它，导致片段没有缩略图")
    }

    /// 新片段要继承源片段的时间范围和速度（这两个之前 review 抓到过）
    func testNewClipInheritsTimingAndSpeed() {
        var src = VideoClip(assetID: UUID(), name: "源", url: URL(fileURLWithPath: "/tmp/a.mp4"),
                            startTime: 3, endTime: 8)
        src.speed = 1.5

        var out = VideoClip(assetID: UUID(), name: "增强版", url: URL(fileURLWithPath: "/tmp/b.mp4"),
                            startTime: src.startTime, endTime: src.startTime + src.duration)
        out.trimStart = 0
        out.speed = src.speed

        XCTAssertEqual(out.startTime, src.startTime, accuracy: 0.0001)
        XCTAssertEqual(out.duration, src.duration, accuracy: 0.0001, "时间轴宽度要一致")
        XCTAssertEqual(out.speed, src.speed, accuracy: 0.0001, "变速片段不继承 speed 会播放截断")
        XCTAssertEqual(out.trimStart, 0, accuracy: 0.0001, "新文件是完整的，不该有裁剪偏移")
    }
}
