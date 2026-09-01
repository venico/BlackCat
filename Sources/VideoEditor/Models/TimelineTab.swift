// TimelineTab.swift
//
// 一个标签页 = 一整套轨道。
//
// 轨道数据原先直接长在 ProjectState 上，现在整组搬进这里，ProjectState 那边
// 留同名的计算属性代理到当前标签页 —— 这样几千处 `project.videoTracks` 之类的
// 调用一行都不用改，多时间线是"底下换了个容器"，上层无感。
//
// 素材库**不在**标签页里：它是全项目共享的，所以删素材会同时影响所有标签页
// 引用它的片段，这是设计如此。

import Foundation

struct TimelineTab: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String = "时间线"

    // 六种类型各留一条空轨。空标签页就能看到完整的轨道结构，
    // 第一个素材直接落在对应的空轨上，不用先凭空多出一条轨道来
    var videoTracks: [Track<VideoClip>]       = [Track(label: "视频")]
    var audioTracks: [Track<AudioClip>]       = [Track(label: "音频")]
    var imageTracks: [Track<ImageClip>]       = [Track(label: "图片")]
    var subtitleTracks: [Track<SubtitleClip>] = [ProjectState.makeEmptySubtitleTrack()]
    var textTracks: [Track<TextClip>]         = [Track(label: "文字")]
    var shapeTracks: [Track<ShapeClip>]       = [Track(label: "图形")]
    /// 滤镜轨道。多条 = 叠加，从下往上依次套
    var filterTracks: [Track<FilterClip>]     = []
    var adjustTracks: [Track<AdjustClip>]     = []
    var effectTracks: [Track<EffectClip>]     = []
    var compoundTracks: [Track<CompoundClip>] = []

    /// 标签栏上显不显示它。
    /// **关闭标签页 ≠ 删除时间线** —— 关掉只是把标签收起来，
    /// 数据还在，从「更多 → 显示所有标签页」能再拿回来
    var isTabOpen: Bool = true

    var overlayTrackOrder: [ProjectState.OverlayTrackRef] = []
    var videoSectionOrder: [ProjectState.VideoSectionRef] = []
    var audioSectionOrder: [ProjectState.AudioSectionRef] = []

    enum CodingKeys: String, CodingKey {
        case id, name, videoTracks, audioTracks, imageTracks, subtitleTracks
        case textTracks, shapeTracks, filterTracks, adjustTracks, effectTracks
        case compoundTracks, overlayTrackOrder, videoSectionOrder, audioSectionOrder
        case isTabOpen
    }

    init(name: String = "时间线") { self.name = name }

    /// 老项目文件里没有标签页这一层，缺什么补什么
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? "时间线"
        videoTracks = (try? c.decode([Track<VideoClip>].self, forKey: .videoTracks)) ?? [Track(label: "视频")]
        audioTracks = (try? c.decode([Track<AudioClip>].self, forKey: .audioTracks)) ?? [Track(label: "音频")]
        imageTracks = (try? c.decode([Track<ImageClip>].self, forKey: .imageTracks)) ?? [Track(label: "图片")]
        subtitleTracks = (try? c.decode([Track<SubtitleClip>].self, forKey: .subtitleTracks))
            ?? [ProjectState.makeEmptySubtitleTrack()]
        textTracks = (try? c.decode([Track<TextClip>].self, forKey: .textTracks)) ?? [Track(label: "文字")]
        shapeTracks = (try? c.decode([Track<ShapeClip>].self, forKey: .shapeTracks)) ?? [Track(label: "图形")]
        filterTracks = (try? c.decode([Track<FilterClip>].self, forKey: .filterTracks)) ?? []
        adjustTracks = (try? c.decode([Track<AdjustClip>].self, forKey: .adjustTracks)) ?? []
        effectTracks = (try? c.decode([Track<EffectClip>].self, forKey: .effectTracks)) ?? []
        compoundTracks = (try? c.decode([Track<CompoundClip>].self, forKey: .compoundTracks)) ?? []
        isTabOpen = (try? c.decode(Bool.self, forKey: .isTabOpen)) ?? true
        overlayTrackOrder = (try? c.decode([ProjectState.OverlayTrackRef].self, forKey: .overlayTrackOrder)) ?? []
        videoSectionOrder = (try? c.decode([ProjectState.VideoSectionRef].self, forKey: .videoSectionOrder)) ?? []
        audioSectionOrder = (try? c.decode([ProjectState.AudioSectionRef].self, forKey: .audioSectionOrder)) ?? []
    }
}
