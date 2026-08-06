// RecentProjects.swift
// 欢迎页「最近文件」的数据层：记录打开/保存过的 .bcj，附一张缩略图。
//
// 不用 NSDocumentController.sharedDocumentController.recentDocumentURLs：
// 那套是给 NSDocument 架构用的，这个项目是自己管文件读写的，而且我们还要
// 存缩略图、支持单条移除和清空，索引自己维护更直接。
import Foundation
import AppKit

struct RecentProject: Identifiable, Codable, Equatable {
    var url: URL
    var name: String
    var openedAt: Date

    var id: URL { url }
    /// 文件还在不在。移动或删除过的项目在欢迎页上要能看出来
    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }
}

@MainActor
final class RecentProjects: ObservableObject {
    static let shared = RecentProjects()

    /// 最多留这么多条。再多欢迎页也一屏放不下，还拖慢缩略图加载
    private static let maxCount = 30
    private static let storeKey = "settings.recentProjects"

    @Published private(set) var items: [RecentProject] = []
    /// 缩略图按 url 缓存，懒加载。放内存里就够——数量上限 30
    @Published private(set) var thumbnails: [URL: NSImage] = [:]

    private let ud = UserDefaults.standard
    private var loading = Set<URL>()

    private init() {
        if let data = ud.data(forKey: Self.storeKey),
           let saved = try? JSONDecoder().decode([RecentProject].self, from: data) {
            items = saved
        }
    }

    // MARK: - 增删

    /// 打开或保存项目后调一次。已存在就提到最前并更新时间，不产生重复项
    func record(url: URL, name: String) {
        // 清掉这个项目的缩略图缓存。保存之后素材可能已经换了，
        // 留着旧图会一直显示上一版的画面
        thumbnails[url] = nil
        items.removeAll { $0.url == url }
        items.insert(RecentProject(url: url, name: name, openedAt: Date()), at: 0)
        if items.count > Self.maxCount { items.removeLast(items.count - Self.maxCount) }
        persist()
    }

    /// 从列表移除。只动索引，不碰磁盘上的项目文件
    func remove(_ url: URL) {
        items.removeAll { $0.url == url }
        thumbnails[url] = nil
        persist()
    }

    func clearAll() {
        items.removeAll()
        thumbnails.removeAll()
        persist()
    }

    /// 重命名：磁盘上的文件跟着一起改，索引里的 url 也要换掉
    /// - Returns: 失败原因，nil 表示成功
    func rename(_ url: URL, to newName: String) -> String? {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "名称不能为空" }
        guard FileManager.default.fileExists(atPath: url.path) else { return "文件不存在" }

        let ext = url.pathExtension.isEmpty ? "bcj" : url.pathExtension
        let dest = url.deletingLastPathComponent().appendingPathComponent("\(trimmed).\(ext)")
        if dest == url { return nil }   // 没改动
        guard !FileManager.default.fileExists(atPath: dest.path) else { return "同目录下已有同名项目" }

        do {
            try FileManager.default.moveItem(at: url, to: dest)
        } catch {
            return error.localizedDescription
        }

        if let i = items.firstIndex(where: { $0.url == url }) {
            items[i].url = dest
            items[i].name = trimmed
        }
        if let img = thumbnails[url] {
            thumbnails[dest] = img
            thumbnails[url] = nil
        }
        persist()
        return nil
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) {
            ud.set(data, forKey: Self.storeKey)
        }
    }

    // MARK: - 缩略图

    /// 取这个项目的缩略图，没有就后台生成一张。
    /// .bcj 本身是 JSON 没有画面，所以从它引用的素材里取：
    /// **视频优先，其次图片，都没有则返回 nil 由 UI 显示缺省图**。
    /// 这样旧项目不用重新保存也能有图。
    func loadThumbnail(for url: URL) {
        guard thumbnails[url] == nil, !loading.contains(url) else { return }
        loading.insert(url)

        Task.detached(priority: .utility) {
            let image = Self.makeThumbnail(projectURL: url)
            await MainActor.run {
                self.loading.remove(url)
                if let image { self.thumbnails[url] = image }
            }
        }
    }

    /// 从 .bcj 的**轨道**生成缩略图：视频轨优先，其次图片轨，都没有返回 nil。
    ///
    /// 取轨道而不是 mediaAssets：素材库里可能躺着一堆没用上的素材，
    /// 排在最前的那个未必出现在成片里。轨道上的第一个片段才是这个项目的开头。
    /// 而且片段自带 trimStart，能取到用户在时间轴上真正看到的那一帧。
    ///
    /// 只解析需要的字段，不整份 decode 成 ProjectDocument——那个结构随版本变，
    /// 旧文件解不出来就连缩略图都没有了。
    nonisolated static func makeThumbnail(projectURL: URL) -> NSImage? {
        guard let data = try? Data(contentsOf: projectURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        /// 把片段里的 url 字段解成本地路径。存的是 file:// 形式且做过百分号编码
        func localURL(_ clip: [String: Any]) -> URL? {
            guard let path = clip["url"] as? String else { return nil }
            let u = path.hasPrefix("file://") ? (URL(string: path) ?? URL(fileURLWithPath: path))
                                              : URL(fileURLWithPath: path)
            return FileManager.default.fileExists(atPath: u.path) ? u : nil
        }

        /// 按时间轴顺序摊平某一类轨道上的所有片段
        func clips(in key: String) -> [[String: Any]] {
            let tracks = root[key] as? [[String: Any]] ?? []
            return tracks.flatMap { ($0["clips"] as? [[String: Any]]) ?? [] }
                .sorted { (($0["startTime"] as? Double) ?? 0) < (($1["startTime"] as? Double) ?? 0) }
        }

        // 视频轨优先
        for clip in clips(in: "videoTracks") {
            guard let u = localURL(clip) else { continue }
            // trimStart 是这个片段从源文件的哪一秒开始播，取那一帧才是
            // 用户在时间轴上看到的画面，不是源文件的第 0 秒
            let at = (clip["trimStart"] as? Double) ?? 0
            if let img = frame(of: u, at: at) { return img }
        }
        // 没有视频轨才看图片轨
        for clip in clips(in: "imageTracks") {
            guard let u = localURL(clip), let img = NSImage(contentsOf: u) else { continue }
            return img
        }
        // 两类轨道都没有可用画面（纯音频项目、空项目）→ UI 显示缺省图
        return nil
    }

    /// 取视频某一秒的画面。AVFoundation 优先，失败或超时退 ffmpeg——
    /// 跟素材库封面同一套（家用机上 AVFoundation 会挂死，见 home_machine_decode_issue）
    private nonisolated static func frame(of url: URL, at seconds: Double) -> NSImage? {
        if case .success(let cg) = ProjectState.avSingleFrameSync(url: url, maxSize: 480,
                                                                  timeout: 6, at: seconds) {
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
        return ProjectState.ffmpegSingleFrame(url: url, maxSize: 480, at: seconds)
    }
}
