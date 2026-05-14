import SwiftUI
import AVFoundation
import MediaToolbox
import Accelerate

// MARK: - Asset Type

enum AssetType {
    case video, audio, subtitle, image
    var label: String {
        switch self { case .video: return "视频"; case .audio: return "音频"; case .subtitle: return "字幕"; case .image: return "图片" }
    }
    var icon: String {
        switch self { case .video: return "film"; case .audio: return "music.note"; case .subtitle: return "captions.bubble"; case .image: return "photo" }
    }
    var color: Color {
        switch self { case .video: return Color(hex:"#3DBFBA"); case .audio: return Color(hex:"#5DB85D"); case .subtitle: return Color(hex:"#8B7ED8"); case .image: return Color(hex:"#E8A54B") }
    }
}

// MARK: - Media Asset

struct MediaAsset: Identifiable, Equatable {
    let id = UUID()
    var url: URL
    var name: String
    var type: AssetType
    var duration: Double = 0
    var fileExists: Bool { FileManager.default.fileExists(atPath: url.path) }
    static func == (lhs: MediaAsset, rhs: MediaAsset) -> Bool { lhs.id == rhs.id }
}

// MARK: - Subtitle Style

struct SubtitleStyle: Equatable {
    var fontName: String  = "PingFang SC"
    var fontSize: CGFloat = 23
    var bold: Bool        = false
    var italic: Bool      = false
    var textColor: Color      = .white
    var backgroundColor: Color = .black
    var backgroundOpacity: Double = 0.7
    var bottomMargin: Double  = 5      // % from bottom edge
    var widthPercent: Double  = 95
    var alignment: String     = "center" // "left" / "center" / "right"
    var lineSpacing: Double   = 6      // px between bilingual lines
}

// MARK: - Clips

struct SubtitleClip: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var startTime: Double
    var endTime: Double
    var duration: Double { endTime - startTime }
}

struct VideoClip: Identifiable, Equatable {
    let id = UUID()
    var assetID: UUID
    var name: String   = ""
    var url: URL?      = nil
    var startTime: Double
    var endTime: Double
    var trimStart: Double = 0  // source in-point (seconds into the source file)
    var duration: Double { endTime - startTime }
    // Export overrides (0 = use original)
    var overrideResolution: String = "原始分辨率"
    var overrideFPS: Int           = 0
    var overrideBitrate: Int       = 0   // kbps
    var volume: Float              = 1.0
}

struct AudioClip: Identifiable, Equatable {
    let id = UUID()
    var assetID: UUID
    var name: String   = ""
    var url: URL?      = nil
    var startTime: Double
    var endTime: Double
    var trimStart: Double = 0  // source in-point (seconds into the source file)
    var duration: Double { endTime - startTime }
    var volume: Float  = 1.0
    var leftChannel: Float  = 1.0
    var rightChannel: Float = 1.0
    var sampleRate: Int = 44100
    var format: String = "AAC"
}

struct ImageClip: Identifiable, Equatable {
    let id = UUID()
    var assetID: UUID
    var name: String   = ""
    var imageURL: URL?  = nil   // original image
    var videoURL: URL?  = nil   // generated video for preview/export
    var startTime: Double
    var endTime: Double
    var duration: Double { endTime - startTime }
    var imageWidth: Int  = 0
    var imageHeight: Int = 0
    var scaleX: Double   = 1.0
    var scaleY: Double   = 1.0
    var lockAspect: Bool = true
}

struct Track<Clip: Identifiable & Equatable>: Identifiable {
    let id = UUID()
    var clips: [Clip]   = []
    var label: String   = ""
    var isMuted: Bool   = false
    var isVisible: Bool = true
}

// MARK: - Export Settings

enum ExportContent: String, CaseIterable {
    case video        // full video + audio + burned-in subtitles
    case audioOnly    // export audio track only (m4a)
    case subtitleOnly // export subtitles as SRT
}

struct ExportSettings {
    var outputPath: URL?         = nil
    var filename: String         = ""
    var resolution: String       = "1080p  1920×1080"
    var fps: Int                 = 30
    var bitrate: Int             = 8000   // kbps
    var content: ExportContent   = .video
    static let resolutions = ["原始分辨率","4K  3840×2160","1080p  1920×1080","720p  1280×720","480p  854×480"]
    static let fpsOptions  = [24, 25, 30, 60]
}

// MARK: - Thumbnail & Waveform

struct ThumbnailFrame {
    let time: Double
    let image: NSImage
}

struct WaveformData {
    let totalDuration: Double
    let samples: [Float]  // normalized 0..1 peak values
}

// MARK: - Snapshot (for undo/redo)

struct ProjectSnapshot {
    var videoTracks: [Track<VideoClip>]
    var audioTracks: [Track<AudioClip>]
    var imageTracks: [Track<ImageClip>]
    var subtitleTracks: [Track<SubtitleClip>]
    var subtitleStyles: [SubtitleStyle]
}

// MARK: - Project State

final class ProjectState: ObservableObject {
    // Media
    @Published var mediaAssets: [MediaAsset] = []

    // Tracks
    @Published var videoTracks: [Track<VideoClip>]    = [Track(label: "视频")]
    @Published var audioTracks: [Track<AudioClip>]    = []
    @Published var imageTracks: [Track<ImageClip>]       = []
    @Published var subtitleTracks: [Track<SubtitleClip>] = [Track(label: "字幕")]
    @Published var subtitleStyles: [SubtitleStyle]    = [SubtitleStyle(), SubtitleStyle()]

    // Playback
    @Published var currentTime: Double  = 0
    @Published var duration: Double     = 60
    @Published var isPlaying: Bool      = false
    @Published var playerItem: AVPlayerItem? = nil
    var pendingSeekTime: Double? = nil
    /// End time of the last video clip on the timeline — used to black out
    /// the preview when the playhead is past all clip content.
    @Published var lastVideoEndTime: Double = 0
    /// Bumped whenever the user drags the playhead/ruler — PlayerView
    /// observes this and tells AVPlayer to seek to `currentTime`. The
    /// periodic time observer doesn't bump it (so playback doesn't loop).
    @Published var seekRequest: Int     = 0

    // Timeline
    @Published var pixelsPerSecond: Double = 30

    // Selection (single — used by Inspector)
    @Published var selectedVideoClipID: UUID?    = nil
    @Published var selectedAudioClipID: UUID?    = nil
    @Published var selectedImageClipID: UUID?    = nil
    @Published var selectedSubtitleClipID: UUID? = nil
    // Multi-selection (used by box-select & bulk delete)
    @Published var selectedClipIDs: Set<UUID>    = []

    // Clipboard for copy/cut/paste
    enum ClipboardItem {
        case video(VideoClip, trackIndex: Int)
        case audio(AudioClip, trackIndex: Int)
        case image(ImageClip, trackIndex: Int)
        case subtitle(SubtitleClip, trackIndex: Int)
    }
    var clipboard: ClipboardItem?
    @Published var clipboardIsCut: Bool = false
    @Published var clipboardSourceID: UUID?

    // Export
    @Published var exportSettings  = ExportSettings()
    @Published var showExportSheet = false

    // Undo / Redo
    @Published var undoCount: Int = 0
    @Published var redoCount: Int = 0
    private var undoStack: [ProjectSnapshot] = []
    private var redoStack: [ProjectSnapshot] = []

    // Thumbnail & Waveform cache
    @Published var mediaThumbnails: [UUID: NSImage] = [:]          // asset ID → single thumbnail (media library)
    @Published var assetThumbnails: [UUID: [ThumbnailFrame]] = [:] // asset ID → timeline thumbnail strip
    @Published var waveformCache: [UUID: WaveformData] = [:]       // asset ID → waveform peaks
    var imageVideoCache: [UUID: URL] = [:]                         // asset ID → generated video file

    // Translation
    @Published var translationTargetLang: String = "中文（简体）"
    static let supportedLanguages = [
        "中文（简体）","中文（繁体）","English","日本語",
        "한국어","Français","Deutsch","Español",
        "Русский","العربية","Português","Italiano"
    ]

    // MARK: - Helpers

    var selectedSubtitleClip: SubtitleClip? {
        guard let id = selectedSubtitleClipID else { return nil }
        for t in subtitleTracks { if let c = t.clips.first(where:{ $0.id == id }) { return c } }
        return nil
    }

    var selectedVideoClip: VideoClip? {
        guard let id = selectedVideoClipID else { return nil }
        for t in videoTracks { if let c = t.clips.first(where:{ $0.id == id }) { return c } }
        return nil
    }

    var selectedImageClip: ImageClip? {
        guard let id = selectedImageClipID else { return nil }
        for t in imageTracks { if let c = t.clips.first(where:{ $0.id == id }) { return c } }
        return nil
    }

    var selectedAudioClip: AudioClip? {
        guard let id = selectedAudioClipID else { return nil }
        for t in audioTracks { if let c = t.clips.first(where:{ $0.id == id }) { return c } }
        return nil
    }

    // MARK: - Thumbnail & Waveform Generation

    /// Generate a single thumbnail for the media library (video assets only).
    func loadMediaThumbnail(assetID: UUID, url: URL) {
        guard mediaThumbnails[assetID] == nil else { return }
        let id = assetID
        Task {
            let av = AVURLAsset(url: url)
            let gen = AVAssetImageGenerator(asset: av)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 200, height: 200)
            if let cg = try? gen.copyCGImage(at: .zero, actualTime: nil) {
                let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                await MainActor.run { self.mediaThumbnails[id] = img }
            }
        }
    }

    /// Generate timeline thumbnail strip for a video asset (evenly spaced frames).
    func loadTimelineThumbnails(assetID: UUID, url: URL) {
        guard assetThumbnails[assetID] == nil else { return }
        let id = assetID
        Task {
            let av = AVURLAsset(url: url)
            let dur = (try? await av.load(.duration))?.seconds ?? 0
            guard dur > 0.1 else { return }
            let gen = AVAssetImageGenerator(asset: av)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 80, height: 52)
            gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
            gen.requestedTimeToleranceAfter  = CMTime(seconds: 0.5, preferredTimescale: 600)

            let interval = max(1.0, dur / 30.0)  // at most ~30 frames
            var frames: [ThumbnailFrame] = []
            var t = 0.0
            while t < dur {
                let time = CMTime(seconds: t, preferredTimescale: 600)
                if let cg = try? gen.copyCGImage(at: time, actualTime: nil) {
                    let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                    frames.append(ThumbnailFrame(time: t, image: img))
                }
                t += interval
            }
            await MainActor.run { self.assetThumbnails[id] = frames }
        }
    }

    /// Generate waveform peak data for an audio asset.
    func loadWaveform(assetID: UUID, url: URL) {
        guard waveformCache[assetID] == nil else { return }
        let id = assetID
        Task {
            let av = AVURLAsset(url: url)
            let dur = (try? await av.load(.duration))?.seconds ?? 0
            guard dur > 0 else { return }
            guard let track = try? await av.loadTracks(withMediaType: .audio).first else { return }
            guard let reader = try? AVAssetReader(asset: av) else { return }
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            reader.add(output)
            reader.startReading()

            var allPeaks: [Float] = []
            var buf16: [Int16] = []
            let chunkTarget = 2000  // samples per peak

            while let sampleBuf = output.copyNextSampleBuffer() {
                guard let blockBuf = CMSampleBufferGetDataBuffer(sampleBuf) else { continue }
                var length = 0
                var dataPtr: UnsafeMutablePointer<Int8>?
                CMBlockBufferGetDataPointer(blockBuf, atOffset: 0, lengthAtOffsetOut: nil,
                                            totalLengthOut: &length, dataPointerOut: &dataPtr)
                guard let ptr = dataPtr else { continue }
                let count = length / MemoryLayout<Int16>.size
                let samples = UnsafeBufferPointer(
                    start: UnsafeRawPointer(ptr).bindMemory(to: Int16.self, capacity: count), count: count)
                buf16.append(contentsOf: samples)

                while buf16.count >= chunkTarget {
                    let chunk = Array(buf16.prefix(chunkTarget))
                    buf16.removeFirst(chunkTarget)
                    let peak = chunk.map { abs(Float($0)) }.max() ?? 0
                    allPeaks.append(peak / Float(Int16.max))
                }
            }
            if !buf16.isEmpty {
                let peak = buf16.map { abs(Float($0)) }.max() ?? 0
                allPeaks.append(peak / Float(Int16.max))
            }

            await MainActor.run {
                self.waveformCache[id] = WaveformData(totalDuration: dur, samples: allPeaks)
            }
        }
    }

    /// Load an image file as thumbnail for the media library.
    func loadImageThumbnail(assetID: UUID, url: URL) {
        guard mediaThumbnails[assetID] == nil else { return }
        if let img = NSImage(contentsOf: url) {
            mediaThumbnails[assetID] = img
        }
    }

    // MARK: - Relink missing asset

    /// Update all timeline clips that reference a given asset to use a new URL.
    func relinkAsset(id: UUID, newURL: URL) {
        for ti in videoTracks.indices {
            for ci in videoTracks[ti].clips.indices where videoTracks[ti].clips[ci].assetID == id {
                videoTracks[ti].clips[ci].url = newURL
            }
        }
        for ti in audioTracks.indices {
            for ci in audioTracks[ti].clips.indices where audioTracks[ti].clips[ci].assetID == id {
                audioTracks[ti].clips[ci].url = newURL
            }
        }
        rebuildTimelinePreview()
    }

    // MARK: - Cross-track move

    func moveVideoClipToTrack(id: UUID, from: Int, to: Int) {
        guard videoTracks.indices.contains(from), videoTracks.indices.contains(to) else { return }
        guard let idx = videoTracks[from].clips.firstIndex(where: { $0.id == id }) else { return }
        let clip = videoTracks[from].clips.remove(at: idx)
        videoTracks[to].clips.append(clip)
    }

    func moveImageClipToTrack(id: UUID, from: Int, to: Int) {
        guard imageTracks.indices.contains(from), imageTracks.indices.contains(to) else { return }
        guard let idx = imageTracks[from].clips.firstIndex(where: { $0.id == id }) else { return }
        let clip = imageTracks[from].clips.remove(at: idx)
        imageTracks[to].clips.append(clip)
    }

    func moveAudioClipToTrack(id: UUID, from: Int, to: Int) {
        guard audioTracks.indices.contains(from), audioTracks.indices.contains(to) else { return }
        guard let idx = audioTracks[from].clips.firstIndex(where: { $0.id == id }) else { return }
        let clip = audioTracks[from].clips.remove(at: idx)
        audioTracks[to].clips.append(clip)
    }

    func moveSubtitleClipToTrack(id: UUID, from: Int, to: Int) {
        guard subtitleTracks.indices.contains(from), subtitleTracks.indices.contains(to) else { return }
        guard let idx = subtitleTracks[from].clips.firstIndex(where: { $0.id == id }) else { return }
        let clip = subtitleTracks[from].clips.remove(at: idx)
        subtitleTracks[to].clips.append(clip)
    }

    // MARK: - Multi-select helpers

    /// Shift+click: toggle a clip in/out of multi-selection
    func shiftToggleClip(_ id: UUID) {
        if selectedClipIDs.contains(id) {
            selectedClipIDs.remove(id)
            // Also clear primary if it matches
            if selectedVideoClipID == id    { selectedVideoClipID = nil }
            if selectedImageClipID == id    { selectedImageClipID = nil }
            if selectedAudioClipID == id    { selectedAudioClipID = nil }
            if selectedSubtitleClipID == id { selectedSubtitleClipID = nil }
        } else {
            // Move current primary into multi-set if needed
            if let pid = selectedVideoClipID, pid != id { selectedClipIDs.insert(pid) }
            if let pid = selectedImageClipID, pid != id { selectedClipIDs.insert(pid) }
            if let pid = selectedAudioClipID, pid != id { selectedClipIDs.insert(pid) }
            if let pid = selectedSubtitleClipID, pid != id { selectedClipIDs.insert(pid) }
            selectedClipIDs.insert(id)
            // Set as new primary based on type
            if videoTracks.flatMap(\.clips).contains(where: { $0.id == id }) {
                selectedVideoClipID = id
                selectedImageClipID = nil; selectedAudioClipID = nil; selectedSubtitleClipID = nil
            } else if imageTracks.flatMap(\.clips).contains(where: { $0.id == id }) {
                selectedImageClipID = id
                selectedVideoClipID = nil; selectedAudioClipID = nil; selectedSubtitleClipID = nil
            } else if audioTracks.flatMap(\.clips).contains(where: { $0.id == id }) {
                selectedAudioClipID = id
                selectedVideoClipID = nil; selectedImageClipID = nil; selectedSubtitleClipID = nil
            } else if subtitleTracks.flatMap(\.clips).contains(where: { $0.id == id }) {
                selectedSubtitleClipID = id
                selectedVideoClipID = nil; selectedImageClipID = nil; selectedAudioClipID = nil
            }
        }
    }

    /// 向左全选：选中同轨道中 startTime <= 当前片段的所有片段
    func selectLeftOf(_ id: UUID) {
        for track in videoTracks {
            if let clip = track.clips.first(where: { $0.id == id }) {
                selectedClipIDs.formUnion(track.clips.filter { $0.startTime <= clip.startTime }.map(\.id)); return
            }
        }
        for track in imageTracks {
            if let clip = track.clips.first(where: { $0.id == id }) {
                selectedClipIDs.formUnion(track.clips.filter { $0.startTime <= clip.startTime }.map(\.id)); return
            }
        }
        for track in audioTracks {
            if let clip = track.clips.first(where: { $0.id == id }) {
                selectedClipIDs.formUnion(track.clips.filter { $0.startTime <= clip.startTime }.map(\.id)); return
            }
        }
        for track in subtitleTracks {
            if let clip = track.clips.first(where: { $0.id == id }) {
                selectedClipIDs.formUnion(track.clips.filter { $0.startTime <= clip.startTime }.map(\.id)); return
            }
        }
    }

    /// 向右全选：选中同轨道中 startTime >= 当前片段的所有片段
    func selectRightOf(_ id: UUID) {
        for track in videoTracks {
            if let clip = track.clips.first(where: { $0.id == id }) {
                selectedClipIDs.formUnion(track.clips.filter { $0.startTime >= clip.startTime }.map(\.id)); return
            }
        }
        for track in imageTracks {
            if let clip = track.clips.first(where: { $0.id == id }) {
                selectedClipIDs.formUnion(track.clips.filter { $0.startTime >= clip.startTime }.map(\.id)); return
            }
        }
        for track in audioTracks {
            if let clip = track.clips.first(where: { $0.id == id }) {
                selectedClipIDs.formUnion(track.clips.filter { $0.startTime >= clip.startTime }.map(\.id)); return
            }
        }
        for track in subtitleTracks {
            if let clip = track.clips.first(where: { $0.id == id }) {
                selectedClipIDs.formUnion(track.clips.filter { $0.startTime >= clip.startTime }.map(\.id)); return
            }
        }
    }

    // MARK: - Preview

    /// Build a full timeline composition from all clips and load it as the
    /// playerItem. If `seekTo` is given, also seeks to that time after load.
    /// Gaps between clips are rendered black by AVPlayer automatically.
    func rebuildTimelinePreview(seekTo: Double? = nil) {
        // Snapshot the clip arrays so the async task captures stable values.
        let vTracks = videoTracks
        let iTracks = imageTracks
        let aTracks = audioTracks
        let sTracks = subtitleTracks
        // 默认保留当前播放位置
        let restoreTime = seekTo ?? currentTime
        // endTime 取所有轨道（不管可见性），保证播放头范围正确
        let vEnd = vTracks.flatMap(\.clips).map(\.endTime).max() ?? 0
        let iEnd = iTracks.flatMap(\.clips).map(\.endTime).max() ?? 0
        let aEnd = aTracks.flatMap(\.clips).map(\.endTime).max() ?? 0
        let sEnd = sTracks.flatMap(\.clips).map(\.endTime).max() ?? 0
        let endTime = max(vEnd, max(iEnd, max(aEnd, sEnd)))
        Task {
            let composition = AVMutableComposition()
            var audioParams: [(trackID: CMPersistentTrackID, volume: Float, left: Float, right: Float)] = []
            var videoCompTracks: [AVMutableCompositionTrack] = []  // from video clips
            var imageCompTracks: [(track: AVMutableCompositionTrack, clip: ImageClip)] = []  // from image clips (on top)
            var renderSize = CGSize(width: 1920, height: 1080)

            // 视频轨道
            for track in vTracks {
                for clip in track.clips.sorted(by: { $0.startTime < $1.startTime }) {
                    guard let url = clip.url else { continue }
                    let asset = AVURLAsset(url: url)
                    let assetDur = (try? await asset.load(.duration)) ?? .zero
                    let trimSt  = CMTime(seconds: clip.trimStart, preferredTimescale: 600)
                    let maxDur  = assetDur - trimSt
                    let useDur  = CMTimeMinimum(CMTime(seconds: clip.duration, preferredTimescale: 600), maxDur)
                    guard useDur.seconds > 0.01 else { continue }
                    let range = CMTimeRange(start: trimSt, duration: useDur)
                    let at    = CMTime(seconds: clip.startTime, preferredTimescale: 600)

                    if track.isVisible,
                       let vAsset = try? await asset.loadTracks(withMediaType: .video).first,
                       let vt = composition.addMutableTrack(withMediaType: .video,
                                                            preferredTrackID: kCMPersistentTrackID_Invalid) {
                        try? vt.insertTimeRange(range, of: vAsset, at: at)
                        videoCompTracks.append(vt)
                        // Detect render size from first video
                        if let natSize = try? await vAsset.load(.naturalSize) {
                            if natSize.width > 0 && natSize.height > 0 {
                                renderSize = natSize
                            }
                        }
                    }
                    if !track.isMuted,
                       let aAsset = try? await asset.loadTracks(withMediaType: .audio).first,
                       let at2 = composition.addMutableTrack(withMediaType: .audio,
                                                             preferredTrackID: kCMPersistentTrackID_Invalid) {
                        try? at2.insertTimeRange(range, of: aAsset, at: at)
                        audioParams.append((at2.trackID, clip.volume, 1.0, 1.0))
                    }
                }
            }

            // 图片轨道（上层）
            for track in iTracks {
                guard track.isVisible else { continue }
                for clip in track.clips {
                    guard let url = clip.videoURL else { continue }
                    let asset = AVURLAsset(url: url)
                    let assetDur = (try? await asset.load(.duration)) ?? .zero
                    let useDur = CMTimeMinimum(CMTime(seconds: clip.duration, preferredTimescale: 600), assetDur)
                    guard useDur.seconds > 0.01 else { continue }
                    let range = CMTimeRange(start: .zero, duration: useDur)
                    let at = CMTime(seconds: clip.startTime, preferredTimescale: 600)
                    if let vAsset = try? await asset.loadTracks(withMediaType: .video).first,
                       let vt = composition.addMutableTrack(withMediaType: .video,
                                                            preferredTrackID: kCMPersistentTrackID_Invalid) {
                        try? vt.insertTimeRange(range, of: vAsset, at: at)
                        imageCompTracks.append((track: vt, clip: clip))
                    }
                }
            }

            for track in aTracks {
                guard track.isVisible && !track.isMuted else { continue }
                for clip in track.clips {
                    guard let url = clip.url else { continue }
                    let asset = AVURLAsset(url: url)
                    guard let aAsset = try? await asset.loadTracks(withMediaType: .audio).first else { continue }
                    let assetDur = (try? await asset.load(.duration)) ?? .zero
                    let trimSt  = CMTime(seconds: clip.trimStart, preferredTimescale: 600)
                    let maxDur  = assetDur - trimSt
                    let useDur  = CMTimeMinimum(CMTime(seconds: clip.duration, preferredTimescale: 600), maxDur)
                    guard useDur.seconds > 0.01 else { continue }
                    let range = CMTimeRange(start: trimSt, duration: useDur)
                    let at    = CMTime(seconds: clip.startTime, preferredTimescale: 600)
                    if let at2 = composition.addMutableTrack(withMediaType: .audio,
                                                             preferredTrackID: kCMPersistentTrackID_Invalid) {
                        try? at2.insertTimeRange(range, of: aAsset, at: at)
                        audioParams.append((at2.trackID, clip.volume, clip.leftChannel, clip.rightChannel))
                    }
                }
            }

            // 用空白音频轨道撑开 composition 到 endTime
            let compositionDur = composition.duration.seconds
            if endTime > compositionDur + 0.1 {
                if let padTrack = composition.addMutableTrack(withMediaType: .audio,
                                                              preferredTrackID: kCMPersistentTrackID_Invalid) {
                    padTrack.insertEmptyTimeRange(
                        CMTimeRange(start: CMTime(seconds: compositionDur, preferredTimescale: 600),
                                    duration: CMTime(seconds: endTime - compositionDur, preferredTimescale: 600)))
                }
            }

            // 构建 AudioMix — 音量 + 左右声道
            let audioMix = AVMutableAudioMix()
            audioMix.inputParameters = audioParams.map { param in
                let p = AVMutableAudioMixInputParameters(track: composition.track(withTrackID: param.trackID))
                p.trackID = param.trackID
                p.setVolume(param.volume, at: .zero)
                // 左右声道不全是 1.0 时，用 MTAudioProcessingTap 处理
                if param.left != 1.0 || param.right != 1.0 {
                    if let tap = makeChannelTap(left: param.left, right: param.right) {
                        p.audioTapProcessor = tap
                    }
                }
                return p
            }

            // Build AVVideoComposition to layer image tracks on top of video tracks.
            // We need time-segmented instructions so image layers only appear during
            // their clip range and disappear afterwards (letting video show through).
            let allVideoTracks = videoCompTracks + imageCompTracks.map(\.track)
            var videoComposition: AVMutableVideoComposition? = nil
            if !allVideoTracks.isEmpty && composition.duration.seconds > 0.01 {
                let vc = AVMutableVideoComposition()
                vc.renderSize = renderSize
                vc.frameDuration = CMTime(value: 1, timescale: 30)

                // Collect image clip time ranges to build segmented instructions
                var imageClipRanges: [(start: Double, end: Double)] = []
                for track in iTracks where track.isVisible {
                    for clip in track.clips {
                        guard clip.videoURL != nil else { continue }
                        imageClipRanges.append((clip.startTime, clip.endTime))
                    }
                }

                // Collect all time boundaries
                var boundaries: Set<Double> = [0, composition.duration.seconds]
                for r in imageClipRanges { boundaries.insert(r.start); boundaries.insert(r.end) }
                let sorted = boundaries.sorted()

                var instructions: [AVMutableVideoCompositionInstruction] = []
                for i in 0..<(sorted.count - 1) {
                    let segStart = sorted[i]
                    let segEnd   = sorted[i + 1]
                    guard segEnd - segStart > 0.001 else { continue }

                    let instruction = AVMutableVideoCompositionInstruction()
                    instruction.timeRange = CMTimeRange(
                        start: CMTime(seconds: segStart, preferredTimescale: 600),
                        duration: CMTime(seconds: segEnd - segStart, preferredTimescale: 600))
                    instruction.backgroundColor = CGColor(gray: 0, alpha: 1)

                    // Is any image clip active in this segment?
                    let hasImage = imageClipRanges.contains { segStart >= $0.start - 0.001 && segStart < $0.end - 0.001 }

                    var layerInstructions: [AVMutableVideoCompositionLayerInstruction] = []
                    if hasImage {
                        // Image on top, video below
                        for entry in imageCompTracks {
                            let li = AVMutableVideoCompositionLayerInstruction(assetTrack: entry.track)
                            if let natSize = try? await entry.track.load(.naturalSize), natSize.width > 0, natSize.height > 0 {
                                // Base scale to fit image into render size
                                let sx = renderSize.width / natSize.width
                                let sy = renderSize.height / natSize.height
                                let baseScale = min(sx, sy)
                                // Apply user scale from inspector
                                let finalSX = baseScale * entry.clip.scaleX
                                let finalSY = baseScale * entry.clip.scaleY
                                let tx = (renderSize.width - natSize.width * finalSX) / 2
                                let ty = (renderSize.height - natSize.height * finalSY) / 2
                                li.setTransform(CGAffineTransform(scaleX: finalSX, y: finalSY)
                                    .concatenating(CGAffineTransform(translationX: tx, y: ty)), at: .zero)
                            }
                            layerInstructions.append(li)
                        }
                        for track in videoCompTracks {
                            let li = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
                            layerInstructions.append(li)
                        }
                    } else {
                        // Video only — hide image tracks
                        for entry in imageCompTracks {
                            let li = AVMutableVideoCompositionLayerInstruction(assetTrack: entry.track)
                            li.setOpacity(0, at: .zero)
                            layerInstructions.append(li)
                        }
                        for track in videoCompTracks {
                            let li = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
                            layerInstructions.append(li)
                        }
                    }
                    instruction.layerInstructions = layerInstructions
                    instructions.append(instruction)
                }

                if !instructions.isEmpty {
                    vc.instructions = instructions
                    videoComposition = vc
                }
            }

            await MainActor.run {
                self.lastVideoEndTime = endTime
                self.pendingSeekTime = restoreTime
                if composition.tracks.isEmpty && endTime < 0.01 {
                    self.playerItem = nil
                } else {
                    let item = AVPlayerItem(asset: composition)
                    item.audioMix = audioMix
                    if let vc = videoComposition {
                        item.videoComposition = vc
                    }
                    self.playerItem = item
                }
            }
        }
    }

    /// Select a clip for preview and seek to its start so the user sees it.
    func loadClipForPreview(_ clip: VideoClip) {
        rebuildTimelinePreview(seekTo: clip.startTime)
    }

    // MARK: - Import

    func importFile(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        let type: AssetType
        switch ext {
        case "mp4","mov","mkv","avi","m4v": type = .video
        case "mp3","wav","aac","m4a","flac": type = .audio
        case "srt","ass","vtt": type = .subtitle
        case "png","jpg","jpeg","gif","bmp","tiff","tif","webp","heic": type = .image
        default: return
        }
        let asset = MediaAsset(url: url, name: url.lastPathComponent, type: type)
        let aid = asset.id
        mediaAssets.append(asset)
        // Trigger thumbnail / waveform generation
        if type == .video {
            loadMediaThumbnail(assetID: aid, url: url)
            loadTimelineThumbnails(assetID: aid, url: url)
        } else if type == .audio {
            loadWaveform(assetID: aid, url: url)
        } else if type == .image {
            loadImageThumbnail(assetID: aid, url: url)
        }
        if type != .subtitle && type != .image {
            Task {
                let av = AVURLAsset(url: url)
                if let d = try? await av.load(.duration) {
                    await MainActor.run {
                        if let i = self.mediaAssets.firstIndex(where:{ $0.id == aid }) {
                            self.mediaAssets[i].duration = d.seconds
                        }
                    }
                }
            }
        }
    }

    func addToTimeline(_ asset: MediaAsset) {
        switch asset.type {
        case .video:
            // 每条视频放到独立的视频轨道，方便多轨编辑
            let trackIdx: Int
            if let emptyIdx = videoTracks.firstIndex(where: { $0.clips.isEmpty }) {
                trackIdx = emptyIdx
            } else {
                videoTracks.append(Track(label: "视频"))
                trackIdx = videoTracks.count - 1
            }
            Task {
                let dur = (try? await AVURLAsset(url: asset.url).load(.duration))?.seconds ?? 30
                await MainActor.run {
                    self.videoTracks[trackIdx].clips.append(
                        VideoClip(assetID: asset.id, name: asset.name, url: asset.url,
                                  startTime: 0, endTime: dur))
                    self.duration = max(self.duration, dur)
                    if let i = self.mediaAssets.firstIndex(where:{ $0.id == asset.id }) { self.mediaAssets[i].duration = dur }
                    self.rebuildTimelinePreview()
                }
            }
        case .audio:
            if audioTracks.isEmpty { audioTracks.append(Track(label: "音频")) }
            let st = audioTracks[0].clips.map(\.endTime).max() ?? 0
            Task {
                let dur = (try? await AVURLAsset(url: asset.url).load(.duration))?.seconds ?? 30
                await MainActor.run {
                    self.audioTracks[0].clips.append(
                        AudioClip(assetID: asset.id, name: asset.name, url: asset.url,
                                  startTime: st, endTime: st + dur))
                    self.duration = max(self.duration, st + dur)
                    if let i = self.mediaAssets.firstIndex(where:{ $0.id == asset.id }) { self.mediaAssets[i].duration = dur }
                    self.rebuildTimelinePreview()
                }
            }
        case .subtitle:
            let clips = parseSRT(url: asset.url)
            // Use the first empty subtitle track if available; otherwise create
            // a brand-new track so each imported subtitle file lives on its own
            // line (so bilingual / multi-language workflows don't merge).
            if let idx = subtitleTracks.firstIndex(where: { $0.clips.isEmpty }) {
                subtitleTracks[idx].clips = clips
                if subtitleStyles.indices.contains(idx) == false {
                    subtitleStyles.append(SubtitleStyle())
                }
            } else {
                subtitleTracks.append(
                    Track(clips: clips, label: "字幕"))
                subtitleStyles.append(SubtitleStyle())
            }
            if let mx = clips.map(\.endTime).max() { duration = max(duration, mx) }
            if let i = mediaAssets.firstIndex(where:{ $0.id == asset.id }) {
                mediaAssets[i].duration = clips.last?.endTime ?? 0
            }
        case .image:
            let trackIdx: Int
            if let emptyIdx = imageTracks.firstIndex(where: { $0.clips.isEmpty }) {
                trackIdx = emptyIdx
            } else {
                imageTracks.append(Track(label: "图片"))
                trackIdx = imageTracks.count - 1
            }
            let dur = 5.0
            let videoURL = imageVideoCache[asset.id]
            var imgW = 0, imgH = 0
            if let img = NSImage(contentsOf: asset.url) {
                if let rep = img.representations.first {
                    imgW = rep.pixelsWide; imgH = rep.pixelsHigh
                }
            }
            imageTracks[trackIdx].clips.append(
                ImageClip(assetID: asset.id, name: asset.name, imageURL: asset.url,
                          videoURL: videoURL, startTime: 0, endTime: dur,
                          imageWidth: imgW, imageHeight: imgH))
            duration = max(duration, dur)
            // Generate video if not cached yet, then update clip
            if videoURL == nil {
                let aid = asset.id
                let imgURL = asset.url
                let ti = trackIdx
                Task {
                    guard let vURL = await Self.createVideoFromImage(imageURL: imgURL, duration: dur) else { return }
                    await MainActor.run {
                        self.imageVideoCache[aid] = vURL
                        for ci in self.imageTracks[ti].clips.indices where self.imageTracks[ti].clips[ci].assetID == aid {
                            self.imageTracks[ti].clips[ci].videoURL = vURL
                        }
                        self.rebuildTimelinePreview()
                    }
                }
            } else {
                rebuildTimelinePreview()
            }
        }
    }

    // MARK: - Mutation helpers

    func updateSubtitleText(id: UUID, text: String) {
        for i in subtitleTracks.indices {
            if let j = subtitleTracks[i].clips.firstIndex(where:{ $0.id == id }) {
                subtitleTracks[i].clips[j].text = text; return
            }
        }
    }

    func updateSubtitleTime(id: UUID, start: Double? = nil, end: Double? = nil) {
        for i in subtitleTracks.indices {
            if let j = subtitleTracks[i].clips.firstIndex(where:{ $0.id == id }) {
                if let s = start { subtitleTracks[i].clips[j].startTime = s }
                if let e = end   { subtitleTracks[i].clips[j].endTime   = e }
                return
            }
        }
    }

    func updateVideoClip(id: UUID, _ modify: (inout VideoClip) -> Void) {
        for i in videoTracks.indices {
            if let j = videoTracks[i].clips.firstIndex(where:{ $0.id == id }) {
                modify(&videoTracks[i].clips[j]); return
            }
        }
    }

    func updateImageClip(id: UUID, _ modify: (inout ImageClip) -> Void) {
        for i in imageTracks.indices {
            if let j = imageTracks[i].clips.firstIndex(where:{ $0.id == id }) {
                modify(&imageTracks[i].clips[j]); return
            }
        }
    }

    func updateAudioClip(id: UUID, _ modify: (inout AudioClip) -> Void) {
        for i in audioTracks.indices {
            if let j = audioTracks[i].clips.firstIndex(where:{ $0.id == id }) {
                modify(&audioTracks[i].clips[j]); return
            }
        }
    }

    // MARK: - SRT Parser

    func parseSRT(url: URL) -> [SubtitleClip] {
        let raw: String
        if let s = try? String(contentsOf: url, encoding: .utf8) { raw = s }
        else if let s = try? String(contentsOf: url, encoding: .utf16) { raw = s }
        else { return [] }
        var clips: [SubtitleClip] = []
        for block in raw.components(separatedBy: "\n\n") {
            let lines = block.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
            guard lines.count >= 2, let tsLine = lines.first(where: { $0.contains("-->") }) else { continue }
            let parts = tsLine.components(separatedBy: "-->")
            guard parts.count == 2,
                  let s = srtTime(parts[0].trimmingCharacters(in: .whitespaces)),
                  let e = srtTime(parts[1].trimmingCharacters(in: .whitespaces)) else { continue }
            let idx = lines.firstIndex(where: { $0.contains("-->") }) ?? 0
            let text = lines.dropFirst(idx + 1).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { clips.append(SubtitleClip(text: text, startTime: s, endTime: e)) }
        }
        return clips
    }
    private func srtTime(_ s: String) -> Double? {
        let c = s.replacingOccurrences(of: ",", with: ".")
        let p = c.components(separatedBy: ":"); guard p.count == 3 else { return nil }
        guard let h = Double(p[0]), let m = Double(p[1]), let sec = Double(p[2]) else { return nil }
        return h * 3600 + m * 60 + sec
    }

    /// User-initiated playhead move — updates `currentTime` AND tells the
    /// player to seek (via `seekRequest` counter observed by PlayerView).
    func requestSeek(to t: Double) {
        currentTime = t.clamped(to: 0...max(duration, 0))
        seekRequest &+= 1
    }

    // MARK: - Undo / Redo

    func pushUndo() {
        undoStack.append(currentSnapshot())
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll()
        undoCount = undoStack.count
        redoCount = 0
    }

    func undo() {
        guard let s = undoStack.popLast() else { return }
        redoStack.append(currentSnapshot())
        applySnapshot(s)
        undoCount = undoStack.count
        redoCount = redoStack.count
    }

    func redo() {
        guard let s = redoStack.popLast() else { return }
        undoStack.append(currentSnapshot())
        applySnapshot(s)
        undoCount = undoStack.count
        redoCount = redoStack.count
    }

    private func currentSnapshot() -> ProjectSnapshot {
        ProjectSnapshot(videoTracks: videoTracks, audioTracks: audioTracks,
                        imageTracks: imageTracks,
                        subtitleTracks: subtitleTracks, subtitleStyles: subtitleStyles)
    }
    private func applySnapshot(_ s: ProjectSnapshot) {
        videoTracks    = s.videoTracks
        audioTracks    = s.audioTracks
        imageTracks    = s.imageTracks
        subtitleTracks = s.subtitleTracks
        subtitleStyles = s.subtitleStyles
        rebuildTimelinePreview()
    }

    // MARK: - Edit operations

    /// Split ONLY the currently selected clip at the playhead. If nothing selected, do nothing.
    func splitAtPlayhead() {
        let t = currentTime
        let snap = currentSnapshot()
        var changed = false

        if let id = selectedVideoClipID {
            outer: for ti in videoTracks.indices {
                if let ci = videoTracks[ti].clips.firstIndex(where: { $0.id == id }) {
                    let c = videoTracks[ti].clips[ci]
                    if c.startTime + 0.01 < t && c.endTime - 0.01 > t {
                        videoTracks[ti].clips[ci].endTime = t
                        let newClip = VideoClip(
                            assetID: c.assetID, name: c.name, url: c.url,
                            startTime: t, endTime: c.endTime,
                            trimStart: c.trimStart + (t - c.startTime),
                            overrideResolution: c.overrideResolution,
                            overrideFPS: c.overrideFPS,
                            overrideBitrate: c.overrideBitrate)
                        videoTracks[ti].clips.insert(newClip, at: ci + 1)
                        changed = true
                    }
                    break outer
                }
            }
        } else if let id = selectedAudioClipID {
            outer: for ti in audioTracks.indices {
                if let ci = audioTracks[ti].clips.firstIndex(where: { $0.id == id }) {
                    let c = audioTracks[ti].clips[ci]
                    if c.startTime + 0.01 < t && c.endTime - 0.01 > t {
                        audioTracks[ti].clips[ci].endTime = t
                        let newClip = AudioClip(
                            assetID: c.assetID, name: c.name, url: c.url,
                            startTime: t, endTime: c.endTime,
                            trimStart: c.trimStart + (t - c.startTime),
                            volume: c.volume, leftChannel: c.leftChannel, rightChannel: c.rightChannel,
                            sampleRate: c.sampleRate, format: c.format)
                        audioTracks[ti].clips.insert(newClip, at: ci + 1)
                        changed = true
                    }
                    break outer
                }
            }
        } else if let id = selectedSubtitleClipID {
            outer: for ti in subtitleTracks.indices {
                if let ci = subtitleTracks[ti].clips.firstIndex(where: { $0.id == id }) {
                    let c = subtitleTracks[ti].clips[ci]
                    if c.startTime + 0.01 < t && c.endTime - 0.01 > t {
                        subtitleTracks[ti].clips[ci].endTime = t
                        let newClip = SubtitleClip(text: c.text, startTime: t, endTime: c.endTime)
                        subtitleTracks[ti].clips.insert(newClip, at: ci + 1)
                        changed = true
                    }
                    break outer
                }
            }
        }

        if changed {
            undoStack.append(snap)
            if undoStack.count > 50 { undoStack.removeFirst() }
            redoStack.removeAll()
            undoCount = undoStack.count
            redoCount = 0
            rebuildTimelinePreview()
        }
    }

    /// Delete every selected clip — multi-selection (box-select) + the
    /// single-selection IDs used by the Inspector.
    func deleteSelected() {
        let snap = currentSnapshot()
        var changed = false

        // Pool of all IDs to remove
        var ids = selectedClipIDs
        if let id = selectedVideoClipID    { ids.insert(id) }
        if let id = selectedImageClipID    { ids.insert(id) }
        if let id = selectedAudioClipID    { ids.insert(id) }
        if let id = selectedSubtitleClipID { ids.insert(id) }
        guard !ids.isEmpty else { return }

        for i in videoTracks.indices {
            let before = videoTracks[i].clips.count
            videoTracks[i].clips.removeAll { ids.contains($0.id) }
            if videoTracks[i].clips.count != before { changed = true }
        }
        for i in imageTracks.indices {
            let before = imageTracks[i].clips.count
            imageTracks[i].clips.removeAll { ids.contains($0.id) }
            if imageTracks[i].clips.count != before { changed = true }
        }
        for i in audioTracks.indices {
            let before = audioTracks[i].clips.count
            audioTracks[i].clips.removeAll { ids.contains($0.id) }
            if audioTracks[i].clips.count != before { changed = true }
        }
        for i in subtitleTracks.indices {
            let before = subtitleTracks[i].clips.count
            subtitleTracks[i].clips.removeAll { ids.contains($0.id) }
            if subtitleTracks[i].clips.count != before { changed = true }
        }

        selectedVideoClipID    = nil
        selectedImageClipID    = nil
        selectedAudioClipID    = nil
        selectedSubtitleClipID = nil
        selectedClipIDs.removeAll()

        if changed {
            undoStack.append(snap)
            if undoStack.count > 50 { undoStack.removeFirst() }
            redoStack.removeAll()
            undoCount = undoStack.count
            redoCount = 0
            rebuildTimelinePreview()
        }
    }

    // MARK: - Copy / Cut / Paste

    /// 复制当前选中的片段到剪贴板
    func copySelected() {
        if let id = selectedVideoClipID {
            for (ti, track) in videoTracks.enumerated() {
                if let clip = track.clips.first(where: { $0.id == id }) {
                    clipboard = .video(clip, trackIndex: ti)
                    clipboardIsCut = false; clipboardSourceID = nil; return
                }
            }
        }
        if let id = selectedImageClipID {
            for (ti, track) in imageTracks.enumerated() {
                if let clip = track.clips.first(where: { $0.id == id }) {
                    clipboard = .image(clip, trackIndex: ti)
                    clipboardIsCut = false; clipboardSourceID = nil; return
                }
            }
        }
        if let id = selectedAudioClipID {
            for (ti, track) in audioTracks.enumerated() {
                if let clip = track.clips.first(where: { $0.id == id }) {
                    clipboard = .audio(clip, trackIndex: ti)
                    clipboardIsCut = false
                    clipboardSourceID = nil
                    return
                }
            }
        }
        if let id = selectedSubtitleClipID {
            for (ti, track) in subtitleTracks.enumerated() {
                if let clip = track.clips.first(where: { $0.id == id }) {
                    clipboard = .subtitle(clip, trackIndex: ti)
                    clipboardIsCut = false
                    clipboardSourceID = nil
                    return
                }
            }
        }
    }

    /// 剪切当前选中的片段（粘贴时移除原始片段）
    func cutSelected() {
        if let id = selectedVideoClipID {
            for (ti, track) in videoTracks.enumerated() {
                if let clip = track.clips.first(where: { $0.id == id }) {
                    clipboard = .video(clip, trackIndex: ti)
                    clipboardIsCut = true; clipboardSourceID = id; return
                }
            }
        }
        if let id = selectedImageClipID {
            for (ti, track) in imageTracks.enumerated() {
                if let clip = track.clips.first(where: { $0.id == id }) {
                    clipboard = .image(clip, trackIndex: ti)
                    clipboardIsCut = true; clipboardSourceID = id; return
                }
            }
        }
        if let id = selectedAudioClipID {
            for (ti, track) in audioTracks.enumerated() {
                if let clip = track.clips.first(where: { $0.id == id }) {
                    clipboard = .audio(clip, trackIndex: ti)
                    clipboardIsCut = true
                    clipboardSourceID = id
                    return
                }
            }
        }
        if let id = selectedSubtitleClipID {
            for (ti, track) in subtitleTracks.enumerated() {
                if let clip = track.clips.first(where: { $0.id == id }) {
                    clipboard = .subtitle(clip, trackIndex: ti)
                    clipboardIsCut = true
                    clipboardSourceID = id
                    return
                }
            }
        }
    }

    /// 粘贴剪贴板内容到当前播放头位置，放在同类型的当前选中轨道或原始轨道
    func pasteAtPlayhead() {
        guard let item = clipboard else { return }
        let snap = currentSnapshot()
        let t = currentTime

        // 如果是剪切，先删除原始片段
        if clipboardIsCut, let srcID = clipboardSourceID {
            for i in videoTracks.indices {
                videoTracks[i].clips.removeAll { $0.id == srcID }
            }
            for i in imageTracks.indices {
                imageTracks[i].clips.removeAll { $0.id == srcID }
            }
            for i in audioTracks.indices {
                audioTracks[i].clips.removeAll { $0.id == srcID }
            }
            for i in subtitleTracks.indices {
                subtitleTracks[i].clips.removeAll { $0.id == srcID }
            }
            // 剪切只能粘贴一次
            clipboardIsCut = false
            clipboardSourceID = nil
        }

        switch item {
        case .video(let clip, let trackIdx):
            var newClip = VideoClip(assetID: clip.assetID, name: clip.name, url: clip.url,
                                    startTime: t, endTime: t + clip.duration, trimStart: clip.trimStart)
            newClip.volume = clip.volume
            newClip.overrideResolution = clip.overrideResolution
            newClip.overrideFPS = clip.overrideFPS
            newClip.overrideBitrate = clip.overrideBitrate
            let idx = videoTracks.indices.contains(trackIdx) ? trackIdx : 0
            if videoTracks.indices.contains(idx) {
                videoTracks[idx].clips.append(newClip)
                selectedVideoClipID = newClip.id
                selectedAudioClipID = nil
                selectedSubtitleClipID = nil
            }

        case .image(let clip, let trackIdx):
            let newClip = ImageClip(assetID: clip.assetID, name: clip.name, imageURL: clip.imageURL,
                                     videoURL: clip.videoURL, startTime: t, endTime: t + clip.duration)
            let idx = imageTracks.indices.contains(trackIdx) ? trackIdx : 0
            if imageTracks.indices.contains(idx) {
                imageTracks[idx].clips.append(newClip)
                selectedImageClipID = newClip.id
                selectedVideoClipID = nil; selectedAudioClipID = nil; selectedSubtitleClipID = nil
            }

        case .audio(let clip, let trackIdx):
            var newClip = AudioClip(assetID: clip.assetID, name: clip.name, url: clip.url,
                                    startTime: t, endTime: t + clip.duration, trimStart: clip.trimStart)
            newClip.volume = clip.volume
            newClip.leftChannel = clip.leftChannel
            newClip.rightChannel = clip.rightChannel
            newClip.sampleRate = clip.sampleRate
            newClip.format = clip.format
            let idx = audioTracks.indices.contains(trackIdx) ? trackIdx : 0
            if audioTracks.indices.contains(idx) {
                audioTracks[idx].clips.append(newClip)
                selectedAudioClipID = newClip.id
                selectedVideoClipID = nil
                selectedSubtitleClipID = nil
            }

        case .subtitle(let clip, let trackIdx):
            let newClip = SubtitleClip(text: clip.text, startTime: t, endTime: t + clip.duration)
            let idx = subtitleTracks.indices.contains(trackIdx) ? trackIdx : 0
            if subtitleTracks.indices.contains(idx) {
                subtitleTracks[idx].clips.append(newClip)
                selectedSubtitleClipID = newClip.id
                selectedVideoClipID = nil
                selectedAudioClipID = nil
            }
        }

        undoStack.append(snap)
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll()
        undoCount = undoStack.count
        redoCount = 0
        rebuildTimelinePreview()
    }

    /// Move the selected clip so its start aligns with the current playhead.
    func alignSelectedToPlayhead() {
        let t = currentTime
        let snap = currentSnapshot()
        var changed = false
        if let id = selectedVideoClipID {
            updateVideoClip(id: id) { c in
                let d = c.duration; c.startTime = t; c.endTime = t + d
            }; changed = true
        } else if let id = selectedAudioClipID {
            updateAudioClip(id: id) { c in
                let d = c.duration; c.startTime = t; c.endTime = t + d
            }; changed = true
        } else if let id = selectedSubtitleClipID {
            for ti in subtitleTracks.indices {
                if let ci = subtitleTracks[ti].clips.firstIndex(where:{ $0.id==id }) {
                    let d = subtitleTracks[ti].clips[ci].duration
                    subtitleTracks[ti].clips[ci].startTime = t
                    subtitleTracks[ti].clips[ci].endTime   = t + d
                    changed = true; break
                }
            }
        }
        if changed {
            undoStack.append(snap)
            if undoStack.count > 50 { undoStack.removeFirst() }
            redoStack.removeAll()
            undoCount = undoStack.count
            redoCount = 0
        }
    }

    // MARK: - Image → Video generation

    static func createVideoFromImage(imageURL: URL, duration: Double) async -> URL? {
        guard let nsImage = NSImage(contentsOf: imageURL),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        let width = cgImage.width
        let height = cgImage.height

        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mov) else { return nil }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB, nil, &pixelBuffer)
        guard let pb = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb),
                               width: width, height: height, bitsPerComponent: 8,
                               bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) {
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        CVPixelBufferUnlockBaseAddress(pb, [])

        // Write 1 frame per second
        let totalFrames = max(Int(duration), 1)
        for i in 0..<totalFrames {
            while !input.isReadyForMoreMediaData {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            adaptor.append(pb, withPresentationTime: CMTime(value: Int64(i), timescale: 1))
        }
        // Final frame at exact end
        while !input.isReadyForMoreMediaData {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        adaptor.append(pb, withPresentationTime: CMTime(seconds: duration, preferredTimescale: 600))

        input.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed ? outputURL : nil
    }

    /// Insert a new subtitle clip into the active subtitle track at the playhead.
    func insertSubtitleAtPlayhead() {
        let snap = currentSnapshot()
        if subtitleTracks.isEmpty {
            subtitleTracks.append(Track(label: "字幕"))
            subtitleStyles.append(SubtitleStyle())
        }
        var trackIdx = 0
        if let sid = selectedSubtitleClipID {
            for (i, t) in subtitleTracks.enumerated() {
                if t.clips.contains(where: { $0.id == sid }) { trackIdx = i; break }
            }
        }
        let start = currentTime
        let end   = min(currentTime + 2.0, max(duration, currentTime + 2.0))
        let clip  = SubtitleClip(text: "新字幕", startTime: start, endTime: end)
        subtitleTracks[trackIdx].clips.append(clip)
        subtitleTracks[trackIdx].clips.sort { $0.startTime < $1.startTime }
        selectedSubtitleClipID = clip.id

        undoStack.append(snap)
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll()
        undoCount = undoStack.count
        redoCount = 0
    }
}

// MARK: - Color helper

extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var v: UInt64 = 0; Scanner(string: h).scanHexInt64(&v)
        self.init(red: Double((v>>16)&0xFF)/255, green: Double((v>>8)&0xFF)/255, blue: Double(v&0xFF)/255)
    }
}

// MARK: - Channel Volume Tap

/// 存储左右声道音量，传给 MTAudioProcessingTap
private struct ChannelVols {
    var left: Float
    var right: Float
}

/// 创建一个音频处理 Tap，对左右声道分别应用音量
func makeChannelTap(left: Float, right: Float) -> MTAudioProcessingTap? {
    let ctx = UnsafeMutablePointer<ChannelVols>.allocate(capacity: 1)
    ctx.initialize(to: ChannelVols(left: left, right: right))

    var callbacks = MTAudioProcessingTapCallbacks(
        version: kMTAudioProcessingTapCallbacksVersion_0,
        clientInfo: UnsafeMutableRawPointer(ctx),
        `init`: { (_, clientInfo, storageOut) in
            storageOut.pointee = clientInfo
        },
        finalize: { tap in
            let s = MTAudioProcessingTapGetStorage(tap)
            s.assumingMemoryBound(to: ChannelVols.self).deinitialize(count: 1)
            s.assumingMemoryBound(to: ChannelVols.self).deallocate()
        },
        prepare: nil,
        unprepare: nil,
        process: { (tap, frames, _, buf, framesOut, flagsOut) in
            guard MTAudioProcessingTapGetSourceAudio(tap, frames, buf, flagsOut, nil, framesOut) == noErr else { return }
            let vols = MTAudioProcessingTapGetStorage(tap).assumingMemoryBound(to: ChannelVols.self).pointee
            let abl = UnsafeMutableAudioBufferListPointer(buf)
            for i in 0..<abl.count {
                guard let data = abl[i].mData?.assumingMemoryBound(to: Float.self) else { continue }
                let n = Int(abl[i].mDataByteSize) / MemoryLayout<Float>.size
                var vol = (i == 0) ? vols.left : vols.right
                vDSP_vsmul(data, 1, &vol, data, 1, vDSP_Length(n))
            }
        }
    )

    var tap: MTAudioProcessingTap?
    let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                             kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
    guard status == noErr else { ctx.deallocate(); return nil }
    return tap
}
