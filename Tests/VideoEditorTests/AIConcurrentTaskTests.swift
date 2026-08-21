// 模块 48：AI 生成多任务（v5.1.0，画布的前置）
//
// 原来 AIVideoService 只伺候一个任务：一个 isGenerating 布尔 + 一个
// generatingMessageId，进度回调靠「最后一条还在跑的助手消息」定位。
// 画布要同时跑一堆节点，这组守的是「任务之间不串台」。
import XCTest
@testable import VideoEditorLib

final class AIConcurrentTaskTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MediaLibrary.shared.resetForTesting()
        AIVideoService.shared.cancelAllGenerations()
    }

    override func tearDown() {
        AIVideoService.shared.cancelAllGenerations()
        super.tearDown()
    }

    // 聊天面板的锁只认聊天任务：画布在跑的时候聊天输入框不该被锁住
    func testCanvasTasksDoNotLockChatInput() {
        let s = AIVideoService.shared
        let canvas = AIVideoService.RunningGeneration(
            id: UUID(), convId: UUID(), msgId: UUID(),
            source: .canvas, category: .image, handle: nil)
        s.testHook_insertRunningTask(canvas)

        XCTAssertFalse(s.isGenerating, "画布任务不该把聊天面板锁住")

        let chat = AIVideoService.RunningGeneration(
            id: UUID(), convId: UUID(), msgId: UUID(),
            source: .chat, category: .video, handle: nil)
        s.testHook_insertRunningTask(chat)
        XCTAssertTrue(s.isGenerating, "聊天任务在跑时才锁")
    }

    // 多个任务同时挂着，各自记着自己的会话和消息
    func testTasksKeepTheirOwnMessageBinding() {
        let s = AIVideoService.shared
        let a = AIVideoService.RunningGeneration(id: UUID(), convId: UUID(), msgId: UUID(),
                                                 source: .canvas, category: .image, handle: nil)
        let b = AIVideoService.RunningGeneration(id: UUID(), convId: UUID(), msgId: UUID(),
                                                 source: .canvas, category: .video, handle: nil)
        s.testHook_insertRunningTask(a)
        s.testHook_insertRunningTask(b)

        XCTAssertEqual(s.runningTasks.count, 2)
        XCTAssertEqual(s.runningTasks[a.id]?.msgId, a.msgId)
        XCTAssertEqual(s.runningTasks[b.id]?.msgId, b.msgId)
        XCTAssertNotEqual(s.runningTasks[a.id]?.msgId, s.runningTasks[b.id]?.msgId)
    }

    // 取消一个不该动到别的
    func testCancelOneLeavesOthersRunning() {
        let s = AIVideoService.shared
        let a = AIVideoService.RunningGeneration(id: UUID(), convId: UUID(), msgId: UUID(),
                                                 source: .canvas, category: .image, handle: nil)
        let b = AIVideoService.RunningGeneration(id: UUID(), convId: UUID(), msgId: UUID(),
                                                 source: .canvas, category: .image, handle: nil)
        s.testHook_insertRunningTask(a)
        s.testHook_insertRunningTask(b)

        s.cancel(taskID: a.id)
        XCTAssertNil(s.runningTasks[a.id])
        XCTAssertNotNil(s.runningTasks[b.id], "取消一个不该连累另一个")
    }

    // 退出/关窗时一把收干净
    func testCancelAllClearsEverything() {
        let s = AIVideoService.shared
        for _ in 0..<5 {
            s.testHook_insertRunningTask(
                AIVideoService.RunningGeneration(id: UUID(), convId: UUID(), msgId: UUID(),
                                                 source: .canvas, category: .image, handle: nil))
        }
        XCTAssertEqual(s.runningTasks.count, 5)
        s.cancelAllGenerations()
        XCTAssertTrue(s.runningTasks.isEmpty)
    }

    // 按消息查任务 / 按消息取消 —— 消息气泡上那个「停这一条」靠它
    func testCancelByMessageOnlyStopsThatOne() {
        let s = AIVideoService.shared
        let a = AIVideoService.RunningGeneration(id: UUID(), convId: UUID(), msgId: UUID(),
                                                 source: .chat, category: .image, handle: nil)
        let b = AIVideoService.RunningGeneration(id: UUID(), convId: UUID(), msgId: UUID(),
                                                 source: .chat, category: .video, handle: nil)
        s.testHook_insertRunningTask(a)
        s.testHook_insertRunningTask(b)

        XCTAssertNotNil(s.runningTask(forMessage: a.msgId))
        s.cancelTask(forMessage: a.msgId)

        XCTAssertNil(s.runningTask(forMessage: a.msgId), "这一条该停了")
        XCTAssertNotNil(s.runningTask(forMessage: b.msgId), "另一条不该受影响")
    }

    // 聊天面板现在允许边生成边发：同一个会话可以同时挂多个任务
    func testChatCanHaveMultipleConcurrentTasks() {
        let s = AIVideoService.shared
        let conv = UUID()
        let img = AIVideoService.RunningGeneration(id: UUID(), convId: conv, msgId: UUID(),
                                                   source: .chat, category: .image, handle: nil)
        let vid = AIVideoService.RunningGeneration(id: UUID(), convId: conv, msgId: UUID(),
                                                   source: .chat, category: .video, handle: nil)
        s.testHook_insertRunningTask(img)
        s.testHook_insertRunningTask(vid)

        XCTAssertEqual(s.runningTasks.values.filter { $0.convId == conv }.count, 2,
                       "同一个会话该能同时挂图片和视频两个任务")
        XCTAssertTrue(s.isGenerating)
    }

    // TaskLocal 是进度回调定位消息的依据，得能沿 async 调用链传下去
    func testTaskContextPropagatesAcrossAwait() async {
        let id = UUID()
        var seen: UUID?
        await AIVideoService.Context.$taskID.withValue(id) {
            await Task.yield()
            seen = await deepCall()
        }
        XCTAssertEqual(seen, id, "任务 id 要能穿过 await 传到嵌套调用里，否则进度会写错消息")
        XCTAssertNil(AIVideoService.Context.taskID, "出了作用域该恢复成 nil")
    }

    private func deepCall() async -> UUID? {
        await Task.yield()
        return AIVideoService.Context.taskID
    }
}
