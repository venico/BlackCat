// 多窗口下的菜单命令路由。
//
// 这块最容易出的错是**广播**：原来 7 个菜单命令都是不带目标的
// NotificationCenter.post，单窗口时看不出问题，多开一个窗口之后按一次「保存」
// 会把所有打开的项目都存一遍，而且没有任何报错。
import XCTest
@testable import VideoEditorLib

final class WindowRoutingTests: XCTestCase {

    func testEachWindowGetsItsOwnID() {
        let a = WindowID(), b = WindowID()
        XCTAssertNotEqual(a, b, "两个窗口不能共用 id，否则命令会串台")
        XCTAssertEqual(a, a)
    }

    func testNotificationOnlyMatchesItsTargetWindow() {
        let target = WindowID(), other = WindowID()
        let note = Notification(name: MenuCommand.saveProject.notificationName,
                                object: nil,
                                userInfo: ["windowID": target])
        XCTAssertTrue(note.isFor(target))
        XCTAssertFalse(note.isFor(other), "别的窗口不该响应发给 target 的命令")
    }

    /// 没带 windowID 的通知一律不认。挡住「有人图省事又写了个裸 post」
    func testNotificationWithoutWindowIDMatchesNobody() {
        let note = Notification(name: MenuCommand.saveProject.notificationName,
                                object: nil, userInfo: nil)
        XCTAssertFalse(note.isFor(WindowID()))
    }

    func testCommandNamesAreDistinct() {
        let all: [MenuCommand] = [.newProject, .openProject, .openProjectFile,
                                  .saveProject, .importFiles, .exportVideo]
        let names = Set(all.map(\.notificationName))
        XCTAssertEqual(names.count, all.count, "命令的通知名撞了会互相触发")
    }

    @MainActor
    func testPostToSpecificWindowCarriesID() {
        let id = WindowID()
        let exp = expectation(description: "收到命令")
        var receivedFor: WindowID?

        let token = NotificationCenter.default.addObserver(
            forName: MenuCommand.exportVideo.notificationName, object: nil, queue: .main) { note in
                receivedFor = note.userInfo?["windowID"] as? WindowID
                exp.fulfill()
            }
        defer { NotificationCenter.default.removeObserver(token) }

        MenuCommand.exportVideo.post(to: id)
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(receivedFor, id, "投递的命令必须带上目标窗口 id")
    }

    @MainActor
    func testObjectPayloadSurvives() {
        let id = WindowID()
        let urls = [URL(fileURLWithPath: "/tmp/a.mp4"), URL(fileURLWithPath: "/tmp/b.mp4")]
        let exp = expectation(description: "收到附带的 URL")
        var got: [URL]?

        let token = NotificationCenter.default.addObserver(
            forName: MenuCommand.importFiles.notificationName, object: nil, queue: .main) { note in
                guard note.isFor(id) else { return }
                got = note.object as? [URL]
                exp.fulfill()
            }
        defer { NotificationCenter.default.removeObserver(token) }

        MenuCommand.importFiles.post(to: id, object: urls)
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(got, urls, "导入命令要能把选中的文件带过去")
    }
}
