// OnlineAudioPanel.swift
// 素材库「音频」页：左边竖排导航（我的 / 音乐库 / 音效库，可折叠），右边内容。
// 在线部分数据来自 Openverse（api.openverse.org）：匿名可用、不用 Key，
// 音效实际来自 Freesound，音乐来自 Jamendo。
//
// **只放能商用的许可**：CC0、公共领域（pdm）、CC BY。
//   · BY-ND（禁止演绎）排掉 —— 配进视频就是演绎作品
//   · BY-SA（相同方式共享）排掉 —— 会要求整条成片按同样的协议发布
//   · 带 NC 的本来就不能商用
// CC BY 要署名：加到时间轴时把 Openverse 给的署名存到素材上，右键素材能复制。
//
// 卡片上两个按钮：收藏（进「我的 → 收藏」）、下载。下载**不进素材库、不进收藏**，
// 下完自动播一遍，按钮变「添加」，点了才导入并放到时间轴播放头处。
//
// 匿名限流：每分钟 20 次、每天 200 次（按 IP）。所以分类结果按页缓存，
// 只在点分类 / 回车 / 翻页时才请求，不做边打边搜。
import SwiftUI
import AVFoundation

// MARK: - 数据

struct OnlineAudioItem: Identifiable, Codable, Equatable {
    let id: String
    let title: String?
    let creator: String?
    let license: String
    let license_version: String?
    let url: String
    /// 毫秒
    let duration: Int?
    let attribution: String?
    let source: String?
    /// 封面。只有音乐（Jamendo 的专辑图）有，音效是 nil。老收藏里没存这个字段，解成 nil
    let thumbnail: String?

    /// 有没有封面可取。老收藏没存 thumbnail，但音乐的封面地址规则是固定的，按 id 拼得出来
    var coverURL: URL? {
        if let t = thumbnail, let u = URL(string: t) { return u }
        guard source == "jamendo" else { return nil }
        return URL(string: "https://api.openverse.org/v1/audio/\(id)/thumb/")
    }

    var displayTitle: String {
        let t = (title ?? "").trimmingCharacters(in: .whitespaces)
        // Freesound 的标题常带原文件扩展名（xxx.wav），列表里不需要
        let noExt = t.replacingOccurrences(of: #"\.(wav|mp3|aiff?|flac|ogg)$"#, with: "",
                                           options: [.regularExpression, .caseInsensitive])
        return noExt.isEmpty ? "未命名" : noExt
    }

    var licenseLabel: String {
        switch license.lowercased() {
        case "cc0": return "CC0"
        case "pdm": return "公共领域"
        default: return "CC " + license.uppercased()
        }
    }

    /// 要不要署名。CC0 / 公共领域不用
    var needsCredit: Bool { !["cc0", "pdm"].contains(license.lowercased()) }

    var durationText: String {
        guard let ms = duration, ms > 0 else { return "" }
        let s = Int((Double(ms) / 1000).rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct OpenverseResponse: Decodable {
    let result_count: Int
    let page_count: Int
    let results: [OnlineAudioItem]
}

/// 一个分类 = 一组预设搜索词。Openverse 没有「风格」筛选，只能按关键词搜；
/// 库是英文索引的，所以词写英文
struct AudioCategory: Identifiable, Equatable {
    let id: String
    let name: String
    let query: String
}

enum AudioLibrarySection: Equatable {
    case local, favorites
    case music(String)   // 分类 id
    case sfx(String)

    var raw: String {
        switch self {
        case .local: return "local"
        case .favorites: return "favorites"
        case .music(let c): return "music:" + c
        case .sfx(let c): return "sfx:" + c
        }
    }

    init(raw: String) {
        if raw == "favorites" { self = .favorites }
        else if raw.hasPrefix("music:") { self = .music(String(raw.dropFirst(6))) }
        else if raw.hasPrefix("sfx:") { self = .sfx(String(raw.dropFirst(4))) }
        else { self = .local }
    }

    var isOnlineLibrary: Bool {
        switch self { case .music, .sfx: return true; default: return false }
    }
}

// MARK: - 状态

@MainActor
final class OnlineAudioStore: ObservableObject {
    static let shared = OnlineAudioStore()

    static let musicCategories: [AudioCategory] = [
        .init(id: "happy", name: "轻快", query: "happy"),
        .init(id: "relax", name: "舒缓", query: "relaxing"),
        .init(id: "piano", name: "钢琴", query: "piano"),
        .init(id: "lofi", name: "Lo-fi", query: "lofi"),
        .init(id: "electronic", name: "电子", query: "electronic"),
        .init(id: "pop", name: "流行", query: "pop"),
        .init(id: "rock", name: "摇滚", query: "rock"),
        .init(id: "hiphop", name: "嘻哈", query: "hip hop"),
        .init(id: "jazz", name: "爵士", query: "jazz"),
        .init(id: "classical", name: "古典", query: "classical"),
        .init(id: "ambient", name: "氛围", query: "ambient"),
        .init(id: "epic", name: "史诗", query: "epic"),
    ]

    static let sfxCategories: [AudioCategory] = [
        .init(id: "whoosh", name: "转场", query: "whoosh"),
        .init(id: "click", name: "按键", query: "click"),
        .init(id: "nature", name: "自然", query: "nature"),
        .init(id: "rain", name: "雨声", query: "rain"),
        .init(id: "city", name: "城市", query: "traffic"),
        .init(id: "footsteps", name: "脚步", query: "footsteps"),
        .init(id: "door", name: "开关门", query: "door"),
        .init(id: "laugh", name: "笑声", query: "laugh"),
        .init(id: "animal", name: "动物", query: "animal"),
        .init(id: "impact", name: "撞击", query: "impact"),
        .init(id: "explosion", name: "爆炸", query: "explosion"),
        .init(id: "cartoon", name: "搞笑", query: "cartoon"),
    ]

    @Published var section: AudioLibrarySection {
        didSet {
            UserDefaults.standard.set(section.raw, forKey: "audioLibrary.section")
            // 换分类就把搜索清掉，看的是这个分类本身
            if oldValue != section { searchText = ""; activeSearch = nil; stopPreview(); loadCurrent() }
        }
    }
    @Published var searchText = ""
    @Published private(set) var activeSearch: String?
    @Published private(set) var results: [OnlineAudioItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var playingID: String?
    /// 正在下的，0…1
    @Published private(set) var downloading: [String: Double] = [:]
    @Published private(set) var favorites: [OnlineAudioItem] = []
    /// 音效标题的中文译名，按条目 id。落盘，同一条只翻一次
    @Published private(set) var zhTitles: [String: String] = [:]

    private struct Page { var items: [OnlineAudioItem]; var page: Int; var pageCount: Int }
    /// 按「库 + 搜索词」缓存，来回点分类不重复请求（限流很紧）
    private var cache: [String: Page] = [:]
    private var inflightKey: String?
    private var player: AVPlayer?
    private var endObserver: Any?

    private init() {
        section = AudioLibrarySection(raw: UserDefaults.standard.string(forKey: "audioLibrary.section") ?? "local")
        favorites = (try? JSONDecoder().decode([OnlineAudioItem].self,
                                               from: Data(contentsOf: Self.favoritesURL))) ?? []
        zhTitles = (try? JSONDecoder().decode([String: String].self,
                                              from: Data(contentsOf: Self.zhTitlesURL))) ?? [:]
    }

    private static var zhTitlesURL: URL { downloadDir.appendingPathComponent("zh-titles.json") }

    /// 列表上显示的名字：音效有译名用译名，音乐（歌名）照原样
    func title(for item: OnlineAudioItem) -> String {
        zhTitles[item.id] ?? item.displayTitle
    }

    /// 把一批音效标题翻成中文。走 设置 → 字幕 里选的翻译引擎；
    /// 翻不动（没网、引擎挂了）就留英文，不影响列表
    private func translateTitles(_ items: [OnlineAudioItem]) {
        let todo = items.filter { zhTitles[$0.id] == nil }
        guard !todo.isEmpty else { return }
        Task {
            // Freesound 标题常用逗号分层级（Door, Wooden, Close），翻出来是一串词。
            // 这是原作者起的名，保留结构，只是换成中文
            let out = await Translator.translateBatchRaw(todo.map(\.displayTitle), to: "中文（简体）")
            var changed = false
            for (item, zh) in zip(todo, out) {
                let t = zh.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty, t != item.displayTitle else { continue }
                zhTitles[item.id] = t
                changed = true
            }
            if changed, let data = try? JSONEncoder().encode(zhTitles) {
                try? data.write(to: Self.zhTitlesURL)
            }
        }
    }

    static var downloadDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("黑猫剪辑/online-audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var favoritesURL: URL { downloadDir.appendingPathComponent("favorites.json") }

    // MARK: 当前看的是哪一页

    private var isMusic: Bool { if case .music = section { return true } else { return false } }

    private var category: AudioCategory? {
        switch section {
        case .music(let c): return Self.musicCategories.first { $0.id == c }
        case .sfx(let c): return Self.sfxCategories.first { $0.id == c }
        default: return nil
        }
    }

    private var currentKey: String? {
        guard section.isOnlineLibrary, let cat = category else { return nil }
        return (isMusic ? "music|" : "sfx|") + (activeSearch ?? cat.query)
    }

    var canLoadMore: Bool {
        guard !isLoading, let k = currentKey, let p = cache[k] else { return false }
        return p.page < p.pageCount
    }

    /// 进到当前分类：有缓存直接用，没有就请求第一页
    func loadCurrent() {
        error = nil
        guard let key = currentKey else { results = []; return }
        if let p = cache[key] { results = p.items; return }
        results = []
        fetch(key: key, page: 1)
    }

    func submitSearch() {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard section.isOnlineLibrary else { return }   // 收藏页是本地过滤，不用提交
        activeSearch = q.isEmpty ? nil : q
        loadCurrent()
    }

    func loadMore() {
        guard canLoadMore, let key = currentKey, let p = cache[key] else { return }
        fetch(key: key, page: p.page + 1)
    }

    private func fetch(key: String, page: Int) {
        let isMusicKey = key.hasPrefix("music|")
        let q = String(key.split(separator: "|", maxSplits: 1).last ?? "")
        var comps = URLComponents(string: "https://api.openverse.org/v1/audio/")!
        comps.queryItems = [
            URLQueryItem(name: "q", value: q),
            URLQueryItem(name: "license", value: "cc0,pdm,by"),
            URLQueryItem(name: "page_size", value: "20"),
            URLQueryItem(name: "page", value: String(page)),
            // Freesound 那边的条目没有 category 字段，只能按来源筛；音乐走 category
            isMusicKey ? URLQueryItem(name: "category", value: "music")
                       : URLQueryItem(name: "source", value: "freesound"),
        ]
        guard let url = comps.url else { return }
        isLoading = true
        inflightKey = key
        Task {
            defer { if inflightKey == key { isLoading = false } }
            do {
                var req = URLRequest(url: url)
                req.timeoutInterval = 20
                let (data, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard currentKey == key else { return }   // 中途换了分类
                if code == 429 {
                    error = "请求太频繁了（在线库免登录每分钟 20 次、每天 200 次），稍后再试"
                    return
                }
                guard (200...299).contains(code) else { error = "加载失败（HTTP \(code)）"; return }
                let r = try JSONDecoder().decode(OpenverseResponse.self, from: data)
                var p = cache[key] ?? Page(items: [], page: 0, pageCount: 0)
                p.items += r.results.filter { n in !p.items.contains { $0.id == n.id } }
                p.page = page
                p.pageCount = r.page_count
                cache[key] = p
                results = p.items
                if !isMusicKey { translateTitles(r.results) }
            } catch {
                if currentKey == key { self.error = "加载失败：\(error.localizedDescription)" }
            }
        }
    }

    /// 收藏页按搜索框过滤
    var visibleFavorites: [OnlineAudioItem] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return favorites }
        return favorites.filter { title(for: $0).lowercased().contains(q)
            || $0.displayTitle.lowercased().contains(q)
            || ($0.creator ?? "").lowercased().contains(q) }
    }

    // MARK: 封面

    /// 只取**收藏过或下载过**的那些曲子的封面：封面也走 Openverse 的接口，
    /// 免登录每分钟只有 20 次，浏览时每条都取的话一页就把额度用光了。
    /// 取过一次就落盘，之后不再请求
    @Published private(set) var covers: [String: NSImage] = [:]
    private var coverFetching: Set<String> = []

    private static var coverDir: URL {
        let dir = downloadDir.appendingPathComponent("covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 这一条该不该显示封面、有就给
    func cover(for item: OnlineAudioItem) -> NSImage? {
        guard isFavorite(item) || isDownloaded(item) else { return nil }
        return covers[item.id]
    }

    /// 收藏 / 下载过的才取。先看盘上有没有，没有再请求一次
    func ensureCover(_ item: OnlineAudioItem) {
        guard covers[item.id] == nil, !coverFetching.contains(item.id),
              isFavorite(item) || isDownloaded(item), let src = item.coverURL else { return }
        let file = Self.coverDir.appendingPathComponent("\(item.id).jpg")
        if let img = NSImage(contentsOf: file) { covers[item.id] = img; return }
        coverFetching.insert(item.id)
        Task {
            defer { coverFetching.remove(item.id) }
            guard let (data, resp) = try? await URLSession.shared.data(from: src),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let img = NSImage(data: data) else { return }
            try? data.write(to: file)
            covers[item.id] = img
        }
    }

    // MARK: 收藏

    func isFavorite(_ item: OnlineAudioItem) -> Bool { favorites.contains { $0.id == item.id } }

    func toggleFavorite(_ item: OnlineAudioItem) {
        if let i = favorites.firstIndex(where: { $0.id == item.id }) {
            favorites.remove(at: i)
        } else {
            favorites.insert(item, at: 0)   // 新收藏的排最前
            ensureCover(item)
        }
        if let data = try? JSONEncoder().encode(favorites) { try? data.write(to: Self.favoritesURL) }
    }

    // MARK: 试听

    func togglePreview(_ item: OnlineAudioItem) {
        if playingID == item.id { stopPreview(); return }
        // 下好了就放本地文件，不再走网络
        let local = localURL(for: item)
        let src = FileManager.default.fileExists(atPath: local.path) ? local : URL(string: item.url)
        guard let url = src else { return }
        play(url, id: item.id)
    }

    /// 本地音频列表用：直接给文件试听。跟在线库共用一个播放器，点别的会把这条停掉
    func togglePreview(url: URL, id: String) {
        if playingID == id { stopPreview(); return }
        play(url, id: id)
    }

    private func play(_ url: URL, id: String) {
        stopPreview()
        let p = AVPlayer(url: url)
        player = p
        playingID = id
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.stopPreview() }
            }
        p.play()
    }

    func stopPreview() {
        player?.pause()
        player = nil
        playingID = nil
        if let o = endObserver { NotificationCenter.default.removeObserver(o) }
        endObserver = nil
    }

    // MARK: 下载 / 添加到时间轴

    func localURL(for item: OnlineAudioItem) -> URL {
        // 文件名带上 id 前 8 位：同名的两条不会互相覆盖，再下同一条也能认出来
        let safe = item.displayTitle
            .replacingOccurrences(of: #"[/\\:*?"<>|]"#, with: "_", options: .regularExpression)
            .prefix(60)
        return Self.downloadDir.appendingPathComponent("\(safe)_\(item.id.prefix(8)).mp3")
    }

    func isDownloaded(_ item: OnlineAudioItem) -> Bool {
        FileManager.default.fileExists(atPath: localURL(for: item).path)
    }

    /// 只下到本地：不进素材库、不进收藏。下完自动放一遍
    func download(_ item: OnlineAudioItem, project: ProjectState) {
        guard downloading[item.id] == nil, !isDownloaded(item), let src = URL(string: item.url) else { return }
        let dest = localURL(for: item)
        downloading[item.id] = 0
        Task {
            do {
                let (tmp, resp) = try await DownloadProgress.download(URLRequest(url: src)) { pct in
                    Task { @MainActor in
                        if self.downloading[item.id] != nil { self.downloading[item.id] = pct }
                    }
                }
                guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    try? FileManager.default.removeItem(at: tmp)
                    throw URLError(.badServerResponse)
                }
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmp, to: dest)
                downloading[item.id] = nil
                play(dest, id: item.id)
                ensureCover(item)
            } catch {
                downloading[item.id] = nil
                project.showSuccessToast(icon: "exclamationmark.triangle.fill", iconColor: .orange,
                                         title: "下载失败", subtitle: item.displayTitle)
            }
        }
    }

    /// 放到时间轴播放头处。片段得挂在素材上，所以这一步才导入素材库
    func addToTimeline(_ item: OnlineAudioItem, project: ProjectState) {
        let dest = localURL(for: item)
        guard FileManager.default.fileExists(atPath: dest.path) else { return }
        if !project.mediaAssets.contains(where: { $0.url == dest }) { project.importFile(dest) }
        guard let i = project.mediaAssets.firstIndex(where: { $0.url == dest }) else { return }
        // CC BY 要署名，存到素材上，右键素材能复制
        if item.needsCredit, project.mediaAssets[i].attribution == nil {
            project.mediaAssets[i].attribution = item.attribution
                ?? "\"\(item.displayTitle)\" by \(item.creator ?? "unknown"), \(item.licenseLabel)"
        }
        project.addToTimelineAt(project.mediaAssets[i], time: project.currentTime)
    }
}

// MARK: - 左侧导航

struct AudioLibraryNav: View {
    static let width: CGFloat = 58
    /// 连同外面那 3pt 左边距。素材宫格按它扣宽度
    static let totalWidth: CGFloat = width + 3
    /// 跟右边搜索框一样高
    static let rowHeight: CGFloat = 22
    /// 导航跟右边内容之间的间距。本地音频和在线面板共用，两边才对得齐
    static let contentGap: CGFloat = 6

    @ObservedObject private var store = OnlineAudioStore.shared
    @AppStorage("audioLibrary.fold.mine") private var foldMine = false
    @AppStorage("audioLibrary.fold.music") private var foldMusic = false
    @AppStorage("audioLibrary.fold.sfx") private var foldSfx = true

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 6) {
                group("我的", folded: $foldMine) {
                    item("本地音频", .local)
                    item("收藏", .favorites)
                }
                group("音乐库", folded: $foldMusic) {
                    ForEach(OnlineAudioStore.musicCategories) { c in item(c.name, .music(c.id)) }
                }
                group("音效库", folded: $foldSfx) {
                    ForEach(OnlineAudioStore.sfxCategories) { c in item(c.name, .sfx(c.id)) }
                }
            }
            .padding(.bottom, 12)
        }
        .frame(width: Self.width)
    }

    private func group<Content: View>(_ title: String, folded: Binding<Bool>,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Button { withAnimation(.easeOut(duration: 0.15)) { folded.wrappedValue.toggle() } } label: {
                HStack(spacing: 2) {
                    // 标题不许截成「音…」：宁可把箭头挤到边上
                    Text(title)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(Color.labelPrimary)
                        .fixedSize()
                    Spacer(minLength: 0)
                    Image(systemName: folded.wrappedValue ? "chevron.down" : "chevron.up")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundColor(Color.labelSecondary)
                }
                .padding(.horizontal, 6).frame(height: Self.rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !folded.wrappedValue {
                content()
            }
        }
    }

    private func item(_ name: String, _ s: AudioLibrarySection) -> some View {
        let on = store.section == s
        return Button { store.section = s } label: {
            Text(name)
                .font(.system(size: 10.5, weight: on ? .semibold : .regular))
                .foregroundColor(on ? Color.accent : Color.labelSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 8).frame(height: Self.rowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 右侧：收藏 / 在线分类

struct OnlineAudioPanel: View {
    @EnvironmentObject var project: ProjectState
    @ObservedObject private var store = OnlineAudioStore.shared

    private var isFavorites: Bool { store.section == .favorites }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            searchField
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.leading, AudioLibraryNav.contentGap).padding(.trailing, 10).padding(.bottom, 8)
        .onAppear { store.loadCurrent() }
        .onDisappear { store.stopPreview() }
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(nsImage: SidebarSVGIcon.load("search"))
                .renderingMode(.template)
                .resizable().aspectRatio(contentMode: .fit)
                .frame(width: 10, height: 10)
                .foregroundColor(Color.labelSecondary)
            TextField("搜索", text: $store.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(Color.labelPrimary)
                .onSubmit { store.submitSearch() }
            if !store.searchText.isEmpty {
                Button { store.searchText = ""; store.submitSearch() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 9))
                        .foregroundColor(Color.labelSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: AudioLibraryNav.rowHeight)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var hasCJK: Bool {
        (store.activeSearch ?? "").unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }

    @ViewBuilder
    private var content: some View {
        if isFavorites {
            if store.visibleFavorites.isEmpty {
                if store.favorites.isEmpty {
                    // 跟本地音频的空状态同一个样子：分类图标 + 一行字，摆在三分之一高度
                    VStack(spacing: 10) {
                        Image(nsImage: SidebarSVGIcon.load("audio"))
                            .renderingMode(.template)
                            .resizable().aspectRatio(contentMode: .fit)
                            .frame(width: 44, height: 44)
                            .foregroundColor(Color.labelSecondary.opacity(0.30))
                        Text("你还没有任何收藏")
                            .font(.system(size: 11))
                            .foregroundColor(Color.labelSecondary.opacity(0.45))
                    }
                    .modifier(PositionedAtOneThird())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    hint("没有匹配的收藏")
                }
            } else {
                list(store.visibleFavorites, paged: false)
            }
        } else if let err = store.error, store.results.isEmpty {
            hint(err, color: .orange.opacity(0.85))
        } else if store.results.isEmpty {
            if store.isLoading {
                hint("加载中…")
            } else {
                // 库是英文索引的，中文词基本搜不到
                hint(hasCJK ? "没搜到。这个库是英文的，换成英文词试试（如 雨 → rain）" : "没有结果，换个词试试")
            }
        } else {
            list(store.results, paged: true)
        }
    }

    private func list(_ items: [OnlineAudioItem], paged: Bool) -> some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 2) {
                ForEach(items) { item in
                    row(item)
                        .onAppear {
                            store.ensureCover(item)
                            if paged, item.id == items.last?.id { store.loadMore() }
                        }
                }
                if paged {
                    if store.isLoading {
                        ProgressView().controlSize(.small).padding(.vertical, 6)
                    } else if let err = store.error {
                        Text(err).font(.system(size: 10)).foregroundColor(.orange.opacity(0.85))
                            .padding(.vertical, 6)
                    }
                }
            }
        }
    }

    private func hint(_ s: String, color: Color = Color.labelSecondary) -> some View {
        Text(s)
            .font(.system(size: 11))
            .foregroundColor(color)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 12)
    }

    private func row(_ item: OnlineAudioItem) -> some View {
        OnlineAudioRow(item: item)
    }
}

// MARK: - 一行（在线库 / 收藏共用）

/// 左边播放圆钮：跟预览区传输控件同一套图标。有封面就拿封面当底（压暗一层让图标看得清），
/// 没有就是浅色圆底。本地音频列表也用它，两边长得一样
struct AudioPlayCircle: View {
    let playing: Bool
    var cover: NSImage? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(nsImage: TimelineSVGIcon.load(playing ? "pause" : "play"))
                .renderingMode(.template)
                .resizable().aspectRatio(contentMode: .fit)
                .frame(width: 10, height: 10)
                .foregroundColor(playing ? Color.accent : (cover == nil ? Color.labelPrimary : .white))
                .frame(width: 24, height: 24)
                .background {
                    if let cover {
                        Image(nsImage: cover).resizable().aspectRatio(contentMode: .fill)
                            .overlay(Color.black.opacity(0.35))
                            .clipShape(Circle())
                    } else {
                        Circle().fill(Color.white.opacity(0.08))
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(playing ? "停止" : "试听")
    }
}

/// 行尾的小图标按钮
struct AudioRowIconButton: View {
    let symbol: String
    let color: Color
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(color)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct OnlineAudioRow: View {
    let item: OnlineAudioItem
    @EnvironmentObject var project: ProjectState
    @ObservedObject private var store = OnlineAudioStore.shared
    @State private var hover = false

    var body: some View {
        let playing = store.playingID == item.id
        let downloading = store.downloading[item.id]
        HStack(spacing: 8) {
            AudioPlayCircle(playing: playing, cover: store.cover(for: item)) { store.togglePreview(item) }

            VStack(alignment: .leading, spacing: 2) {
                Text(store.title(for: item))
                    .font(.system(size: 11.5))
                    .foregroundColor(Color.labelPrimary)
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 5) {
                    Text(item.licenseLabel)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(item.needsCredit ? Color.labelSecondary : Color(hex: "#3ECF8E"))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.08)))
                    let meta = [item.durationText, item.creator ?? ""].filter { !$0.isEmpty }
                        .joined(separator: " · ")
                    Text(meta)
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundColor(Color.labelSecondary.opacity(0.7))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)

            // 收藏 / 下载两个按钮 hover 才出来；下载进行中的进度条一直显示，不然看不出在下
            if let pct = downloading {
                ProgressView(value: pct).frame(width: 24).tint(Color.accent)
            } else if hover {
                let fav = store.isFavorite(item)
                AudioRowIconButton(symbol: fav ? "heart.fill" : "heart",
                                   color: fav ? Color(hex: "#FF6B8A") : Color.labelSecondary,
                                   help: fav ? "取消收藏" : "收藏") { store.toggleFavorite(item) }
                if store.isDownloaded(item) {
                    AudioRowIconButton(symbol: "plus.circle.fill", color: Color.accent,
                                       help: "添加到时间轴（播放头处）") {
                        store.addToTimeline(item, project: project)
                    }
                } else {
                    AudioRowIconButton(symbol: "arrow.down.circle", color: Color.labelSecondary,
                                       help: "下载") { store.download(item, project: project) }
                }
            }
        }
        // 按钮不出来时也占着高度，行不会因为 hover 跳一下
        .frame(minHeight: 34)
        .padding(.horizontal, 4).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(playing ? Color.white.opacity(0.06) : (hover ? Color.white.opacity(0.04) : Color.clear)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}
