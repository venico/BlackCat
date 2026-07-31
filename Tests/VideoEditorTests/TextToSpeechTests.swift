import XCTest
import Foundation
import AVFoundation
import CoreMedia
@testable import VideoEditorLib

// MARK: - 字幕转语音
//
// 不打 TTS 接口（要 API Key、要网络、要花钱），只验证选取和摆放这两段本地逻辑。

@MainActor
final class TextToSpeechTests: XCTestCase {

    private func makeProject(tracks: [[SubtitleClip]]) -> ProjectState {
        let p = ProjectState()
        for clips in tracks {
            p.subtitleTracks.append(Track(clips: clips, label: "字幕"))
        }
        p.syncOverlayOrder()
        return p
    }

    private func sub(_ text: String, _ start: Double, _ end: Double) -> SubtitleClip {
        SubtitleClip(text: text, startTime: start, endTime: end)
    }

    /// 跨轨道选取：翻译那条链路只认单条源轨，这里必须把两条轨的选中项都收上来
    func testCollectsAcrossSubtitleTracks() {
        let a1 = sub("第一句", 0, 2)
        let a2 = sub("第二句", 5, 7)
        let b1 = sub("另一轨", 2, 4)
        let p = makeProject(tracks: [[a1, a2], [b1]])

        p.selectedClipIDs = [a1.id, b1.id]
        let picked = p.selectedSubtitleClipsForTTS

        XCTAssertEqual(picked.count, 2, "两条轨道的选中项都要收上来")
        XCTAssertEqual(picked.map(\.text), ["第一句", "另一轨"], "应按时间轴先后排序")
        XCTAssertFalse(picked.contains { $0.id == a2.id }, "没选中的不该混进来")
    }

    /// 空白字幕送去 TTS 只会白花钱，选取阶段就该滤掉
    func testSkipsEmptySubtitles() {
        let a = sub("有内容", 0, 2)
        let b = sub("   \n  ", 2, 4)
        let p = makeProject(tracks: [[a, b]])

        p.selectedClipIDs = [a.id, b.id]
        XCTAssertEqual(p.selectedSubtitleClipsForTTS.map(\.text), ["有内容"])
    }

    /// 单选（selectedSubtitleClipID）和多选集合要合并，右键单个片段时也得能用
    func testMergesSingleSelection() {
        let a = sub("单选的", 0, 2)
        let p = makeProject(tracks: [[a]])

        p.selectedSubtitleClipID = a.id
        XCTAssertEqual(p.selectedSubtitleClipsForTTS.count, 1)
        XCTAssertTrue(p.canConvertSubtitleToSpeech)
    }

    /// 没选中任何字幕时菜单该是灰的
    func testDisabledWithoutSelection() {
        let p = makeProject(tracks: [[sub("没选中", 0, 2)]])
        XCTAssertTrue(p.selectedSubtitleClipsForTTS.isEmpty)
        XCTAssertFalse(p.canConvertSubtitleToSpeech)
    }

    /// 生成中不允许再次触发，否则会重复扣费
    func testDisabledWhileGenerating() {
        let a = sub("生成中", 0, 2)
        let p = makeProject(tracks: [[a]])
        p.selectedSubtitleClipID = a.id
        XCTAssertTrue(p.canConvertSubtitleToSpeech)

        p.speechTotal = 3
        XCTAssertTrue(p.isGeneratingSpeech)
        XCTAssertFalse(p.canConvertSubtitleToSpeech, "生成中应禁用")
    }

    /// 取消要清空进度并给提示
    func testCancelResetsProgress() {
        let p = ProjectState()
        p.speechTotal = 5
        p.speechDone = 2
        p.cancelSpeechGeneration()

        XCTAssertFalse(p.isGeneratingSpeech)
        XCTAssertEqual(p.speechTotal, 0)
        XCTAssertEqual(p.speechDone, 0)
        XCTAssertEqual(p.successToasts.last?.subtitle, "已停止")
    }

    /// 没填 API Key 就点，要给明确提示而不是静默失败
    func testMissingAPIKeyReportsClearly() {
        let a = sub("要配音", 0, 2)
        let p = makeProject(tracks: [[a]])
        p.selectedSubtitleClipID = a.id

        let provider = AppSettings.shared.ttsProvider
        let savedKey = AppSettings.shared.providerAPIKey(for: provider.rawValue)
        AppSettings.shared.setProviderAPIKey("", for: provider.rawValue)
        defer { AppSettings.shared.setProviderAPIKey(savedKey, for: provider.rawValue) }

        p.convertSelectedSubtitlesToSpeech()

        XCTAssertFalse(p.isGeneratingSpeech, "缺 Key 时不该真的开跑")
        let toast = p.successToasts.last
        XCTAssertEqual(toast?.title, "转换成语音")
        XCTAssertTrue(toast?.subtitle.contains("API Key") == true,
                      "应提示去填 Key，实际 \(toast?.subtitle ?? "nil")")
    }

    /// 造一个真实可读的短音频文件，用来量批量插入的开销
    private nonisolated func makeSilentAudio(seconds: Double = 0.4) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tts_\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1
        ]
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let sampleRate = 44100.0
        let total = Int(sampleRate * seconds)
        var fmt = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &fmt,
                                       layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil,
                                       formatDescriptionOut: &format)
        var block: CMBlockBuffer?
        let bytes = total * 2
        CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                           blockLength: bytes, blockAllocator: kCFAllocatorDefault,
                                           customBlockSource: nil, offsetToData: 0,
                                           dataLength: bytes, flags: 0, blockBufferOut: &block)
        if let block { CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 44100),
                                        presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        if let block, let format {
            CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
                                      formatDescription: format, sampleCount: total,
                                      sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                      sampleSizeEntryCount: 0, sampleSizeArray: nil,
                                      sampleBufferOut: &sample)
        }
        if let sample { input.append(sample) }
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        return url
    }

    /// 批量插入不能把主线程堵死 —— 之前逐条 importFileDirectly，
    /// 每条改两个 @Published，界面会整个转圈没响应
    func testBatchInsertDoesNotBlockMainThread() async throws {
        let count = 24
        var urls: [URL] = []
        for _ in 0..<count { urls.append(try makeSilentAudio()) }
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }

        let p = ProjectState()
        var clips: [SubtitleClip] = []
        for i in 0..<count {
            clips.append(sub("第\(i)句", Double(i) * 3, Double(i) * 3 + 2))
        }
        p.subtitleTracks.append(Track(clips: clips, label: "字幕"))

        // 主线程上挂个心跳，被堵住时相邻两拍的间隔会明显拉大
        var gaps: [TimeInterval] = []
        var last = Date()
        let ticker = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
            let now = Date()
            gaps.append(now.timeIntervalSince(last))
            last = now
        }
        RunLoop.current.add(ticker, forMode: .common)
        defer { ticker.invalidate() }

        let items = zip(clips, urls).map { (clip: $0, url: $1) }
        let t0 = Date()
        _ = await p.testHook_addSpeechClips(items)
        let elapsed = Date().timeIntervalSince(t0)

        XCTAssertEqual(p.mediaAssets.count, count, "素材应全部导入")
        XCTAssertEqual(p.audioTracks.flatMap(\.clips).count, count, "片段应全部落轨")

        let worst = gaps.max() ?? 0
        print(String(format: "插入 %d 条耗时 %.2fs，主线程最长停顿 %.2fs", count, elapsed, worst))
        XCTAssertLessThan(worst, 1.5, "主线程停顿过久（\(worst)s），界面会转圈")
    }

    /// 超长的要被压到字幕时长，压得动的听起来还得是完整一句
    func testAutoFitCompressesOverlongAudio() async throws {
        try XCTSkipUnless(ProjectState.findFFmpeg() != nil, "没有 ffmpeg，跳过")

        // 音频 1.2s，字幕只有 1.0s → 需要 1.2 倍压缩，在上限内
        let url = try makeSilentAudio(seconds: 1.2)
        defer { try? FileManager.default.removeItem(at: url) }

        let saved = AppSettings.shared.ttsAutoFit
        AppSettings.shared.ttsAutoFit = true
        defer { AppSettings.shared.ttsAutoFit = saved }

        let p = ProjectState()
        let clip = sub("要压缩", 0, 1.0)
        p.subtitleTracks.append(Track(clips: [clip], label: "字幕"))

        let overlong = await p.testHook_addSpeechClips([(clip: clip, url: url)])

        XCTAssertEqual(overlong, 0, "1.2 倍在上限内，应该压得动")
        let placed = try XCTUnwrap(p.audioTracks.flatMap(\.clips).first)
        XCTAssertEqual(placed.duration, 1.0, accuracy: 0.06, "应被压到字幕时长")
        XCTAssertEqual(placed.startTime, 0, accuracy: 0.001, "起点仍对齐字幕")
        // 压完的是新文件，原始文件不该被改动
        XCTAssertNotEqual(placed.url, url, "应指向变速后的新文件")
    }

    /// 压过头会听不清，超上限的保持原速并如实计数
    func testAutoFitSkipsExtremeRatio() async throws {
        try XCTSkipUnless(ProjectState.findFFmpeg() != nil, "没有 ffmpeg，跳过")

        // 音频 2.0s，字幕 0.5s → 需要 4 倍，远超 1.6 上限
        let url = try makeSilentAudio(seconds: 2.0)
        defer { try? FileManager.default.removeItem(at: url) }

        let saved = AppSettings.shared.ttsAutoFit
        AppSettings.shared.ttsAutoFit = true
        defer { AppSettings.shared.ttsAutoFit = saved }

        let p = ProjectState()
        let clip = sub("压不动", 0, 0.5)
        p.subtitleTracks.append(Track(clips: [clip], label: "字幕"))

        let overlong = await p.testHook_addSpeechClips([(clip: clip, url: url)])

        XCTAssertEqual(overlong, 1, "超上限的应计入超长，提示用户")
        let placed = try XCTUnwrap(p.audioTracks.flatMap(\.clips).first)
        XCTAssertEqual(placed.url, url, "不该变速，仍用原文件")
        XCTAssertGreaterThan(placed.duration, 1.5, "保持原时长")
    }

    /// 关掉自动对齐就一律按原时长摆
    func testAutoFitDisabledKeepsOriginal() async throws {
        let url = try makeSilentAudio(seconds: 1.2)
        defer { try? FileManager.default.removeItem(at: url) }

        let saved = AppSettings.shared.ttsAutoFit
        AppSettings.shared.ttsAutoFit = false
        defer { AppSettings.shared.ttsAutoFit = saved }

        let p = ProjectState()
        let clip = sub("不对齐", 0, 1.0)
        p.subtitleTracks.append(Track(clips: [clip], label: "字幕"))

        let overlong = await p.testHook_addSpeechClips([(clip: clip, url: url)])

        XCTAssertEqual(overlong, 1, "关掉对齐后超长应照实计数")
        let placed = try XCTUnwrap(p.audioTracks.flatMap(\.clips).first)
        XCTAssertEqual(placed.url, url, "不该产生变速文件")
        XCTAssertEqual(placed.duration, 1.2, accuracy: 0.1)
    }

    /// 语速设置要落在各家接口的合法区间内
    func testTTSSpeedRange() {
        let saved = AppSettings.shared.ttsSpeed
        defer { AppSettings.shared.ttsSpeed = saved }

        AppSettings.shared.ttsSpeed = 1.25
        XCTAssertEqual(AppSettings.shared.ttsSpeed, 1.25, accuracy: 0.001)
        // Fish Audio 只认 0.5~2.0，是三家里最窄的，设置面板的范围不能超出它
        XCTAssertGreaterThanOrEqual(AppSettings.shared.ttsSpeed, 0.5)
        XCTAssertLessThanOrEqual(AppSettings.shared.ttsSpeed, 2.0)
    }

    /// TTS 模型只能在音频类里选，默认值也必须是音频类
    func testTTSProviderIsAudioOnly() {
        XCTAssertFalse(AppSettings.ttsProviders.isEmpty)
        for p in AppSettings.ttsProviders {
            XCTAssertEqual(p.category, .audio, "\(p.displayName) 不是音频模型，不该出现在语音合成列表里")
        }
        XCTAssertEqual(AppSettings.shared.ttsProvider.category, .audio, "当前选中的必须是音频模型")
    }
}
