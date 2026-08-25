import SwiftUI
import AVFoundation

/// 画布上的素材浏览器（v5.1.0，B5）
///
/// 一份内容，两种外壳：
/// - **弹窗**（`CanvasAssetPicker`）：给节点换素材、从菜单进素材库时用，样式跟「设置」对齐
/// - **抽屉**（侧栏右边那块）：常驻浏览用，窄一点
///
/// 标签始终四个都显示 —— 给某个节点选素材时，不能选的那几个**置灰**而不是藏掉，
/// 藏掉的话用户会以为素材库里没有那类东西。
struct CanvasAssetBrowser: View {
    @EnvironmentObject var project: ProjectState
    /// 滚轮要跟画布抢：悬在这个面板上时归列表滚，不平移画布
    @ObservedObject var canvas: CanvasState

    /// 只让选这一类（给节点换素材时给）。nil = 随便选
    var limitTo: CanvasNode.Kind?
    /// 每行几列由外壳定：弹窗宽、抽屉窄
    var cellWidth: CGFloat = 96
    var onPick: (URL, CanvasNode.Kind) -> Void

    @State private var keyword = ""
    @State private var tab: Tab = .all
    /// 滚到哪儿了（0~1）、视口占内容多少（决定滑块多长）。
    /// 都由底层 NSScrollView 的 bounds 变化推上来
    @State private var scrollFraction: Double = 0
    @State private var viewportFraction: Double = 1
    /// 指针在不在这个面板里 —— 决定滚动条露不露面
    @State private var panelHovered = false
    /// 正在改名的那一项（按 url 认）。同一时刻只可能有一个
    @State private var renamingURL: URL?
    @State private var editName = ""
    /// 面板当前多宽 —— 一行放几个按它算（面板右边缘可以拖）
    @State private var panelWidth: CGFloat = 300

    enum Tab: String, CaseIterable {
        case all = "全部", video = "视频", audio = "音频", image = "图片"

        var assetType: AssetType? {
            switch self {
            case .all:   return nil
            case .video: return .video
            case .audio: return .audio
            case .image: return .image
            }
        }

        var nodeKind: CanvasNode.Kind? {
            switch self {
            case .all:   return nil
            case .video: return .video
            case .audio: return .audio
            case .image: return .image
            }
        }
    }


    /// 列的就是**全局素材库**那一份，跟侧边栏同源（v5.3.0 合并了元素库）
    private var items: [Item] {
        var list: [Item] = project.mediaAssets.compactMap { asset in
            guard asset.type != .subtitle,
                  let kind = CanvasSurfaceKindResolver.nodeKind(for: asset.url) else { return nil }
            return Item(url: asset.url, kind: kind, name: asset.name,
                        assetID: asset.id,
                        duration: asset.duration,
                        fileSize: asset.fileSize ?? 0,
                        date: asset.importDate ?? .distantPast)
        }
        // 不按 limitTo 过滤 —— 不能选的素材照样列出来，只是格子置灰。
        // 直接藏掉的话用户会以为素材库里没有那些东西
        if let want = tab.nodeKind { list = list.filter { $0.kind == want } }
        if !keyword.isEmpty {
            list = list.filter { $0.name.localizedCaseInsensitiveContains(keyword) }
        }
        return sorted(list)
    }

    /// 排序跟素材库侧边栏共用同一份设置（`mediaSortOrder` / `mediaSortAscending`），
    /// 那边改了这边跟着变，不另立一套。
    /// 四个维度的值都在 `Item` 上备好了，这里只管比大小
    private func sorted(_ list: [Item]) -> [Item] {
        let asc = project.mediaSortAscending
        switch project.mediaSortOrder {
        case .name:
            return list.sorted { asc ? $0.name.localizedCompare($1.name) == .orderedAscending
                                     : $0.name.localizedCompare($1.name) == .orderedDescending }
        case .duration:
            return list.sorted { asc ? $0.duration < $1.duration : $0.duration > $1.duration }
        case .importDate:
            return list.sorted { asc ? $0.date < $1.date : $0.date > $1.date }
        case .fileSize:
            return list.sorted { asc ? $0.fileSize < $1.fileSize : $0.fileSize > $1.fileSize }
        }
    }

    /// 音频没有画面，摆成网格全是一样的图标 —— 跟素材库侧边栏一样用列表
    private var showsAsList: Bool { tab == .audio }

    struct Item: Identifiable {
        var id: URL { url }
        let url: URL
        let kind: CanvasNode.Kind
        let name: String
        /// 全局素材库里的 id。缩略图 / 波形缓存也按它取
        let assetID: UUID
        /// 排序用的三个值，构造时就备好
        let duration: Double
        let fileSize: Int64
        let date: Date
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            searchRow

            if items.isEmpty {
                Spacer()
                Text(emptyHint)
                    .font(.system(size: 12))
                    .foregroundColor(Color.labelSecondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView(showsIndicators: false) {
                    // finder 必须待在 ScrollView **内容里** —— 它靠 `enclosingScrollView`
                    // 往上找，挂在 .background 上是 ScrollView 的兄弟，找不着
                    CanvasScrollViewFinder(canvas: canvas) { frac, vpFrac in
                        scrollFraction = frac
                        viewportFraction = vpFrac
                    }
                    .frame(width: 1, height: 1)
                    .opacity(0)

                    if showsAsList {
                        LazyVStack(spacing: 2) {
                            ForEach(items) { item in
                                AssetRow(item: item,
                                         enabled: limitTo == nil || item.kind == limitTo,
                                         renaming: renamingURL == item.url,
                                         editName: $editName,
                                         onCommitRename: { commitRename(item) },
                                         onRelink: { relink(item) },
                                         menu: { menu(for: item) }) {
                                    onPick(item.url, item.kind)
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                    } else {
                        // 列数按面板宽度算，夹在 2~4 之间：窄了也不挤成一列，
                        // 拖宽了也不无限加列（格子跟着变宽，一屏看得清）
                        LazyVGrid(columns: gridColumns, spacing: 12) {
                            ForEach(items) { item in
                                AssetCell(item: item,
                                          // 限定了类型时，别的类型置灰不可选
                                          enabled: limitTo == nil || item.kind == limitTo,
                                          renaming: renamingURL == item.url,
                                          editName: $editName,
                                          onCommitRename: { commitRename(item) },
                                          onRelink: { relink(item) },
                                          menu: { menu(for: item) }) {
                                    onPick(item.url, item.kind)
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                    }
                }
                // 自绘竖向滚动条，贴右边内缘。系统那条已经关掉（showsIndicators: false）
                .overlay(alignment: .trailing) {
                    CanvasVScrollBar(fraction: scrollFraction,
                                     viewportFraction: viewportFraction,
                                     isVisible: panelHovered) { frac in
                        canvas.scrollAssetPanel(toFraction: frac)
                    }
                }
            }
        }
        // 指针进面板 = 滚轮归这个列表（画布那个 monitor 按这个状态放手），
        // 同时把滚动条亮出来。用 onContinuousHover：格子之间快速划过时
        // onHover 的 exit 会丢，状态会卡在错的值上
        .onContinuousHover { phase in
            let inside: Bool
            switch phase {
            case .active: inside = true
            case .ended:  inside = false
            }
            guard inside != panelHovered else { return }
            panelHovered = inside
            canvas.assetPanelHovered = inside
        }
        // 一行放几个要按面板宽度算，面板右边缘可以拖，所以得一直盯着
        .background(
            GeometryReader { g in
                Color.clear
                    .onAppear { panelWidth = g.size.width }
                    .onChange(of: g.size.width) { _, w in panelWidth = w }
            }
        )
        .onAppear {
            // 限定类型时默认落在那个标签上，省得用户还要自己找
            if let limitTo, let t = Tab.allCases.first(where: { $0.nodeKind == limitTo }) {
                tab = t
            }
        }
        .onDisappear {
            // 面板关掉时把状态收干净，否则滚轮会一直以为指针还在面板里，画布再也推不动
            panelHovered = false
            canvas.assetPanelHovered = false
            canvas.assetPanelScroller = nil
        }
    }

    /// 一行几个：按可用宽度算，**夹在 2~4**。拖宽面板时先把格子撑大，
    /// 够放下一列了才加列；窄到极限也保底两列
    private var gridColumns: [GridItem] {
        let usable = max(0, panelWidth - 40)              // 左右各 20 内边距
        let n = Int((usable + 10) / (cellWidth + 10))     // 每列 = 格子宽 + 10 间距
        return Array(repeating: GridItem(.flexible(), spacing: 10),
                     count: min(max(n, 2), 4))
    }

    // MARK: - 右键菜单

    /// 素材库项和元素库项动的东西完全不一样，靠 `producedID` 分流：
    /// 素材库走 `ProjectState` 那套（重命名连磁盘文件、移除连片段），
    /// 元素库只动画布自己那份清单
    @ViewBuilder
    private func menu(for item: Item) -> some View {
        if FileManager.default.fileExists(atPath: item.url.path) {
            Button("添加到画布") { onPick(item.url, item.kind) }
        } else {
            Button("重新关联文件…") { relink(item) }
        }
        Button("重命名") {
            editName = item.name
            renamingURL = item.url
        }
        Button("在 Finder 中显示") {
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
        }
        Divider()
        // 跟侧边栏同一条路：有引用时先弹确认框
        Button("移除", role: .destructive) {
            if project.clipCountForAsset(item.assetID) == 0 {
                project.removeAssetAndClips(assetID: item.assetID)
            } else {
                project.pendingDeleteAssetID = item.assetID
                project.showAssetDeleteConfirm = true
            }
        }
    }

    /// 重新关联。素材库项走 `ProjectState` 那套（时间轴片段一起换），
    /// 元素库项走画布这套（元素库记录 + 卡片一起换）。
    /// 两种都要**同时**把画布上的卡片重指过去，不然卡片还挂在旧路径上
    private func relink(_ item: Item) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "请选择「\(item.name)」的新位置"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // 素材是唯一的真相源：这里一改，时间轴片段和画布卡片都会跟着好
        project.relinkAsset(id: item.assetID, newURL: url)
        project.mediaThumbnails.removeValue(forKey: item.assetID)
    }

    private func commitRename(_ item: Item) {
        defer { renamingURL = nil }
        let name = editName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != item.name else { return }
        // 连磁盘文件一起改名并锁后缀；撤销时由 reconcileAssetFiles 还原
        project.renameAsset(id: item.assetID, to: name)
    }

    private var emptyHint: String {
        keyword.isEmpty ? "素材库里还没有这类素材" : "没有匹配的素材"
    }

    /// 标签栏跟「设置」那套一致：胶囊底 + 选中态填充
    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { t in
                Button { tab = t } label: {
                    Text(t.rawValue)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(tab == t ? .white : Color.labelSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                        .background(tab == t ? Color.white.opacity(0.15) : Color.clear)
                        .clipShape(Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color.white.opacity(0.06))
        .clipShape(Capsule())
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    /// 搜索框跟素材库侧边栏那个一致
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(nsImage: SidebarSVGIcon.load("search"))
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 11, height: 11)
                .foregroundColor(Color.labelSecondary)
            TextField("搜索", text: $keyword)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(Color.labelPrimary)
            if !keyword.isEmpty {
                Button { keyword = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(Color.labelSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// 搜索 + 排序一行。排序菜单直接用素材库那个，选项和当前项都一致
    private var searchRow: some View {
        HStack(spacing: 8) {
            searchField
            Button { showSortNSMenu(project: project) } label: {
                Image(nsImage: SidebarSVGIcon.load("sort", size: 13))
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 13, height: 13)
                    .foregroundColor(Color.labelSecondary)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help("排序")
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }
}

/// 一格素材。缩略图**先定尺寸再裁切** ——
/// 只给 aspectRatio(.fill) 不裁的话，竖图会顶出格子盖住旁边那几个。
/// 宽度由 grid 的列决定（面板能拖宽），所以不再收固定 width
private struct AssetCell<Menu: View>: View {
    @EnvironmentObject var project: ProjectState
    let item: CanvasAssetBrowser.Item
    /// 这个卡片放不了的类型：压暗 + 不可点，但仍然列出来
    var enabled: Bool = true
    let renaming: Bool
    @Binding var editName: String
    let onCommitRename: () -> Void
    let onRelink: () -> Void
    @ViewBuilder let menu: () -> Menu
    let action: () -> Void

    @State private var hovering = false
    @FocusState private var nameFocused: Bool

    /// 文件还在不在。丢了要盖一层提示，跟侧边栏一样
    private var fileExists: Bool { FileManager.default.fileExists(atPath: item.url.path) }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack(alignment: .topTrailing) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06))
                        if let thumb = thumbnail {
                            // 先按格子比例定框、再 fill 裁切：竖图不会顶出去
                            Color.clear.overlay(
                                Image(nsImage: thumb)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            )
                        } else {
                            Image(nsImage: SidebarSVGIcon.load(CanvasNodeView.iconKey(for: item.kind), size: 18))
                                .renderingMode(.template)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 18, height: 18)
                                .foregroundColor(Color.labelSecondary.opacity(0.4))
                        }
                    }
                    .aspectRatio(10.0 / 7.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    // 时长角标，跟侧边栏同一个样式。元素库项的时长是异步补的，
                    // 补上之前先不显示，别挂个 00:00 在那儿
                    if item.kind == .video, item.duration > 0 {
                        Text(durationBadge(item.duration))
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.6))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .padding(4)
                    }

                    if !fileExists {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.black.opacity(0.5))
                            .overlay(
                                VStack(spacing: 4) {
                                    Image(nsImage: SidebarSVGIcon.load("toastWarn", size: 16))
                                        .renderingMode(.template)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: 16, height: 16)
                                        .foregroundColor(Color(hex: "#FF9230"))
                                    Text("素材丢失")
                                        .font(.system(size: 10))
                                        .foregroundColor(.orange)
                                }
                            )
                    }
                }
                // 丢了才出的重新关联按钮，跟侧边栏一样挂在缩略图右下角、hover 才出
                .overlay(alignment: .bottomTrailing) {
                    if !fileExists && hovering {
                        RelinkButton(action: onRelink).padding(4)
                    }
                }

                if renaming {
                    // 就地改名。跟素材库侧边栏一样：回车或失焦提交，Esc 取消
                    TextField("", text: $editName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 10))
                        .multilineTextAlignment(.center)
                        .focused($nameFocused)
                        .onAppear { nameFocused = true }
                        .onSubmit { onCommitRename() }
                        .onExitCommand { editName = item.name; onCommitRename() }
                        // 失焦也提交 —— 只认回车的话，点到别处改名就白改了
                        .onChange(of: nameFocused) { _, focused in
                            if !focused { onCommitRename() }
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.12)))
                        .frame(maxWidth: .infinity)
                } else {
                    Text(item.name)
                        .font(.system(size: 10))
                        .foregroundColor(fileExists ? Color.labelPrimary : Color.labelSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity)
                        // 名字提示跟侧边栏同一套：系统 tooltip，指到名字上才出
                        .help(item.name)
                }
            }
            .padding(4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        // hover 灰底，跟侧边栏一致（原来是给缩略图描一圈 accent 边）
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(Color.white.opacity(hovering ? 0.08 : 0)))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onHover { hovering = enabled && $0 }
        .contextMenu { menu() }
        // 元素库里的视频没进素材库，没人替它抽过帧；卡片被删掉后缓存也可能是空的。
        // 格子露面时按同一个 key 补一帧，不然这里永远只有一个视频图标
        .onAppear {
            guard item.kind == .video, project.mediaThumbnails[item.assetID] == nil else { return }
            project.loadMediaThumbnail(assetID: item.assetID, url: item.url)
        }
    }

    /// 时长角标：跟侧边栏同一个格式，超过一小时才显示小时位
    private func durationBadge(_ d: Double) -> String {
        let h = Int(d) / 3600, m = Int(d) / 60 % 60, s = Int(d) % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%02d:%02d", m, s)
    }

    /// 缩略图走 `thumbKey` 那份缓存（跟画布卡片、素材库、时间轴共用，不重复抽帧），
    /// 图片没缓存就直接读文件
    private var thumbnail: NSImage? {
        if let thumb = project.mediaThumbnails[item.assetID] { return thumb }
        if let asset = project.mediaAssets.first(where: { $0.url == item.url }),
           let thumb = project.mediaThumbnails[asset.id] { return thumb }
        return item.kind == .image ? NSImage(contentsOf: item.url) : nil
    }
}

// MARK: - 弹窗外壳

/// 从素材库挑一个（弹窗版）。标题、边距、关闭按钮都按「设置」那套来
struct CanvasAssetPicker: View {
    @EnvironmentObject var project: ProjectState
    @ObservedObject var canvas: CanvasState
    var limitTo: CanvasNode.Kind?
    var onPick: (MediaAsset?) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(limitTo == nil ? "从素材库选择" : "选择\(limitTo!.label)素材")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color.labelSecondary)
                Spacer()
                Button { onPick(nil) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color.labelSecondary)
                        .frame(width: 26, height: 26)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 8)

            CanvasAssetBrowser(canvas: canvas, limitTo: limitTo, cellWidth: 110) { url, _ in
                onPick(project.mediaAssets.first { $0.url == url })
            }
            .environmentObject(project)
        }
        .frame(width: 560, height: 480)
        .floatingPanelMaterial()
    }
}


/// 音频那种没画面的，用列表行：名称 + 时长，跟素材库侧边栏一致
private struct AssetRow<Menu: View>: View {
    @EnvironmentObject var project: ProjectState
    let item: CanvasAssetBrowser.Item
    var enabled: Bool = true
    let renaming: Bool
    @Binding var editName: String
    let onCommitRename: () -> Void
    let onRelink: () -> Void
    @ViewBuilder let menu: () -> Menu
    let action: () -> Void

    @State private var hovering = false
    /// 元素库里的音频没进素材库，取不到现成时长，自己读一次（读盘，放后台）
    @State private var localDuration: Double = 0
    @FocusState private var nameFocused: Bool

    private var fileExists: Bool { FileManager.default.fileExists(atPath: item.url.path) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    if renaming {
                        TextField("", text: $editName)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .focused($nameFocused)
                            .onAppear { nameFocused = true }
                            .onSubmit { onCommitRename() }
                            .onExitCommand { editName = item.name; onCommitRename() }
                            // 失焦也提交 —— 只认回车的话，点到别处改名就白改了
                            .onChange(of: nameFocused) { _, focused in
                                if !focused { onCommitRename() }
                            }
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.12)))
                    } else {
                        Text(item.name)
                            .font(.system(size: 12))
                            .foregroundColor(fileExists ? Color.labelPrimary : Color.labelSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(item.name)
                    }
                    if fileExists {
                        Text(durationText)
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundColor(Color.labelSecondary)
                    } else {
                        Text("素材丢失")
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "#FF9230"))
                    }
                }
                Spacer(minLength: 0)
                // 丢失状态必须看得见，给个警示图标（侧边栏同款）；hover 时换成关联按钮
                if !fileExists {
                    if hovering {
                        RelinkButton(action: onRelink)
                    } else {
                        Image(nsImage: SidebarSVGIcon.load("toastWarn", size: 14))
                            .renderingMode(.template)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 14, height: 14)
                            .foregroundColor(Color(hex: "#FF9230"))
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(hovering && enabled ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .onHover { hovering = enabled && $0 }
        .contextMenu { menu() }
        .task(id: item.url) {
            guard libraryDuration <= 0, localDuration <= 0 else { return }
            let url = item.url
            let d = await Task.detached { AVURLAsset(url: url).duration.seconds }.value
            if d.isFinite, d > 0 { localDuration = d }
        }
    }

    private var libraryDuration: Double {
        project.mediaAssets.first { $0.id == item.assetID }?.duration ?? 0
    }

    private var durationText: String {
        let d = libraryDuration > 0 ? libraryDuration : localDuration
        guard d > 0 else { return "--:--" }
        return String(format: "%02d:%02d", Int(d) / 60, Int(d) % 60)
    }
}

// MARK: - 滚动（面板自己的滚轮 + 自绘竖向滚动条）

/// 找出 SwiftUI `ScrollView` 底下那个真实的 NSScrollView。
///
/// SwiftUI 既不给滚动位置、也没有程序化滚到某个偏移的口子，只能顺着视图链挖
/// （跟时间轴那条横向滚动条同一套路，见 `TimelineScrollViewFinder`）。
/// 挖到之后交给 `CanvasState` 保管：画布的滚轮监听要用它，拖滚动条也要用它。
///
/// ⚠️ 必须放在 ScrollView 的**内容**里，`enclosingScrollView` 才找得到。
private struct CanvasScrollViewFinder: NSViewRepresentable {
    let canvas: CanvasState
    let onScroll: (Double, Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onScroll: onScroll) }

    func makeNSView(context: Context) -> NSView {
        let v = FinderView()
        v.coordinator = context.coordinator
        v.canvas = canvas
        return v
    }

    /// 内容变了（切标签、搜索、缩略图到位）也要重算一遍：
    /// 内容高度变化不会发 contentView 的 boundsDidChange，光靠通知会漏
    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onScroll = onScroll
        context.coordinator.refresh()
    }

    final class Coordinator: NSObject {
        var onScroll: (Double, Double) -> Void
        private var observer: Any?
        private weak var scrollView: NSScrollView?

        init(onScroll: @escaping (Double, Double) -> Void) { self.onScroll = onScroll }
        deinit { if let o = observer { NotificationCenter.default.removeObserver(o) } }

        func observe(_ sv: NSScrollView) {
            scrollView = sv
            sv.contentView.postsBoundsChangedNotifications = true
            // queue 传 nil = 在发通知的线程上同步回调，跟时间轴那条一致：
            // 异步派发会让滚动位置和内容尺寸错开一帧，滑块会抖
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: sv.contentView, queue: nil
            ) { [weak self] _ in
                if Thread.isMainThread {
                    self?.update()
                } else {
                    DispatchQueue.main.async { self?.update() }
                }
            }
            update()
        }

        /// SwiftUI 刷新时调。视图第一次上屏可能还没找到 scrollView，这里不做别的
        func refresh() { update() }

        private func update() {
            guard let sv = scrollView, let doc = sv.documentView else { return }
            let contentH = doc.frame.height
            let viewH = sv.contentView.bounds.height
            guard contentH > 0, viewH > 0 else { return }
            let vpFrac = min(viewH / contentH, 1.0)
            let maxScroll = contentH - viewH
            let frac = maxScroll > 0 ? Double(sv.contentView.bounds.origin.y / maxScroll) : 0
            onScroll(min(max(frac, 0), 1), Double(vpFrac))
        }
    }

    private final class FinderView: NSView {
        weak var canvas: CanvasState?
        weak var coordinator: Coordinator?
        private var didFind = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !didFind, window != nil, let sv = enclosingScrollView else { return }
            didFind = true
            canvas?.assetPanelScroller = sv
            coordinator?.observe(sv)
        }
    }
}

/// 面板右侧那条自绘竖向滚动条。
///
/// 交互规则照抄时间轴底部那条（`TimelineScrollBar`），只是转了 90°：
/// - **默认细（6pt）**，指针进到滚动条这条竖带里就**变粗（10pt）**
/// - 命中区固定 22pt 宽，视觉细条在里面居中 —— 只有 6pt 可点的话鼠标差几个像素就落空
/// - hover 判定挂在**固定尺寸**的命中带上，绝不能挂在会变的 `.frame(width:)` 上：
///   那样动画期间反复 hit test，onHover 来回翻又驱动动画，指针不动也会一粗一细
private struct CanvasVScrollBar: View {
    let fraction: Double
    let viewportFraction: Double
    /// 指针在不在面板里 —— 进面板就露面（用户要的「hover 到窗口就出滚动条」）
    let isVisible: Bool
    let onDrag: (Double) -> Void

    @State private var isDragging = false
    @State private var dragStartFraction: Double = 0
    /// 指针是否落在滚动条自己身上。没有这个会来回闪：滚动条一显示就开始接事件，
    /// 把面板的 hover 挡住 → 面板以为指针走了 → 隐藏 → 事件又落回面板 → 再显示
    @State private var selfHovered = false

    private let barWThin: CGFloat = 6
    private let barW: CGFloat = 10
    private let hitW: CGFloat = 22
    /// 上下留白，别顶到面板边缘
    private let inset: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let trackH = geo.size.height - inset * 2
            let knobH = max(trackH * viewportFraction, 30)
            let maxOffset = max(trackH - knobH, 1)
            let knobY = inset + fraction * maxOffset
            let thick = selfHovered || isDragging
            let knobW = thick ? barW : barWThin

            ZStack(alignment: .top) {
                // 轨道背景也接事件：点空白处直接把滑块挪过去（标准滚动条行为）
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: knobW, height: trackH)
                    .animation(.easeOut(duration: 0.12), value: knobW)
                    .frame(width: hitW, height: trackH)
                    .contentShape(Rectangle())
                    .offset(y: inset)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                onDrag(((v.location.y - knobH / 2) / maxOffset).clamped(to: 0...1))
                            }
                    )

                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(isDragging ? 0.55 : 0.35))
                    .frame(width: knobW, height: knobH)
                    .animation(.easeOut(duration: 0.12), value: knobW)
                    // 外层撑到 hitW 再配 contentShape：视觉是 6/10pt 的条在 22pt 里居中，
                    // 可点范围始终是这 22pt
                    .frame(width: hitW, height: knobH)
                    .contentShape(Rectangle())
                    .offset(y: knobY)
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { v in
                                if !isDragging {
                                    isDragging = true
                                    dragStartFraction = fraction
                                }
                                let delta = v.translation.height / maxOffset
                                onDrag((dragStartFraction + delta).clamped(to: 0...1))
                            }
                            .onEnded { _ in isDragging = false }
                    )
            }
            .frame(width: hitW)
            // 只驱动 opacity / allowsHitTesting，不改任何布局尺寸
            .onHover { selfHovered = $0 }
            .opacity(show ? 1 : 0)
            .allowsHitTesting(show)
            .animation(.easeInOut(duration: show ? 0.15 : 0.3), value: show)
        }
        .frame(width: hitW)
        // 内容不足一屏就没有滚动条这回事
        .opacity(viewportFraction >= 1 ? 0 : 1)
        .allowsHitTesting(viewportFraction < 1)
    }

    private var show: Bool { isVisible || selfHovered || isDragging }
}

/// 「重新关联」小圆钮。素材丢失时才出现，跟侧边栏那颗同一个图标
private struct RelinkButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(nsImage: SidebarSVGIcon.load("relink", size: 11))
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 11, height: 11)
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.black.opacity(hovering ? 0.85 : 0.6)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("重新关联文件…")
    }
}
