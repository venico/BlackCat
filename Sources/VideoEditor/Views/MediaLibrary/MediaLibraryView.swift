import SwiftUI
import UniformTypeIdentifiers

struct MediaLibraryView: View {
    @EnvironmentObject private var project: ProjectState
    /// 拖入接收区按窗口登记，多窗口时各认各的
    @Environment(\.windowID) private var windowID
    @State private var isDragOver = false

    private var isTransitionTab: Bool { project.mediaLibraryTab == "transition" }
    private var isAITab: Bool { project.mediaLibraryTab == "ai" }
    /// 素材库里的分类（六个标签页）
    private var isTextTab: Bool { project.mediaLibraryTab == "library" && project.libraryCategory == "text" }
    private var isShapeTab: Bool { project.mediaLibraryTab == "library" && project.libraryCategory == "shape" }

    /// 只有视频和图片有缩略图可看，能在两种视图之间切
    private var canSwitchViewMode: Bool {
        selectedAssetType == .video || selectedAssetType == .image
    }

    /// 素材库里六个标签页，按用户定的顺序
    private static let libraryCategories = ["video", "audio", "image", "subtitle", "text", "shape"]
    /// 「效果」栏下的四个分类。滤镜、特效、调节先占位
    private static let effectCategories = ["effTransition", "effFilter", "effEffect", "effAdjust"]

    private var selectedAssetType: AssetType {
        switch project.libraryCategory {
        case "audio": return .audio
        case "image": return .image
        case "subtitle": return .subtitle
        default: return .video
        }
    }

    private var filteredAssets: [MediaAsset] {
        var result = project.mediaAssets.filter { $0.type == selectedAssetType }
        let q = project.mediaSearchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            result = result.filter { $0.name.lowercased().contains(q) }
        }
        let asc = project.mediaSortAscending
        switch project.mediaSortOrder {
        case .name:
            result.sort { asc ? $0.name.localizedCompare($1.name) == .orderedAscending
                              : $0.name.localizedCompare($1.name) == .orderedDescending }
        case .duration:
            result.sort { asc ? $0.duration < $1.duration : $0.duration > $1.duration }
        case .importDate:
            result.sort { asc ? ($0.importDate ?? .distantPast) < ($1.importDate ?? .distantPast)
                              : ($0.importDate ?? .distantPast) > ($1.importDate ?? .distantPast) }
        case .fileSize:
            result.sort { asc ? ($0.fileSize ?? 0) < ($1.fileSize ?? 0)
                              : ($0.fileSize ?? 0) > ($1.fileSize ?? 0) }
        }
        return result
    }

    private func countFor(_ type: AssetType) -> Int {
        project.mediaAssets.filter { $0.type == type }.count
    }

    var body: some View {
        HStack(spacing: 0) {
            verticalTabBar
            if isAITab {
                AIChatPanel()
            } else {
            VStack(spacing: 0) {
            // Section header
            HStack {
                Text(isTransitionTab ? "效果" : "素材库")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color.labelSecondary)
                    .textCase(.uppercase)
                Spacer()
                // 转场/文字/图形面板没有素材可清，不显示按钮
                if let type = project.currentLibraryAssetType {
                    MediaToolBtn(svgName: "clear",
                                 enabled: project.mediaAssets.contains { $0.type == type },
                                 help: "清空\(type.label)素材") {
                        project.showClearLibraryConfirm = true
                    }
                }
                MediaToolBtn(svgName: "refresh", help: "刷新素材库") {
                    project.refreshMediaLibrary()
                }
            }
            .padding(.leading, 3)
            .padding(.trailing, 10)
            .padding(.top, 8)
            .padding(.bottom, 8)

            // 六个分类标签页。样式跟画布素材库那套一致：胶囊底 + 选中态填充
            if isTransitionTab {
                effectTabBar
            } else {
                libraryTabBar
            }

            // Search + Sort bar
            if !isTransitionTab && !isTextTab && !isShapeTab && !isAITab {
                HStack(spacing: 4) {
                    HStack(spacing: 4) {
                        Image(nsImage: SidebarSVGIcon.load("search"))
                            .renderingMode(.template)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 10, height: 10)
                            .foregroundColor(Color.labelSecondary)
                        TextField("搜索", text: $project.mediaSearchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundColor(Color.labelPrimary)
                        if !project.mediaSearchText.isEmpty {
                            Button { project.mediaSearchText = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 9))
                                    .foregroundColor(Color.labelSecondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                    // 缩略图 / 列表切换。一个按钮循环切，图标显示**当前**是哪种。
                    // 音频和字幕没有画面，不给这个按钮
                    if canSwitchViewMode {
                        MediaToolBtn(svgName: project.mediaGridMode ? "gridView" : "listView",
                                     help: project.mediaGridMode ? "缩略图（点击切列表）"
                                                                 : "列表（点击切缩略图）") {
                            project.mediaGridMode.toggle()
                        }
                    }
                    MediaToolBtn(svgName: "sort", help: "排序") {
                        showSortNSMenu(project: project)
                    }
                }
                .padding(.leading, 3).padding(.trailing, 10)
                .padding(.bottom, 6)
            }

            // Asset list + drag-drop target
            ZStack {
                if isShapeTab {
                    ShapePanel()
                } else if isTextTab {
                    TextLayerPanel()
                } else if isTransitionTab {
                    switch project.effectCategory {
                    case "effTransition": TransitionPanel()
                    case "effFilter": FilterPanel()
                    case "effAdjust": AdjustPanel()
                    default: EffectPanel()
                    }
                } else if filteredAssets.isEmpty {
                    emptyState
                } else {
                    ScrollView(showsIndicators: false) {
                        // 缩略图两列 / 列表一条条。只有**视频和图片**能切，
                        // 音频和字幕固定列表
                        if project.mediaGridMode, canSwitchViewMode {
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 4),
                                                GridItem(.flexible(), spacing: 4)], spacing: 4) {
                                ForEach(filteredAssets) { asset in
                                    AssetRow(assetID: asset.id)
                                }
                            }
                            .padding(.leading, 3).padding(.trailing, 10)
                            .padding(.bottom, 8)
                        } else {
                            VStack(spacing: 2) {
                                ForEach(filteredAssets) { asset in
                                    AssetRow(assetID: asset.id)
                                }
                            }
                            .padding(.leading, 3).padding(.trailing, 10)
                            .padding(.bottom, 8)
                        }
                    }
                }

                // 拖入反馈：整块素材区染个底色，不加描边也不加文字提示
                if isDragOver {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.accent.opacity(0.06))
                        .allowsHitTesting(false)
                }
            }
            // 把这块登记成文件拖入的接收区，drop 由宿主统一收了再按坐标分发过来。
            // 这里不能用 SwiftUI 的 .onDrop——实测收不到 Finder 拖拽，原因见 FileDropRouter
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { registerDropZone(g.frame(in: .global)) }
                    // 侧栏能拖宽、窗口能缩放、切 tab 也会变，位置得跟着更新
                    .onChange(of: g.frame(in: .global)) { _, r in registerDropZone(r) }
            })

            Spacer()
            }
            } // else (non-AI tabs)
        }
        // 标签页一变就核一次登记：AI 那条排在素材区前面，漏撤会把素材区的拖入吃掉
        .onAppear { syncAIDropZone() }
        .onChange(of: project.mediaLibraryTab) { _, _ in syncAIDropZone() }
    }

    /// 切走 AI 标签页时撤掉聊天区的拖入登记。
    ///
    /// **不能只靠 AIChatPanel 的 onDisappear**：那条登记排在素材区**前面**
    /// （聊天卡片浮在素材区上面，得优先），一旦漏撤，拖到素材区的文件会被
    /// 聊天区收走当附件 —— 而那时聊天区不可见，看着就是「没高亮、导不进去」
    private func syncAIDropZone() {
        if !isAITab { FileDropRouter.unregister(windowID, kind: .aiChat) }
    }

    private func registerDropZone(_ rect: CGRect) {
        FileDropRouter.register(windowID, rect: rect,
                                onFiles: { urls in project.importFiles(urls) },
                                onTargetChange: { isDragOver = $0 })
    }

    // 左侧竖排图标标签栏
    private var verticalTabBar: some View {
        VStack(spacing: 4) {
            // AI 生成排第一（进软件默认选中它），素材库第二。
            // 视频/音频/图片/字幕/文字/图形原来各占一个图标，现在并进素材库当标签页。
            // **转场留着**：它不是素材，是拖到片段上的效果，没并进去
            tabBtnAI()
            tabBtnSVG("library", icon: "folderFill")
            tabBtnSVG("transition")
            Spacer()
            importExportMenuBtn
        }
        .padding(.top, 10)
        .padding(.bottom, 14)
        .padding(.horizontal, 6)
        .frame(minWidth: 44, maxWidth: 44, alignment: .center)
        .frame(maxHeight: .infinity)
    }

    /// 素材库里的六个分类标签页。跟画布素材库那套一个样式：胶囊底 + 选中态填充。
    /// 六个挤在窄侧栏里，字号和内边距都收紧一档
    private var libraryTabBar: some View {
        tabBar(Self.libraryCategories, selection: $project.libraryCategory)
    }

    /// 「效果」栏的分类标签
    private var effectTabBar: some View {
        tabBar(Self.effectCategories, selection: $project.effectCategory)
    }

    private func tabBar(_ items: [String], selection: Binding<String>) -> some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.self) { cat in
                let isOn = selection.wrappedValue == cat
                Button { selection.wrappedValue = cat } label: {
                    Text(tabName(cat))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(isOn ? .white : Color.labelSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 22)
                        .background(isOn ? Color.white.opacity(0.15) : Color.clear)
                        .clipShape(Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color.white.opacity(0.06))
        .clipShape(Capsule())
        .padding(.leading, 3).padding(.trailing, 10)
        .padding(.bottom, 8)
    }

    /// 还没做的那几个分类
    private var effectPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 22))
                .foregroundColor(Color.labelSecondary.opacity(0.35))
            Text("\(tabName(project.effectCategory))即将上线")
                .font(.system(size: 11))
                .foregroundColor(Color.labelSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func tabName(_ tab: String) -> String {
        switch tab {
        case "video": return "视频"
        case "audio": return "音频"
        case "image": return "图片"
        case "subtitle": return "字幕"
        case "transition": return "效果"
        case "effTransition": return "转场"
        case "effFilter": return "滤镜"
        case "effEffect": return "特效"
        case "effAdjust": return "调节"
        case "text": return "文字"
        case "shape": return "图形"
        case "library": return "素材库"
        case "ai": return "AI 创作"
        default: return ""
        }
    }

    @ViewBuilder
    private func tabBtnSVG(_ tab: String, icon: String? = nil) -> some View {
        let isActive = project.mediaLibraryTab == tab
        Button { project.mediaLibraryTab = tab } label: {
            Image(nsImage: SidebarSVGIcon.load(icon ?? tab))
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
                .foregroundColor(isActive ? .white : Color.labelSecondary)
                .frame(width: 30, height: 30)
                .background(isActive ? Color.white.opacity(0.15) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(tabName(tab))
    }

    @ViewBuilder
    private func tabBtnAI() -> some View {
        let isActive = project.mediaLibraryTab == "ai"
        Button { project.mediaLibraryTab = "ai" } label: {
            Image(nsImage: SidebarSVGIcon.load("ai"))
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
                .foregroundColor(isActive ? .white : Color.labelSecondary)
                .frame(width: 30, height: 30)
                .background(isActive ? Color.white.opacity(0.15) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help("AI 创作")
    }

    private var emptyState: some View {
        // 图标直接复用左侧标签栏那套 SVG（同一个 key），只是放大。
        // 原来这里是 SF Symbols，跟标签栏的自绘图标不是一套，形状对不上
        VStack(spacing: 10) {
            // 空状态图标跟着**分类**走（素材库那栏的六个标签），不是侧边栏那一栏
            Image(nsImage: SidebarSVGIcon.load(project.libraryCategory))
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 44, height: 44)
                .foregroundColor(Color.labelSecondary.opacity(0.30))
            Text("拖入文件或点击导入")
                .font(.system(size: 11))
                .foregroundColor(Color.labelSecondary.opacity(0.45))
        }
        // 摆在空白区上方三分之一处，不居中——居中的话整组图文会掉到视觉重心以下，
        // 素材区又高又窄，看着像沉在底下
        .modifier(PositionedAtOneThird())
    }

    /// 把内容摆到容器高度 1/3 的位置（水平居中）
    // 导入/导出合并菜单按钮
    private var importExportMenuBtn: some View {
        Button {
            let menu = NSMenu()
            let importItem = NSMenuItem(title: "导入素材", action: #selector(NSApp.sendAction(_:to:from:)), keyEquivalent: "")
            importItem.image = SidebarSVGIcon.load("importFile", size: 14)
            importItem.isEnabled = project.projectFileURL != nil
            importItem.target = nil
            importItem.representedObject = "import" as NSString
            let exportItem = NSMenuItem(title: "导出 MP4", action: #selector(NSApp.sendAction(_:to:from:)), keyEquivalent: "")
            exportItem.image = SidebarSVGIcon.load("exportFile", size: 14)
            exportItem.isEnabled = project.projectFileURL != nil
            exportItem.representedObject = "export" as NSString
            menu.addItem(importItem)
            menu.addItem(exportItem)
            ImportExportMenuHandler.shared.project = project
            importItem.target = ImportExportMenuHandler.shared
            importItem.action = #selector(ImportExportMenuHandler.handleImport)
            exportItem.target = ImportExportMenuHandler.shared
            exportItem.action = #selector(ImportExportMenuHandler.handleExport)
            if let event = NSApp.currentEvent {
                NSMenu.popUpContextMenu(menu, with: event, for: NSApp.keyWindow?.contentView ?? NSView())
            }
        } label: {
            Image(nsImage: SidebarSVGIcon.load("importExport"))
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
                .foregroundColor(Color.labelSecondary)
                .frame(width: 30, height: 30)
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help("导入 / 导出")
    }
}


// MARK: - Import/Export Menu Handler

private class ImportExportMenuHandler: NSObject {
    static let shared = ImportExportMenuHandler()
    weak var project: ProjectState?

    @objc func handleImport() {
        guard let project = project, project.projectFileURL != nil else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = []
        panel.begin { r in
            guard r == .OK else { return }
            project.importFiles(panel.urls)
        }
    }

    @objc func handleExport() {
        project?.showExportSheet = true
    }
}

// MARK: - Asset Row

private struct AssetRow: View {
    @EnvironmentObject private var project: ProjectState
    let assetID: UUID
    @State private var hovered = false
    @State private var editName = ""
    @State private var editingAsset = false
    @FocusState private var nameFocused: Bool

    private var isRenaming: Bool { project.renamingAssetID == assetID }

    /// 原位输入框：Enter 或失焦（点素材区空白）确认，Esc 取消
    private func nameEditor(fontSize: CGFloat) -> some View {
        TextField("", text: $editName)
            .textFieldStyle(.plain)
            .font(.system(size: fontSize))
            .foregroundColor(Color.labelPrimary)
            .focused($nameFocused)
            .onAppear {
                editName = asset.name
                editingAsset = true
                DispatchQueue.main.async { nameFocused = true }
            }
            .onSubmit { commitRename() }
            .onChange(of: nameFocused) { f in if !f { commitRename() } }
            .onDisappear { commitRename() }
            .onExitCommand {                                   // Esc 取消
                editingAsset = false
                project.renamingAssetID = nil
            }
    }

    private func commitRename() {
        guard editingAsset else { return }
        editingAsset = false
        project.renameAsset(id: assetID, to: editName)
        project.renamingAssetID = nil
    }

    private var asset: MediaAsset {
        project.mediaAssets.first(where: { $0.id == assetID }) ?? MediaAsset(url: URL(fileURLWithPath: "/"), name: "?", type: .video)
    }

    var body: some View {
        Group {
            // 视频和图片跟着**视图模式**走；音频和字幕没有画面，
            // 摆成网格全是一样的占位图标，没意义 —— 固定用列表
            if project.mediaGridMode, asset.type == .video || asset.type == .image {
                videoAssetCard
            } else {
                normalAssetRow
            }
        }
        // 内容不贴着底色边缘 —— 音频和字幕没有封面打头，标题会直接顶到边上
        .padding(.leading, 4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(hovered ? Color.white.opacity(0.08) : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onDrag {
            guard asset.fileExists else { return NSItemProvider() }
            return NSItemProvider(object: asset.id.uuidString as NSString)
        }
        .onHover { hovered = $0 }
        .gesture(TapGesture(count: 2).onEnded {
            if asset.fileExists { project.addToTimeline(asset) } else { relinkAsset() }
        })
        .contextMenu {
            if asset.fileExists {
                Button("添加到时间轴") { project.addToTimeline(asset) }
                Button("添加到 AI 参考") { addToAIReference() }
            }
            if !asset.fileExists {
                Button("重新关联文件…") { relinkAsset() }
            }
            Button("重命名") { project.renamingAssetID = assetID }
            if asset.fileExists {
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([asset.url])
                }
            }
            Divider()
            Button("移除", role: .destructive) { confirmDeleteAsset() }
        }
    }

    // MARK: Video asset card — thumbnail on top, name below

    private var videoAssetCard: some View {
        VStack(spacing: 0) {
            // Thumbnail
            ZStack(alignment: .topTrailing) {
                if let thumb = project.mediaThumbnails[asset.id] {
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .aspectRatio(4.0/3.0, contentMode: .fit)
                        .overlay(
                            Image(nsImage: thumb)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.06))
                        .aspectRatio(4.0/3.0, contentMode: .fit)
                        .overlay(
                            Image(systemName: asset.type == .image ? "photo" : "film")
                                .font(.system(size: 22, weight: .ultraLight))
                                .foregroundColor(Color.labelSecondary.opacity(0.3))
                        )
                }
                // Duration badge
                if asset.duration > 0 {
                    Text(fmtDur(asset.duration))
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .padding(4)
                }
                // Missing overlay
                if !asset.fileExists {
                    RoundedRectangle(cornerRadius: 6)
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
            .overlay(alignment: .bottomTrailing) {
                if hovered {
                    HStack(spacing: 2) {
                        if asset.fileExists {
                            videoMiniBtn(icon: "plus.circle") { project.addToTimeline(asset) }
                        } else {
                            videoMiniBtn(icon: "arrow.triangle.2.circlepath", svgName: "relink") { relinkAsset() }
                        }
                        videoMiniBtn(icon: "trash") { confirmDeleteAsset() }
                    }
                    .padding(4)
                }
            }

            // Name
            Group {
                if isRenaming {
                    nameEditor(fontSize: 11)
                } else {
                    Text(asset.name)
                        .font(.system(size: 11))
                        .foregroundColor(asset.fileExists ? Color.labelPrimary : Color.labelSecondary)
                        .lineLimit(1)
                        .help(asset.name)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.vertical, 5)
        }
        .padding(4)
    }

    // MARK: Normal asset row — audio / subtitle

    /// 字幕和音频的格式标签：文字就是扩展名本身，每种格式一个颜色。
    /// 视频和图片有封面可认，不挂标签
    private var formatTag: (text: String, color: Color)? {
        guard asset.type == .subtitle || asset.type == .audio else { return nil }
        let ext = asset.url.pathExtension.uppercased()
        guard !ext.isEmpty else { return nil }
        let color: Color
        switch ext {
        // 字幕
        case "SRT":  color = Color(hex: "#7B6FC4")
        case "ASS", "SSA": color = Color(hex: "#C4708F")
        case "VTT":  color = Color(hex: "#5B8FF9")
        case "LRC":  color = Color(hex: "#3F8F6B")
        case "TXT":  color = Color(hex: "#8A8F9A")
        // 音频
        case "MP3":  color = Color(hex: "#5DB85D")
        case "WAV":  color = Color(hex: "#3DBFBA")
        case "M4A", "AAC": color = Color(hex: "#E8A54B")
        case "FLAC": color = Color(hex: "#9B6FD4")
        case "AIFF", "AIF": color = Color(hex: "#D4668E")
        case "OGG", "OPUS": color = Color(hex: "#FF9F43")
        default:     color = Color(hex: "#8A8F9A")
        }
        return (ext, color)
    }

    /// 名字，前面内联一个格式标签
    private var titleWithTag: Text {
        guard let tag = formatTag,
              let img = FormatTagImage.image(text: tag.text, color: tag.color)
        else { return Text(breakableName) }
        return Text(Image(nsImage: img)).baselineOffset(-1) + Text(" " + breakableName)
    }

    /// 给长文件名塞软换行点（下划线、连字符、点后面各加一个零宽空格）。
    ///
    /// `Think_Different_Crazy_Ones` 这种整串没有空格的名字算**一个不可断的词**，
    /// 第一行剩下的宽度放不下它就整体挪到第二行，把标签孤零零留在上面一行。
    /// 零宽空格本身不显示、也不进文件名，只是给排版一个可以断开的位置
    private var breakableName: String {
        var out = ""
        for ch in asset.name {
            out.append(ch)
            if ch == "_" || ch == "-" || ch == "." { out.append("\u{200B}") }
        }
        return out
    }

    private var normalAssetRow: some View {
        // spacing 0：名字长到撑满时 Spacer 压到 0，行内不再有任何死间距，
        // 名字能一直排到按钮跟前（按钮自己的 padding 就是视觉间隔）
        HStack(spacing: 0) {
            // 视频和图片在列表视图里带一张**正方形**小封面，一眼认得出是哪条；
            // 音频和字幕没有画面，不占这个位置
            if asset.type == .video || asset.type == .image {
                ZStack {
                    RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.06))
                    if let thumb = project.mediaThumbnails[asset.id] {
                        Color.clear.overlay(
                            Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                        )
                    } else {
                        Image(systemName: asset.type == .image ? "photo" : "film")
                            .font(.system(size: 12, weight: .ultraLight))
                            .foregroundColor(Color.labelSecondary.opacity(0.35))
                    }
                }
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .padding(.trailing, 6)
            }
            // 正常状态不再放类型图标：音频/字幕列表本来就按标签页分好了类，
            // 图标提供不了额外信息，却白占宽度，名字长的素材少显示好几个字。
            // 丢失状态仍要图标——那是必须看见的警示
            if !asset.fileExists {
                Image(nsImage: SidebarSVGIcon.load("toastWarn", size: 14))
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
                    .foregroundColor(Color(hex: "#FF9230"))
                    .frame(width: 20)
            }

            VStack(alignment: .leading, spacing: 2) {
                if isRenaming {
                    nameEditor(fontSize: 12)
                } else {
                    // 格式标签**内联进文字里**（渲染成图片当字符用），不是并排的两个视图。
                    // 并排的话名字换到第二行会缩在标签右边；内联之后第二行顶到标签左边缘
                    titleWithTag
                        .font(.system(size: 12))
                        .foregroundColor(asset.fileExists ? Color.labelPrimary : Color.labelSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(asset.name)
                }

                if !asset.fileExists {
                    Text("素材丢失")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "#FF9230"))
                } else if asset.duration > 0 {
                    Text(fmtDur(asset.duration))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundColor(Color.labelSecondary)
                }
            }

            Spacer()

            if hovered {
                HStack(spacing: 2) {
                    if asset.fileExists {
                        miniBtn(icon: "plus.circle") { project.addToTimeline(asset) }
                    } else {
                        miniBtn(icon: "arrow.triangle.2.circlepath", svgName: "relink") { relinkAsset() }
                    }
                    miniBtn(icon: "trash") { confirmDeleteAsset() }
                }
            }
        }
        .padding(.leading, 3).padding(.trailing, 10)
        .padding(.vertical, 7)
    }

    private func confirmDeleteAsset() {
        if project.clipCountForAsset(asset.id) == 0 {
            project.removeAssetAndClips(assetID: asset.id)
        } else {
            project.pendingDeleteAssetID = asset.id
            project.showAssetDeleteConfirm = true
        }
    }

    /// 加进 AI 参考。不跳转标签页，状态存在 AIVideoService 上，切过去时还在
    private func addToAIReference() {
        let service = AIVideoService.shared
        switch service.addToReference(url: asset.url) {
        case .added:
            let target = (service.selectedProvider.category == .video && service.imageMode == .frames) ? "首尾帧" : "参考内容"
            project.showSuccessToast(icon: "sparkles", iconColor: .purple, title: "已添加到 AI \(target)", subtitle: asset.name.truncatedFileName())
        case .duplicate:
            project.showSuccessToast(icon: "exclamationmark.triangle", iconColor: .orange, title: "已经添加过了", subtitle: asset.name.truncatedFileName())
        case .unsupportedType:
            project.showSuccessToast(icon: "exclamationmark.triangle", iconColor: .orange, title: "不支持当前素材类型", subtitle: "当前占位不接受该类型素材")
        case .limitReached(let msg):
            project.showSuccessToast(icon: "exclamationmark.triangle", iconColor: .orange, title: "无法添加", subtitle: msg)
        }
    }

    private func relinkAsset() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.message = "请选择「\(asset.name)」的新位置"
        panel.begin { r in
            guard r == .OK, let url = panel.url else { return }
            project.relinkAsset(id: asset.id, newURL: url)
        }
    }

    private func fmtDur(_ d: Double) -> String {
        let h = Int(d)/3600; let m = Int(d)/60%60; let s = Int(d)%60
        return h > 0 ? String(format:"%d:%02d:%02d",h,m,s) : String(format:"%02d:%02d",m,s)
    }

    @ViewBuilder
    private func miniBtn(icon: String, svgName: String? = nil,
                         action: @escaping () -> Void) -> some View {
        MiniBtnView(icon: icon, svgName: svgName, action: action)
    }

    @ViewBuilder
    private func videoMiniBtn(icon: String, svgName: String? = nil,
                              action: @escaping () -> Void) -> some View {
        VideoMiniBtnView(icon: icon, svgName: svgName, action: action)
    }
}

private struct MiniBtnView: View {
    let icon: String
    /// 传了就用自绘 SVG，否则退回 SF Symbol
    var svgName: String? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if let svgName {
                    Image(nsImage: SidebarSVGIcon.load(svgName, size: 12))
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .light))
                }
            }
                .foregroundColor(Color.labelSecondary)
                .padding(4)          // 原来是固定 26×26；12pt 图标 + 4 内边距 = 20pt
                .background(hovering ? Color.white.opacity(0.12) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct VideoMiniBtnView: View {
    let icon: String
    /// 传了就用自绘 SVG，否则退回 SF Symbol
    var svgName: String? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if let svgName {
                    Image(nsImage: SidebarSVGIcon.load(svgName, size: 13))
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 13, height: 13)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: hovering ? .medium : .light))
                }
            }
                .foregroundColor(Color.white.opacity(hovering ? 1.0 : 0.80))
                .frame(width: 26, height: 26)
                .shadow(color: .black.opacity(0.6), radius: 3, x: 0, y: 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Import / Export Buttons

private struct ImportButton: View {
    @EnvironmentObject private var project: ProjectState

    var body: some View {
        Button { openPicker() } label: {
            HStack {
                Spacer()
                Text("导入素材")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            .foregroundColor(hasProject ? Color.labelPrimary : Color.labelSecondary.opacity(0.5))
            .frame(height: 36)
            .background(Color.white.opacity(hasProject ? 0.08 : 0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(!hasProject)
    }

    private var hasProject: Bool { project.projectFileURL != nil }

    private func openPicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = []  // 不限制，由 importFile 做格式过滤
        panel.begin { r in
            guard r == .OK else { return }
            project.importFiles(panel.urls)
        }
    }
}

private struct ExportButton: View {
    @EnvironmentObject private var project: ProjectState
    private var hasProject: Bool { project.projectFileURL != nil }
    var body: some View {
        Button { project.showExportSheet = true } label: {
            HStack {
                Spacer()
                Text("导出 MP4")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(hasProject ? .black : Color.labelSecondary.opacity(0.5))
                Spacer()
            }
            .frame(height: 36)
            .background(hasProject ? Color.accent : Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(!hasProject)
    }
}

// MARK: - Transcribe Overlay (右下角浮层，语音识别状态)

struct TranscribeOverlay: View {
    @EnvironmentObject private var project: ProjectState
    @State private var autoDismissWork: DispatchWorkItem? = nil

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if project.isTranscribing {
                TranscribeBubble(state: project.transcribeState, onCancel: { project.cancelTranscribe() })
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .opacity))
            }
            if case .failed(let msg) = project.transcribeState {
                TranscribeFailBubble(message: msg, onDismiss: { project.transcribeState = .idle })
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: project.transcribeState)
        .onChange(of: project.transcribeState) { newState in
            autoDismissWork?.cancel()
            autoDismissWork = nil
            if case .failed = newState {
                let work = DispatchWorkItem { project.transcribeState = .idle }
                autoDismissWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
            }
        }
    }
}

// MARK: - 音源分离浮层

struct SeparateOverlay: View {
    @EnvironmentObject private var project: ProjectState

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if project.isSeparatingAudio {
                SeparateBubble(state: project.separateState, onCancel: { project.cancelSeparate() })
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: project.separateState)
    }
}

struct SpeechOverlay: View {
    @EnvironmentObject private var project: ProjectState

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if project.isGeneratingSpeech {
                SpeechBubble(done: project.speechDone, total: project.speechTotal,
                             onCancel: { project.cancelSpeechGeneration() })
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: project.speechDone)
    }
}

private struct SpeechBubble: View {
    /// 卡片出现即开始计时，用于估算剩余时间
    @State private var startedAt = Date()
    let done: Int
    let total: Int
    let onCancel: () -> Void
    @State private var xHovering = false

    private var progress: Double {
        total > 0 ? Double(done) / Double(total) : 0
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.accent.opacity(0.2)).frame(width: 28, height: 28)
                Image(nsImage: SidebarSVGIcon.load("toSpeech", size: 14))
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
                    .foregroundColor(Color.accent)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("转换成语音")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color.labelPrimary)
                        .lineLimit(1)
                    if let eta = TaskETA.text(progress: progress, startedAt: startedAt) {
                        Text(eta)
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundColor(Color.labelSecondary)
                            .fixedSize()
                    }
                }

                GeometryReader { geo in
                    HStack(spacing: 6) {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .tint(Color.accent)
                        Text("\(done)/\(total)")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundColor(Color.labelSecondary)
                            .fixedSize()
                    }
                    .frame(width: geo.size.width)
                }
                .frame(height: 14)
            }

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(xHovering ? Color.labelPrimary : Color.labelSecondary)
                    .frame(width: 18, height: 18)
                    .background(Color.white.opacity(xHovering ? 0.15 : 0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { xHovering = $0 }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 280)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(red: 0.16, green: 0.16, blue: 0.17))
                .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
        )
    }
}

struct RemoveBackgroundOverlay: View {
    @EnvironmentObject private var project: ProjectState

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if project.isRemovingBackground {
                RemoveBackgroundBubble(state: project.removeBackgroundState,
                                       onCancel: { project.cancelRemoveBackground() })
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: project.removeBackgroundState)
    }
}

struct ClarityEnhanceOverlay: View {
    @EnvironmentObject private var project: ProjectState

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if project.isEnhancingClarity {
                ClarityEnhanceBubble(state: project.clarityEnhanceState,
                                     etaSeconds: project.clarityETASeconds,
                                     onCancel: { project.cancelClarityEnhance() })
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: project.clarityEnhanceState)
    }
}

private struct RemoveBackgroundBubble: View {
    /// 卡片出现即开始计时，用于估算剩余时间
    @State private var startedAt = Date()
    let state: ProjectState.RemoveBackgroundState
    let onCancel: () -> Void
    @State private var xHovering = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.accent.opacity(0.2)).frame(width: 28, height: 28)
                Image(nsImage: SidebarSVGIcon.load("removeBg", size: 14))
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
                    .foregroundColor(Color.accent)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("去除背景")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color.labelPrimary)
                        .lineLimit(1)
                    if let eta = TaskETA.text(progress: state.progress, startedAt: startedAt) {
                        Text(eta)
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundColor(Color.labelSecondary)
                            .fixedSize()
                    }
                }
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)

                GeometryReader { geo in
                    HStack(spacing: 6) {
                        ProgressView(value: state.progress)
                            .progressViewStyle(.linear)
                            .tint(Color.accent)
                        Text("\(Int(state.progress * 100))%")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundColor(Color.labelSecondary)
                            .fixedSize()
                    }
                    .frame(width: geo.size.width)
                }
                .frame(height: 14)
            }

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(xHovering ? Color.labelPrimary : Color.labelSecondary)
                    .frame(width: 18, height: 18)
                    .background(Color.white.opacity(xHovering ? 0.15 : 0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { xHovering = $0 }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 280)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(red: 0.16, green: 0.16, blue: 0.17))
                .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
        )
    }
}

private struct ClarityEnhanceBubble: View {
    let state: ProjectState.ClarityEnhanceState
    let etaSeconds: Double?
    let onCancel: () -> Void

    /// "还需约 X" —— 取整到分钟，不足一分钟就直说，免得看着秒数一跳一跳。
    /// 云端引擎算不出 ETA（排队多久是 fal 那边的事），这个位置改显示当前阶段
    private var etaText: String? {
        if let stage = state.cloudStage { return stage }
        guard let s = etaSeconds, s.isFinite, s > 0 else { return nil }
        // 统一成倒计时形式：不足 1 小时「约 MM:SS」，超过则「约 H:MM:SS」
        let total = Int(s.rounded())
        let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
        return h > 0 ? String(format: "约 %d:%02d:%02d", h, m, sec)
                     : String(format: "约 %02d:%02d", m, sec)
    }
    @State private var xHovering = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.accent.opacity(0.2)).frame(width: 28, height: 28)
                Image(nsImage: SidebarSVGIcon.load("clarity", size: 14))
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
                    .foregroundColor(Color.accent)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("清晰度提升")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color.labelPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let eta = etaText {
                        Text(eta)
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundColor(Color.labelSecondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .fixedSize(horizontal: false, vertical: true)

                GeometryReader { geo in
                    HStack(spacing: 6) {
                        ProgressView(value: state.approximateProgress)
                            .progressViewStyle(.linear)
                            .tint(Color.accent)
                        Text("\(Int(state.approximateProgress * 100))%")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundColor(Color.labelSecondary)
                            .fixedSize()
                    }
                    .frame(width: geo.size.width)
                }
                .frame(height: 14)
            }

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(xHovering ? Color.labelPrimary : Color.labelSecondary)
                    .frame(width: 18, height: 18)
                    .background(Color.white.opacity(xHovering ? 0.15 : 0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { xHovering = $0 }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 280)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(red: 0.16, green: 0.16, blue: 0.17))
                .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
        )
    }
}

private struct SeparateBubble: View {
    /// 卡片出现即开始计时，用于估算剩余时间
    @State private var startedAt = Date()
    let state: ProjectState.SeparateState
    let onCancel: () -> Void
    @State private var xHovering = false

    private var progressValue: Double {
        switch state {
        case .downloading(let p): return p * 0.1
        case .running(let p, _):  return 0.1 + p * 0.9
        default: return 0
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.accent.opacity(0.2)).frame(width: 28, height: 28)
                Image(nsImage: SidebarSVGIcon.load("separateAudio", size: 14))
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
                    .foregroundColor(Color.accent)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("分离音轨")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color.labelPrimary)
                        .lineLimit(1)
                    if let eta = TaskETA.text(progress: progressValue, startedAt: startedAt) {
                        Text(eta)
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundColor(Color.labelSecondary)
                            .fixedSize()
                    }
                }
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)

                GeometryReader { geo in
                    HStack(spacing: 6) {
                        ProgressView(value: progressValue)
                            .progressViewStyle(.linear)
                            .tint(Color.accent)
                        Text("\(Int(progressValue * 100))%")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundColor(Color.labelSecondary)
                            .fixedSize()
                    }
                    .frame(width: geo.size.width)
                }
                .frame(height: 14)
            }

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(xHovering ? Color.labelPrimary : Color.labelSecondary)
                    .frame(width: 18, height: 18)
                    .background(Color.white.opacity(xHovering ? 0.15 : 0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { xHovering = $0 }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 280)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(red: 0.16, green: 0.16, blue: 0.17))
                .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
        )
    }
}

private struct TranscribeBubble: View {
    /// 卡片出现即开始计时，用于估算剩余时间
    @State private var startedAt = Date()
    let state: ProjectState.TranscribeState
    let onCancel: () -> Void
    @State private var xHovering = false

    private var progressValue: Double {
        switch state {
        case .downloading(let p): return p * 0.05
        case .running(let p): return 0.05 + p * 0.95
        default: return 0
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.accent.opacity(0.2)).frame(width: 28, height: 28)
                Image(nsImage: TimelineSVGIcon.load("whisper", size: 14))
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
                    .foregroundColor(Color.accent)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("语音识别")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color.labelPrimary)
                        .lineLimit(1)
                    if let eta = TaskETA.text(progress: progressValue, startedAt: startedAt) {
                        Text(eta)
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundColor(Color.labelSecondary)
                            .fixedSize()
                    }
                }

                GeometryReader { geo in
                    HStack(spacing: 6) {
                        ProgressView(value: progressValue)
                            .progressViewStyle(.linear)
                            .tint(Color.accent)
                        Text("\(Int(progressValue * 100))%")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundColor(Color.labelSecondary)
                            .fixedSize()
                    }
                    .frame(width: geo.size.width)
                }
                .frame(height: 14)
            }

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(xHovering ? Color.labelPrimary : Color.labelSecondary)
                    .frame(width: 18, height: 18)
                    .background(Color.white.opacity(xHovering ? 0.15 : 0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { xHovering = $0 }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 260)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(red: 0.16, green: 0.16, blue: 0.17))
                .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
        )
    }
}

private struct TranscribeFailBubble: View {
    let message: String
    let onDismiss: () -> Void
    @State private var xHovering = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.red.opacity(0.2)).frame(width: 28, height: 28)
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.red.opacity(0.8))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("语音识别")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color.labelPrimary)
                    .lineLimit(1)
                Text(message)
                    .font(.system(size: 10))
                    .foregroundColor(.red.opacity(0.8))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(xHovering ? Color.labelPrimary : Color.labelSecondary)
                    .frame(width: 18, height: 18)
                    .background(Color.white.opacity(xHovering ? 0.15 : 0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { xHovering = $0 }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 260)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(red: 0.16, green: 0.16, blue: 0.17))
                .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
        )
    }
}

// MARK: - SceneDetect Bubble (右下角浮层)

struct SceneDetectBubble: View {
    /// 卡片出现即开始计时，用于估算剩余时间
    @State private var startedAt = Date()
    let progress: Double
    let onCancel: () -> Void
    @State private var xHovering = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.accent.opacity(0.2)).frame(width: 28, height: 28)
                Image(nsImage: TimelineSVGIcon.load("smartAnalysis", size: 14))
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
                    .foregroundColor(Color.accent)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("智能分割")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color.labelPrimary)
                        .lineLimit(1)
                    if let eta = TaskETA.text(progress: progress, startedAt: startedAt) {
                        Text(eta)
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundColor(Color.labelSecondary)
                            .fixedSize()
                    }
                }

                GeometryReader { geo in
                    HStack(spacing: 6) {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .tint(Color.accent)
                        Text("\(Int(progress * 100))%")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundColor(Color.labelSecondary)
                            .fixedSize()
                    }
                    .frame(width: geo.size.width)
                }
                .frame(height: 14)
            }

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(xHovering ? Color.labelPrimary : Color.labelSecondary)
                    .frame(width: 18, height: 18)
                    .background(Color.white.opacity(xHovering ? 0.15 : 0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { xHovering = $0 }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 260)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(red: 0.16, green: 0.16, blue: 0.17))
                .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
        )
    }
}

// MARK: - Reverse Video Bubble (右下角浮层)

struct ReverseVideoBubble: View {
    let onCancel: () -> Void
    @State private var xHovering = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.accent.opacity(0.2)).frame(width: 28, height: 28)
                Image(nsImage: TimelineSVGIcon.load("reverse", size: 14))
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
                    .foregroundColor(Color.accent)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("生成倒放视频")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color.labelPrimary)
                    .lineLimit(1)

                // ffmpeg 的 reverse 滤镜要把整段读进内存再倒着写，中途拿不到进度，
                // 所以这里是不确定进度条，也就没有倒计时可估
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(Color.accent)
                    .frame(height: 14)
            }

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(xHovering ? Color.labelPrimary : Color.labelSecondary)
                    .frame(width: 18, height: 18)
                    .background(xHovering ? Color.white.opacity(0.12) : Color.clear)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { xHovering = $0 }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 260)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(red: 0.16, green: 0.16, blue: 0.17))
                .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
        )
    }
}

// MARK: - LLM Analyze Bubble (右下角浮层)

struct LLMAnalyzeBubble: View {
    /// 卡片出现即开始计时，用于估算剩余时间
    @State private var startedAt = Date()
    let progress: Double
    let onCancel: () -> Void
    @State private var xHovering = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.accent.opacity(0.2)).frame(width: 28, height: 28)
                Image(nsImage: TimelineSVGIcon.load("smartAnalysis", size: 14))
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
                    .foregroundColor(Color.accent)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("AI 剪辑")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color.labelPrimary)
                        .lineLimit(1)
                    if let eta = TaskETA.text(progress: progress, startedAt: startedAt) {
                        Text(eta)
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundColor(Color.labelSecondary)
                            .fixedSize()
                    }
                }

                GeometryReader { geo in
                    HStack(spacing: 6) {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .tint(Color.accent)
                        Text("\(Int(progress * 100))%")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundColor(Color.labelSecondary)
                            .fixedSize()
                    }
                    .frame(width: geo.size.width)
                }
                .frame(height: 14)
            }

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(xHovering ? Color.labelPrimary : Color.labelSecondary)
                    .frame(width: 18, height: 18)
                    .background(Color.white.opacity(xHovering ? 0.15 : 0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { xHovering = $0 }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 260)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(red: 0.16, green: 0.16, blue: 0.17))
                .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
        )
    }
}

// MARK: - Transcode Overlay (右下角浮层)

struct TranscodeOverlay: View {
    @EnvironmentObject private var project: ProjectState

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(project.activeTasks) { task in
                TranscodeTaskBubble(task: task)
                    .environmentObject(project)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: project.activeTasks.count)
    }
}

private struct TranscodeTaskBubble: View {
    @EnvironmentObject private var project: ProjectState
    @ObservedObject var task: ProjectState.TranscodeTask
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            // Icon
            ZStack {
                Circle()
                    .fill(Color.accent.opacity(0.2))
                    .frame(width: 28, height: 28)
                Image(nsImage: SidebarSVGIcon.load("importFile", size: 14))
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
                    .foregroundColor(Color.accent)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(Self.truncatedFilename(task.displayName))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color.labelPrimary)
                    .lineLimit(1)

                GeometryReader { geo in
                    HStack(spacing: 6) {
                        ProgressView(value: task.progress)
                            .progressViewStyle(.linear)
                            .tint(Color.accent)
                        Text("\(Int(task.progress * 100))%")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundColor(Color.labelSecondary)
                            .fixedSize()
                    }
                    .frame(width: geo.size.width)
                }
                .frame(height: 14)
            }

            Button { project.cancelTranscodeTask(task.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(hovering ? Color.labelPrimary : Color.labelSecondary)
                    .frame(width: 18, height: 18)
                    .background(Color.white.opacity(hovering ? 0.15 : 0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 260)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(red: 0.16, green: 0.16, blue: 0.17))
                .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
        )
    }

    /// 文件名截断：按视觉宽度（CJK算2），保留前部分 + ... + 后6字符 + 后缀
    private static func truncatedFilename(_ name: String, maxVisualWidth: Int = 28) -> String {
        guard visualWidth(of: name) > maxVisualWidth else { return name }
        let ext: String
        let base: String
        if let dotIdx = name.lastIndex(of: ".") {
            ext = String(name[dotIdx...])
            base = String(name[..<dotIdx])
        } else {
            ext = ""
            base = name
        }
        let tailLen = 6
        guard tailLen < base.count else { return name }
        let tail = String(base.suffix(tailLen))
        let dotsWidth = 3 // "..."
        let tailWidth = visualWidth(of: tail)
        let extWidth = visualWidth(of: ext)
        let budget = maxVisualWidth - dotsWidth - tailWidth - extWidth
        guard budget > 0 else { return name }
        // 从前往后取字符，直到视觉宽度用完
        var head = ""
        var used = 0
        for ch in base {
            let w = ch.isCJK ? 2 : 1
            if used + w > budget { break }
            head.append(ch)
            used += w
        }
        guard !head.isEmpty else { return name }
        return "\(head)...\(tail)\(ext)"
    }

    private static func visualWidth(of str: String) -> Int {
        str.reduce(0) { $0 + ($1.isCJK ? 2 : 1) }
    }
}

private extension Character {
    var isCJK: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        let v = scalar.value
        return (0x4E00...0x9FFF).contains(v)   // CJK统一汉字
            || (0x3400...0x4DBF).contains(v)    // CJK扩展A
            || (0x3000...0x303F).contains(v)    // CJK标点
            || (0xFF00...0xFFEF).contains(v)    // 全角字符
            || (0x3040...0x309F).contains(v)    // 平假名
            || (0x30A0...0x30FF).contains(v)    // 片假名
            || (0xAC00...0xD7AF).contains(v)    // 韩文
    }
}

// MARK: - Text Layer Panel

/// 文字模板。侧边栏点了是套用到选中的文字片段，封面弹窗点了是往封面加一条 ——
/// 同上，落点用 `onPick` 传
struct TextLayerPanel: View {
    @EnvironmentObject private var project: ProjectState
    var onPick: ((TextTemplate) -> Void)? = nil
    /// 同 `ShapePanel`：侧边栏 3 / 10，封面弹窗两边都 24
    var hLeading: CGFloat = 3
    var hTrailing: CGFloat = 10

    var body: some View {
        VStack(spacing: 0) {
            if project.textTemplates.isEmpty {
                // 跟其他标签页的空状态一致：44pt 图标 0.30、11pt 文字 0.45、
                // 间距 10、摆在上方三分之一处。图标复用右键菜单那个「保存为文字模板」
                VStack(spacing: 10) {
                    Image(nsImage: SidebarSVGIcon.load("saveTextTemplate", size: 44))
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 44, height: 44)
                        .foregroundColor(Color.labelSecondary.opacity(0.30))
                    Text("右键文字片段\n「保存为文字模板」")
                        .font(.system(size: 11))
                        .foregroundColor(Color.labelSecondary.opacity(0.45))
                        .multilineTextAlignment(.center)
                }
                .modifier(PositionedAtOneThird())
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(project.textTemplates) { tmpl in
                            TextTemplateCard(template: tmpl, onPick: onPick)
                        }
                    }
                    .padding(.leading, hLeading).padding(.trailing, hTrailing)
                    .padding(.top, 6)
                    .padding(.bottom, 8)
                }
            }
        }
    }
}

private struct TextTemplateCard: View {
    let template: TextTemplate
    var onPick: ((TextTemplate) -> Void)? = nil
    @EnvironmentObject private var project: ProjectState
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("T")
                    .font(.system(size: 14, weight: .bold, design: .serif))
                    .foregroundColor(Color(hex: template.textColorHex))
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(hex: template.bgColorHex).opacity(template.bgOpacity))
                            .overlay(RoundedRectangle(cornerRadius: 4)
                                .stroke(Color(hex: "#D4668E").opacity(0.3), lineWidth: 0.5))
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text(template.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color.labelPrimary)
                        .lineLimit(1)
                    Text("\(template.fontName) \(Int(template.fontSize))pt")
                        .font(.system(size: 9))
                        .foregroundColor(Color.labelSecondary)
                }
                Spacer()
                if isHovered {
                    Button {
                        project.deleteTextTemplate(id: template.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(Color.labelSecondary)
                            .frame(width: 16, height: 16)
                            .background(Color.white.opacity(0.1))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.leading, 3).padding(.trailing, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(isHovered ? 0.08 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(hex: "#D4668E").opacity(0.3), lineWidth: 0.5)
        )
        .onHover { isHovered = $0 }
        .onTapGesture {
            if let onPick {
                onPick(template)
            } else if let clipID = project.selectedTextClipID {
                project.applyTextTemplate(template, to: clipID)
            }
        }
    }
}

// MARK: - Transition Panel

private struct TransitionPanel: View {
    @EnvironmentObject private var project: ProjectState

    private var selectedClipTransition: Transition? {
        guard let id = project.selectedTransitionClipID else { return nil }
        return project.videoTracks.flatMap(\.clips).first(where: { $0.id == id })?.inTransition
    }

    private var hasSelection: Bool { project.selectedTransitionClipID != nil }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                if hasSelection {
                    Text("选择转场")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color.labelSecondary)
                        .padding(.leading, 3).padding(.trailing, 10)
                        .padding(.top, 4)
                }

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6),
                                    GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(TransitionType.allCases, id: \.self) { type in
                        TransitionPreviewCard(
                            type: type,
                            isSelected: hasSelection && selectedClipTransition?.type == type,
                            onSelect: {
                                guard let clipID = project.selectedTransitionClipID else { return }
                                project.pushUndo()
                                project.updateVideoClip(id: clipID) {
                                    if $0.inTransition == nil {
                                        $0.inTransition = Transition(type: type)
                                    } else {
                                        $0.inTransition?.type = type
                                    }
                                }
                                project.rebuildTimelinePreviewDebounced()
                            }
                        )
                    }
                }
                .padding(.leading, 3).padding(.trailing, 10)
            }
            // 不留上边距：标题行自己的 8pt 就够了，加了这 6 转场这栏
            // 比素材库、AI 创作宽出一截
            .padding(.bottom, 8)
        }
    }
}

// MARK: - Transition Preview Card

private struct TransitionPreviewCard: View {
    let type: TransitionType
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var phase: Double = 0
    @State private var hoverTask: Task<Void, Never>? = nil
    @State private var hover = false

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 4) {
                GeometryReader { geo in
                    ZStack {
                        // 底层：转场**前**的画面
                        Image(nsImage: TransitionPreviewFrames.before)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                        // 叠加层：转场**后**的画面，按转场类型演示进场方式
                        transitionOverlay(in: geo.size)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
                // **固定 16:9**。原来只钉死高度 44，侧边栏一拉宽封面就越来越扁
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 4))

                Text(type.label)
                    .font(.system(size: 9))
                    .foregroundColor(isSelected ? Color.accent : Color.labelSecondary)
                    .lineLimit(1)
            }
            .padding(6)
            .background(isSelected ? Color.accent.opacity(0.15) : (hover ? Color.white.opacity(0.08) : Color.clear))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accent : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hover = hovering
            if hovering {
                // hover 进入：启动独立 Task 循环播放，不污染其他卡片
                hoverTask = Task {
                    while !Task.isCancelled {
                        withAnimation(.easeInOut(duration: 0.9)) { phase = 1.0 }
                        try? await Task.sleep(nanoseconds: 950_000_000)
                        guard !Task.isCancelled else { break }
                        withAnimation(.easeInOut(duration: 0.9)) { phase = 0.0 }
                        try? await Task.sleep(nanoseconds: 950_000_000)
                    }
                }
            } else {
                // hover 离开：取消任务，重置到初始状态
                hoverTask?.cancel()
                hoverTask = nil
                withAnimation(.easeInOut(duration: 0.3)) { phase = 0.0 }
            }
        }
    }

    /// 转场后的那张画面。各个 case 拿它做位移、缩放、淡入
    private var afterFrame: some View {
        Image(nsImage: TransitionPreviewFrames.after)
            .resizable()
            .aspectRatio(contentMode: .fill)
    }

    @ViewBuilder
    private func transitionOverlay(in size: CGSize) -> some View {
        let p = phase
        // 位移量按卡片尺寸的八成算：**静止时要露出两成的上层帧**，
        // 不然看不出这个转场是从哪个方向进来的（原来纵向写死 50，
        // 差不多等于整个卡片高度，上下那四种就全看不见了）
        let dx = size.width * 0.8
        let dy = size.height * 0.8
        switch type {
        case .dissolve:
            // 右侧浅灰块淡入淡出
            afterFrame
                .opacity(p)
        case .fadeToBlack:
            // 黑色遮罩淡入淡出
            Color.black.opacity(p)
        case .pushLeft:
            // 浅灰块从右推入
            afterFrame
                .offset(x: (1 - p) * dx)
        case .pushRight:
            // 浅灰块从左推入
            afterFrame
                .offset(x: -(1 - p) * dx)
        case .pushUp:
            // 浅灰块从下推入
            afterFrame
                .offset(y: (1 - p) * dy)
        case .pushDown:
            // 浅灰块从上推入
            afterFrame
                .offset(y: -(1 - p) * dy)
        case .zoom:
            // 浅灰块从放大缩回 + 淡入
            afterFrame
                .scaleEffect(1.5 - 0.5 * p)
                .opacity(p)
        case .slideLeft:
            // 浅灰块从右滑入覆盖
            afterFrame
                .offset(x: (1 - p) * dx)
        case .slideRight:
            // 浅灰块从左滑入覆盖
            afterFrame
                .offset(x: -(1 - p) * dx)
        case .slideUp:
            // 浅灰块从下滑入覆盖
            afterFrame
                .offset(y: (1 - p) * dy)
        case .slideDown:
            // 浅灰块从上滑入覆盖
            afterFrame
                .offset(y: -(1 - p) * dy)
        }
    }
}

// MARK: - 排序下拉菜单

private class SortMenuTarget: NSObject {
    let project: ProjectState
    init(_ project: ProjectState) { self.project = project }

    @objc func pick(_ sender: NSMenuItem) {
        let allCases = ProjectState.MediaSortOrder.allCases
        guard sender.tag >= 0, sender.tag < allCases.count else { return }
        let order = allCases[sender.tag]
        if project.mediaSortOrder == order {
            project.mediaSortAscending.toggle()
        } else {
            project.mediaSortOrder = order
            project.mediaSortAscending = order == .name
        }
    }
}

private var _sortMenuTarget: SortMenuTarget?

func showSortNSMenu(project: ProjectState) {
    let target = SortMenuTarget(project)
    _sortMenuTarget = target

    let menu = NSMenu()
    for (i, order) in ProjectState.MediaSortOrder.allCases.enumerated() {
        let arrow = project.mediaSortOrder == order
            ? (project.mediaSortAscending ? " ↑" : " ↓") : ""
        let item = NSMenuItem(title: order.rawValue + arrow, action: #selector(SortMenuTarget.pick(_:)), keyEquivalent: "")
        item.target = target
        item.tag = i
        if project.mediaSortOrder == order { item.state = .on }
        menu.addItem(item)
    }

    guard let window = NSApp.keyWindow, let contentView = window.contentView else { return }
    let loc = NSEvent.mouseLocation
    let winPoint = window.convertPoint(fromScreen: loc)
    let viewPoint = contentView.convert(winPoint, from: nil)
    menu.popUp(positioning: nil, at: viewPoint, in: contentView)
}

private struct MediaToolBtn: View {
    var icon: String = ""
    var svgName: String? = nil
    var enabled: Bool = true
    var help: String = ""
    let action: () -> Void
    @State private var hov = false
    var body: some View {
        Button(action: action) {
            Group {
                if let svgName {
                    Image(nsImage: SidebarSVGIcon.load(svgName))
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .foregroundColor(enabled ? (hov ? Color.labelPrimary : Color.labelSecondary)
                                     : Color.labelSecondary.opacity(0.3))
            .frame(width: 24, height: 24)
            .background((enabled && hov) ? Color.white.opacity(0.08) : Color.clear)
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hov = $0 }
        .help(help)
    }
}

// MARK: - Shape Panel（图形素材面板）

/// 八种图形。侧边栏点了是加到时间轴，封面弹窗点了是加到封面 ——
/// 落点用 `onPick` 传进来，不传就走时间轴那条老路
struct ShapePanel: View {
    @EnvironmentObject private var project: ProjectState
    var onPick: ((ShapeType) -> Void)? = nil
    /// 左右内边距。侧边栏那两侧的**可视间距**要各 10pt：左边被 44 宽的图标栏
    /// 占着（按钮右边缘落在 37），所以 leading 只给 3；封面弹窗两边都传 24
    var hLeading: CGFloat = 3
    var hTrailing: CGFloat = 10
    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8),
                                GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(ShapeType.allCases, id: \.self) { type in
                    ShapeCard(type: type) {
                        if let onPick { onPick(type) }
                        else { project.addShapeAtPlayhead(type: type) }
                    }
                }
            }
            .padding(.leading, hLeading).padding(.trailing, hTrailing)
            .padding(.top, 6)
            .padding(.bottom, 8)
        }
    }
}

private struct ShapeCard: View {
    let type: ShapeType
    let onAdd: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05))
                GeometryReader { geo in
                    // 图形按固定基准宽度画、居中放，**不跟着侧边栏拉宽**（拉宽只有灰底变宽）。
                    // 84 = 侧边栏默认 260 宽时的卡片内容宽；侧边栏拉窄到装不下时才跟着缩
                    let boxW = min(geo.size.width, 84)
                    let ox = (geo.size.width - boxW) / 2
                    let r = CGRect(x: ox + boxW * 0.2, y: geo.size.height * 0.28,
                                   width: boxW * 0.6, height: geo.size.height * 0.44)
                    let col = Color.labelSecondary.opacity(0.85)
                    if type == .pen {
                        // 钢笔图标：一条贝塞尔曲线
                        let pr = CGRect(x: r.midX - r.width * 0.3, y: r.midY - r.height * 0.3,
                                        width: r.width * 0.6, height: r.height * 0.6)
                        ZStack {
                            Path { p in
                                p.move(to: CGPoint(x: pr.minX, y: pr.maxY))
                                p.addCurve(to: CGPoint(x: pr.maxX, y: pr.minY),
                                           control1: CGPoint(x: pr.minX + pr.width * 0.3, y: pr.minY - pr.height * 0.2),
                                           control2: CGPoint(x: pr.maxX - pr.width * 0.3, y: pr.maxY + pr.height * 0.2))
                            }.stroke(col, lineWidth: 2)
                            Circle().fill(col).frame(width: 5, height: 5)
                                .position(x: pr.minX, y: pr.maxY)
                            Circle().fill(col).frame(width: 5, height: 5)
                                .position(x: pr.maxX, y: pr.minY)
                        }
                    } else if type == .arrow {
                        let ar = CGRect(x: r.midX - r.width * 0.25, y: r.midY - r.height * 0.25,
                                        width: r.width * 0.5, height: r.height * 0.5)
                        let y = ar.midY
                        let headLen = ar.width * 0.5
                        let wing = min(ar.height * 0.44, headLen * 0.62)
                        ZStack {
                            Path { p in
                                p.move(to: CGPoint(x: ar.minX, y: y))
                                p.addLine(to: CGPoint(x: ar.maxX - headLen, y: y))
                            }.stroke(col, lineWidth: 2)
                            Path { p in
                                p.move(to: CGPoint(x: ar.maxX - headLen, y: y - wing))
                                p.addLine(to: CGPoint(x: ar.maxX, y: y))
                                p.addLine(to: CGPoint(x: ar.maxX - headLen, y: y + wing))
                                p.closeSubpath()
                            }.fill(col)
                        }
                    } else if type.isClosed {
                        ShapeGeometry.path(for: type, in: r).fill(col)
                    } else {
                        ShapeGeometry.path(for: type, in: r).stroke(col, lineWidth: 2)
                    }
                }
            }
            .frame(height: 54)
            .overlay(alignment: .bottomTrailing) {
                if hover {
                    VideoMiniBtnView(icon: "plus.circle", action: onAdd)
                        .padding(2)
                }
            }
            Text(type.label)
                .font(.system(size: 9))
                .foregroundColor(Color.labelSecondary)
                .lineLimit(1)
        }
        .padding(6)
        .background(hover ? Color.white.opacity(0.08) : Color.clear)
        .cornerRadius(8)
        .contentShape(Rectangle())
        // 拖到时间轴按落点插入。载荷带 "shape:" 前缀，跟素材拖拽的裸 UUID 区分；
        // 接收方是宿主 GatedHostingView（内层 .onDrop 收不到，见 WindowDragGate.swift）。
        //
        // **必须排在 .gesture(TapGesture) 之前**：后加的手势包在外层先收事件，
        // 写反了双击会把拖拽的起始事件抢走，拖动完全没反应（素材项就是这个顺序）
        .onDrag { NSItemProvider(object: FileDropRouter.pasteboardString(for: type) as NSString) }
        .onHover { hover = $0 }
        .gesture(TapGesture(count: 2).onEnded { onAdd() })
        .help("双击添加\(type.label)，或拖到时间轴")
    }
}

// MARK: - Sidebar SVG Icons

enum SidebarSVGIcon {
    static var cache: [String: NSImage] = [:]

    static let svgs: [String: String] = [
        "relink": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path fill-rule="evenodd" d="M12.7716286,11.4720826 L12.7282337,11.3760569 C12.5585888,11.0390069 12.1795714,10.6685796 10.8709017,9.53097035 L10.5690179,9.26854674 C9.13571297,8.02259378 8.76892283,7.75287247 8.38226638,7.65646819 C7.97245372,7.55429042 7.54081339,7.58447365 7.1492094,7.74269194 C6.77973274,7.89197019 6.45405012,8.21011392 5.20809717,9.64341883 L4.94567356,9.94530266 C3.69972061,11.3786076 3.4299993,11.7453977 3.33359502,12.1320542 C3.15165093,12.861792 3.3944681,13.6319097 3.96206841,14.1253171 L5.62242949,15.568647 C7.0557344,16.8145999 7.42252455,17.0843213 7.809181,17.1807255 C8.21899365,17.2829033 8.65063399,17.2527201 9.04223798,17.0945018 C9.35104719,16.9697348 9.55713818,16.8344442 9.67123214,16.7031941 L11.1806513,18.0153121 C10.839671,18.4075651 10.3730305,18.7138962 9.79145116,18.9488695 C9.00824318,19.2653061 8.14496252,19.3256725 7.32533721,19.121317 C6.48901984,18.9127996 6.04708395,18.5878195 4.31031143,17.0780662 L2.64995035,15.6347363 C1.51474974,14.6479214 1.0291154,13.1076861 1.39300356,11.6482104 C1.6015209,10.811893 1.92650108,10.3699571 3.4362544,8.63318461 L3.69867801,8.33130077 C5.20843133,6.59452825 5.60083783,6.21120517 6.39999621,5.88832423 C7.18320419,5.57188766 8.04648486,5.5115212 8.86611017,5.71587674 C9.70242753,5.92439408 10.1443634,6.24937425 11.8811359,7.75912758 L12.1830198,8.02155119 C13.9197923,9.53130451 14.3031154,9.92371101 14.6259963,10.7228694 C15.1894629,12.1174981 14.9229141,13.7103313 13.9360992,14.8455319 L12.4266801,13.5334138 C12.9200875,12.9658135 13.0533619,12.169397 12.7716286,11.4720826 Z M19.2814936,7.56856006 L20.3983169,8.53939973 C21.7918124,9.76233653 22.1385748,10.1531138 22.4345489,10.8856757 C22.7509855,11.6688836 22.811352,12.5321643 22.6069964,13.3517896 C22.3984791,14.188107 22.0734989,14.6300429 20.5637456,16.3668154 L20.301322,16.6686992 C18.7915687,18.4054718 18.3991622,18.7887948 17.6000038,19.1116758 C16.8167958,19.4281123 15.9535151,19.4884788 15.1338898,19.2841233 C14.2975725,19.0756059 13.8556366,18.7506257 12.1188641,17.2408724 L11.8169802,16.9784488 C10.0802077,15.4686955 9.69688462,15.076289 9.37400368,14.2771306 C8.81053708,12.8825019 9.07708593,11.2896687 10.0639008,10.1544681 L11.5733199,11.4665862 C11.0799125,12.0341865 10.9466381,12.830603 11.2283714,13.5279174 C11.3776496,13.8973941 11.6957934,14.2230767 13.1290983,15.4690297 L13.4309821,15.7314533 C14.864287,16.9774062 15.2310772,17.2471275 15.6177336,17.3435318 C16.0275463,17.4457096 16.4591866,17.4155263 16.8507906,17.2573081 C17.2202673,17.1080298 17.5459499,16.7898861 18.7919028,15.3565812 L19.0543264,15.0546973 C20.3002794,13.6213924 20.5700007,13.2546023 20.666405,12.8679458 C20.7685828,12.4581332 20.7383995,12.0264928 20.5801812,11.6348888 C20.430903,11.2654122 20.1127593,10.9397296 18.6794543,9.69377662 L18.3775705,9.43135301 C16.9442656,8.18540006 16.5774755,7.91567875 16.190819,7.81927447 C15.4610811,7.63733038 14.6909635,7.88014755 14.1975561,8.44774786 L12.6881369,7.1356298 C13.6749517,6.00042919 15.2151871,5.51479485 16.6746628,5.87868301 C17.441287,6.06982391 17.8765213,6.35882593 19.2814936,7.56856006 Z" fill="black"/></svg>
        """,
        "doubleClickAdd": """
        <svg width="24px" height="24px" viewBox="0 0 24 24" version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"><g id="双击添加" stroke="none" fill="none" stroke-width="2"><path d="M5.21220963,18.6183218 L11.3529426,3.26648936 C11.6882009,2.42834359 12.8746377,2.42834359 13.209896,3.26648936 L19.350629,18.6183218 C19.686197,19.4572418 18.8252969,20.2757401 18.0043799,19.8982642 L14.370281,18.2272246 C13.0444317,17.6175695 11.5184069,17.6175695 10.1925576,18.2272246 L6.55845866,19.8982642 C5.73754173,20.2757401 4.87664163,19.4572418 5.21220963,18.6183218 Z" id="形状结合" stroke="#FFFFFF" transform="translate(12.2814, 12.0666) rotate(-22) translate(-12.2814, -12.0666)"></path></g></svg>
        """,
        "freeCanvas": """
        <svg width="24px" height="24px" viewBox="0 0 24 24" version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"><g id="自由画布" stroke="none" fill="none" fill-rule="evenodd"><path d="M9.1480503,3.2283614 C9.8079861,3.50171576 10.3487299,4.00157419 10.6730196,4.6380285 C10.9689538,5.21883214 11,5.59881947 11,7.2 L11,8.8 C11,10.4011805 10.9689538,10.7811679 10.6730196,11.3619715 C10.3487299,11.9984258 9.8079861,12.4982842 9.1480503,12.7716386 C8.64885572,12.9784118 8.33244923,13 7,13 C5.66755077,13 5.35114428,12.9784118 4.8519497,12.7716386 C4.1920139,12.4982842 3.65127009,11.9984258 3.32698043,11.3619715 C3.03104619,10.7811679 3,10.4011805 3,8.8 L3,7.2 C3,5.59881947 3.03104619,5.21883214 3.32698043,4.6380285 C3.65127009,4.00157419 4.1920139,3.50171576 4.8519497,3.2283614 C5.35114428,3.02158824 5.66755077,3 7,3 C8.33244923,3 8.64885572,3.02158824 9.1480503,3.2283614 Z M5.61731657,5.07612047 C5.39733797,5.16723859 5.21709003,5.33385806 5.10899348,5.5460095 C5.02345055,5.71389695 5,6.000918 5,7.2 L5,8.8 C5,9.999082 5.02345055,10.286103 5.10899348,10.4539905 C5.21709003,10.6661419 5.39733797,10.8327614 5.61731657,10.9238795 C5.76132072,10.983528 6.00274133,11 7,11 C7.99725867,11 8.23867928,10.983528 8.38268343,10.9238795 C8.60266203,10.8327614 8.78290997,10.6661419 8.89100652,10.4539905 C8.97654945,10.286103 9,9.999082 9,8.8 L9,7.2 C9,6.000918 8.97654945,5.71389695 8.89100652,5.5460095 C8.78290997,5.33385806 8.60266203,5.16723859 8.38268343,5.07612047 C8.23867928,5.01647199 7.99725867,5 7,5 C6.00274133,5 5.76132072,5.01647199 5.61731657,5.07612047 Z M19.1480503,5.2283614 L19.284077,5.28869625 C19.9550454,5.60643613 20.4861868,6.16280821 20.7716386,6.8519497 C20.9784118,7.35114428 21,7.66755077 21,9 C21,10.3324492 20.9784118,10.6488557 20.7716386,11.1480503 C20.4671567,11.8831346 19.8831346,12.4671567 19.1480503,12.7716386 C18.6488557,12.9784118 18.3324492,13 17,13 C15.6675508,13 15.3511443,12.9784118 14.8519497,12.7716386 C14.1168654,12.4671567 13.5328433,11.8831346 13.2283614,11.1480503 C13.0215882,10.6488557 13,10.3324492 13,9 C13,7.66755077 13.0215882,7.35114428 13.2283614,6.8519497 C13.5328433,6.11686544 14.1168654,5.53284327 14.8519497,5.2283614 C15.3511443,5.02158824 15.6675508,5 17,5 C18.3324492,5 18.6488557,5.02158824 19.1480503,5.2283614 Z M15.6173166,7.07612047 C15.3722885,7.17761442 15.1776144,7.37228848 15.0761205,7.61731657 C15.016472,7.76132072 15,8.00274133 15,9 C15,9.99725867 15.016472,10.2386793 15.0761205,10.3826834 C15.1776144,10.6277115 15.3722885,10.8223856 15.6173166,10.9238795 C15.7613207,10.983528 16.0027413,11 17,11 C17.9972587,11 18.2386793,10.983528 18.3826834,10.9238795 C18.6277115,10.8223856 18.8223856,10.6277115 18.9238795,10.3826834 C18.983528,10.2386793 19,9.99725867 19,9 C19,8.00274133 18.983528,7.76132072 18.9238795,7.61731657 C18.8223856,7.37228848 18.6277115,7.17761442 18.3826834,7.07612047 L18.3543803,7.06543583 C18.2055492,7.01447734 17.93493,7 17,7 C16.0027413,7 15.7613207,7.01647199 15.6173166,7.07612047 Z M19.3619715,15.3269804 L19.5126724,15.4092719 C20.2519223,15.840828 20.7742956,16.5698334 20.9423558,17.414729 C20.9945906,17.677331 21,17.8353368 21,18.5 C21,19.1646632 20.9945906,19.322669 20.9423558,19.585271 C20.7630916,20.486493 20.1806978,21.2558577 19.3619715,21.6730196 C18.7811679,21.9689538 18.4011805,22 16.8,22 L7.2,22 C5.59881947,22 5.21883214,21.9689538 4.6380285,21.6730196 C3.81930218,21.2558577 3.23690837,20.486493 3.05764416,19.585271 C3.00540938,19.322669 3,19.1646632 3,18.5 C3,17.8353368 3.00540938,17.677331 3.05764416,17.414729 C3.23690837,16.513507 3.81930218,15.7441423 4.6380285,15.3269804 C5.21883214,15.0310462 5.59881947,15 7.2,15 L16.8,15 C18.4011805,15 18.7811679,15.0310462 19.3619715,15.3269804 Z M7.2,17 C6.000918,17 5.71389695,17.0234505 5.5460095,17.1089935 C5.27310073,17.2480474 5.07896946,17.5045023 5.01921472,17.8049097 C5.00419798,17.8804039 5,18.0030252 5,18.5 C5,18.9969748 5.00419798,19.1195961 5.01921472,19.1950903 C5.07896946,19.4954977 5.27310073,19.7519526 5.5460095,19.8910065 C5.71389695,19.9765495 6.000918,20 7.2,20 L16.8,20 C17.999082,20 18.286103,19.9765495 18.4539905,19.8910065 C18.7268993,19.7519526 18.9210305,19.4954977 18.9807853,19.1950903 C18.995802,19.1195961 19,18.9969748 19,18.5 C19,18.0030252 18.995802,17.8804039 18.9807853,17.8049097 C18.9210305,17.5045023 18.7268993,17.2480474 18.4539905,17.1089935 L18.4209219,17.0936724 C18.2466627,17.0206108 17.9241394,17 16.8,17 Z" id="形状结合" fill="#FFFFFF"></path></g></svg>
        """,
        "chatHistory": """
        <svg width="24px" height="24px" viewBox="0 0 24 24" version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"><g id="历史会話" stroke="none" fill="none"><g id="24px参考"></g><path d="M12,2 C17.5228475,2 22,6.4771525 22,12 C22,17.5228475 17.5228475,22 12,22 C6.4771525,22 2,17.5228475 2,12 C2,6.4771525 6.4771525,2 12,2 Z M12,4 C7.581722,4 4,7.581722 4,12 C4,16.418278 7.581722,20 12,20 C16.418278,20 20,16.418278 20,12 C20,7.581722 16.418278,4 12,4 Z M11,8 C11.3760389,8 11.7202884,8.21095639 11.8910065,8.5460095 C12,8.75992124 12,9.03994749 12,9.6 L12,12 L14.9,12 C15.4600525,12 15.7400788,12 15.9539905,12.1089935 C16.2890436,12.2797116 16.5,12.6239611 16.5,13 C16.5,13.3760389 16.2890436,13.7202884 15.9539905,13.8910065 C15.7400788,14 15.4600525,14 14.9,14 L11.6144821,14 C11.4083828,14 11.2402057,14 11.0992904,13.9945682 L11,14 C10.6239611,14 10.2797116,13.7890436 10.1089935,13.4539905 C10,13.2400788 10,12.9600525 10,12.4 L10,9.6 C10,9.03994749 10,8.75992124 10.1089935,8.5460095 C10.2797116,8.21095639 10.6239611,8 11,8 Z" id="形状结合" fill="#FFFFFF" fill-rule="evenodd"></path></g></svg>
        """,
        "newChat": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path fill-rule="evenodd" d="M12,3 C12.5522847,3 13,3.44771525 13,4 C13,4.55228475 12.5522847,5 12,5 L10.4,5 C7.80078673,5 7.1802615,5.05069892 6.6380285,5.32698043 C6.07354222,5.61460055 5.61460055,6.07354222 5.32698043,6.6380285 C5.05069892,7.1802615 5,7.80078673 5,10.4 L5,13.6 C5,16.1992133 5.05069892,16.8197385 5.32698043,17.3619715 C5.61460055,17.9264578 6.07354222,18.3853994 6.6380285,18.6730196 C7.1802615,18.9493011 7.80078673,19 10.4,19 L13.6,19 C16.1992133,19 16.8197385,18.9493011 17.3619715,18.6730196 C17.9264578,18.3853994 18.3853994,17.9264578 18.6730196,17.3619715 C18.9493011,16.8197385 19,16.1992133 19,13.6 L19,12 C19,11.4477153 19.4477153,11 20,11 C20.5522847,11 21,11.4477153 21,12 L21,13.6 C21,16.6013118 20.9417054,17.3148033 20.4550326,18.2699525 C19.9756657,19.210763 19.210763,19.9756657 18.2699525,20.4550326 C17.3148033,20.9417054 16.6013118,21 13.6,21 L10.4,21 C7.39868821,21 6.68519669,20.9417054 5.7300475,20.4550326 C4.78923704,19.9756657 4.02433425,19.210763 3.54496738,18.2699525 C3.05829456,17.3148033 3,16.6013118 3,13.6 L3,10.4 C3,7.39868821 3.05829456,6.68519669 3.54496738,5.7300475 C4.02433425,4.78923704 4.78923704,4.02433425 5.7300475,3.54496738 C6.68519669,3.05829456 7.39868821,3 10.4,3 L12,3 Z M20.1601089,3.38235931 C20.5506332,3.7728836 20.5506332,4.40604858 20.1601089,4.79657288 L13.0890411,11.8676407 C12.6985168,12.258165 12.0653518,12.258165 11.6748276,11.8676407 C11.2843033,11.4771164 11.2843033,10.8439514 11.6748276,10.4534271 L18.7458954,3.38235931 C19.1364197,2.99183502 19.7695846,2.99183502 20.1601089,3.38235931 Z" fill="black"/></svg>
        """,
        "swapFrame": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path fill-rule="evenodd" d="M15.7808688,5.87534178 L17.7808688,8.37534178 C18.3046795,9.03010512 17.8385062,10.0000368 17,10.0000368 L7,10.0000368 C6.44771525,10.0000368 6,9.55232157 6,9.00003682 C6,8.44775207 6.44771525,8.00003682 7,8.00003682 L14.9193752,8.00003682 L14.2191312,7.12473187 C13.8741216,6.69346994 13.944043,6.06417756 14.375305,5.71916801 C14.8065669,5.37415847 15.4358593,5.44407984 15.7808688,5.87534178 Z M18,15.0000368 C18,15.5523216 17.5522847,16.0000368 17,16.0000368 L9.08062486,16.0000368 L9.78086881,16.8753418 C10.1258784,17.3066037 10.055957,17.9358961 9.62469505,18.2809056 C9.19343311,18.6259152 8.56414074,18.5559938 8.21913119,18.1247319 L6.21913119,15.6247319 C5.69532051,14.9699685 6.16149379,14.0000368 7,14.0000368 L17,14.0000368 C17.5522847,14.0000368 18,14.4477521 18,15.0000368 Z" fill="black"/></svg>
        """,
        "webSearch": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path fill-rule="evenodd" d="M12,2 C17.5228475,2 22,6.4771525 22,12 C22,17.5228475 17.5228475,22 12,22 C7.54921732,22 3.77756275,19.0923069 2.48100447,15.0728889 C2.46562412,15.0593056 2.45096323,15.0453902 2.43640086,15.0314336 L2.45996971,15.0068921 C2.16113287,14.0578486 2,13.0477416 2,12 C2,6.4771525 6.4771525,2 12,2 Z M12.9997408,17.9764167 L13,19.4 C13,19.6180471 13,19.7936477 12.9935677,19.9394259 C14.0803745,19.8043655 15.1001795,19.4515088 16.0071561,18.9255979 C16,18.7831865 16,18.6115754 16,18.4 L15.9999598,17.6059673 C15.0498315,17.8010967 14.0412955,17.9270742 12.9997408,17.9764167 Z M7.99891046,17.6057362 L8,18.4 C8,18.6115754 8,18.7831865 7.99412362,18.9263665 C8.89879241,19.4510878 9.91859845,19.8040988 11.0060723,19.9388611 C11,19.7936477 11,19.6180471 11,19.4 L10.9991726,17.9763713 C9.95713681,17.9269614 8.94866009,17.8008705 7.99891046,17.6057362 Z M7.99883516,12.6057565 L7.99907056,15.5582912 C8.92704846,15.7744451 9.93947364,15.9178939 10.9994843,15.9737501 L10.9990244,12.9763582 C9.95793174,12.9269776 8.94934286,12.8010144 7.99883516,12.6057565 Z M12.9998008,12.9764139 L12.9999368,15.9738158 C14.0589495,15.9181129 15.0713992,15.7750056 16.0003003,15.558625 L16.00022,12.6059503 C15.049633,12.8011708 14.0409666,12.9270885 12.9998008,12.9764139 Z M4.03961375,11.1958208 L4.02761567,11.3305133 C4.00932682,11.5512539 4,11.7745378 4,12 C4,12.6694495 4.08222833,13.3196936 4.23713589,13.9411831 C4.71720588,14.3110842 5.31351368,14.6427745 5.9985635,14.9265793 L5.99950728,12.0631324 C5.28728417,11.8173897 4.62898561,11.526861 4.03961375,11.1958208 Z M17.9999888,12.0633061 L18.0005019,14.9266648 C18.6833851,14.6435258 19.2793558,14.3122115 19.763247,13.9423374 C19.9177717,13.3196936 20,12.6694495 20,12 C20,11.7279377 19.9864193,11.4590473 19.9598988,11.1939698 C19.3706551,11.5270362 18.7122869,11.8175675 17.9999888,12.0633061 Z M7.99851645,7.60051154 L7.99905151,10.5586233 C8.9288561,10.775334 9.94122047,10.9181718 10.999131,10.9738022 L10.9994099,7.95704495 C9.96218752,7.89767976 8.95495283,7.77744841 7.99851645,7.60051154 Z M12.9999648,7.99553646 L13.0001362,10.9738406 C14.0579333,10.9182572 15.0702004,10.7754855 15.9999382,10.5588582 L16.0003871,7.76537496 C15.0350416,7.89875516 14.0284825,7.97673729 12.9999648,7.99553646 Z M5.72153061,7.04125985 L5.6039813,7.19392554 C5.15795351,7.7865665 4.79238021,8.44319156 4.52348749,9.14757465 L4.31033638,8.9973581 C4.7825041,9.34561522 5.35247874,9.65775303 5.99910782,9.92615114 L5.99907592,7.12571078 C5.90579682,7.09817374 5.81327321,7.07002173 5.72153061,7.04125985 Z M18.000781,7.39570128 L17.99997,9.92653546 C18.5519487,9.69748631 19.0480868,9.43657132 19.4752309,9.1485304 C19.2205657,8.47710436 18.8770237,7.84990414 18.45988,7.27996746 C18.308395,7.32147074 18.1554057,7.35936963 18.000781,7.39570128 Z M12.9929236,4.06101454 C13,4.20555068 13,4.38145507 13,4.6 L12.999,5.994 L13.0220344,5.99472857 C14.0500782,5.97348791 15.0507987,5.88835207 15.9998904,5.7446783 L16,5.6 C16,5.38792678 16,5.2160061 16.005918,5.0726233 C15.1001795,4.54849116 14.0803745,4.19563445 12.9929236,4.06101454 Z M11.0064764,4.0595761 L10.7741848,4.0933267 C9.77354428,4.24719382 8.8340358,4.58647389 7.99184478,5.07498152 C7.99950043,5.20736717 7.9999694,5.36697959 7.99999813,5.56147618 C8.94245371,5.75631269 9.95143293,5.88845003 10.9988069,5.95345962 L11,4.6 C11,4.38145507 11,4.20555068 11.0064764,4.0595761 Z" fill="black"/></svg>
        """,
        "send": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path fill-rule="evenodd" d="M14.6923077,4.30769231 C17.4537314,4.30769231 19.6923077,6.54626856 19.6923077,9.30769231 L19.6923077,13.0769231 C19.6923077,15.8383468 17.4537314,18.0769231 14.6923077,18.0769231 L6.721,18.076 L7.6301837,18.9852009 C8.020708,19.3757252 8.020708,20.0088902 7.6301837,20.3994145 C7.23965941,20.7899388 6.60649443,20.7899388 6.21597014,20.3994145 L3.60058553,17.7840299 C3.21006123,17.3935056 3.21006123,16.7603406 3.60058553,16.3698163 L6.21597014,13.7544317 C6.60649443,13.3639074 7.23965941,13.3639074 7.6301837,13.7544317 C8.020708,14.144956 8.020708,14.778121 7.6301837,15.1686452 L6.722,16.076 L14.6923077,16.0769231 C16.3491619,16.0769231 17.6923077,14.7337773 17.6923077,13.0769231 L17.6923077,9.30769231 C17.6923077,7.65083806 16.3491619,6.30769231 14.6923077,6.30769231 L12.1538462,6.30769231 C11.6015614,6.30769231 11.1538462,5.85997706 11.1538462,5.30769231 C11.1538462,4.75540756 11.6015614,4.30769231 12.1538462,4.30769231 L14.6923077,4.30769231 Z" fill="black"/></svg>
        """,
        "importFile": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path fill-rule="evenodd" d="M19.9696672,4.390028 C20.6660443,4.73499367 21.2341519,5.28732059 21.5914495,5.96907766 C21.959113,6.67061409 22,7.15714634 22,9.2 L22,14.8 C22,16.8428537 21.959113,17.3293859 21.5914495,18.0309223 C21.2341519,18.7126794 20.6660443,19.2650063 19.9696672,19.609972 C19.2616185,19.9607195 18.7671113,20 16.68,20 L7.32,20 C5.23288865,20 4.73838149,19.9607195 4.0303328,19.609972 C3.33395574,19.2650063 2.76584806,18.7126794 2.40855055,18.0309223 C2.04088701,17.3293859 2,16.8428537 2,14.8 L2,9.2 C2,7.15714634 2.04088701,6.67061409 2.40855055,5.96907766 C2.76584806,5.28732059 3.33395574,4.73499367 4.0303328,4.390028 C4.52522405,4.14487275 5.12515027,4.34732378 5.37030552,4.84221503 C5.61546077,5.33710628 5.41300975,5.9370325 4.9181185,6.18218775 C4.59842026,6.34055729 4.34043294,6.5913783 4.18001422,6.89747222 C4.03268359,7.17859284 4,7.56750909 4,9.2 L4,14.8 C4,16.4324909 4.03268359,16.8214072 4.18001422,17.1025278 C4.34043294,17.4086217 4.59842026,17.6594427 4.9181185,17.8178123 C5.22080279,17.9677536 5.62675693,18 7.32,18 L16.68,18 C18.3732431,18 18.7791972,17.9677536 19.0818815,17.8178123 C19.4015797,17.6594427 19.6595671,17.4086217 19.8199858,17.1025278 C19.9673164,16.8214072 20,16.4324909 20,14.8 L20,9.2 C20,7.56750909 19.9673164,7.17859284 19.8199858,6.89747222 C19.6595671,6.5913783 19.4015797,6.34055729 19.0818815,6.18218775 C18.5869903,5.9370325 18.3845392,5.33710628 18.6296945,4.84221503 C18.8748497,4.34732378 19.4747759,4.14487275 19.9696672,4.390028 Z M12,2 C12.5522847,2 13,2.44771525 13,3 L13,12.13 L14.4452998,11.1679497 C14.9048285,10.8615972 15.5256978,10.9857711 15.8320503,11.4452998 C16.1384028,11.9048285 16.0142289,12.5256978 15.5547002,12.8320503 L12.5547002,14.8320503 L12.5301119,14.8482178 L12.503,14.863 L12.5547002,14.8320503 L12.4739482,14.8807773 L12.4941822,14.8694068 L12.503,14.863 L12.4941822,14.8694068 C12.4737332,14.881058 12.4530206,14.891911 12.4320831,14.9019733 C12.4138926,14.9106891 12.3958384,14.9186586 12.377585,14.9260817 C12.3601704,14.9333116 12.3424375,14.9399776 12.3245953,14.9461122 C12.3064164,14.9521315 12.2880643,14.9578309 12.2695717,14.9629985 C12.2525627,14.9680297 12.235207,14.9723901 12.2177904,14.9762714 C12.2008105,14.9797763 12.1841533,14.9830436 12.1674219,14.985888 C12.1486117,14.9893245 12.129524,14.9919882 12.1104106,14.994095 C12.0903823,14.9961486 12.0700712,14.9977974 12.0497114,14.9988267 C12.0326363,14.9997436 12.0159408,15.0001325 11.9992618,15.0001049 C11.9833914,15.0001168 11.9670298,14.9997274 11.9506679,14.998935 C11.9295931,14.9977804 11.908948,14.996094 11.8883846,14.9937739 C11.86981,14.9918951 11.8510562,14.9892682 11.8323509,14.9860989 C11.8155066,14.9829858 11.7985124,14.9796433 11.781614,14.9758641 C11.7637925,14.9721478 11.7464364,14.967768 11.7291607,14.962905 C11.7109341,14.9575299 11.692578,14.9518083 11.6743883,14.9455594 C11.6565641,14.9396127 11.6388232,14.9329219 11.6212139,14.9256945 C11.6031624,14.918229 11.5850995,14.9102319 11.5672635,14.9016929 C11.5527593,14.8946687 11.5387017,14.8874819 11.5247593,14.8799308 C11.5060229,14.8699935 11.4872837,14.8591051 11.4688748,14.8475845 L11.4452998,14.8320503 L8.4452998,12.8320503 C7.98577112,12.5256978 7.86159725,11.9048285 8.16794971,11.4452998 C8.47430216,10.9857711 9.09517151,10.8615972 9.5547002,11.1679497 L11,12.131 L11,3 C11,2.44771525 11.4477153,2 12,2 Z" fill="black"/></svg>
        """,
        "exportFile": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path fill-rule="evenodd" d="M19.9696672,4.390028 C20.6660443,4.73499367 21.2341519,5.28732059 21.5914495,5.96907766 C21.959113,6.67061409 22,7.15714634 22,9.2 L22,14.8 C22,16.8428537 21.959113,17.3293859 21.5914495,18.0309223 C21.2341519,18.7126794 20.6660443,19.2650063 19.9696672,19.609972 C19.2616185,19.9607195 18.7671113,20 16.68,20 L7.32,20 C5.23288865,20 4.73838149,19.9607195 4.0303328,19.609972 C3.33395574,19.2650063 2.76584806,18.7126794 2.40855055,18.0309223 C2.04088701,17.3293859 2,16.8428537 2,14.8 L2,9.2 C2,7.15714634 2.04088701,6.67061409 2.40855055,5.96907766 C2.76584806,5.28732059 3.33395574,4.73499367 4.0303328,4.390028 C4.52522405,4.14487275 5.12515027,4.34732378 5.37030552,4.84221503 C5.61546077,5.33710628 5.41300975,5.9370325 4.9181185,6.18218775 C4.59842026,6.34055729 4.34043294,6.5913783 4.18001422,6.89747222 C4.03268359,7.17859284 4,7.56750909 4,9.2 L4,14.8 C4,16.4324909 4.03268359,16.8214072 4.18001422,17.1025278 C4.34043294,17.4086217 4.59842026,17.6594427 4.9181185,17.8178123 C5.22080279,17.9677536 5.62675693,18 7.32,18 L16.68,18 C18.3732431,18 18.7791972,17.9677536 19.0818815,17.8178123 C19.4015797,17.6594427 19.6595671,17.4086217 19.8199858,17.1025278 C19.9673164,16.8214072 20,16.4324909 20,14.8 L20,9.2 C20,7.56750909 19.9673164,7.17859284 19.8199858,6.89747222 C19.6595671,6.5913783 19.4015797,6.34055729 19.0818815,6.18218775 C18.5869903,5.9370325 18.3845392,5.33710628 18.6296945,4.84221503 C18.8748497,4.34732378 19.4747759,4.14487275 19.9696672,4.390028 Z M11.9751491,2.0002847 L11.9992618,2.00000137 C12.0159408,1.99997376 12.0326363,2.00036265 12.0497114,2.00127953 C12.0700712,2.0023089 12.0903823,2.00395771 12.1104106,2.00601124 C12.129524,2.00811805 12.1486117,2.01078178 12.1674219,2.01421824 C12.1841533,2.01706266 12.2008105,2.02033001 12.2177904,2.0238349 C12.235207,2.02771613 12.2525627,2.03207661 12.2695717,2.03710781 C12.2880643,2.04227541 12.3064164,2.04797476 12.3245953,2.05399404 C12.3424375,2.06012869 12.3601704,2.06679464 12.377585,2.07402458 C12.3958384,2.08144765 12.4138926,2.08941716 12.4320831,2.098133 L12.4739482,2.119329 L12.4941822,2.13069949 C12.4922506,2.12934273 12.4831337,2.1242615 12.4739482,2.119329 L12.5547002,2.16805598 L12.5012951,2.1345719 C12.5109855,2.14017458 12.5205927,2.14594709 12.5301119,2.15188848 L12.5547002,2.16805598 L15.5547002,4.16805598 C16.0142289,4.47440843 16.1384028,5.09527778 15.8320503,5.55480647 C15.5256978,6.01433515 14.9048285,6.13850902 14.4452998,5.83215656 L13,4.87010627 L13,14.0001063 C13,14.552391 12.5522847,15.0001063 12,15.0001063 C11.4477153,15.0001063 11,14.552391 11,14.0001063 L11,4.86910627 L9.5547002,5.83215656 C9.09517151,6.13850902 8.47430216,6.01433515 8.16794971,5.55480647 C7.86159725,5.09527778 7.98577112,4.47440843 8.4452998,4.16805598 L11.4452998,2.16805598 L11.4688748,2.15252177 C11.4872837,2.14100113 11.5060229,2.13011275 11.5247593,2.12017545 C11.5387017,2.11262434 11.5527593,2.10543756 11.5672635,2.09841333 C11.5850995,2.08987434 11.6031624,2.08187731 11.6212139,2.07441172 C11.6388232,2.06718441 11.6565641,2.06049359 11.6743883,2.05454685 C11.692578,2.04829802 11.7109341,2.04257637 11.7291607,2.03720131 C11.7464364,2.03233825 11.7637925,2.0279585 11.781614,2.02424215 C11.7985124,2.020463 11.8155066,2.01712047 11.8323509,2.01400733 C11.8510562,2.01083805 11.86981,2.00821117 11.8883846,2.00633238 C11.908948,2.00401225 11.9295931,2.00232587 11.9506679,2.00117131 C11.9670298,2.00037882 11.9833914,1.99998948 11.9992618,2.00000137 Z" fill="black"/></svg>
        """,
        "toastSuccess": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path fill-rule="evenodd" d="M12,2 C17.5228475,2 22,6.4771525 22,12 C22,17.5228475 17.5228475,22 12,22 C6.4771525,22 2,17.5228475 2,12 C2,6.4771525 6.4771525,2 12,2 Z M12,4 C7.581722,4 4,7.581722 4,12 C4,16.418278 7.581722,20 12,20 C16.418278,20 20,16.418278 20,12 C20,7.581722 16.418278,4 12,4 Z M16.7071068,9.29289322 C17.0976311,9.68341751 17.0976311,10.3165825 16.7071068,10.7071068 L12.4142136,15 C11.633165,15.7810486 10.366835,15.7810486 9.58578644,15 L7.29289322,12.7071068 C6.90236893,12.3165825 6.90236893,11.6834175 7.29289322,11.2928932 C7.68341751,10.9023689 8.31658249,10.9023689 8.70710678,11.2928932 L11,13.5857864 L15.2928932,9.29289322 C15.6834175,8.90236893 16.3165825,8.90236893 16.7071068,9.29289322 Z" fill="black"/></svg>
        """,
        "toastFail": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path fill-rule="evenodd" d="M12,2 C17.5228475,2 22,6.4771525 22,12 C22,17.5228475 17.5228475,22 12,22 C6.4771525,22 2,17.5228475 2,12 C2,6.4771525 6.4771525,2 12,2 Z M12,4 C7.581722,4 4,7.581722 4,12 C4,16.418278 7.581722,20 12,20 C16.418278,20 20,16.418278 20,12 C20,7.581722 16.418278,4 12,4 Z M15.8492424,8.77817459 C16.1151421,9.04407424 16.2093945,9.43666413 16.0931921,9.79429837 C16.0190037,10.0226268 15.8209953,10.2206353 15.4249783,10.6166522 L13.7279221,12.3137085 L15.4249783,14.0107648 C15.8209953,14.4067817 16.0190037,14.6047902 16.0931921,14.8331186 C16.2093945,15.1907529 16.1151421,15.5833428 15.8492424,15.8492424 C15.5833428,16.1151421 15.1907529,16.2093945 14.8331186,16.0931921 C14.6047902,16.0190037 14.4067817,15.8209953 14.0107648,15.4249783 L12.3137085,13.7279221 L10.6166522,15.4249783 C10.2206353,15.8209953 10.0226268,16.0190037 9.79429837,16.0931921 C9.43666413,16.2093945 9.04407424,16.1151421 8.77817459,15.8492424 C8.51227494,15.5833428 8.41802245,15.1907529 8.53422486,14.8331186 C8.60841327,14.6047902 8.80642174,14.4067817 9.20243866,14.0107648 L10.8994949,12.3137085 L9.20243866,10.6166522 C8.80642174,10.2206353 8.60841327,10.0226268 8.53422486,9.79429837 C8.41802245,9.43666413 8.51227494,9.04407424 8.77817459,8.77817459 C9.04407424,8.51227494 9.43666413,8.41802245 9.79429837,8.53422486 C10.0226268,8.60841327 10.2206353,8.80642174 10.6166522,9.20243866 L12.3137085,10.8994949 L14.0107648,9.20243866 C14.4067817,8.80642174 14.6047902,8.60841327 14.8331186,8.53422486 C15.1907529,8.41802245 15.5833428,8.51227494 15.8492424,8.77817459 Z" fill="black"/></svg>
        """,
        "toastWarn": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path fill-rule="evenodd" d="M13.563665,2.76881202 C14.6359857,3.22423968 15.381057,4.31821318 16.7413485,6.45101075 L17.021889,6.89153984 L20.3345724,12.0971853 C21.978932,14.6811788 22.8011117,15.9731756 22.7022035,17.2978379 C22.6160018,18.4523235 22.0338378,19.5128361 21.1061223,20.2053762 C20.0416571,21 18.510241,21 15.4474089,21 L8.55259112,21 C5.48975897,21 3.9583429,21 2.89387772,20.2053762 C1.9661622,19.5128361 1.38399818,18.4523235 1.2977965,17.2978379 C1.19888828,15.9731756 2.02106803,14.6811788 3.66542755,12.0971853 L6.97811101,6.89153984 C8.52105454,4.46691429 9.2925263,3.25460152 10.436335,2.76881202 C11.4355842,2.3444187 12.5644158,2.3444187 13.563665,2.76881202 Z M11.2181675,4.60966453 C11.0961997,4.66146574 10.9698952,4.74965404 10.8038397,4.91370633 C10.3675039,5.3447783 9.94892437,5.94837737 8.66543399,7.96529082 L5.35275053,13.1709363 C3.61845664,15.8962552 3.26932785,16.5949508 3.29052458,17.1190604 C3.29120937,17.133906 3.29120937,17.133906 3.29224458,17.1489189 C3.33534542,17.7261618 3.62642743,18.2564181 4.09028519,18.6026881 C4.50987626,18.9159131 5.2707345,19 8.55259112,19 L15.4474089,19 C18.7292655,19 19.4901237,18.9159131 19.9097148,18.6026881 C20.3735726,18.2564181 20.6646546,17.7261618 20.7077554,17.1489189 C20.7467431,16.6267633 20.4091979,15.9397123 18.6472495,13.1709363 L15.3349196,7.96584621 L15.055121,7.52648125 C13.6739937,5.36101522 13.2042427,4.78906731 12.7818325,4.60966455 L12.5916893,4.54003752 C12.1421163,4.40078344 11.655339,4.42399245 11.2181675,4.60966453 Z M12.25,15.5 C12.9403559,15.5 13.5,16.0596441 13.5,16.75 C13.5,17.4403559 12.9403559,18 12.25,18 C11.5596441,18 11,17.4403559 11,16.75 C11,16.0596441 11.5596441,15.5 12.25,15.5 Z M12.25,7 C12.6260389,7 12.9702884,7.21095639 13.1410065,7.5460095 C13.25,7.75992124 13.25,8.03994749 13.25,8.6 L13.25,12.4 C13.25,12.9600525 13.25,13.2400788 13.1410065,13.4539905 C12.9702884,13.7890436 12.6260389,14 12.25,14 C11.8739611,14 11.5297116,13.7890436 11.3589935,13.4539905 C11.25,13.2400788 11.25,12.9600525 11.25,12.4 L11.25,8.6 C11.25,8.03994749 11.25,7.75992124 11.3589935,7.5460095 C11.5297116,7.21095639 11.8739611,7 12.25,7 Z" fill="black"/></svg>
        """,
        "toastStop": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path fill-rule="evenodd" d="M9.8,5 L14.2,5 C15.8801575,5 16.7202363,5 17.3619715,5.32698043 C17.9264578,5.61460055 18.3853994,6.07354222 18.6730196,6.6380285 C19,7.27976372 19,8.11984248 19,9.8 L19,14.2 C19,15.8801575 19,16.7202363 18.6730196,17.3619715 C18.3853994,17.9264578 17.9264578,18.3853994 17.3619715,18.6730196 C16.7202363,19 15.8801575,19 14.2,19 L9.8,19 C8.11984248,19 7.27976372,19 6.6380285,18.6730196 C6.07354222,18.3853994 5.61460055,17.9264578 5.32698043,17.3619715 C5,16.7202363 5,15.8801575 5,14.2 L5,9.8 C5,8.11984248 5,7.27976372 5.32698043,6.6380285 C5.61460055,6.07354222 6.07354222,5.61460055 6.6380285,5.32698043 C7.27976372,5 8.11984248,5 9.8,5 Z" fill="black"/></svg>
        """,
        "saveTextTemplate": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path fill-rule="evenodd" d="M14.3211917,4.11039691 L20.9284767,20.6286093 C21.1335901,21.1413928 20.8841742,21.7233633 20.3713907,21.9284767 C19.8586072,22.1335901 19.2766367,21.8841742 19.0715233,21.3713907 L16.5594454,15.0881928 C16.5089415,15.0883009 16.4558638,15.0883009 16.4,15.0883009 L7.6,15.0883009 L7.44173223,15.0873214 L4.92847669,21.3713907 C4.72336328,21.8841742 4.14139284,22.1335901 3.62860932,21.9284767 C3.11582581,21.7233633 2.8664099,21.1413928 3.07152331,20.6286093 L9.67880827,4.11039691 C10.516954,2.0150325 13.483046,2.0150325 14.3211917,4.11039691 Z M11.5357617,4.85317827 L8.24173223,13.0873214 L15.7577322,13.0873214 L12.4642383,4.85317827 C12.2966092,4.43410538 11.7033908,4.43410538 11.5357617,4.85317827 Z" fill="black"/></svg>
        """,
        "info": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path fill-rule="evenodd" d="M12,2 C17.5228475,2 22,6.4771525 22,12 C22,17.5228475 17.5228475,22 12,22 C6.4771525,22 2,17.5228475 2,12 C2,6.4771525 6.4771525,2 12,2 Z M12,4 C7.581722,4 4,7.581722 4,12 C4,16.418278 7.581722,20 12,20 C16.418278,20 20,16.418278 20,12 C20,7.581722 16.418278,4 12,4 Z M12,10.5 C12.3760389,10.5 12.7202884,10.7109564 12.8910065,11.0460095 C13,11.2599212 13,11.5399475 13,12.1 L13,15.9 C13,16.4600525 13,16.7400788 12.8910065,16.9539905 C12.7202884,17.2890436 12.3760389,17.5 12,17.5 C11.6239611,17.5 11.2797116,17.2890436 11.1089935,16.9539905 C11,16.7400788 11,16.4600525 11,15.9 L11,12.1 C11,11.5399475 11,11.2599212 11.1089935,11.0460095 C11.2797116,10.7109564 11.6239611,10.5 12,10.5 Z M12,6.5 C12.6903559,6.5 13.25,7.05964406 13.25,7.75 C13.25,8.44035594 12.6903559,9 12,9 C11.3096441,9 10.75,8.44035594 10.75,7.75 C10.75,7.05964406 11.3096441,6.5 12,6.5 Z" fill="black"/></svg>
        """,
        "recentFiles": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M15.7656375,2.18866999 C16.9901571,2.48265113 18.1095301,3.10953014 19,4 C19.8904699,4.89046986 20.5173489,6.00984288 20.81133,7.23436247 C21,8.02022952 21,8.97247143 21,10.8769553 L21,15.6 C21,17.84021 21,18.960315 20.5640261,19.815962 C20.1805326,20.5686104 19.5686104,21.1805326 18.815962,21.5640261 C17.960315,22 16.84021,22 14.6,22 L9.4,22 C7.15978998,22 6.03968496,22 5.184038,21.5640261 C4.43138963,21.1805326 3.8194674,20.5686104 3.4359739,19.815962 C3,18.960315 3,17.84021 3,15.6 L3,8.4 C3,6.15978998 3,5.03968496 3.4359739,4.184038 C3.8194674,3.43138963 4.43138963,2.8194674 5.184038,2.4359739 C5.98620703,2.02724837 7.02080989,2.00170302 8.99287796,2.00010645 L9.40000002,2 L12.1230447,2 C14.0275286,2 14.9797705,2 15.7656375,2.18866999 Z M9.40052294,3.99999993 L8.99449715,4.00010579 C6.99384943,4.00172551 6.40667202,4.05766323 6.092019,4.21798695 C5.71569481,4.4097337 5.4097337,4.71569481 5.21798695,5.092019 C5.04690109,5.42779391 5,6.001836 5,8.4 L5,15.6 C5,17.998164 5.04690109,18.5722061 5.21798695,18.907981 C5.4097337,19.2843052 5.71569481,19.5902663 6.092019,19.782013 C6.42779391,19.9530989 7.001836,20 9.4,20 L14.6,20 C16.998164,20 17.5722061,19.9530989 17.907981,19.782013 C18.2843052,19.5902663 18.5902663,19.2843052 18.782013,18.907981 C18.9530989,18.5722061 19,17.998164 19,15.6 L19,10.8769553 C19,8.69756004 18.978175,8.16603735 18.8665902,7.7012532 C18.6587141,6.83538709 18.2154437,6.04387084 17.5857864,5.41421356 C16.9561292,4.78455629 16.1646129,4.34128589 15.2987468,4.13340983 L15.2104317,4.11352298 C14.7610853,4.01918215 14.1662278,4 12.1230447,4 L9.40052294,3.99999993 Z M15.4539905,15.1089935 C15.7890436,15.2797116 16,15.6239611 16,16 C16,16.3760389 15.7890436,16.7202884 15.4539905,16.8910065 C15.2400788,17 14.9600525,17 14.4,17 L9.6,17 C9.03994749,17 8.75992124,17 8.5460095,16.8910065 C8.21095639,16.7202884 8,16.3760389 8,16 C8,15.6239611 8.21095639,15.2797116 8.5460095,15.1089935 C8.75992124,15 9.03994749,15 9.6,15 L14.4,15 C14.9600525,15 15.2400788,15 15.4539905,15.1089935 Z M15.4539905,11.1089935 C15.7890436,11.2797116 16,11.6239611 16,12 C16,12.3760389 15.7890436,12.7202884 15.4539905,12.8910065 C15.2400788,13 14.9600525,13 14.4,13 L9.6,13 C9.03994749,13 8.75992124,13 8.5460095,12.8910065 C8.21095639,12.7202884 8,12.3760389 8,12 C8,11.6239611 8.21095639,11.2797116 8.5460095,11.1089935 C8.75992124,11 9.03994749,11 9.6,11 L14.4,11 C14.9600525,11 15.2400788,11 15.4539905,11.1089935 Z M15.4539905,7.10899348 C15.7890436,7.27971156 16,7.62396111 16,8 C16,8.37603889 15.7890436,8.72028844 15.4539905,8.89100652 C15.2400788,9 14.9600525,9 14.4,9 L9.6,9 C9.03994749,9 8.75992124,9 8.5460095,8.89100652 C8.21095639,8.72028844 8,8.37603889 8,8 C8,7.62396111 8.21095639,7.27971156 8.5460095,7.10899348 C8.75992124,7 9.03994749,7 9.6,7 L14.4,7 C14.9600525,7 15.2400788,7 15.4539905,7.10899348 Z" fill="black"/></svg>
        """,
        "toSpeech": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M19.815962,4.4359739 C20.5686104,4.8194674 21.1805326,5.43138963 21.5640261,6.184038 C22,7.03968496 22,8.15978998 22,10.4 L22,13.6 C22,15.84021 22,16.960315 21.5640261,17.815962 C21.1805326,18.5686104 20.5686104,19.1805326 19.815962,19.5640261 C18.960315,20 17.84021,20 15.6,20 L3.6,20 C3.03994749,20 2.75992124,20 2.5460095,19.8910065 C2.35784741,19.7951331 2.20486685,19.6421526 2.10899348,19.4539905 C2,19.2400788 2,18.9600525 2,18.4 L2,10.4 C2,8.15978998 2,7.03968496 2.4359739,6.184038 C2.8194674,5.43138963 3.43138963,4.8194674 4.184038,4.4359739 C4.98620703,4.02724837 6.02080989,4.00170302 7.99287797,4.00010644 L8.40000001,4.00000001 L15.6,4 C17.84021,4 18.960315,4 19.815962,4.4359739 Z M8.40052284,5.99999994 L7.99449716,6.00010578 C5.99384942,6.00172551 5.40667202,6.05766323 5.092019,6.21798695 C4.71569481,6.4097337 4.4097337,6.71569481 4.21798695,7.092019 C4.04690109,7.42779391 4,8.001836 4,10.4 L4,18 L15.6,18 C17.998164,18 18.5722061,17.9530989 18.907981,17.782013 C19.2843052,17.5902663 19.5902663,17.2843052 19.782013,16.907981 C19.9530989,16.5722061 20,15.998164 20,13.6 L20,10.4 C20,8.001836 19.9530989,7.42779391 19.782013,7.092019 C19.5902663,6.71569481 19.2843052,6.4097337 18.907981,6.21798697 L18.8418438,6.18734479 C18.4933254,6.04122166 17.8482788,6 15.6,6 L8.40052284,5.99999994 Z M12,8 C12.3760389,8 12.7202884,8.21095639 12.8910065,8.5460095 C13,8.75992124 13,9.03994749 13,9.6 L13,14.4 C13,14.9600525 13,15.2400788 12.8910065,15.4539905 C12.7202884,15.7890436 12.3760389,16 12,16 C11.6239611,16 11.2797116,15.7890436 11.1089935,15.4539905 C11,15.2400788 11,14.9600525 11,14.4 L11,9.6 C11,9.03994749 11,8.75992124 11.1089935,8.5460095 C11.2797116,8.21095639 11.6239611,8 12,8 Z M8,10 C8.37603889,10 8.72028844,10.2109564 8.89100652,10.5460095 C9,10.7599212 9,11.0399475 9,11.6 L9,12.4 C9,12.9600525 9,13.2400788 8.89100652,13.4539905 C8.72028844,13.7890436 8.37603889,14 8,14 C7.62396111,14 7.27971156,13.7890436 7.10899348,13.4539905 C7,13.2400788 7,12.9600525 7,12.4 L7,11.6 C7,11.0399475 7,10.7599212 7.10899348,10.5460095 C7.27971156,10.2109564 7.62396111,10 8,10 Z M16,10 C16.3760389,10 16.7202884,10.2109564 16.8910065,10.5460095 C17,10.7599212 17,11.0399475 17,11.6 L17,12.4 C17,12.9600525 17,13.2400788 16.8910065,13.4539905 C16.7202884,13.7890436 16.3760389,14 16,14 C15.6239611,14 15.2797116,13.7890436 15.1089935,13.4539905 C15,13.2400788 15,12.9600525 15,12.4 L15,11.6 C15,11.0399475 15,10.7599212 15.1089935,10.5460095 C15.2797116,10.2109564 15.6239611,10 16,10 Z" fill="black"/></svg>
        """,
        "removeBg": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M18.6468037,6.76740982 L6.76740982,18.6468037 C6.37139289,19.0428207 6.17338443,19.2408291 5.94505596,19.3150175 C5.58742173,19.43122 5.19483184,19.3369675 4.92893219,19.0710678 C4.66303254,18.8051682 4.56878005,18.4125783 4.68498245,18.054944 C4.75917087,17.8266156 4.95717933,17.6286071 5.35319626,17.2325902 L17.2325902,5.35319626 C17.6286071,4.95717933 17.8266156,4.75917087 18.054944,4.68498245 C18.4125783,4.56878005 18.8051682,4.66303254 19.0710678,4.92893219 C19.3369675,5.19483184 19.43122,5.58742173 19.3150175,5.94505596 C19.2408291,6.17338443 19.0428207,6.37139289 18.6468037,6.76740982 Z M13.461354,6.2960053 L6.2960053,13.461354 C5.89998837,13.8573709 5.70197991,14.0553794 5.47365144,14.1295678 C5.11601721,14.2457702 4.72342732,14.1515177 4.45752767,13.8856181 C4.19162802,13.6197184 4.09737552,13.2271285 4.21357793,12.8694943 C4.28776635,12.6411658 4.48577481,12.4431574 4.88179174,12.0471405 L12.0471405,4.88179174 C12.4431574,4.48577481 12.6411658,4.28776635 12.8694943,4.21357793 C13.2271285,4.09737552 13.6197184,4.19162802 13.8856181,4.45752767 C14.1515177,4.72342732 14.2457702,5.11601721 14.1295678,5.47365144 C14.0553794,5.70197991 13.8573709,5.89998837 13.461354,6.2960053 Z M8.27590429,5.82460078 L5.82460078,8.27590429 C5.42858385,8.67192121 5.23057539,8.86992967 5.00224692,8.94411809 C4.64461268,9.0603205 4.2520228,8.966068 3.98612315,8.70016835 C3.7202235,8.4342687 3.625971,8.04167882 3.74217341,7.68404458 C3.81636183,7.45571611 4.01437029,7.25770765 4.41038722,6.86169072 L6.86169072,4.41038722 C7.25770765,4.01437029 7.45571611,3.81636183 7.68404458,3.74217341 C8.04167882,3.625971 8.4342687,3.7202235 8.70016835,3.98612315 C8.966068,4.2520228 9.0603205,4.64461268 8.94411809,5.00224692 C8.86992967,5.23057539 8.67192121,5.42858385 8.27590429,5.82460078 Z M19.1182083,11.9528595 L11.9528595,19.1182083 C11.5568426,19.5142252 11.3588342,19.7122337 11.1305057,19.7864221 C10.7728715,19.9026245 10.3802816,19.808372 10.1143819,19.5424723 C9.84848227,19.2765727 9.75422977,18.8839828 9.87043218,18.5263486 C9.9446206,18.2980201 10.1426291,18.1000116 10.538646,17.7039947 L17.7039947,10.538646 C18.1000116,10.1426291 18.2980201,9.9446206 18.5263486,9.87043218 C18.8839828,9.75422977 19.2765727,9.84848227 19.5424723,10.1143819 C19.808372,10.3802816 19.9026245,10.7728715 19.7864221,11.1305057 C19.7122337,11.3588342 19.5142252,11.5568426 19.1182083,11.9528595 Z M19.5896128,17.1383093 L17.1383093,19.5896128 C16.7422924,19.9856297 16.5442839,20.1836382 16.3159554,20.2578266 C15.9583212,20.374029 15.5657313,20.2797765 15.2998316,20.0138769 C15.033932,19.7479772 14.9396795,19.3553873 15.0558819,18.9977531 C15.1300703,18.7694246 15.3280788,18.5714161 15.7240957,18.1753992 L18.1753992,15.7240957 C18.5714161,15.3280788 18.7694246,15.1300703 18.9977531,15.0558819 C19.3553873,14.9396795 19.7479772,15.033932 20.0138769,15.2998316 C20.2797765,15.5657313 20.374029,15.9583212 20.2578266,16.3159554 C20.1836382,16.5442839 19.9856297,16.7422924 19.5896128,17.1383093 Z" fill="black"/></svg>
        """,
        "clarity": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path fill-rule="evenodd" d="M12,2 C17.5228475,2 22,6.4771525 22,12 C22,17.5228475 17.5228475,22 12,22 C6.4771525,22 2,17.5228475 2,12 C2,6.4771525 6.4771525,2 12,2 Z M4,12 C4,16.0796344 7.05371356,19.4460359 11.0000487,19.9381123 L11.0000487,4.06188768 C7.05371356,4.55396414 4,7.92036556 4,12 Z M19.6741326,14.267414 L14.3878884,19.5532371 L14.267414,19.6741326 C16.862514,18.9085818 18.9085818,16.862514 19.6741326,14.267414 Z M19.378937,8.90410887 L13.4450793,14.8391919 C13.2618245,15.0224468 13.1209697,15.1633015 12.9998903,15.2691074 L13,18.112 L19.1962145,11.9164839 C19.5617235,11.5509749 19.7585568,11.3541416 19.9662345,11.2676543 C19.8914369,10.4363058 19.6889233,9.64206683 19.378937,8.90410887 Z M16.6034896,6.02392736 L13.2093771,9.41803991 C13.1323738,9.4950432 13.0628569,9.56456006 12.9991479,9.6271359 L13,12.454 L18.2534055,7.20243866 L18.3379069,7.11766361 C17.9283612,6.58680551 17.453608,6.10883226 16.9256429,5.69573947 C16.8374838,5.78993315 16.730703,5.896714 16.6034896,6.02392736 Z M13.0009551,4.06201291 L13,6.797 L15.1530349,4.64532969 C14.4784582,4.3557501 13.7560513,4.15626425 13.0009551,4.06201291 Z" fill="black"/></svg>
        """,
        "separateAudio": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M12.9988039,18.7342304 C12.9946176,19.0812437 12.9757792,19.2876147 12.8910065,19.4539905 C12.7202884,19.7890436 12.3760389,20 12,20 C11.6239611,20 11.2797116,19.7890436 11.1089935,19.4539905 C11,19.2400788 11,18.9600525 11,18.4 L11,5.6 C11,5.03994749 11,4.75992124 11.1089935,4.5460095 C11.2797116,4.21095639 11.6239611,4 12,4 C12.3760389,4 12.7202884,4.21095639 12.8910065,4.5460095 C12.9757792,4.7123853 12.9946176,4.9187563 12.9988039,5.26576958 L12.9988039,18.7342304 Z M18.2908885,9.29289322 C17.9003642,9.68341751 17.9003642,10.3165825 18.2908885,10.7071068 L18.5837817,11 L16,11 C15.4477153,11 15,11.4477153 15,12 C15,12.5522847 15.4477153,13 16,13 L20.9979952,13 C21.8889001,13 22.3350669,11.9228581 21.705102,11.2928932 L19.705102,9.29289322 C19.3145777,8.90236893 18.6814128,8.90236893 18.2908885,9.29289322 Z M5.70911154,14.7071068 C6.09963583,14.3165825 6.09963583,13.6834175 5.70911154,13.2928932 L5.41621832,13 L8,13 C8.55228475,13 9,12.5522847 9,12 C9,11.4477153 8.55228475,11 8,11 L3.00200475,11 C2.1110999,11 1.66493311,12.0771419 2.29489797,12.7071068 L4.29489797,14.7071068 C4.68542227,15.0976311 5.31858724,15.0976311 5.70911154,14.7071068 Z" fill="black"/></svg>
        """,
        "newFile": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path fill-rule="evenodd" d="M18.815962,3.4359739 C19.5686104,3.8194674 20.1805326,4.43138963 20.5640261,5.184038 C21,6.03968496 21,7.15978998 21,9.4 L21,14.6 C21,16.84021 21,17.960315 20.5640261,18.815962 C20.1805326,19.5686104 19.5686104,20.1805326 18.815962,20.5640261 C17.960315,21 16.84021,21 14.6,21 L9.4,21 C7.15978998,21 6.03968496,21 5.184038,20.5640261 C4.43138963,20.1805326 3.8194674,19.5686104 3.4359739,18.815962 C3,17.960315 3,16.84021 3,14.6 L3,9.4 C3,7.15978998 3,6.03968496 3.4359739,5.184038 C3.8194674,4.43138963 4.43138963,3.8194674 5.184038,3.4359739 C6.03968496,3 7.15978998,3 9.4,3 L14.6,3 C16.84021,3 17.960315,3 18.815962,3.4359739 Z M6.092019,5.21798695 C5.71569481,5.4097337 5.4097337,5.71569481 5.21798695,6.092019 C5.04690109,6.42779391 5,7.001836 5,9.4 L5,14.6 C5,16.998164 5.04690109,17.5722061 5.21798695,17.907981 C5.4097337,18.2843052 5.71569481,18.5902663 6.092019,18.782013 C6.42779391,18.9530989 7.001836,19 9.4,19 L14.6,19 C16.998164,19 17.5722061,18.9530989 17.907981,18.782013 C18.2843052,18.5902663 18.5902663,18.2843052 18.782013,17.907981 C18.9530989,17.5722061 19,16.998164 19,14.6 L19,9.4 C19,7.001836 18.9530989,6.42779391 18.782013,6.092019 C18.5902663,5.71569481 18.2843052,5.4097337 17.907981,5.21798696 L17.8418438,5.18734478 C17.4933254,5.04122166 16.8482788,5 14.6,5 L9.4,5 C7.001836,5 6.42779391,5.04690109 6.092019,5.21798695 Z M12,7 C12.3760389,7 12.7202884,7.21095639 12.8910065,7.5460095 C13,7.75992124 13,8.03994749 13,8.6 L13,11 L15.4,11 C15.9600525,11 16.2400788,11 16.4539905,11.1089935 C16.7890436,11.2797116 17,11.6239611 17,12 C17,12.3760389 16.7890436,12.7202884 16.4539905,12.8910065 C16.2400788,13 15.9600525,13 15.4,13 L13,13 L13,15.4 C13,15.9600525 13,16.2400788 12.8910065,16.4539905 C12.7202884,16.7890436 12.3760389,17 12,17 C11.6239611,17 11.2797116,16.7890436 11.1089935,16.4539905 C11,16.2400788 11,15.9600525 11,15.4 L11,13 L8.6,13 C8.03994749,13 7.75992124,13 7.5460095,12.8910065 C7.21095639,12.7202884 7,12.3760389 7,12 C7,11.6239611 7.21095639,11.2797116 7.5460095,11.1089935 C7.75992124,11 8.03994749,11 8.6,11 L11,11 L11,8.6 C11,8.03994749 11,7.75992124 11.1089935,7.5460095 C11.2797116,7.21095639 11.6239611,7 12,7 Z" fill="black"/></svg>
        """,
        "settings": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path fill-rule="evenodd" d="M9.20088608,2.00726738 L14.9730848,2.0576406 L15.2694586,2.07490758 C15.9556071,2.14908788 16.5986882,2.45823839 17.0866566,2.95479857 L21.1325982,7.07197868 C21.6902763,7.63947603 21.9996759,8.40526691 21.9927326,9.20088608 L21.9423594,14.9730848 C21.9354161,15.768704 21.6126988,16.5289785 21.0452014,17.0866566 L16.9280213,21.1325982 C16.360524,21.6902763 15.5947331,21.9996759 14.7991139,21.9927326 L9.02691517,21.9423594 C8.231296,21.9354161 7.47102151,21.6126988 6.91334343,21.0452014 L2.8674018,16.9280213 C2.30972371,16.360524 2.00032411,15.5947331 2.00726738,14.7991139 L2.05764059,9.02691517 C2.06458385,8.231296 2.38730123,7.47102151 2.95479857,6.91334343 L7.07197868,2.8674018 C7.63947603,2.30972371 8.40526691,2.00032411 9.20088608,2.00726738 Z M9.18343302,4.00719122 C8.91822662,4.0048768 8.66296299,4.10801 8.47379721,4.2939027 L4.3566171,8.33984433 C4.16745132,8.52573702 4.05987886,8.77916185 4.05756444,9.04436824 L4.00719122,14.816567 C4.0048768,15.0817734 4.10801,15.337037 4.2939027,15.5262028 L8.33984433,19.6433829 C8.52573702,19.8325487 8.77916185,19.9401211 9.04436824,19.9424356 L14.816567,19.9928088 C15.0817734,19.9951232 15.337037,19.89199 15.5262028,19.7060973 L19.6433829,15.6601557 C19.8325487,15.474263 19.9401211,15.2208381 19.9424356,14.9556318 L19.9928088,9.18343301 C19.9951232,8.91822662 19.89199,8.66296299 19.7060973,8.47379721 L15.6601557,4.3566171 C15.474263,4.16745132 15.2208381,4.05987886 14.9556317,4.05756445 L9.18343302,4.00719122 Z M12,8 C14.209139,8 16,9.790861 16,12 C16,14.209139 14.209139,16 12,16 C9.790861,16 8,14.209139 8,12 C8,9.790861 9.790861,8 12,8 Z M12,10 C10.8954305,10 10,10.8954305 10,12 C10,13.1045695 10.8954305,14 12,14 C13.1045695,14 14,13.1045695 14,12 C14,10.8954305 13.1045695,10 12,10 Z" fill="black"/></svg>
        """,
        "gridView": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path fill-rule="evenodd" d="M9.1480503,3.2283614 C9.88313456,3.53284327 10.4671567,4.11686544 10.7716386,4.8519497 C10.9784118,5.35114428 11,5.66755077 11,7 C11,8.33244923 10.9784118,8.64885572 10.7716386,9.1480503 C10.4671567,9.88313456 9.88313456,10.4671567 9.1480503,10.7716386 C8.64885572,10.9784118 8.33244923,11 7,11 C5.66755077,11 5.35114428,10.9784118 4.8519497,10.7716386 C4.11686544,10.4671567 3.53284327,9.88313456 3.2283614,9.1480503 C3.02158824,8.64885572 3,8.33244923 3,7 C3,5.66755077 3.02158824,5.35114428 3.2283614,4.8519497 C3.53284327,4.11686544 4.11686544,3.53284327 4.8519497,3.2283614 C5.35114428,3.02158824 5.66755077,3 7,3 C8.33244923,3 8.64885572,3.02158824 9.1480503,3.2283614 Z M5.61731657,5.07612047 C5.37228848,5.17761442 5.17761442,5.37228848 5.07612047,5.61731657 C5.01647199,5.76132072 5,6.00274133 5,7 C5,7.99725867 5.01647199,8.23867928 5.07612047,8.38268343 C5.17761442,8.62771152 5.37228848,8.82238558 5.61731657,8.92387953 C5.76132072,8.98352801 6.00274133,9 7,9 C7.99725867,9 8.23867928,8.98352801 8.38268343,8.92387953 C8.62771152,8.82238558 8.82238558,8.62771152 8.92387953,8.38268343 C8.98352801,8.23867928 9,7.99725867 9,7 C9,6.00274133 8.98352801,5.76132072 8.92387953,5.61731657 C8.82238558,5.37228848 8.62771152,5.17761442 8.38268343,5.07612047 C8.23867928,5.01647199 7.99725867,5 7,5 C6.00274133,5 5.76132072,5.01647199 5.61731657,5.07612047 Z M19.1480503,3.2283614 L19.284077,3.28869625 C19.9550454,3.60643613 20.4861868,4.16280821 20.7716386,4.8519497 C20.9784118,5.35114428 21,5.66755077 21,7 C21,8.33244923 20.9784118,8.64885572 20.7716386,9.1480503 C20.4671567,9.88313456 19.8831346,10.4671567 19.1480503,10.7716386 C18.6488557,10.9784118 18.3324492,11 17,11 C15.6675508,11 15.3511443,10.9784118 14.8519497,10.7716386 C14.1168654,10.4671567 13.5328433,9.88313456 13.2283614,9.1480503 C13.0215882,8.64885572 13,8.33244923 13,7 C13,5.66755077 13.0215882,5.35114428 13.2283614,4.8519497 C13.5328433,4.11686544 14.1168654,3.53284327 14.8519497,3.2283614 C15.3511443,3.02158824 15.6675508,3 17,3 C18.3324492,3 18.6488557,3.02158824 19.1480503,3.2283614 Z M15.6173166,5.07612047 C15.3722885,5.17761442 15.1776144,5.37228848 15.0761205,5.61731657 C15.016472,5.76132072 15,6.00274133 15,7 C15,7.99725867 15.016472,8.23867928 15.0761205,8.38268343 C15.1776144,8.62771152 15.3722885,8.82238558 15.6173166,8.92387953 C15.7613207,8.98352801 16.0027413,9 17,9 C17.9972587,9 18.2386793,8.98352801 18.3826834,8.92387953 C18.6277115,8.82238558 18.8223856,8.62771152 18.9238795,8.38268343 C18.983528,8.23867928 19,7.99725867 19,7 C19,6.00274133 18.983528,5.76132072 18.9238795,5.61731657 C18.8223856,5.37228848 18.6277115,5.17761442 18.3826834,5.07612047 L18.3543803,5.06543583 C18.2055492,5.01447734 17.93493,5 17,5 C16.0027413,5 15.7613207,5.01647199 15.6173166,5.07612047 Z M9.1480503,13.2283614 L9.28407697,13.2886963 C9.95504537,13.6064361 10.4861868,14.1628082 10.7716386,14.8519497 C10.9784118,15.3511443 11,15.6675508 11,17 C11,18.3324492 10.9784118,18.6488557 10.7716386,19.1480503 C10.4671567,19.8831346 9.88313456,20.4671567 9.1480503,20.7716386 C8.64885572,20.9784118 8.33244923,21 7,21 C5.66755077,21 5.35114428,20.9784118 4.8519497,20.7716386 C4.11686544,20.4671567 3.53284327,19.8831346 3.2283614,19.1480503 C3.02158824,18.6488557 3,18.3324492 3,17 C3,15.6675508 3.02158824,15.3511443 3.2283614,14.8519497 C3.53284327,14.1168654 4.11686544,13.5328433 4.8519497,13.2283614 C5.35114428,13.0215882 5.66755077,13 7,13 C8.33244923,13 8.64885572,13.0215882 9.1480503,13.2283614 Z M5.61731657,15.0761205 C5.37228848,15.1776144 5.17761442,15.3722885 5.07612047,15.6173166 C5.01647199,15.7613207 5,16.0027413 5,17 C5,17.9972587 5.01647199,18.2386793 5.07612047,18.3826834 C5.17761442,18.6277115 5.37228848,18.8223856 5.61731657,18.9238795 C5.76132072,18.983528 6.00274133,19 7,19 C7.99725867,19 8.23867928,18.983528 8.38268343,18.9238795 C8.62771152,18.8223856 8.82238558,18.6277115 8.92387953,18.3826834 C8.98352801,18.2386793 9,17.9972587 9,17 C9,16.0027413 8.98352801,15.7613207 8.92387953,15.6173166 C8.82238558,15.3722885 8.62771152,15.1776144 8.38268343,15.0761205 L8.3543803,15.0654358 C8.20554921,15.0144773 7.93493,15 7,15 C6.00274133,15 5.76132072,15.016472 5.61731657,15.0761205 Z M19.1480503,13.2283614 C19.8831346,13.5328433 20.4671567,14.1168654 20.7716386,14.8519497 C20.9784118,15.3511443 21,15.6675508 21,17 C21,18.3324492 20.9784118,18.6488557 20.7716386,19.1480503 C20.4671567,19.8831346 19.8831346,20.4671567 19.1480503,20.7716386 C18.6488557,20.9784118 18.3324492,21 17,21 C15.6675508,21 15.3511443,20.9784118 14.8519497,20.7716386 C14.1168654,20.4671567 13.5328433,19.8831346 13.2283614,19.1480503 C13.0215882,18.6488557 13,18.3324492 13,17 C13,15.6675508 13.0215882,15.3511443 13.2283614,14.8519497 C13.5328433,14.1168654 14.1168654,13.5328433 14.8519497,13.2283614 C15.3511443,13.0215882 15.6675508,13 17,13 C18.3324492,13 18.6488557,13.0215882 19.1480503,13.2283614 Z M15.6173166,15.0761205 C15.3722885,15.1776144 15.1776144,15.3722885 15.0761205,15.6173166 C15.016472,15.7613207 15,16.0027413 15,17 C15,17.9972587 15.016472,18.2386793 15.0761205,18.3826834 C15.1776144,18.6277115 15.3722885,18.8223856 15.6173166,18.9238795 C15.7613207,18.983528 16.0027413,19 17,19 C17.9972587,19 18.2386793,18.983528 18.3826834,18.9238795 C18.6277115,18.8223856 18.8223856,18.6277115 18.9238795,18.3826834 C18.983528,18.2386793 19,17.9972587 19,17 C19,16.0027413 18.983528,15.7613207 18.9238795,15.6173166 C18.8223856,15.3722885 18.6277115,15.1776144 18.3826834,15.0761205 C18.2386793,15.016472 17.9972587,15 17,15 C16.0027413,15 15.7613207,15.016472 15.6173166,15.0761205 Z" fill="black"/></svg>
        """,
        "listView": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M18.9,6 L10.1,6 C9.53994749,6 9.25992124,6 9.0460095,5.89100652 C8.71095639,5.72028844 8.5,5.37603889 8.5,5 C8.5,4.62396111 8.71095639,4.27971156 9.0460095,4.10899348 C9.25992124,4 9.53994749,4 10.1,4 L18.9,4 C19.4600525,4 19.7400788,4 19.9539905,4.10899348 C20.2890436,4.27971156 20.5,4.62396111 20.5,5 C20.5,5.37603889 20.2890436,5.72028844 19.9539905,5.89100652 C19.7400788,6 19.4600525,6 18.9,6 Z M5,6 C4.53405842,6 4.30108763,6 4.11731657,5.92387953 C3.74364218,5.76909853 3.5,5.40446224 3.5,5 C3.5,4.59553776 3.74364218,4.23090147 4.11731657,4.07612047 C4.30108763,4 4.53405842,4 5,4 C5.46594158,4 5.69891237,4 5.88268343,4.07612047 C6.25635782,4.23090147 6.5,4.59553776 6.5,5 C6.5,5.40446224 6.25635782,5.76909853 5.88268343,5.92387953 C5.69891237,6 5.46594158,6 5,6 Z M18.9,13 L10.1,13 C9.53994749,13 9.25992124,13 9.0460095,12.8910065 C8.71095639,12.7202884 8.5,12.3760389 8.5,12 C8.5,11.6239611 8.71095639,11.2797116 9.0460095,11.1089935 C9.25992124,11 9.53994749,11 10.1,11 L18.9,11 C19.4600525,11 19.7400788,11 19.9539905,11.1089935 C20.2890436,11.2797116 20.5,11.6239611 20.5,12 C20.5,12.3760389 20.2890436,12.7202884 19.9539905,12.8910065 C19.7400788,13 19.4600525,13 18.9,13 Z M5,13 C4.53405842,13 4.30108763,13 4.11731657,12.9238795 C3.74364218,12.7690985 3.5,12.4044622 3.5,12 C3.5,11.5955378 3.74364218,11.2309015 4.11731657,11.0761205 C4.30108763,11 4.53405842,11 5,11 C5.46594158,11 5.69891237,11 5.88268343,11.0761205 C6.25635782,11.2309015 6.5,11.5955378 6.5,12 C6.5,12.4044622 6.25635782,12.7690985 5.88268343,12.9238795 C5.69891237,13 5.46594158,13 5,13 Z M18.9,20 L10.1,20 C9.53994749,20 9.25992124,20 9.0460095,19.8910065 C8.71095639,19.7202884 8.5,19.3760389 8.5,19 C8.5,18.6239611 8.71095639,18.2797116 9.0460095,18.1089935 C9.25992124,18 9.53994749,18 10.1,18 L18.9,18 C19.4600525,18 19.7400788,18 19.9539905,18.1089935 C20.2890436,18.2797116 20.5,18.6239611 20.5,19 C20.5,19.3760389 20.2890436,19.7202884 19.9539905,19.8910065 C19.7400788,20 19.4600525,20 18.9,20 Z M5,20 C4.53405842,20 4.30108763,20 4.11731657,19.9238795 C3.74364218,19.7690985 3.5,19.4044622 3.5,19 C3.5,18.5955378 3.74364218,18.2309015 4.11731657,18.0761205 C4.30108763,18 4.53405842,18 5,18 C5.46594158,18 5.69891237,18 5.88268343,18.0761205 C6.25635782,18.2309015 6.5,18.5955378 6.5,19 C6.5,19.4044622 6.25635782,19.7690985 5.88268343,19.9238795 C5.69891237,20 5.46594158,20 5,20 Z" fill="black"/></svg>
        """,
        "video": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M12,20 L19,20 C19.5522847,20 20,20.4477153 20,21 C20,21.5522847 19.5522847,22 19,22 L12,22 C6.47715,22 2,17.5228 2,12 C2,6.47715 6.47715,2 12,2 C17.5228,2 22,6.47715 22,12 C22,14.0555391 21.3797913,15.9662599 20.3162915,17.5551689 C20.1312259,17.8316638 19.8228123,18 19.4900981,18 L19.4858042,18 C18.6856066,18 18.2089685,17.1078816 18.6539292,16.4428055 C19.5041891,15.1719351 20,13.6438792 20,12 C20,7.58172 16.4183,4 12,4 C7.58172,4 4,7.58172 4,12 C4,16.4183 7.58172,20 12,20 Z M12,10 C10.8954,10 10,9.10457 10,8 C10,6.89543 10.8954,6 12,6 C13.1046,6 14,6.89543 14,8 C14,9.10457 13.1046,10 12,10 Z M8,14 C6.89543,14 6,13.1046 6,12 C6,10.8954 6.89543,10 8,10 C9.10457,10 10,10.8954 10,12 C10,13.1046 9.10457,14 8,14 Z M16,14 C14.8954,14 14,13.1046 14,12 C14,10.8954 14.8954,10 16,10 C17.1046,10 18,10.8954 18,12 C18,13.1046 17.1046,14 16,14 Z M12,18 C10.8954,18 10,17.1046 10,16 C10,14.8954 10.8954,14 12,14 C13.1046,14 14,14.8954 14,16 C14,17.1046 13.1046,18 12,18 Z" fill="black"/></svg>
        """,
        "audio": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path fill-rule="evenodd" d="M17.4,3 C19.3430635,3 21,4.30634802 21,6.04987027 L21,18 L20.9954375,18.1827516 C20.9167312,19.7545041 19.8295744,21 18.5,21 C17.1192881,21 16,19.6568542 16,18 C16,16.3431458 17.1192881,15 18.5,15 C18.6715236,15 18.8390128,15.0207284 19.0008228,15.0602115 L19,6.04987027 C19,5.52916834 18.3288172,5 17.4,5 L9.6,5 C8.67118281,5 8,5.52916834 8,6.04987027 L8,18 L7.99543746,18.1827516 C7.91673116,19.7545041 6.8295744,21 5.5,21 C4.11928813,21 3,19.6568542 3,18 C3,16.3431458 4.11928813,15 5.5,15 C5.67129267,15 5.83856172,15.0206726 6.00016911,15.0600521 L6,6.04987027 C6,4.30634802 7.65693649,3 9.6,3 L17.4,3 Z" fill="black"/></svg>
        """,
        "audioSpeaker": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M9.78042309,4.22303561 C10.4293798,4.15135434 11.0724713,4.40094878 11.5031555,4.89165656 C12,5.4577452 12,6.32026038 12,8.04529073 L12,15.9546274 C12,17.6796533 12,18.5421662 11.5031579,19.1082542 C11.0724757,19.5989615 10.4293868,19.8485572 9.78043149,19.7768788 C9.03178594,19.6941895 8.44991956,19.0575105 7.2861868,17.7841526 L5.24474054,15.5516097 C5.05092006,15.339646 4.95400983,15.2336642 4.85263001,15.1662108 C4.76257437,15.106292 4.66488749,15.0590986 4.56044747,15.0309462 C4.44092046,14.9987269 4.27240962,15.0038137 3.93730831,14.9830279 C3.64240899,14.9647358 3.42528308,14.9267289 3.23463314,14.8477591 C2.74457696,14.6447712 2.35522885,14.255423 2.15224093,13.7653669 C2,13.3978247 2,12.9318832 2,12 C2,11.0681168 2,10.6021753 2.15224093,10.2346331 C2.35522885,9.74457696 2.74457696,9.35522885 3.23463314,9.15224093 C3.42528271,9.0732713 3.64240814,9.03526439 3.93730657,9.01697222 C4.27240805,8.99618632 4.44091898,9.00127311 4.56044852,8.96905247 C4.66488891,8.94089929 4.76257472,8.89370305 4.85263038,8.83378332 C4.9540117,8.76632791 5.05092059,8.66034486 5.24473837,8.44837876 L7.28618372,6.21578067 C8.4499118,4.94241244 9.03177584,4.30572832 9.78042309,4.22303561 Z M16.0574347,7.24538838 C17.280325,8.37740168 18,10.1234609 18,12 C18,13.8765391 17.280325,15.6225983 16.0574347,16.7546116 C15.6521415,17.1297861 15.0194475,17.1053701 14.644273,16.7000769 C14.2690985,16.2947837 14.2935145,15.6620897 14.6988077,15.2869152 C15.5010791,14.5442633 16,13.3337926 16,12 C16,10.6662074 15.5010791,9.45573673 14.6988077,8.71308478 C14.2935145,8.3379103 14.2690985,7.70521626 14.644273,7.29992309 C15.0194475,6.89462992 15.6521415,6.8702139 16.0574347,7.24538838 Z M20.1881454,5.41360362 C21.3342884,6.99683911 22,9.40703003 22,12 C22,14.59297 21.3342884,17.0031609 20.1881454,18.5863964 C19.8642877,19.0337604 19.2390889,19.133882 18.7917248,18.8100242 C18.3443608,18.4861665 18.2442392,17.8609677 18.5680969,17.4136036 C19.4471158,16.1993625 20,14.1976602 20,12 C20,9.80233976 19.4471158,7.80063747 18.5680969,6.58639638 C18.2442392,6.13903234 18.3443608,5.51383353 18.7917248,5.18997575 C19.2390889,4.86611797 19.8642877,4.96623958 20.1881454,5.41360362 Z" fill="black" fill-rule="evenodd"/></svg>
        """,
        "image": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path fill-rule="evenodd" d="M16.2,4 C18.5012462,4 19.0479856,4.04467038 19.815962,4.43597392 L20.0914373,4.59032027 C20.7180217,4.97464681 21.2284693,5.52547068 21.5640261,6.184038 C21.9553296,6.95201441 22,7.49875384 22,9.8 L22,14.2 C22,16.5012462 21.9553296,17.0479856 21.5640261,17.815962 C21.1805326,18.5686104 20.5686104,19.1805326 19.815962,19.5640261 C19.0479856,19.9553296 18.5012462,20 16.2,20 L7.8,20 C5.49875384,20 4.95201441,19.9553296 4.184038,19.5640261 C3.43138963,19.1805326 2.8194674,18.5686104 2.4359739,17.815962 C2.04467038,17.0479856 2,16.5012462 2,14.2 L2,9.8 C2,7.49875384 2.04467038,6.95201441 2.4359739,6.184038 C2.8194674,5.43138963 3.43138963,4.8194674 4.184038,4.4359739 C4.91926163,4.06135875 5.5459482,4.00165717 7.494397,4.00007988 L7.80000001,4.00000001 L16.2,4 Z M7.80026148,5.99999997 L7.49546806,6.00007952 C5.9054993,6.00136674 5.42785554,6.04686969 5.092019,6.21798695 C4.71569481,6.4097337 4.4097337,6.71569481 4.21798695,7.092019 C4.03707473,7.44707923 4,7.90085237 4,9.8 L4,14.2 C4,16.0991476 4.03707473,16.5529208 4.21798695,16.907981 C4.32668692,17.1213167 4.47209175,17.31204 4.64621255,17.4721619 L14.0790484,9.76231624 C15.1382553,8.89661825 16.7344869,9.32598077 17.2164648,10.6062345 L19.6659331,17.1066506 C19.7082502,17.0429467 19.7470322,16.9766347 19.782013,16.907981 C19.9629253,16.5529208 20,16.0991476 20,14.2 L20,9.8 C20,7.90085237 19.9629253,7.44707923 19.782013,7.092019 C19.5902663,6.71569481 19.2843052,6.4097337 18.907981,6.21798697 L18.8399216,6.18572544 C18.4905531,6.03258521 17.9804509,6 16.2,6 L7.80026148,5.99999997 Z M7.5,9 C8.32842712,9 9,9.67157288 9,10.5 C9,11.3284271 8.32842712,12 7.5,12 C6.67157288,12 6,11.3284271 6,10.5 C6,9.67157288 6.67157288,9 7.5,9 Z" fill="black"/></svg>
        """,
        "subtitle": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path fill-rule="nonzero" d="M19.815962,4.43597392 L20.0914373,4.59032027 C20.7180217,4.97464681 21.2284693,5.52547068 21.5640261,6.184038 C21.9553296,6.95201441 22,7.49875384 22,9.8 L22,14.2 C22,16.5012462 21.9553296,17.0479856 21.5640261,17.815962 C21.1805326,18.5686104 20.5686104,19.1805326 19.815962,19.5640261 C19.0479856,19.9553296 18.5012462,20 16.2,20 L7.8,20 C5.49875384,20 4.95201441,19.9553296 4.184038,19.5640261 C3.43138963,19.1805326 2.8194674,18.5686104 2.4359739,17.815962 C2.04467038,17.0479856 2,16.5012462 2,14.2 L2,9.8 C2,7.49875384 2.04467038,6.95201441 2.4359739,6.184038 C2.8194674,5.43138963 3.43138963,4.8194674 4.184038,4.4359739 C4.91926163,4.06135875 5.5459482,4.00165717 7.494397,4.00007988 L7.80000001,4.00000001 L16.2,4 C18.5012462,4 19.0479856,4.04467038 19.815962,4.43597392 Z M7.49546806,6.00007952 C5.9054993,6.00136674 5.42785554,6.04686969 5.092019,6.21798695 C4.71569481,6.4097337 4.4097337,6.71569481 4.21798695,7.092019 C4.03707473,7.44707923 4,7.90085237 4,9.8 L4,14.2 C4,16.0991476 4.03707473,16.5529208 4.21798695,16.907981 C4.4097337,17.2843052 4.71569481,17.5902663 5.092019,17.782013 C5.44707923,17.9629253 5.90085237,18 7.8,18 L16.2,18 C18.0991476,18 18.5529208,17.9629253 18.907981,17.782013 C19.2843052,17.5902663 19.5902663,17.2843052 19.782013,16.907981 C19.9629253,16.5529208 20,16.0991476 20,14.2 L20,9.8 C20,7.90085237 19.9629253,7.44707923 19.782013,7.092019 C19.5902663,6.71569481 19.2843052,6.4097337 18.907981,6.21798697 L18.8399216,6.18572544 C18.4905531,6.03258521 17.9804509,6 16.2,6 L7.80026148,5.99999997 Z M8,13 L16,13 C16.5522847,13 17,13.4477153 17,14 C17,14.5522847 16.5522847,15 16,15 L8,15 C7.44771525,15 7,14.5522847 7,14 C7,13.4477153 7.44771525,13 8,13 Z" fill="black"/></svg>
        """,
        // 调节轨道的图标：一上一下两根带滑钮的推杆
        "adjust": """
        <svg width="24px" height="24px" viewBox="0 0 24 24" version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"><title>调节</title><g id="调节" stroke="none" fill="none"><g id="24px参考"></g><path d="M12,4 C12.3760389,4 12.7202884,4.21095639 12.8910065,4.5460095 C13,4.75992124 13,5.03994749 13,5.6 L13.0010775,11.2681881 C13.5982846,11.6141507 14,12.2601625 14,13 C14,13.7398375 13.5982846,14.3858493 13.0010775,14.7318119 L13,18.4 C13,18.9600525 13,19.2400788 12.8910065,19.4539905 C12.7202884,19.7890436 12.3760389,20 12,20 C11.6239611,20 11.2797116,19.7890436 11.1089935,19.4539905 C11,19.2400788 11,18.9600525 11,18.4 L10.9999275,14.7323937 C10.4021661,14.3865739 10,13.7402524 10,13 C10,12.2597476 10.4021661,11.6134261 10.9999275,11.2676063 L11,5.6 C11,5.03994749 11,4.75992124 11.1089935,4.5460095 C11.2797116,4.21095639 11.6239611,4 12,4 Z M5,6 C5.37603889,6 5.72028844,6.21095639 5.89100652,6.5460095 C6,6.75992124 6,7.03994749 6,7.6 L6.00007248,9.26760632 C6.59783388,9.61342606 7,10.2597476 7,11 C7,11.7402524 6.59783388,12.3865739 6.00007248,12.7323937 L6,16.4 C6,16.9600525 6,17.2400788 5.89100652,17.4539905 C5.72028844,17.7890436 5.37603889,18 5,18 C4.62396111,18 4.27971156,17.7890436 4.10899348,17.4539905 C4,17.2400788 4,16.9600525 4,16.4 L3.9989225,12.7318119 C3.40171539,12.3858493 3,11.7398375 3,11 C3,10.2601625 3.40171539,9.61415066 3.9989225,9.26818814 L4,7.6 C4,7.03994749 4,6.75992124 4.10899348,6.5460095 C4.27971156,6.21095639 4.62396111,6 5,6 Z M19,6 C19.3760389,6 19.7202884,6.21095639 19.8910065,6.5460095 C20,6.75992124 20,7.03994749 20,7.6 L20.0010775,9.26818814 C20.5982846,9.61415066 21,10.2601625 21,11 C21,11.7398375 20.5982846,12.3858493 20.0010775,12.7318119 L20,16.4 C20,16.9600525 20,17.2400788 19.8910065,17.4539905 C19.7202884,17.7890436 19.3760389,18 19,18 C18.6239611,18 18.2797116,17.7890436 18.1089935,17.4539905 C18,17.2400788 18,16.9600525 18,16.4 L17.9999275,12.7323937 C17.4021661,12.3865739 17,11.7402524 17,11 C17,10.2597476 17.4021661,9.61342606 17.9999275,9.26760632 L18,7.6 C18,7.03994749 18,6.75992124 18.1089935,6.5460095 C18.2797116,6.21095639 18.6239611,6 19,6 Z" id="形状结合" fill="#FFFFFF" fill-rule="evenodd"></path></g></svg>
        """,
        // 滤镜轨道的图标
        // 智能体标签的图标
        "agent": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path fill-rule="evenodd" d="M12,1 C12.5522847,1 13,1.44771525 13,2 L13,4 L16.2,4 C17.8801575,4 18.7202363,4 19.3619715,4.32698043 C19.9264578,4.61460055 20.3853994,5.07354222 20.6730196,5.6380285 C21,6.27976372 21,7.11984248 21,8.8 L21,13.2 C21,14.8801575 21,15.7202363 20.6730196,16.3619715 C20.3853994,16.9264578 19.9264578,17.3853994 19.3619715,17.6730196 C18.7202363,18 17.8801575,18 16.2,18 L7.8,18 C6.11984248,18 5.27976372,18 4.6380285,17.6730196 C4.07354222,17.3853994 3.61460055,16.9264578 3.32698043,16.3619715 C3,15.7202363 3,14.8801575 3,13.2 L3,8.8 C3,7.11984248 3,6.27976372 3.32698043,5.6380285 C3.61460055,5.07354222 4.07354222,4.61460055 4.6380285,4.32698043 C5.27976372,4 6.11984248,4 7.8,4 L11,4 L11,2 C11,1.44771525 11.4477153,1 12,1 Z M8.5,8 C7.11928813,8 6,9.11928813 6,10.5 C6,11.8807119 7.11928813,13 8.5,13 C9.88071187,13 11,11.8807119 11,10.5 C11,9.11928813 9.88071187,8 8.5,8 Z M15.5,8 C14.1192881,8 13,9.11928813 13,10.5 C13,11.8807119 14.1192881,13 15.5,13 C16.8807119,13 18,11.8807119 18,10.5 C18,9.11928813 16.8807119,8 15.5,8 Z M9,20 C9,19.4477153 9.44771525,19 10,19 L14,19 C14.5522847,19 15,19.4477153 15,20 C15,20.5522847 14.5522847,21 14,21 L10,21 C9.44771525,21 9,20.5522847 9,20 Z" fill="black"/></svg>
        """,
        "filter": """
        <svg width="24px" height="24px" viewBox="0 0 24 24" version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"><title>滤镜</title><g id="滤镜" stroke="none" fill="none"><g id="24px参考"></g><circle id="椭圆形-2" fill="#FFFFFF" fill-rule="evenodd" cx="11.5" cy="8.5" r="6.5"></circle><path d="M3.25519841,10.5772904 C3.79744255,12.7352109 5.16501987,14.5662108 7.00301936,15.7143335 L7,15.5 C7,17.9156912 8.00771954,20.0960168 9.62571471,21.643533 C8.96059086,21.874688 8.24492953,22 7.5,22 C3.91014913,22 1,19.0898509 1,15.5 C1,13.5325398 1.87412659,11.7692429 3.25519841,10.5772904 Z M19.7445414,10.5765048 L19.7793455,10.6073157 C21.1404333,11.7987507 22,13.5489941 22,15.5 C22,19.0898509 19.0898509,22 15.5,22 C12.3049202,22 9.64827013,19.6947086 9.10261205,16.656688 C9.86248944,16.88025 10.6672602,17 11.5,17 C15.4781026,17 18.8179241,14.2671939 19.7445414,10.5765048 Z M11.5,2 C15.0898509,2 18,4.91014913 18,8.5 C18,12.0898509 15.0898509,15 11.5,15 C7.91014913,15 5,12.0898509 5,8.5 C5,4.91014913 7.91014913,2 11.5,2 Z" id="形状结合" fill="#FFFFFF" fill-rule="evenodd"></path></g></svg>
        """,
        // 侧边栏「效果」按钮的图标
        "transition": """
        <svg width="24px" height="24px" viewBox="0 0 24 24" version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"><title>特效</title><g id="特效" stroke="none" fill="none" fill-rule="evenodd"><path d="M11.0519818,1.25648246 C11.4023452,1.45184709 11.5371808,1.88907053 11.806852,2.7635174 L13.2782079,7.53459598 C13.4544579,8.10611137 13.5425829,8.39186907 13.6756793,8.60812195 C13.7936364,8.79977678 13.9430943,8.97014883 14.1177559,9.11205999 C14.3148346,9.27218483 14.5866826,9.39677258 15.1303787,9.6459481 L17.8652067,10.8993177 C18.6094708,11.2404133 18.9816029,11.4109612 19.1386603,11.7308311 C19.2751484,12.0088087 19.2751484,12.3343371 19.1386603,12.6123147 C18.9816029,12.9321846 18.6094708,13.1027324 17.8652067,13.4438281 L15.1303787,14.6971977 C14.5866826,14.9463732 14.3148346,15.0709609 14.1177559,15.2310858 C13.9430943,15.3729969 13.7936364,15.543369 13.6756793,15.7350238 C13.5425829,15.9512767 13.4544579,16.2370344 13.2782079,16.8085498 L11.806852,21.5796283 C11.5371808,22.4540752 11.4023452,22.8912987 11.0519818,23.0866633 C10.7492495,23.2554686 10.3806928,23.2554686 10.0779605,23.0866633 C9.72759714,22.8912987 9.59276153,22.4540752 9.32309031,21.5796283 L7.85173439,16.8085498 C7.67548439,16.2370344 7.5873594,15.9512767 7.45426299,15.7350238 C7.33630587,15.543369 7.18684802,15.3729969 7.01218641,15.2310858 C6.81510776,15.0709609 6.5432597,14.9463732 5.99956358,14.6971977 L3.26473558,13.4438281 C2.52047147,13.1027324 2.14833942,12.9321846 1.99128204,12.6123147 C1.85479394,12.3343371 1.85479394,12.0088087 1.99128204,11.7308311 C2.14833942,11.4109612 2.52047147,11.2404133 3.26473558,10.8993177 L5.99956358,9.6459481 C6.5432597,9.39677258 6.81510776,9.27218483 7.01218641,9.11205999 C7.18684802,8.97014883 7.33630587,8.79977678 7.45426299,8.60812195 C7.5873594,8.39186907 7.67548439,8.10611137 7.85173439,7.53459598 L9.32309031,2.7635174 C9.59276153,1.88907053 9.72759714,1.45184709 10.0779605,1.25648246 C10.3806928,1.08767714 10.7492495,1.08767714 11.0519818,1.25648246 Z M18.2435053,2.1889014 C18.418687,2.28658372 18.4861048,2.50519544 18.6209404,2.94241887 L18.8866425,3.80399532 C18.930705,3.94687417 18.9527363,4.01831359 18.9860104,4.07237681 C19.0154997,4.12029052 19.0528641,4.16288353 19.0965295,4.19836132 C19.1457992,4.23839253 19.2137612,4.26953947 19.3496852,4.33183335 L19.7939625,4.53544528 C20.1660945,4.70599311 20.3521606,4.79126703 20.4306893,4.95120198 C20.4989333,5.09019078 20.4989333,5.25295497 20.4306893,5.39194377 C20.3521606,5.55187872 20.1660945,5.63715264 19.7939625,5.80770047 L19.3496852,6.0113124 C19.2137612,6.07360628 19.1457992,6.10475322 19.0965295,6.14478443 C19.0528641,6.18026222 19.0154997,6.22285523 18.9860104,6.27076894 C18.9527363,6.32483216 18.930705,6.39627158 18.8866425,6.53915043 L18.6209404,7.40072688 C18.4861048,7.83795032 18.418687,8.05656203 18.2435053,8.15424435 C18.0921392,8.23864701 17.9078608,8.23864701 17.7564947,8.15424435 C17.581313,8.05656203 17.5138952,7.83795032 17.3790596,7.40072688 L17.1133575,6.53915043 C17.069295,6.39627158 17.0472637,6.32483216 17.0139896,6.27076894 C16.9845003,6.22285523 16.9471359,6.18026222 16.9034705,6.14478443 C16.8542008,6.10475322 16.7862388,6.07360628 16.6503148,6.0113124 L16.2060375,5.80770047 C15.8339055,5.63715264 15.6478394,5.55187872 15.5693107,5.39194377 C15.5010667,5.25295497 15.5010667,5.09019078 15.5693107,4.95120198 C15.6478394,4.79126703 15.8339055,4.70599311 16.2060375,4.53544528 L16.6503148,4.33183335 C16.7862388,4.26953947 16.8542008,4.23839253 16.9034705,4.19836132 C16.9471359,4.16288353 16.9845003,4.12029052 17.0139896,4.07237681 C17.0472637,4.01831359 17.069295,3.94687417 17.1133575,3.80399532 L17.3790596,2.94241887 C17.5138952,2.50519544 17.581313,2.28658372 17.7564947,2.1889014 C17.9078608,2.10449874 18.0921392,2.10449874 18.2435053,2.1889014 Z" id="形状结合" fill="#FFFFFF"></path></g></svg>
        """,
        "effect": """
        <svg width="24px" height="24px" viewBox="0 0 24 24" version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"><title>特效</title><g id="特效" stroke="none" fill="none" fill-rule="evenodd"><path d="M11.0519818,1.25648246 C11.4023452,1.45184709 11.5371808,1.88907053 11.806852,2.7635174 L13.2782079,7.53459598 C13.4544579,8.10611137 13.5425829,8.39186907 13.6756793,8.60812195 C13.7936364,8.79977678 13.9430943,8.97014883 14.1177559,9.11205999 C14.3148346,9.27218483 14.5866826,9.39677258 15.1303787,9.6459481 L17.8652067,10.8993177 C18.6094708,11.2404133 18.9816029,11.4109612 19.1386603,11.7308311 C19.2751484,12.0088087 19.2751484,12.3343371 19.1386603,12.6123147 C18.9816029,12.9321846 18.6094708,13.1027324 17.8652067,13.4438281 L15.1303787,14.6971977 C14.5866826,14.9463732 14.3148346,15.0709609 14.1177559,15.2310858 C13.9430943,15.3729969 13.7936364,15.543369 13.6756793,15.7350238 C13.5425829,15.9512767 13.4544579,16.2370344 13.2782079,16.8085498 L11.806852,21.5796283 C11.5371808,22.4540752 11.4023452,22.8912987 11.0519818,23.0866633 C10.7492495,23.2554686 10.3806928,23.2554686 10.0779605,23.0866633 C9.72759714,22.8912987 9.59276153,22.4540752 9.32309031,21.5796283 L7.85173439,16.8085498 C7.67548439,16.2370344 7.5873594,15.9512767 7.45426299,15.7350238 C7.33630587,15.543369 7.18684802,15.3729969 7.01218641,15.2310858 C6.81510776,15.0709609 6.5432597,14.9463732 5.99956358,14.6971977 L3.26473558,13.4438281 C2.52047147,13.1027324 2.14833942,12.9321846 1.99128204,12.6123147 C1.85479394,12.3343371 1.85479394,12.0088087 1.99128204,11.7308311 C2.14833942,11.4109612 2.52047147,11.2404133 3.26473558,10.8993177 L5.99956358,9.6459481 C6.5432597,9.39677258 6.81510776,9.27218483 7.01218641,9.11205999 C7.18684802,8.97014883 7.33630587,8.79977678 7.45426299,8.60812195 C7.5873594,8.39186907 7.67548439,8.10611137 7.85173439,7.53459598 L9.32309031,2.7635174 C9.59276153,1.88907053 9.72759714,1.45184709 10.0779605,1.25648246 C10.3806928,1.08767714 10.7492495,1.08767714 11.0519818,1.25648246 Z M18.2435053,2.1889014 C18.418687,2.28658372 18.4861048,2.50519544 18.6209404,2.94241887 L18.8866425,3.80399532 C18.930705,3.94687417 18.9527363,4.01831359 18.9860104,4.07237681 C19.0154997,4.12029052 19.0528641,4.16288353 19.0965295,4.19836132 C19.1457992,4.23839253 19.2137612,4.26953947 19.3496852,4.33183335 L19.7939625,4.53544528 C20.1660945,4.70599311 20.3521606,4.79126703 20.4306893,4.95120198 C20.4989333,5.09019078 20.4989333,5.25295497 20.4306893,5.39194377 C20.3521606,5.55187872 20.1660945,5.63715264 19.7939625,5.80770047 L19.3496852,6.0113124 C19.2137612,6.07360628 19.1457992,6.10475322 19.0965295,6.14478443 C19.0528641,6.18026222 19.0154997,6.22285523 18.9860104,6.27076894 C18.9527363,6.32483216 18.930705,6.39627158 18.8866425,6.53915043 L18.6209404,7.40072688 C18.4861048,7.83795032 18.418687,8.05656203 18.2435053,8.15424435 C18.0921392,8.23864701 17.9078608,8.23864701 17.7564947,8.15424435 C17.581313,8.05656203 17.5138952,7.83795032 17.3790596,7.40072688 L17.1133575,6.53915043 C17.069295,6.39627158 17.0472637,6.32483216 17.0139896,6.27076894 C16.9845003,6.22285523 16.9471359,6.18026222 16.9034705,6.14478443 C16.8542008,6.10475322 16.7862388,6.07360628 16.6503148,6.0113124 L16.2060375,5.80770047 C15.8339055,5.63715264 15.6478394,5.55187872 15.5693107,5.39194377 C15.5010667,5.25295497 15.5010667,5.09019078 15.5693107,4.95120198 C15.6478394,4.79126703 15.8339055,4.70599311 16.2060375,4.53544528 L16.6503148,4.33183335 C16.7862388,4.26953947 16.8542008,4.23839253 16.9034705,4.19836132 C16.9471359,4.16288353 16.9845003,4.12029052 17.0139896,4.07237681 C17.0472637,4.01831359 17.069295,3.94687417 17.1133575,3.80399532 L17.3790596,2.94241887 C17.5138952,2.50519544 17.581313,2.28658372 17.7564947,2.1889014 C17.9078608,2.10449874 18.0921392,2.10449874 18.2435053,2.1889014 Z" id="形状结合" fill="#FFFFFF"></path></g></svg>
        """,
        "text": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path fill-rule="evenodd" d="M19.3619715,3.32698043 C19.9264578,3.61460055 20.3853994,4.07354222 20.6730196,4.6380285 C21,5.27976372 21,6.11984248 21,7.8 L21,16.2 C21,17.8801575 21,18.7202363 20.6730196,19.3619715 C20.3853994,19.9264578 19.9264578,20.3853994 19.3619715,20.6730196 C18.7202363,21 17.8801575,21 16.2,21 L7.8,21 C6.11984248,21 5.27976372,21 4.6380285,20.6730196 C4.07354222,20.3853994 3.61460055,19.9264578 3.32698043,19.3619715 C3,18.7202363 3,17.8801575 3,16.2 L3,7.8 C3,6.11984248 3,5.27976372 3.32698043,4.6380285 C3.61460055,4.07354222 4.07354222,3.61460055 4.6380285,3.32698043 C5.27976372,3 6.11984248,3 7.8,3 L16.2,3 C17.8801575,3 18.7202363,3 19.3619715,3.32698043 Z M15,8 L9,8 C8.44771525,8 8,8.44771525 8,9 C8,9.55228475 8.44771525,10 9,10 L11,10 L11,16 C11,16.5522847 11.4477153,17 12,17 C12.5522847,17 13,16.5522847 13,16 L13,10 L15,10 C15.5522847,10 16,9.55228475 16,9 C16,8.44771525 15.5522847,8 15,8 Z" fill="black"/></svg>
        """,
        "shape": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path fill-rule="evenodd" d="M7.00005981,9.00169332 C7,13.4176111 10.5806408,16.9989187 14.9979993,16.9999998 C14.9902126,18.1649053 14.943429,18.8312631 14.6730196,19.3619715 C14.3853994,19.9264578 13.9264578,20.3853994 13.3619715,20.6730196 C12.7202363,21 11.8801575,21 10.2,21 L7.8,21 C6.11984248,21 5.27976372,21 4.6380285,20.6730196 C4.07354222,20.3853994 3.61460055,19.9264578 3.32698043,19.3619715 C3,18.7202363 3,17.8801575 3,16.2 L3,13.8 C3,12.1198425 3,11.2797637 3.32698043,10.6380285 C3.61460055,10.0735422 4.07354222,9.61460055 4.6380285,9.32698043 C5.16873687,9.05657101 5.83509473,9.00978737 7.00005981,9.00169332 Z M15,3 C18.3137085,3 21,5.6862915 21,9 C21,12.3137085 18.3137085,15 15,15 C11.6862915,15 9,12.3137085 9,9 C9,5.6862915 11.6862915,3 15,3 Z" fill="black"/></svg>
        """,
        "ai": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M14.0694088,5.8342558 C14.4668191,8.19893129 16.5230785,10 19,10 C19.8516234,10 20.6535185,9.78708758 21.3553593,9.41158873 C21.6467631,9.25568185 22,9.46610091 22,9.79659015 C22,9.79772638 22,9.798863 22,9.8 L22,16.2 C22,17.8801575 22,18.7202363 21.6730196,19.3619715 C21.3853994,19.9264578 20.9264578,20.3853994 20.3619715,20.6730196 C19.7202363,21 18.8801575,21 17.2,21 L3.6,21 C3.03994749,21 2.75992124,21 2.5460095,20.8910065 C2.35784741,20.7951331 2.20486685,20.6421526 2.10899348,20.4539905 C2,20.2400788 2,19.9600525 2,19.4 L2,9.8 C2,8.11984248 2,7.27976372 2.32698043,6.6380285 C2.61460055,6.07354222 3.07354222,5.61460055 3.6380285,5.32698043 C4.27976372,5 5.11984248,5 6.8,5 L13.082422,4.99912341 C13.5713818,4.99905519 13.9883701,5.35205826 14.0694088,5.8342558 Z M8,11 C6.8954305,11 6,11.8954305 6,13 C6,14.1045695 6.8954305,15 8,15 C9.1045695,15 10,14.1045695 10,13 C10,11.8954305 9.1045695,11 8,11 Z M16,11 C14.8954305,11 14,11.8954305 14,13 C14,14.1045695 14.8954305,15 16,15 C17.1045695,15 18,14.1045695 18,13 C18,11.8954305 17.1045695,11 16,11 Z M19.6447444,2.38562184 L20.1104888,3.74949431 C20.1605162,3.89599282 20.2755801,4.01105672 20.4220786,4.06108403 L21.785951,4.52682845 C22.2371753,4.68091556 22.2371753,5.31908444 21.785951,5.47317155 L20.4220786,5.93891597 C20.2755801,5.98894328 20.1605162,6.10400718 20.1104888,6.25050569 L19.6447444,7.61437816 C19.4906573,8.06560239 18.8524884,8.06560239 18.6984013,7.61437816 L18.2326569,6.25050569 C18.1826296,6.10400718 18.0675657,5.98894328 17.9210672,5.93891597 L16.5571947,5.47317155 C16.1059705,5.31908444 16.1059705,4.68091556 16.5571947,4.52682845 L17.9210672,4.06108403 C18.0675657,4.01105672 18.1826296,3.89599282 18.2326569,3.74949431 L18.6984013,2.38562184 C18.8524884,1.93439761 19.4906573,1.93439761 19.6447444,2.38562184 Z" fill="black" fill-rule="evenodd"/></svg>
        """,
        "importExport": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path fill-rule="evenodd" d="M20.3619715,4.32698043 C20.9264578,4.61460055 21.3853994,5.07354222 21.6730196,5.6380285 C22,6.27976372 22,7.11984248 22,8.8 L22,15.2 C22,16.8801575 22,17.7202363 21.6730196,18.3619715 C21.3853994,18.9264578 20.9264578,19.3853994 20.3619715,19.6730196 C19.7202363,20 18.8801575,20 17.2,20 L6.8,20 C5.11984248,20 4.27976372,20 3.6380285,19.6730196 C3.07354222,19.3853994 2.61460055,18.9264578 2.32698043,18.3619715 C2,17.7202363 2,16.8801575 2,15.2 L2,8.8 C2,7.11984248 2,6.27976372 2.32698043,5.6380285 C2.61460055,5.07354222 3.07354222,4.61460055 3.6380285,4.32698043 C4.27976372,4 5.11984248,4 6.8,4 L17.2,4 C18.8801575,4 19.7202363,4 20.3619715,4.32698043 Z M17,13 L7,13 C6.16149379,13 5.69532051,13.9699317 6.21913119,14.624695 L8.21913119,17.124695 C8.56414074,17.555957 9.19343311,17.6258784 9.62469505,17.2808688 C10.055957,16.9358593 10.1258784,16.3065669 9.78086881,15.875305 L9.08062486,15 L17,15 C17.5522847,15 18,14.5522847 18,14 C18,13.4477153 17.5522847,13 17,13 Z M15.7808688,6.87530495 C15.4358593,6.44404302 14.8065669,6.37412164 14.375305,6.71913119 C13.944043,7.06414074 13.8741216,7.69343311 14.2191312,8.12469505 L14.9193752,9 L7,9 C6.44771525,9 6,9.44771525 6,10 C6,10.5522847 6.44771525,11 7,11 L17,11 C17.8385062,11 18.3046795,10.0300683 17.7808688,9.37530495 Z" fill="black"/></svg>
        """,
        "search": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M11,3 C15.418278,3 19,6.581722 19,11 C19,12.8482015 18.3732643,14.550021 17.3207287,15.9045228 C17.3357631,15.9215496 17.3546507,15.9404371 17.3740115,15.959798 L20.0610173,18.6468037 C20.4570342,19.0428207 20.6550427,19.2408291 20.7292311,19.4691576 C20.8454335,19.8267918 20.751181,20.2193817 20.4852814,20.4852814 C20.2193817,20.751181 19.8267918,20.8454335 19.4691576,20.7292311 C19.2408291,20.6550427 19.0428207,20.4570342 18.6468037,20.0610173 L15.959798,17.3740115 L15.9045228,17.3207287 C14.550021,18.3732643 12.8482015,19 11,19 C6.581722,19 3,15.418278 3,11 C3,6.581722 6.581722,3 11,3 Z M11,5 C7.6862915,5 5,7.6862915 5,11 C5,14.3137085 7.6862915,17 11,17 C14.3137085,17 17,14.3137085 17,11 C17,7.6862915 14.3137085,5 11,5 Z" fill="black"/></svg>
        """,
        "sort": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M16,4.50199591 L16,16.7549851 L16.2340257,16.4761459 C16.5890737,16.05311 17.2198353,15.9979949 17.6428712,16.3530429 C18.0659071,16.7080909 18.1210222,17.3388525 17.7659743,17.7618884 L15.7659743,20.1448672 C15.1658181,20.8599469 14,20.4355517 14,19.5019959 L14,4.50199591 C14,3.94971116 14.4477153,3.50199591 15,3.50199591 C15.5522847,3.50199591 16,3.94971116 16,4.50199591 Z M10,4.50199591 L10,19.5019959 C10,20.0542807 9.55228475,20.5019959 9,20.5019959 C8.44771525,20.5019959 8,20.0542807 8,19.5019959 L7.99999999,7.24900671 L7.76597425,7.52784588 C7.41092627,7.95088178 6.78016465,8.00599687 6.35712875,7.65094889 C5.93409285,7.2959009 5.87897776,6.66513928 6.23402575,6.24210339 L8.23402575,3.85912466 C8.83418194,3.14404495 10,3.5684401 10,4.50199591 Z" fill="black"/></svg>
        """,
        "refresh": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M18.4346717,5.56532829 C18.9221738,6.05283036 18.781727,6.87580803 18.1601347,7.17403552 L15.1325698,8.62660044 C14.6346296,8.86550215 14.0373013,8.65550998 13.7983996,8.15756981 C13.5594978,7.65962963 13.76949,7.06230127 14.2674302,6.82339956 L15.8737907,6.05270001 C14.740034,5.30809588 13.403008,4.9 12,4.9 C8.07877828,4.9 4.9,8.07877828 4.9,12 C4.9,15.9212217 8.07877828,19.1 12,19.1 C13.9095615,19.1 15.6968944,18.3440219 17.0204581,17.0204581 C17.679866,16.3610503 18.204659,15.5784277 18.5616907,14.7174095 C18.7732363,14.2072459 19.3582972,13.9651681 19.8684608,14.1767137 C20.3786244,14.3882593 20.6207022,14.9733202 20.4091566,15.4834838 C19.9512409,16.587794 19.2789224,17.590421 18.4346717,18.4346717 C16.7397533,20.1295901 14.4454466,21.1 12,21.1 C6.97420878,21.1 2.9,17.0257912 2.9,12 C2.9,6.97420878 6.97420878,2.9 12,2.9 C14.4454466,2.9 16.7397533,3.87040993 18.4346717,5.56532829 Z" fill="black"/></svg>
        """,
        "elementLibrary": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M20.3619715,5.32698043 C20.9264578,5.61460055 21.3853994,6.07354222 21.6730196,6.6380285 C22,7.27976372 22,8.11984248 22,9.8 L22,16.2 C22,17.8801575 22,18.7202363 21.6730196,19.3619715 C21.3853994,19.9264578 20.9264578,20.3853994 20.3619715,20.6730196 C19.7202363,21 18.8801575,21 17.2,21 L3.6,21 C3.03994749,21 2.75992124,21 2.5460095,20.8910065 C2.35784741,20.7951331 2.20486685,20.6421526 2.10899348,20.4539905 C2,20.2400788 2,19.9600525 2,19.4 L2,9.8 C2,8.11984248 2,7.27976372 2.32698043,6.6380285 C2.61460055,6.07354222 3.07354222,5.61460055 3.6380285,5.32698043 C4.27976372,5 5.11984248,5 6.8,5 L17.2,5 C18.8801575,5 19.7202363,5 20.3619715,5.32698043 Z M4.5460095,7.10899348 C4.35784741,7.20486685 4.20486685,7.35784741 4.10899348,7.5460095 C4.03327691,7.69461163 4,8.10190163 4,9.8 L4,19 L17.2,19 C18.8980984,19 19.3053884,18.9667231 19.4539905,18.8910065 C19.6421526,18.7951331 19.7951331,18.6421526 19.8910065,18.4539905 C19.9667231,18.3053884 20,17.8980984 20,16.2 L20,9.8 C20,8.10190163 19.9667231,7.69461163 19.8910065,7.5460095 C19.7951331,7.35784741 19.6421526,7.20486685 19.4539905,7.10899348 C19.3053884,7.03327691 18.8980984,7 17.2,7 L6.8,7 C5.10190163,7 4.69461163,7.03327691 4.5460095,7.10899348 Z M17,10 C17.5522847,10 18,10.4477153 18,11 C18,11.5522847 17.5522847,12 17,12 L7,12 C6.44771525,12 6,11.5522847 6,11 C6,10.4477153 6.44771525,10 7,10 L17,10 Z" fill="black" fill-rule="evenodd"/></svg>
        """,
        "compound": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M18.014537,10.001797 L17.9980986,10.0022727 L17.9918726,10.5313993 C17.9747155,11.4412279 17.9213389,12.0340162 17.7552826,12.545085 C17.3455006,13.8062643 16.4515006,14.8530038 15.2699525,15.4550326 C14.2003938,16 12.8002625,16 10,16 L9,16 C8.64533099,16 8.31312239,16 8.00120111,15.9988928 C8.00973524,17.1641617 8.05642015,17.8309671 8.32698043,18.3619715 C8.61460055,18.9264578 9.07354222,19.3853994 9.6380285,19.6730196 C10.2797637,20 11.1198425,20 12.8,20 L17.2,20 C18.8801575,20 19.7202363,20 20.3619715,19.6730196 C20.9264578,19.3853994 21.3853994,18.9264578 21.6730196,18.3619715 C22,17.7202363 22,16.8801575 22,15.2 L22,14.8 C22,13.1198425 22,12.2797637 21.6730196,11.6380285 C21.3853994,11.0735422 20.9264578,10.6146006 20.3619715,10.3269804 C19.8334837,10.0577024 19.1704791,10.0101828 18.014537,10.001797 Z M2,8.8 L2,9.2 C2,10.8801575 2,11.7202363 2.32698043,12.3619715 C2.61460055,12.9264578 3.07354222,13.3853994 3.6380285,13.6730196 C4.27976372,14 5.11984248,14 6.8,14 L11.2,14 C12.8801575,14 13.7202363,14 14.3619715,13.6730196 C14.9264578,13.3853994 15.3853994,12.9264578 15.6730196,12.3619715 C16,11.7202363 16,10.8801575 16,9.2 L16,8.8 C16,7.11984248 16,6.27976372 15.6730196,5.6380285 C15.3853994,5.07354222 14.9264578,4.61460055 14.3619715,4.32698043 C13.7579854,4.01923414 12.978304,4.00113142 11.4879085,4 L11.2,4 L6.8,4 C5.11984248,4 4.27976372,4 3.6380285,4.32698043 C3.07354222,4.61460055 2.61460055,5.07354222 2.32698043,5.6380285 C2,6.27976372 2,7.11984248 2,8.8 Z" fill="black"/></svg>
        """,
        "clear": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M17.7982756,5.41984848 L18.9296465,6.55121933 C20.0618521,7.68342494 20.3085907,7.97406953 20.5100238,8.59401683 C20.7057977,9.19654704 20.7057977,9.84558858 20.5100238,10.4481188 C20.3085907,11.0680661 20.0618521,11.3587107 18.9296465,12.4909163 L14.42,16.9994949 L19,17 C19.5522847,17 20,17.4477153 20,18 C20,18.5522847 19.5522847,19 19,19 L12.42,18.9994949 L12,19.0063492 L6.34314575,19.0063492 C6.07792926,19.0063492 5.82357535,18.9009923 5.63603897,18.713456 L5.07035354,18.1477705 C3.93814794,17.0155649 3.69140929,16.7249203 3.4899762,16.104973 C3.29420227,15.5024428 3.29420227,14.8534013 3.4899762,14.2508711 C3.69140929,13.6309238 3.93814794,13.3402792 5.07035354,12.2080736 L11.8585786,5.41984848 C12.9907843,4.28764287 13.2814288,4.04090423 13.9013761,3.83947114 C14.5039064,3.6436972 15.1529479,3.6436972 15.7554781,3.83947114 C16.3754254,4.04090423 16.66607,4.28764287 17.7982756,5.41984848 Z M14.8284271,13.7637085 L10.5857864,9.52106781 L6.2119146,13.8964057 C5.59460939,14.5212636 5.44346544,14.7107854 5.39208923,14.8689051 C5.32683126,15.0697485 5.32683126,15.2860957 5.39208923,15.4869391 C5.4503156,15.6661414 5.63668809,15.885678 6.48456711,16.733557 L6.75735932,17.0063492 L7.90024072,17.0049137 C7.93305339,17.0016638 7.9663324,17 8,17 L11.591,16.9994949 L14.8284271,13.7637085 Z M14.5194101,5.74158417 L14.45353,5.76832409 C14.2798553,5.85281869 14.0209207,6.0859335 13.2727922,6.83406204 L12,8.10685425 L16.2426407,12.3494949 L17.5154329,11.0767027 C18.3633119,10.2288237 18.5496844,10.0092871 18.6079108,9.83008481 C18.6731687,9.6292414 18.6731687,9.41289422 18.6079108,9.21205082 C18.5496844,9.03284848 18.3633119,8.81331191 17.5154329,7.96543288 L16.384062,6.83406204 C15.536183,5.98618303 15.3166465,5.79981054 15.1374441,5.74158417 C14.9366007,5.67632619 14.7202535,5.67632619 14.5194101,5.74158417 Z" fill="black"/></svg>
        """,
        "mute": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M9.78042309,4.22303561 C10.4293798,4.15135434 11.0724713,4.40094878 11.5031555,4.89165656 C12,5.4577452 12,6.32026038 12,8.04529073 L12,15.9546274 C12,17.6796533 12,18.5421662 11.5031579,19.1082542 C11.0724757,19.5989615 10.4293868,19.8485572 9.78043149,19.7768788 C9.03178594,19.6941895 8.44991956,19.0575105 7.2861868,17.7841526 L5.24474054,15.5516097 C5.05092006,15.339646 4.95400983,15.2336642 4.85263001,15.1662108 C4.76257437,15.106292 4.66488749,15.0590986 4.56044747,15.0309462 C4.44092046,14.9987269 4.27240962,15.0038137 3.93730831,14.9830279 C3.64240899,14.9647358 3.42528308,14.9267289 3.23463314,14.8477591 C2.74457696,14.6447712 2.35522885,14.255423 2.15224093,13.7653669 C2,13.3978247 2,12.9318832 2,12 C2,11.0681168 2,10.6021753 2.15224093,10.2346331 C2.35522885,9.74457696 2.74457696,9.35522885 3.23463314,9.15224093 C3.42528271,9.0732713 3.64240814,9.03526439 3.93730657,9.01697222 C4.27240805,8.99618632 4.44091898,9.00127311 4.56044852,8.96905247 C4.66488891,8.94089929 4.76257472,8.89370305 4.85263038,8.83378332 C4.9540117,8.76632791 5.05092059,8.66034486 5.24473837,8.44837876 L7.28618372,6.21578067 C8.4499118,4.94241244 9.03177584,4.30572832 9.78042309,4.22303561 Z M21.580917,7.81807135 C21.8468166,8.083971 21.9410691,8.47656089 21.8248667,8.83419512 C21.7506783,9.06252359 21.5526698,9.26053205 21.1566529,9.65654898 L19.4597477,11.3523421 L21.1566529,13.0506615 C21.5526698,13.4466785 21.7506783,13.6446869 21.8248667,13.8730154 C21.9410691,14.2306496 21.8468166,14.6232395 21.580917,14.8891392 C21.3150173,15.1550388 20.9224274,15.2492913 20.5647932,15.1330889 C20.3364647,15.0589005 20.1384563,14.860892 19.7424394,14.4648751 L18.0455341,12.7665556 L16.3483268,14.4648751 C15.9523099,14.860892 15.7543014,15.0589005 15.525973,15.1330889 C15.1683387,15.2492913 14.7757488,15.1550388 14.5098492,14.8891392 C14.2439495,14.6232395 14.149697,14.2306496 14.2658994,13.8730154 C14.3400879,13.6446869 14.5380963,13.4466785 14.9341132,13.0506615 L16.6313205,11.3523421 L14.9341132,9.65654898 C14.5380963,9.26053205 14.3400879,9.06252359 14.2658994,8.83419512 C14.149697,8.47656089 14.2439495,8.083971 14.5098492,7.81807135 C14.7757488,7.5521717 15.1683387,7.4579192 15.525973,7.57412161 C15.7543014,7.64831003 15.9523099,7.84631849 16.3483268,8.24233542 L18.0455341,9.93812849 L19.7424394,8.24233542 C20.1384563,7.84631849 20.3364647,7.64831003 20.5647932,7.57412161 C20.9224274,7.4579192 21.3150173,7.5521717 21.580917,7.81807135 Z" fill="black" fill-rule="evenodd"/></svg>
        """,
        "show": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M12,19 C14.9286193,19 17.6367095,17.5237529 20.1242705,14.5712588 C21.3789915,13.0820263 21.3708893,10.906211 20.1151072,9.41787314 C17.6300595,6.47262438 14.9250237,5 12,5 C9.07138067,5 6.36329051,6.47624707 3.87572952,9.42874122 C2.62100845,10.9179737 2.62911071,13.093789 3.88489281,14.5821269 C6.36994054,17.5273756 9.07497628,19 12,19 Z" stroke="black" stroke-width="2" fill="none"/><circle cx="12" cy="12" r="3" stroke="black" stroke-width="2" fill="none"/></svg>
        """,
        "hide": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M3.72907219,8.0844456 L5.23576901,9.40083903 C5.03636408,9.61464043 4.8379419,9.83869961 4.64048115,10.0730664 C3.70162763,11.1873947 3.70547071,12.8187779 4.64918504,13.9372568 C6.95684475,16.6722674 9.39573151,18 12,18 C12.8677789,18 13.7172032,17.8525761 14.5495305,17.5547865 L16.2227315,19.0193784 C14.8731571,19.6706911 13.4645389,20 12,20 C8.75422105,20 5.78303634,18.3824838 3.12060057,15.2269969 C1.54976572,13.3652623 1.54335762,10.6450296 3.11097789,8.78441603 C3.31519715,8.54202754 3.5212337,8.30869209 3.72907219,8.0844456 Z M4.65850461,4.24742331 L20.6585046,18.2474233 C21.0741412,18.6111054 21.1162587,19.242868 20.7525767,19.6585046 C20.3888946,20.0741412 19.757132,20.1162587 19.3414954,19.7525767 L3.34149539,5.75257669 C2.92585876,5.38889464 2.88374125,4.75713202 3.24742331,4.34149539 C3.61110536,3.92585876 4.24286798,3.88374125 4.65850461,4.24742331 Z M8.003,11.825 L12.7026739,15.9384837 C12.4745446,15.9789099 12.2397352,16 12,16 C9.790861,16 8,14.209139 8,12 L8.003,11.825 Z M12,4 C15.245779,4 18.2169637,5.61751617 20.8793994,8.7730031 C22.4502343,10.6347377 22.4566424,13.3549704 20.8890221,15.215584 C20.6848029,15.4579725 20.4787663,15.6913079 20.2709278,15.9155544 L18.7651672,14.5981571 C18.964257,14.3846583 19.1623671,14.1609336 19.3595188,13.9269336 C20.2983724,12.8126053 20.2945293,11.1812221 19.350815,10.0627432 C17.0431552,7.32773259 14.6042685,6 12,6 C11.1315235,6 10.2814312,6.14766103 9.44846229,6.44593195 L7.77527213,4.9815853 C9.1254537,4.32963377 10.534739,4 12,4 Z M12,8 C14.209139,8 16,9.790861 16,12 L15.995,12.174 L11.2953251,8.06187139 C11.5240823,8.02121365 11.7595638,8 12,8 Z" fill="black" fill-rule="evenodd"/></svg>
        """,
        "folderFill": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M7.17366336,4 C7.64433057,4 7.7562402,4.00271564 7.94380266,4.02897409 L8.08109393,4.05145178 C8.21779037,4.07709983 8.35259326,4.11223327 8.48452044,4.15662022 C8.66402452,4.21701445 8.76533401,4.26463302 9.18631155,4.47512179 L10.236068,5.00000001 L16.2,5 C18.5012462,5 19.0479856,5.04467038 19.815962,5.4359739 C20.5686104,5.8194674 21.1805326,6.43138963 21.5640261,7.184038 C21.9553296,7.95201441 22,8.49875384 22,10.8 L22,14.2 C22,16.5012462 21.9553296,17.0479856 21.5640261,17.815962 C21.1805326,18.5686104 20.5686104,19.1805326 19.815962,19.5640261 C19.0479856,19.9553296 18.5012462,20 16.2,20 L7.8,20 C5.49875384,20 4.95201441,19.9553296 4.184038,19.5640261 C3.43138963,19.1805326 2.8194674,18.5686104 2.4359739,17.815962 C2.04467038,17.0479856 2,16.5012462 2,14.2 L2,9.8 C2,7.49875384 2.04467038,6.95201441 2.4359739,6.184038 C2.9898659,5.09696375 4.00960181,4.32211449 5.20533469,4.07973125 C5.55869027,4.00810366 5.79108813,4 6.76393202,4 L7.17366336,4 Z M17,10 L7,10 C6.44771525,10 6,10.4477153 6,11 C6,11.5522847 6.44771525,12 7,12 L17,12 C17.5522847,12 18,11.5522847 18,11 C18,10.4477153 17.5522847,10 17,10 Z" fill="#FFFFFF" fill-rule="evenodd"/></svg>
        """,
        "folder": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M7.17366336,4 C7.64433057,4 7.7562402,4.00271564 7.94380266,4.02897409 L8.08109393,4.05145178 C8.21779037,4.07709983 8.35259326,4.11223327 8.48452044,4.15662022 C8.66402452,4.21701445 8.76533401,4.26463302 9.18631155,4.47512179 L9.70811564,4.73602383 C10.0228338,4.89338289 10.1016748,4.93044059 10.1532505,4.94779326 C10.2118848,4.96752079 10.2722232,4.98176477 10.3334898,4.99034198 C10.3873808,4.99788663 10.4744711,5 10.8263366,5 L16.2,5 C18.5012462,5 19.0479856,5.04467038 19.815962,5.4359739 C20.5686104,5.8194674 21.1805326,6.43138963 21.5640261,7.184038 C21.9553296,7.95201441 22,8.49875384 22,10.8 L22,14.2 C22,16.5012462 21.9553296,17.0479856 21.5640261,17.815962 C21.1805326,18.5686104 20.5686104,19.1805326 19.815962,19.5640261 C19.0479856,19.9553296 18.5012462,20 16.2,20 L7.8,20 C5.49875384,20 4.95201441,19.9553296 4.184038,19.5640261 C3.43138963,19.1805326 2.8194674,18.5686104 2.4359739,17.815962 C2.04467038,17.0479856 2,16.5012462 2,14.2 L2,9.8 C2,7.49875384 2.04467038,6.95201441 2.4359739,6.184038 C2.9898659,5.09696375 4.00960181,4.32211449 5.20533469,4.07973125 C5.55869027,4.00810366 5.79108813,4 6.76393202,4 L7.17366336,4 Z M5.60266734,6.03986563 C5.0048009,6.16105725 4.49493295,6.54848188 4.21798695,7.092019 C4.03707473,7.44707923 4,7.90085237 4,9.8 L4,14.2 C4,16.0991476 4.03707473,16.5529208 4.21798695,16.907981 C4.4097337,17.2843052 4.71569481,17.5902663 5.092019,17.782013 C5.44707923,17.9629253 5.90085237,18 7.8,18 L16.2,18 C18.0991476,18 18.5529208,17.9629253 18.907981,17.782013 C19.2843052,17.5902663 19.5902663,17.2843052 19.782013,16.907981 C19.9629253,16.5529208 20,16.0991476 20,14.2 L20,10.8 C20,8.90085237 19.9629253,8.44707923 19.782013,8.092019 C19.5902663,7.71569481 19.2843052,7.4097337 18.907981,7.21798695 C18.5529208,7.03707473 18.0991476,7 16.2,7 L10.8263366,7 C10.3556694,7 10.2437598,6.99728436 10.0561973,6.97102593 C9.87239775,6.9452943 9.69138246,6.90256238 9.51547956,6.84337978 C9.33597548,6.78298555 9.23466599,6.73536698 8.81368845,6.52487821 L8.29188436,6.26397617 C7.97716624,6.10661711 7.8983252,6.06955941 7.84674951,6.05220674 C7.78811521,6.03247921 7.72777678,6.01823523 7.66651026,6.00965803 L7.65596009,6.00830624 C7.60069863,6.00185745 7.50353732,6 7.17366336,6 L6.76393202,6 C5.96189026,6 5.76556108,6.00684595 5.60266734,6.03986563 Z M17,10 C17.5522847,10 18,10.4477153 18,11 C18,11.5522847 17.5522847,12 17,12 L7,12 C6.44771525,12 6,11.5522847 6,11 C6,10.4477153 6.44771525,10 7,10 L17,10 Z" fill="black" fill-rule="evenodd"/></svg>
        """,
        "selectLeft": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M10.7071068,10.2928932 C11.0976311,10.6834175 11.0976311,11.3165825 10.7071068,11.7071068 L10.4142136,12 L19.75,12 C20.3022847,12 20.75,12.4477153 20.75,13 C20.75,13.5522847 20.3022847,14 19.75,14 L8,14 C7.10909515,14 6.66292836,12.9228581 7.29289322,12.2928932 L9.29289322,10.2928932 C9.68341751,9.90236893 10.3165825,9.90236893 10.7071068,10.2928932 Z M3,16.4 L3,7.6 C3,7.03994749 3,6.75992124 3.10899348,6.5460095 C3.27971156,6.21095639 3.62396111,6 4,6 C4.37603889,6 4.72028844,6.21095639 4.89100652,6.5460095 C5,6.75992124 5,7.03994749 5,7.6 L5,16.4 C5,16.9600525 5,17.2400788 4.89100652,17.4539905 C4.72028844,17.7890436 4.37603889,18 4,18 C3.62396111,18 3.27971156,17.7890436 3.10899348,17.4539905 C3,17.2400788 3,16.9600525 3,16.4 Z" fill="black" fill-rule="evenodd"/></svg>
        """,
        "selectRight": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M13.2928932,10.2928932 C12.9023689,10.6834175 12.9023689,11.3165825 13.2928932,11.7071068 L13.5857864,12 L4.25,12 C3.69771525,12 3.25,12.4477153 3.25,13 C3.25,13.5522847 3.69771525,14 4.25,14 L16,14 C16.8909049,14 17.3370716,12.9228581 16.7071068,12.2928932 L14.7071068,10.2928932 C14.3165825,9.90236893 13.6834175,9.90236893 13.2928932,10.2928932 Z M20.9988039,16.7342304 L20.9988039,7.26576958 C20.9946176,6.9187563 20.9757792,6.7123853 20.8910065,6.5460095 C20.7202884,6.21095639 20.3760389,6 20,6 C19.6239611,6 19.2797116,6.21095639 19.1089935,6.5460095 C19,6.75992124 19,7.03994749 19,7.6 L19,16.4 C19,16.9600525 19,17.2400788 19.1089935,17.4539905 C19.2797116,17.7890436 19.6239611,18 20,18 C20.3760389,18 20.7202884,17.7890436 20.8910065,17.4539905 C20.9757792,17.2876147 20.9946176,17.0812437 20.9988039,16.7342304 Z" fill="black" fill-rule="evenodd"/></svg>
        """,
        "copy": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M18.815962,7.4359739 C19.5686104,7.8194674 20.1805326,8.43138963 20.5640261,9.184038 C20.9553296,9.95201441 21,10.4987538 21,12.8 L21,15.2 C21,17.5012462 20.9553296,18.0479856 20.5640261,18.815962 C20.1805326,19.5686104 19.5686104,20.1805326 18.815962,20.5640261 C18.0479856,20.9553296 17.5012462,21 15.2,21 L12.8,21 C10.4987538,21 9.95201441,20.9553296 9.184038,20.5640261 C8.43138963,20.1805326 7.8194674,19.5686104 7.4359739,18.815962 C7.04467038,18.0479856 7,17.5012462 7,15.2 L7,12.8 C7,10.4987538 7.04467038,9.95201441 7.4359739,9.184038 C7.8194674,8.43138963 8.43138963,7.8194674 9.184038,7.4359739 C9.95201441,7.04467038 10.4987538,7 12.8,7 L15.2,7 C17.5012462,7 18.0479856,7.04467038 18.815962,7.4359739 Z M10.092019,9.21798695 C9.71569481,9.4097337 9.4097337,9.71569481 9.21798695,10.092019 C9.03707473,10.4470792 9,10.9008524 9,12.8 L9,15.2 C9,17.0991476 9.03707473,17.5529208 9.21798695,17.907981 C9.4097337,18.2843052 9.71569481,18.5902663 10.092019,18.782013 C10.4470792,18.9629253 10.9008524,19 12.8,19 L15.2,19 C17.0991476,19 17.5529208,18.9629253 17.907981,18.782013 C18.2843052,18.5902663 18.5902663,18.2843052 18.782013,17.907981 C18.9629253,17.5529208 19,17.0991476 19,15.2 L19,12.8 C19,10.9008524 18.9629253,10.4470792 18.782013,10.092019 C18.5902663,9.71569481 18.2843052,9.4097337 17.907981,9.21798695 C17.5529208,9.03707473 17.0991476,9 15.2,9 L12.8,9 C10.9008524,9 10.4470792,9.03707473 10.092019,9.21798695 Z M11.2,3 C13.5012462,3 14.0479856,3.04467038 14.815962,3.43597391 L15.0914373,3.59032027 C15.7180217,3.97464681 16.2284693,4.52547068 16.5640261,5.184038 C16.7019271,5.45468389 16.7967776,5.69785307 16.8617942,6.00002067 L14.729,6 L14.692971,5.935173 C14.5014129,5.63060826 14.2305446,5.38234131 13.907981,5.21798696 L13.8399216,5.18572544 C13.4905531,5.03258521 12.9804509,5 11.2,5 L8.80026147,4.99999997 L8.49546807,5.00007951 C6.9054993,5.00136674 6.42785554,5.04686969 6.092019,5.21798695 C5.71569481,5.4097337 5.4097337,5.71569481 5.21798695,6.092019 C5.03707473,6.44707923 5,6.90085237 5,8.8 L5,11.2 C5,13.0991476 5.03707473,13.5529208 5.21798695,13.907981 C5.39368211,14.2528022 5.66526969,14.5385477 5.99901491,14.7314828 L6.00002067,16.8617942 C5.69785307,16.7967776 5.45468389,16.7019271 5.184038,16.5640261 C4.43138963,16.1805326 3.8194674,15.5686104 3.4359739,14.815962 C3.04467038,14.0479856 3,13.5012462 3,11.2 L3,8.8 C3,6.49875384 3.04467038,5.95201441 3.4359739,5.184038 C3.8194674,4.43138963 4.43138963,3.8194674 5.184038,3.4359739 C5.91926163,3.06135875 6.54594818,3.00165717 8.49439701,3.00007987 L8.8,3 L11.2,3 Z" fill="black" fill-rule="evenodd"/></svg>
        """,
        "cut": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M16.2497107,4.21018685 C16.5790139,4.3927226 16.7784804,4.74418618 16.7663419,5.12050063 C16.7585919,5.36076357 16.6235821,5.6065266 16.3535627,6.09805268 L13.1398841,11.9453303 L14.3092365,14.0741284 C14.8061601,13.3842889 15.5521629,12.8753898 16.4380035,12.6923993 L16.6623138,12.6535253 C18.5764986,12.3845042 20.3463367,13.7181729 20.6153579,15.6323577 C20.884379,17.5465425 19.5507103,19.3163807 17.6365255,19.5854018 C16.1529389,19.7939063 14.7560616,19.0396741 14.0780494,17.7989246 C14.0143604,17.6898121 13.943614,17.5610299 13.8598353,17.4085246 L11.9988841,14.0223303 L10.1401647,17.4085246 C10.056386,17.5610299 9.98563964,17.6898121 9.92195056,17.7989246 C9.24393844,19.0396741 7.84706106,19.7939063 6.36347453,19.5854018 C4.44928969,19.3163807 3.115621,17.5465425 3.38464214,15.6323577 C3.65366327,13.7181729 5.4235014,12.3845042 7.33768623,12.6535253 C8.32177356,12.7918298 9.15242964,13.3268023 9.69076349,14.0741284 L10.8578841,11.9453303 L7.64643727,6.09805268 C7.40642001,5.66114061 7.27307708,5.41841169 7.24096543,5.20112156 L7.23365815,5.12050063 C7.22151964,4.74418618 7.42098605,4.3927226 7.75028926,4.21018685 C8.0787668,4.02810878 8.48172763,4.04623972 8.79252602,4.25708156 C8.9909457,4.39168706 9.12558994,4.63678482 9.39487842,5.12698033 L11.9988841,9.8683303 L14.6051216,5.12698033 C14.8744101,4.63678482 15.0090543,4.39168706 15.207474,4.25708156 C15.5182724,4.04623972 15.9212332,4.02810878 16.2497107,4.21018685 Z M5.36517828,15.9107039 C5.2498835,16.7310688 5.8214558,17.4895709 6.64182073,17.6048657 C7.46218566,17.7201604 8.22068771,17.1485881 8.33598248,16.3282232 C8.45127725,15.5078583 7.87970496,14.7493562 7.05934003,14.6340615 C6.2389751,14.5187667 5.48047305,15.090339 5.36517828,15.9107039 Z M18.6348217,15.9107039 C18.519527,15.090339 17.7610249,14.5187667 16.94066,14.6340615 C16.120295,14.7493562 15.5487227,15.5078583 15.6640175,16.3282232 C15.7793123,17.1485881 16.5378143,17.7201604 17.3581793,17.6048657 C18.1785442,17.4895709 18.7501165,16.7310688 18.6348217,15.9107039 Z" fill="black" fill-rule="evenodd"/></svg>
        """,
        "paste": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M18.815962,7.4359739 C19.5686104,7.8194674 20.1805326,8.43138963 20.5640261,9.184038 C20.9553296,9.95201441 21,10.4987538 21,12.8 L21,15.2 C21,17.5012462 20.9553296,18.0479856 20.5640261,18.815962 C20.1805326,19.5686104 19.5686104,20.1805326 18.815962,20.5640261 C18.0479856,20.9553296 17.5012462,21 15.2,21 L12.8,21 C10.4987538,21 9.95201441,20.9553296 9.184038,20.5640261 C8.43138963,20.1805326 7.8194674,19.5686104 7.4359739,18.815962 C7.04467038,18.0479856 7,17.5012462 7,15.2 L7,12.8 C7,10.4987538 7.04467038,9.95201441 7.4359739,9.184038 C7.8194674,8.43138963 8.43138963,7.8194674 9.184038,7.4359739 C9.95201441,7.04467038 10.4987538,7 12.8,7 L15.2,7 C17.5012462,7 18.0479856,7.04467038 18.815962,7.4359739 Z M10.092019,9.21798695 C9.71569481,9.4097337 9.4097337,9.71569481 9.21798695,10.092019 C9.03707473,10.4470792 9,10.9008524 9,12.8 L9,15.2 C9,17.0991476 9.03707473,17.5529208 9.21798695,17.907981 C9.4097337,18.2843052 9.71569481,18.5902663 10.092019,18.782013 C10.4470792,18.9629253 10.9008524,19 12.8,19 L15.2,19 C17.0991476,19 17.5529208,18.9629253 17.907981,18.782013 C18.2843052,18.5902663 18.5902663,18.2843052 18.782013,17.907981 C18.9629253,17.5529208 19,17.0991476 19,15.2 L19,12.8 C19,10.9008524 18.9629253,10.4470792 18.782013,10.092019 C18.5902663,9.71569481 18.2843052,9.4097337 17.907981,9.21798695 C17.5529208,9.03707473 17.0991476,9 15.2,9 L12.8,9 C10.9008524,9 10.4470792,9.03707473 10.092019,9.21798695 Z M14,11 C14.5522847,11 15,11.4477153 15,12 L15,13 L16,13 C16.5522847,13 17,13.4477153 17,14 C17,14.5522847 16.5522847,15 16,15 L15,15 L15,16 C15,16.5522847 14.5522847,17 14,17 C13.4477153,17 13,16.5522847 13,16 L13,15 L12,15 C11.4477153,15 11,14.5522847 11,14 C11,13.4477153 11.4477153,13 12,13 L13,13 L13,12 C13,11.4477153 13.4477153,11 14,11 Z M12.4539905,2.10899348 C12.7890436,2.27971156 13,2.62396111 13,3 L12.998894,3.02651335 C13.8931772,3.06903406 14.3057445,3.17600512 14.815962,3.43597391 L15.0914373,3.59032027 C15.7180217,3.97464681 16.2284693,4.52547068 16.5640261,5.184038 C16.7019271,5.45468389 16.7967776,5.69785307 16.8617942,6.00002067 L14.729,6 L14.692971,5.935173 C14.5014129,5.63060826 14.2305446,5.38234131 13.907981,5.21798696 L13.8399216,5.18572544 C13.4905531,5.03258521 12.9804509,5 11.2,5 L8.80026147,4.99999997 L8.49546807,5.00007951 C6.9054993,5.00136674 6.42785554,5.04686969 6.092019,5.21798695 C5.71569481,5.4097337 5.4097337,5.71569481 5.21798695,6.092019 C5.03707473,6.44707923 5,6.90085237 5,8.8 L5,11.2 C5,13.0991476 5.03707473,13.5529208 5.21798695,13.907981 C5.39368211,14.2528022 5.66526969,14.5385477 5.99901491,14.7314828 L6.00002067,16.8617942 C5.69785307,16.7967776 5.45468389,16.7019271 5.184038,16.5640261 C4.43138963,16.1805326 3.8194674,15.5686104 3.4359739,14.815962 C3.04467038,14.0479856 3,13.5012462 3,11.2 L3,8.8 C3,6.49875384 3.04467038,5.95201441 3.4359739,5.184038 C3.8194674,4.43138963 4.43138963,3.8194674 5.184038,3.4359739 C5.91926163,3.06135875 6.54594818,3.00165717 8.49439701,3.00007987 L8.8,3 L11.2,3 Z" fill="black" fill-rule="evenodd"/></svg>
        """,
        "alignLeft": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M5,17.4 L5,6.6 C5,6.03994749 5,5.75992124 5.10899348,5.5460095 C5.27971156,5.21095639 5.62396111,5 6,5 C6.37603889,5 6.72028844,5.21095639 6.89100652,5.5460095 C7,5.75992124 7,6.03994749 7,6.6 L7,17.4 C7,17.9600525 7,18.2400788 6.89100652,18.4539905 C6.72028844,18.7890436 6.37603889,19 6,19 C5.62396111,19 5.27971156,18.7890436 5.10899348,18.4539905 C5,18.2400788 5,17.9600525 5,17.4 Z M11.4,8 L16.6,8 C17.4400788,8 17.8601181,8 18.1809857,8.16349021 C18.6835654,8.41956734 19,8.93594166 19,9.5 C19,10.0640583 18.6835654,10.5804327 18.1809857,10.8365098 C17.8601181,11 17.4400788,11 16.6,11 L11.4,11 C10.5599212,11 10.1398819,11 9.81901425,10.8365098 C9.31643459,10.5804327 9,10.0640583 9,9.5 C9,8.93594166 9.31643459,8.41956734 9.81901425,8.16349021 C10.1398819,8 10.5599212,8 11.4,8 Z M11.4,13 L16.6,13 C17.4400788,13 17.8601181,13 18.1809857,13.1634902 C18.6835654,13.4195673 19,13.9359417 19,14.5 C19,15.0640583 18.6835654,15.5804327 18.1809857,15.8365098 C17.8601181,16 17.4400788,16 16.6,16 L11.4,16 C10.5599212,16 10.1398819,16 9.81901425,15.8365098 C9.31643459,15.5804327 9,15.0640583 9,14.5 C9,13.9359417 9.31643459,13.4195673 9.81901425,13.1634902 C10.1398819,13 10.5599212,13 11.4,13 Z" fill="black" fill-rule="evenodd"/></svg>
        """,
        "alignHCenter": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M17.4,13 L16,12.999 L16,14.6 C16,15.4400788 16,15.8601181 15.8365098,16.1809857 C15.5804327,16.6835654 15.0640583,17 14.5,17 C13.9359417,17 13.4195673,16.6835654 13.1634902,16.1809857 C13,15.8601181 13,15.4400788 13,14.6 L13,12.999 L11,12.999 L11,16.6 C11,17.4400788 11,17.8601181 10.8365098,18.1809857 C10.5804327,18.6835654 10.0640583,19 9.5,19 C8.93594166,19 8.41956734,18.6835654 8.16349021,18.1809857 C8,17.8601181 8,17.4400788 8,16.6 L8,13 L6.6,13 C6.03994749,13 5.75992124,13 5.5460095,12.8910065 C5.21095639,12.7202884 5,12.3760389 5,12 C5,11.6239611 5.21095639,11.2797116 5.5460095,11.1089935 C5.75992124,11 6.03994749,11 6.6,11 L8,11 L8,7.4 C8,6.55992124 8,6.13988186 8.16349021,5.81901425 C8.41956734,5.31643459 8.93594166,5 9.5,5 C10.0640583,5 10.5804327,5.31643459 10.8365098,5.81901425 C11,6.13988186 11,6.55992124 11,7.4 L11,10.999 L13,10.999 L13,9.4 C13,8.55992124 13,8.13988186 13.1634902,7.81901425 C13.4195673,7.31643459 13.9359417,7 14.5,7 C15.0640583,7 15.5804327,7.31643459 15.8365098,7.81901425 C16,8.13988186 16,8.55992124 16,9.4 L16,10.999 L17.4,11 C17.9600525,11 18.2400788,11 18.4539905,11.1089935 C18.7890436,11.2797116 19,11.6239611 19,12 C19,12.3760389 18.7890436,12.7202884 18.4539905,12.8910065 C18.2400788,13 17.9600525,13 17.4,13 Z" fill="black" fill-rule="evenodd"/></svg>
        """,
        "alignRight": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M18.9988039,17.7342304 L18.9988039,6.26576958 C18.9946176,5.9187563 18.9757792,5.7123853 18.8910065,5.5460095 C18.7202884,5.21095639 18.3760389,5 18,5 C17.6239611,5 17.2797116,5.21095639 17.1089935,5.5460095 C17,5.75992124 17,6.03994749 17,6.6 L17,17.4 C17,17.9600525 17,18.2400788 17.1089935,18.4539905 C17.2797116,18.7890436 17.6239611,19 18,19 C18.3760389,19 18.7202884,18.7890436 18.8910065,18.4539905 C18.9757792,18.2876147 18.9946176,18.0812437 18.9988039,17.7342304 Z M12.9865216,8.0007569 L7.0134784,8.0007569 C6.42266289,8.00454139 6.08640393,8.02724837 5.81901425,8.16349021 C5.31643459,8.41956734 5,8.93594166 5,9.5 C5,10.0640583 5.31643459,10.5804327 5.81901425,10.8365098 C6.13988186,11 6.55992124,11 7.4,11 L12.6,11 C13.4400788,11 13.8601181,11 14.1809857,10.8365098 C14.6835654,10.5804327 15,10.0640583 15,9.5 C15,8.93594166 14.6835654,8.41956734 14.1809857,8.16349021 C13.9135961,8.02724837 13.5773371,8.00454139 12.9865216,8.0007569 Z M12.9865216,13.0007569 L7.0134784,13.0007569 C6.42266289,13.0045414 6.08640393,13.0272484 5.81901425,13.1634902 C5.31643459,13.4195673 5,13.9359417 5,14.5 C5,15.0640583 5.31643459,15.5804327 5.81901425,15.8365098 C6.13988186,16 6.55992124,16 7.4,16 L12.6,16 C13.4400788,16 13.8601181,16 14.1809857,15.8365098 C14.6835654,15.5804327 15,15.0640583 15,14.5 C15,13.9359417 14.6835654,13.4195673 14.1809857,13.1634902 C13.9135961,13.0272484 13.5773371,13.0045414 12.9865216,13.0007569 Z" fill="black" fill-rule="evenodd"/></svg>
        """,
        "alignTop": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M17.7342304,5.00119609 L6.26576958,5.00119609 C5.9187563,5.00538239 5.7123853,5.02422077 5.5460095,5.10899348 C5.21095639,5.27971156 5,5.62396111 5,6 C5,6.37603889 5.21095639,6.72028844 5.5460095,6.89100652 C5.75992124,7 6.03994749,7 6.6,7 L17.4,7 C17.9600525,7 18.2400788,7 18.4539905,6.89100652 C18.7890436,6.72028844 19,6.37603889 19,6 C19,5.62396111 18.7890436,5.27971156 18.4539905,5.10899348 C18.2876147,5.02422077 18.0812437,5.00538239 17.7342304,5.00119609 L17.7342304,5.00119609 Z M8.0007569,11.0134784 L8.0007569,16.9865216 C8.00454139,17.5773371 8.02724837,17.9135961 8.16349021,18.1809857 C8.41956734,18.6835654 8.93594166,19 9.5,19 C10.0640583,19 10.5804327,18.6835654 10.8365098,18.1809857 C11,17.8601181 11,17.4400788 11,16.6 L11,11.4 C11,10.5599212 11,10.1398819 10.8365098,9.81901425 C10.5804327,9.31643459 10.0640583,9 9.5,9 C8.93594166,9 8.41956734,9.31643459 8.16349021,9.81901425 C8.02724837,10.0864039 8.00454139,10.4226629 8.0007569,11.0134784 Z M13.0007569,11.0134784 L13.0007569,16.9865216 C13.0045414,17.5773371 13.0272484,17.9135961 13.1634902,18.1809857 C13.4195673,18.6835654 13.9359417,19 14.5,19 C15.0640583,19 15.5804327,18.6835654 15.8365098,18.1809857 C16,17.8601181 16,17.4400788 16,16.6 L16,11.4 C16,10.5599212 16,10.1398819 15.8365098,9.81901425 C15.5804327,9.31643459 15.0640583,9 14.5,9 C13.9359417,9 13.4195673,9.31643459 13.1634902,9.81901425 C13.0272484,10.0864039 13.0045414,10.4226629 13.0007569,11.0134784 Z" fill="black" fill-rule="evenodd"/></svg>
        """,
        "alignVCenter": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M12,5 C12.3760389,5 12.7202884,5.21095639 12.8910065,5.5460095 C13,5.75992124 13,6.03994749 13,6.6 L12.999,8 L14.6,8 C15.4400788,8 15.8601181,8 16.1809857,8.16349021 C16.6835654,8.41956734 17,8.93594166 17,9.5 C17,10.0640583 16.6835654,10.5804327 16.1809857,10.8365098 C15.8601181,11 15.4400788,11 14.6,11 L12.999,11 L12.999,13 L16.6,13 C17.4400788,13 17.8601181,13 18.1809857,13.1634902 C18.6835654,13.4195673 19,13.9359417 19,14.5 C19,15.0640583 18.6835654,15.5804327 18.1809857,15.8365098 C17.8601181,16 17.4400788,16 16.6,16 L13,16 L13,17.4 C13,17.9600525 13,18.2400788 12.8910065,18.4539905 C12.7202884,18.7890436 12.3760389,19 12,19 C11.6239611,19 11.2797116,18.7890436 11.1089935,18.4539905 C11,18.2400788 11,17.9600525 11,17.4 L11,16 L7.4,16 C6.55992124,16 6.13988186,16 5.81901425,15.8365098 C5.31643459,15.5804327 5,15.0640583 5,14.5 C5,13.9359417 5.31643459,13.4195673 5.81901425,13.1634902 C6.13988186,13 6.55992124,13 7.4,13 L10.999,13 L10.999,11 L9.4,11 C8.55992124,11 8.13988186,11 7.81901425,10.8365098 C7.31643459,10.5804327 7,10.0640583 7,9.5 C7,8.93594166 7.31643459,8.41956734 7.81901425,8.16349021 C8.13988186,8 8.55992124,8 9.4,8 L10.999,8 L11,6.6 C11,6.03994749 11,5.75992124 11.1089935,5.5460095 C11.2797116,5.21095639 11.6239611,5 12,5 Z" fill="black" fill-rule="evenodd"/></svg>
        """,
        "alignBottom": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M17.7342304,18.9988039 L6.26576958,18.9988039 C5.9187563,18.9946176 5.7123853,18.9757792 5.5460095,18.8910065 C5.21095639,18.7202884 5,18.3760389 5,18 C5,17.6239611 5.21095639,17.2797116 5.5460095,17.1089935 C5.75992124,17 6.03994749,17 6.6,17 L17.4,17 C17.9600525,17 18.2400788,17 18.4539905,17.1089935 C18.7890436,17.2797116 19,17.6239611 19,18 C19,18.3760389 18.7890436,18.7202884 18.4539905,18.8910065 C18.2876147,18.9757792 18.0812437,18.9946176 17.7342304,18.9988039 Z M8.0007569,12.9865216 L8.0007569,7.0134784 C8.00454139,6.42266289 8.02724837,6.08640393 8.16349021,5.81901425 C8.41956734,5.31643459 8.93594166,5 9.5,5 C10.0640583,5 10.5804327,5.31643459 10.8365098,5.81901425 C11,6.13988186 11,6.55992124 11,7.4 L11,12.6 C11,13.4400788 11,13.8601181 10.8365098,14.1809857 C10.5804327,14.6835654 10.0640583,15 9.5,15 C8.93594166,15 8.41956734,14.6835654 8.16349021,14.1809857 C8.02724837,13.9135961 8.00454139,13.5773371 8.0007569,12.9865216 Z M13.0007569,12.9865216 L13.0007569,7.0134784 C13.0045414,6.42266289 13.0272484,6.08640393 13.1634902,5.81901425 C13.4195673,5.31643459 13.9359417,5 14.5,5 C15.0640583,5 15.5804327,5.31643459 15.8365098,5.81901425 C16,6.13988186 16,6.55992124 16,7.4 L16,12.6 C16,13.4400788 16,13.8601181 15.8365098,14.1809857 C15.5804327,14.6835654 15.0640583,15 14.5,15 C13.9359417,15 13.4195673,14.6835654 13.1634902,14.1809857 C13.0272484,13.9135961 13.0045414,13.5773371 13.0007569,12.9865216 L13.0007569,12.9865216 Z" fill="black" fill-rule="evenodd"/></svg>
        """,
        "addToVideoTrack": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M12,22 C17.5228475,22 22,17.5228475 22,12 C22,11.4477153 21.5522847,11 21,11 C20.4477153,11 20,11.4477153 20,12 C20,16.418278 16.418278,20 12,20 C7.581722,20 4,16.418278 4,12 C4,7.581722 7.581722,4 12,4 C13.0655121,4 14.1003227,4.20786433 15.0619036,4.60659557 C15.5720672,4.81814113 16.1571281,4.57606337 16.3686737,4.06589976 C16.5802192,3.55573614 16.3381415,2.97067525 15.8279779,2.75912968 C14.6245998,2.2601343 13.3295738,2 12,2 C6.4771525,2 2,6.4771525 2,12 C2,17.5228475 6.4771525,22 12,22 Z M20,9 C20.5522847,9 21,8.55228475 21,8 L21,7 L22,7 C22.5522847,7 23,6.55228475 23,6 C23,5.44771525 22.5522847,5 22,5 L21,5 L21,4 C21,3.44771525 20.5522847,3 20,3 C19.4477153,3 19,3.44771525 19,4 L19,5 L18,5 C17.4477153,5 17,5.44771525 17,6 C17,6.55228475 17.4477153,7 18,7 L19,7 L19,8 C19,8.55228475 19.4477153,9 20,9 Z M12,10 C13.1046,10 14,9.1046 14,8 C14,6.8954 13.1046,6 12,6 C10.8954,6 10,6.8954 10,8 C10,9.1046 10.8954,10 12,10 Z M8,14 C9.10457,14 10,13.1046 10,12 C10,10.8954 9.10457,10 8,10 C6.89543,10 6,10.8954 6,12 C6,13.1046 6.89543,14 8,14 Z M16,14 C17.1046,14 18,13.1046 18,12 C18,10.8954 17.1046,10 16,10 C14.8954,10 14,10.8954 14,12 C14,13.1046 14.8954,14 16,14 Z M12,18 C13.1046,18 14,17.10457 14,16 C14,14.89543 13.1046,14 12,14 C10.8954,14 10,14.89543 10,16 C10,17.10457 10.8954,18 12,18 Z" fill="black" fill-rule="nonzero"/></svg>
        """,
        "addToImageTrack": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M14,4 C14.5522847,4 15,4.44771525 15,5 C15,5.55228475 14.5522847,6 14,6 L7.8,6 C5.90085237,6 5.44707923,6.03707473 5.092019,6.21798695 C4.71569481,6.4097337 4.4097337,6.71569481 4.21798695,7.092019 C4.03707473,7.44707923 4,7.90085237 4,9.8 L4,14.2 C4,16.0991476 4.03707473,16.5529208 4.21798695,16.907981 C4.32668692,17.1213167 4.47209175,17.31204 4.64621255,17.4721619 L14.0790484,9.76231624 C15.1382553,8.89661825 16.7344869,9.32598077 17.2164648,10.6062345 L19.6659331,17.1066506 C19.7082502,17.0429467 19.7470322,16.9766347 19.782013,16.907981 C19.9629253,16.5529208 20,16.0991476 20,14.2 L20,12 C20,11.4477153 20.4477153,11 21,11 C21.5522847,11 22,11.4477153 22,12 L22,14.2 C22,16.5012462 21.9553296,17.0479856 21.5640261,17.815962 C21.1805326,18.5686104 20.5686104,19.1805326 19.815962,19.5640261 C19.0479856,19.9553296 18.5012462,20 16.2,20 L7.8,20 C5.49875384,20 4.95201441,19.9553296 4.184038,19.5640261 C3.43138963,19.1805326 2.8194674,18.5686104 2.4359739,17.815962 C2.04467038,17.0479856 2,16.5012462 2,14.2 L2,9.8 C2,7.49875384 2.04467038,6.95201441 2.4359739,6.184038 C2.8194674,5.43138963 3.43138963,4.8194674 4.184038,4.4359739 C4.95201441,4.04467038 5.49875384,4 7.8,4 L14,4 Z M7.5,9 C8.32842712,9 9,9.67157288 9,10.5 C9,11.3284271 8.32842712,12 7.5,12 C6.67157288,12 6,11.3284271 6,10.5 C6,9.67157288 6.67157288,9 7.5,9 Z M20,3 C20.5522847,3 21,3.44771525 21,4 L21,5 L22,5 C22.5522847,5 23,5.44771525 23,6 C23,6.55228475 22.5522847,7 22,7 L21,7 L21,8 C21,8.55228475 20.5522847,9 20,9 C19.4477153,9 19,8.55228475 19,8 L19,7 L18,7 C17.4477153,7 17,6.55228475 17,6 C17,5.44771525 17.4477153,5 18,5 L19,5 L19,4 C19,3.44771525 19.4477153,3 20,3 Z" fill="black" fill-rule="evenodd"/></svg>
        """,
        "addToAudioTrack": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M13,3 C13.5522847,3 14,3.44771525 14,4 C14,4.55228475 13.5522847,5 13,5 L9.6,5 C8.67118281,5 8,5.52916834 8,6.04987027 L8,18 L7.99543746,18.1827516 C7.91673116,19.7545041 6.8295744,21 5.5,21 C4.11928813,21 3,19.6568542 3,18 C3,16.3431458 4.11928813,15 5.5,15 C5.67129267,15 5.83856172,15.0206726 6.00016911,15.0600521 L6,6.04987027 C6,4.30634802 7.65693649,3 9.6,3 L13,3 Z M20,11 C20.5522847,11 21,11.4477153 21,12 L21,18 L20.9954375,18.1827516 C20.9167312,19.7545041 19.8295744,21 18.5,21 C17.1192881,21 16,19.6568542 16,18 C16,16.3431458 17.1192881,15 18.5,15 C18.6715236,15 18.8390128,15.0207284 19.0008228,15.0602115 L19,12 C19,11.4477153 19.4477153,11 20,11 Z M19.5,3 C20.0522847,3 20.5,3.44771525 20.5,4 L20.5,5 L21.5,5 C22.0522847,5 22.5,5.44771525 22.5,6 C22.5,6.55228475 22.0522847,7 21.5,7 L20.5,7 L20.5,8 C20.5,8.55228475 20.0522847,9 19.5,9 C18.9477153,9 18.5,8.55228475 18.5,8 L18.5,7 L17.5,7 C16.9477153,7 16.5,6.55228475 16.5,6 C16.5,5.44771525 16.9477153,5 17.5,5 L18.5,5 L18.5,4 C18.5,3.44771525 18.9477153,3 19.5,3 Z" fill="black" fill-rule="evenodd"/></svg>
        """,
        "hDistribute": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M6.5,8.4 L6.5,15.6 C6.5,16.4400788 6.5,16.8601181 6.33650979,17.1809857 C6.08043266,17.6835654 5.56405834,18 5,18 C4.43594166,18 3.91956734,17.6835654 3.66349021,17.1809857 C3.5,16.8601181 3.5,16.4400788 3.5,15.6 L3.5,8.4 C3.5,7.55992124 3.5,7.13988186 3.66349021,6.81901425 C3.91956734,6.31643459 4.43594166,6 5,6 C5.56405834,6 6.08043266,6.31643459 6.33650979,6.81901425 C6.5,7.13988186 6.5,7.55992124 6.5,8.4 Z M13.5,8.4 L13.5,15.6 C13.5,16.4400788 13.5,16.8601181 13.3365098,17.1809857 C13.0804327,17.6835654 12.5640583,18 12,18 C11.4359417,18 10.9195673,17.6835654 10.6634902,17.1809857 C10.5,16.8601181 10.5,16.4400788 10.5,15.6 L10.5,8.4 C10.5,7.55992124 10.5,7.13988186 10.6634902,6.81901425 C10.9195673,6.31643459 11.4359417,6 12,6 C12.5640583,6 13.0804327,6.31643459 13.3365098,6.81901425 C13.5,7.13988186 13.5,7.55992124 13.5,8.4 Z M20.5,8.4 L20.5,15.6 C20.5,16.4400788 20.5,16.8601181 20.3365098,17.1809857 C20.0804327,17.6835654 19.5640583,18 19,18 C18.4359417,18 17.9195673,17.6835654 17.6634902,17.1809857 C17.5,16.8601181 17.5,16.4400788 17.5,15.6 L17.5,8.4 C17.5,7.55992124 17.5,7.13988186 17.6634902,6.81901425 C17.9195673,6.31643459 18.4359417,6 19,6 C19.5640583,6 20.0804327,6.31643459 20.3365098,6.81901425 C20.5,7.13988186 20.5,7.55992124 20.5,8.4 Z" fill="black" fill-rule="evenodd"/></svg>
        """,
        "vDistribute": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M6.5,8.4 L6.5,15.6 C6.5,16.4400788 6.5,16.8601181 6.33650979,17.1809857 C6.08043266,17.6835654 5.56405834,18 5,18 C4.43594166,18 3.91956734,17.6835654 3.66349021,17.1809857 C3.5,16.8601181 3.5,16.4400788 3.5,15.6 L3.5,8.4 C3.5,7.55992124 3.5,7.13988186 3.66349021,6.81901425 C3.91956734,6.31643459 4.43594166,6 5,6 C5.56405834,6 6.08043266,6.31643459 6.33650979,6.81901425 C6.5,7.13988186 6.5,7.55992124 6.5,8.4 Z M13.5,8.4 L13.5,15.6 C13.5,16.4400788 13.5,16.8601181 13.3365098,17.1809857 C13.0804327,17.6835654 12.5640583,18 12,18 C11.4359417,18 10.9195673,17.6835654 10.6634902,17.1809857 C10.5,16.8601181 10.5,16.4400788 10.5,15.6 L10.5,8.4 C10.5,7.55992124 10.5,7.13988186 10.6634902,6.81901425 C10.9195673,6.31643459 11.4359417,6 12,6 C12.5640583,6 13.0804327,6.31643459 13.3365098,6.81901425 C13.5,7.13988186 13.5,7.55992124 13.5,8.4 Z M20.5,8.4 L20.5,15.6 C20.5,16.4400788 20.5,16.8601181 20.3365098,17.1809857 C20.0804327,17.6835654 19.5640583,18 19,18 C18.4359417,18 17.9195673,17.6835654 17.6634902,17.1809857 C17.5,16.8601181 17.5,16.4400788 17.5,15.6 L17.5,8.4 C17.5,7.55992124 17.5,7.13988186 17.6634902,6.81901425 C17.9195673,6.31643459 18.4359417,6 19,6 C19.5640583,6 20.0804327,6.31643459 20.3365098,6.81901425 C20.5,7.13988186 20.5,7.55992124 20.5,8.4 Z" fill="black" fill-rule="evenodd" transform="translate(12, 12) rotate(90) translate(-12, -12)"/></svg>
        """,
        "rename": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M12,4 C12.3760389,4 12.7202884,4.21095639 12.8910065,4.5460095 C13,4.75992124 13,5.03994749 13,5.6 L13,7 L17.2,7 C18.8801575,7 19.7202363,7 20.3619715,7.32698043 C20.9264578,7.61460055 21.3853994,8.07354222 21.6730196,8.6380285 C22,9.27976372 22,10.1198425 22,11.8 L22,12.2 C22,13.8801575 22,14.7202363 21.6730196,15.3619715 C21.3853994,15.9264578 20.9264578,16.3853994 20.3619715,16.6730196 C19.7202363,17 18.8801575,17 17.2,17 L13,17 L13,18.4 C13,18.9600525 13,19.2400788 12.8910065,19.4539905 C12.7202884,19.7890436 12.3760389,20 12,20 C11.6239611,20 11.2797116,19.7890436 11.1089935,19.4539905 C11,19.2400788 11,18.9600525 11,18.4 L11,17 L6.8,17 L6.51209154,16.9999334 L6.8,17 C5.11984248,17 4.27976372,17 3.6380285,16.6730196 C3.07354222,16.3853994 2.61460055,15.9264578 2.32698043,15.3619715 C2,14.7202363 2,13.8801575 2,12.2 L2,11.8 C2,10.1198425 2,9.27976372 2.32698043,8.6380285 C2.61460055,8.07354222 3.07354222,7.61460055 3.6380285,7.32698043 C4.27976372,7 5.11984248,7 6.8,7 L8.2,7 C8.39766559,7 8.58370379,7 8.75915957,7.00053243 L11,7 L11,5.6 C11,5.03994749 11,4.75992124 11.1089935,4.5460095 C11.2797116,4.21095639 11.6239611,4 12,4 Z M13,9 L13,15 L17.2,15 C18.8980984,15 19.3053884,14.9667231 19.4539905,14.8910065 C19.6421526,14.7951331 19.7951331,14.6421526 19.8910065,14.4539905 C19.9667231,14.3053884 20,13.8980984 20,12.2 L20,11.8 C20,10.1019016 19.9667231,9.69461163 19.8910065,9.5460095 C19.7951331,9.35784741 19.6421526,9.20486685 19.4539905,9.10899348 C19.3053884,9.03327691 18.8980984,9 17.2,9 L13,9 Z" fill="black" fill-rule="evenodd"/></svg>
        """,
        "dissolveCompound": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M12.0038417,15.9888789 L16.587,20 L12.8,20 C11.2186753,20 10.3815034,20 9.75346544,19.7273943 L9.6380285,19.6730196 C9.07354222,19.3853994 8.61460055,18.9264578 8.32698043,18.3619715 C8.05642015,17.8309671 8.00973524,17.1641617 8.00120111,15.9988928 C8.31312239,16 8.64533099,16 9,16 L10,16 C10.765229,16 11.4259007,16 12.0038417,15.9888789 Z M18.014537,10.001797 C19.1704791,10.0101828 19.8334837,10.0577024 20.3619715,10.3269804 C20.9264578,10.6146006 21.3853994,11.0735422 21.6730196,11.6380285 C22,12.2797637 22,13.1198425 22,14.8 L22,15.2 C22,15.820809 22,16.3269253 21.9835052,16.7507215 L21.9755138,16.7422699 L17.6144569,12.9253337 C17.6663304,12.800995 17.7133426,12.6741631 17.7552826,12.545085 C17.9213389,12.0340162 17.9747155,11.4412279 17.9918726,10.5313993 L17.9980986,10.0022727 Z M2.01653437,7.24826153 L2.02448618,7.25773008 L9.73,14 L6.8,14 C5.21867528,14 4.38150336,14 3.75346544,13.7273943 L3.6380285,13.6730196 C3.07354222,13.3853994 2.61460055,12.9264578 2.32698043,12.3619715 C2,11.7202363 2,10.8801575 2,9.2 L2,8.8 C2,8.17869434 2,7.67226503 2.01653437,7.24826153 Z M7.412,4 L11.2,4 L11.4879085,4 C12.978304,4.00113142 13.7579854,4.01923414 14.3619715,4.32698043 C14.9264578,4.61460055 15.3853994,5.07354222 15.6730196,5.6380285 C16,6.27976372 16,7.11984248 16,8.8 L16,9.2 C16,10.2065837 16,10.9116448 15.9296893,11.453176 L7.412,4 Z" fill="black" fill-rule="evenodd"/><line x1="3" y1="4" x2="21" y2="20" stroke="black" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>
        """,
    ]

    static func load(_ name: String, size: CGFloat? = nil) -> NSImage {
        let key = size != nil ? "\(name)_\(size!)" : name
        if let cached = cache[key] { return cached }
        guard let svg = svgs[name],
              let data = svg.data(using: .utf8),
              let img = NSImage(data: data) else {
            return NSImage(size: NSSize(width: 24, height: 24))
        }
        img.isTemplate = true
        if let s = size { img.size = NSSize(width: s, height: s) }
        cache[key] = img
        return img
    }
}

/// 把内容摆在容器上方三分之一处，而不是居中。
/// 居中的话整组图文会掉到视觉重心以下，在又高又窄的空白区里看着像沉在底下。
/// 素材库空状态和欢迎页「还没有最近文件」共用这一套。
struct PositionedAtOneThird: ViewModifier {
    func body(content: Content) -> some View {
        GeometryReader { g in
            content.position(x: g.size.width / 2, y: g.size.height / 3)
        }
    }
}

/// 进度气泡共用的倒计时估算。
///
/// 各任务后端只报进度、不报剩余时间，所以按「已用时间 / 已完成比例」外推。
/// 卡片出现即开始计时（`@State private var startedAt = Date()`），进度一变 body
/// 重算，倒计时跟着刷新。
enum TaskETA {
    /// - Parameters:
    ///   - progress: 0~1
    ///   - startedAt: 任务开始时间
    /// - Returns: 「约 MM:SS」/「约 H:MM:SS」；进度太小或刚起步时返回 nil ——
    ///   前几秒的样本外推出来的数字会乱跳，不如先不显示
    static func text(progress: Double, startedAt: Date) -> String? {
        guard progress > 0.03, progress < 1 else { return nil }
        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed > 2 else { return nil }
        let remain = elapsed / progress - elapsed
        guard remain.isFinite, remain > 0 else { return nil }
        return format(remain)
    }

    static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
        return h > 0 ? String(format: "约 %d:%02d:%02d", h, m, sec)
                     : String(format: "约 %02d:%02d", m, sec)
    }
}

// MARK: - Filter Panel（效果 → 滤镜）

/// 滤镜列表。卡片的封面是**那帧素材套上各自滤镜**的实拍效果，
/// 不是画个示意图 —— 一眼能看出这个滤镜到底把画面变成什么样
struct FilterPanel: View {
    @EnvironmentObject private var project: ProjectState
    @State private var importHover = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6),
                                    GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(FilterKind.builtins, id: \.self) { kind in
                        FilterCard(kind: kind) { project.addFilter(kind: kind) }
                    }
                }
                .padding(.leading, 3).padding(.trailing, 10)
                .padding(.bottom, 8)
            }
            // 导入 LUT。吸在底部，列表滚多长都在
            Button(action: importLUT) {
                HStack(spacing: 5) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 11))
                    Text("导入 LUT")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(importHover ? .white : Color.labelPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(importHover ? 0.12 : 0.06)))
                .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .onHover { importHover = $0 }
            .help("导入 .cube 格式的 LUT，加到时间轴上")
            .padding(.leading, 3).padding(.trailing, 10)
            .padding(.bottom, 8)
        }
    }

    /// 选一个 .cube 文件，直接在播放头上加一段 LUT 滤镜
    private func importLUT() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedFileTypes = ["cube", "CUBE"]
        panel.message = "选一个 .cube 格式的 LUT 文件"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // 先解析一遍：格式不对就别往时间轴上加个不起作用的片段
        guard LUTCache.shared.cube(at: url.path) != nil else {
            project.showSuccessToast(icon: "exclamationmark.triangle", iconColor: .orange,
                                     title: "LUT 读不了",
                                     subtitle: "\(url.lastPathComponent) 不是有效的 .cube 文件")
            return
        }
        project.addFilter(kind: .lut, lutPath: url.path)
    }
}

// MARK: - Adjust Panel（效果 → 调节）

/// 调节只有一张卡片：加一段调节片段，参数在属性区里调。
/// 卡片封面直接拿那帧素材演示一个偏暖提亮的调子，比画个图标直观
struct AdjustPanel: View {
    @EnvironmentObject private var project: ProjectState

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6),
                                GridItem(.flexible(), spacing: 6)], spacing: 6) {
                AdjustCard { project.addAdjust() }
            }
            .padding(.leading, 3).padding(.trailing, 10)
            .padding(.bottom, 8)
        }
    }
}

private struct AdjustCard: View {
    let onAdd: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Color.white.opacity(0.08)
                Image(nsImage: SidebarSVGIcon.load("adjust", size: 22))
                    .renderingMode(.template)
                    .foregroundColor(Color.labelSecondary)
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(alignment: .bottomTrailing) {
                if hover { VideoMiniBtnView(icon: "plus.circle", action: onAdd).padding(2) }
            }

            Text("自定义调节")
                .font(.system(size: 9))
                .foregroundColor(Color.labelSecondary)
                .lineLimit(1)
        }
        .padding(6)
        .background(hover ? Color.white.opacity(0.08) : Color.clear)
        .cornerRadius(6)
        .contentShape(Rectangle())
        // 拖拽必须排在双击手势之前，反了起始事件会被点击手势抢走
        .onDrag { NSItemProvider(object: FileDropRouter.adjustPasteboardString as NSString) }
        .onHover { hover = $0 }
        .gesture(TapGesture(count: 2).onEnded { onAdd() })
        .help("双击添加调节，或拖到时间轴")
    }
}

private struct FilterCard: View {
    let kind: FilterKind
    let onAdd: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Image(nsImage: FilterThumbnails.image(for: kind))
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            // 悬停时右下角出 +，跟素材卡片一个位置
            .overlay(alignment: .bottomTrailing) {
                if hover {
                    VideoMiniBtnView(icon: "plus.circle", action: onAdd)
                        .padding(2)
                }
            }

            Text(kind.label)
                .font(.system(size: 9))
                .foregroundColor(Color.labelSecondary)
                .lineLimit(1)
        }
        .padding(6)
        .background(hover ? Color.white.opacity(0.08) : Color.clear)
        .cornerRadius(6)
        .contentShape(Rectangle())
        // 拖到时间轴按落点插入。**必须排在双击手势之前**，
        // 写反了拖拽的起始事件会被点击手势抢走（图形卡片踩过这个坑）
        .onDrag { NSItemProvider(object: FileDropRouter.pasteboardString(for: kind) as NSString) }
        .onHover { hover = $0 }
        .gesture(TapGesture(count: 2).onEnded { onAdd() })
        .help("双击添加\(kind.label)，或拖到时间轴")
    }
}

/// 滤镜卡片的封面。拿转场那帧素材实时套一遍滤镜，算完缓存住
enum FilterThumbnails {
    private static var cache: [FilterKind: NSImage] = [:]
    private static let ctx = CIContext(options: [.useSoftwareRenderer: false])

    static func image(for kind: FilterKind) -> NSImage {
        if let hit = cache[kind] { return hit }
        let base = TransitionPreviewFrames.before
        guard let tiff = base.tiffRepresentation,
              let ci = CIImage(data: tiff) else { return base }

        var clip = FilterClip(kind: kind, startTime: 0, endTime: 1)
        clip.intensity = 1
        let out = FilterEngine.apply(clip, to: ci)
        guard let cg = ctx.createCGImage(out, from: ci.extent) else { return base }
        let img = NSImage(cgImage: cg, size: ci.extent.size)
        cache[kind] = img
        return img
    }
}


/// 格式标签渲染成图片，好让它当成一个字符内联进标题里。
/// 直接用视图并排的话，标题换行后第二行会缩在标签右边，跟第一行对不齐
@MainActor
enum FormatTagImage {
    private static var cache: [String: NSImage] = [:]

    static func image(text: String, color: Color) -> NSImage? {
        let key = "\(text)|\(color)"
        if let hit = cache[key] { return hit }
        let label = Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.18)))
        let r = ImageRenderer(content: label)
        r.scale = 2
        guard let img = r.nsImage else { return nil }
        cache[key] = img
        return img
    }
}


// MARK: - Effect Panel（效果 → 特效）

/// 特效列表。跟滤镜那页一样，卡片封面是**素材帧套上各自特效**的实拍效果
struct EffectPanel: View {
    @EnvironmentObject private var project: ProjectState

    /// 按类别分组显示 —— 26 个平铺下来找不着东西
    private static let groups: [(String, [EffectKind])] = [
        ("模糊", [.gaussianBlur, .motionBlur, .zoomBlur, .bokeh]),
        ("风格化", [.pixellate, .crystallize, .pointillize, .bloom, .gloom]),
        ("线条", [.edges, .edgeWork, .lineOverlay]),
        ("半调网点", [.cmykHalftone, .dotScreen, .lineScreen, .circularScreen, .hatchedScreen]),
        ("扭曲", [.twirl, .vortex, .bump, .pinch, .hole, .circleSplash, .lightTunnel]),
        ("锐化降噪", [.unsharpMask, .noiseReduction]),
    ]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Self.groups, id: \.0) { group in
                    Text(group.0)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color.labelSecondary)
                        .padding(.leading, 3)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 6),
                                        GridItem(.flexible(), spacing: 6)], spacing: 6) {
                        ForEach(group.1, id: \.self) { kind in
                            EffectCard(kind: kind) { project.addEffect(kind: kind) }
                        }
                    }
                }
            }
            .padding(.leading, 3).padding(.trailing, 10)
            .padding(.bottom, 8)
        }
    }
}

private struct EffectCard: View {
    let kind: EffectKind
    let onAdd: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: EffectThumbnails.image(for: kind))
                .resizable()
                .aspectRatio(contentMode: .fill)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(alignment: .bottomTrailing) {
                    if hover { VideoMiniBtnView(icon: "plus.circle", action: onAdd).padding(2) }
                }

            Text(kind.label)
                .font(.system(size: 9))
                .foregroundColor(Color.labelSecondary)
                .lineLimit(1)
        }
        .padding(6)
        .background(hover ? Color.white.opacity(0.08) : Color.clear)
        .cornerRadius(6)
        .contentShape(Rectangle())
        // 拖拽必须排在双击之前，写反了拖的起始事件会被点击手势抢走
        .onDrag { NSItemProvider(object: FileDropRouter.pasteboardString(for: kind) as NSString) }
        .onHover { hover = $0 }
        .gesture(TapGesture(count: 2).onEnded { onAdd() })
        .help("双击添加\(kind.label)，或拖到时间轴")
    }
}

enum EffectThumbnails {
    private static var cache: [EffectKind: NSImage] = [:]
    private static let ctx = CIContext(options: [.useSoftwareRenderer: false])

    static func image(for kind: EffectKind) -> NSImage {
        if let hit = cache[kind] { return hit }
        let base = TransitionPreviewFrames.before
        guard let tiff = base.tiffRepresentation, let ci = CIImage(data: tiff) else { return base }

        var clip = EffectClip(kind: kind, startTime: 0, endTime: 1)
        clip.intensity = 1
        let out = EffectEngine.apply(clip, to: ci, renderSize: ci.extent.size)
        guard let cg = ctx.createCGImage(out, from: ci.extent) else { return base }
        let img = NSImage(cgImage: cg, size: ci.extent.size)
        cache[kind] = img
        return img
    }
}
