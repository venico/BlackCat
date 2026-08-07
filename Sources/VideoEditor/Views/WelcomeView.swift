import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 欢迎页。左边是动作（新建/打开，左下角设置），右边是最近文件。
/// 布局参照 Sketch 的启动窗：侧栏窄、内容区大，最近文件支持缩略图/列表两种视图和搜索。
struct WelcomeView: View {
    @Environment(\.windowID) private var windowID
    @EnvironmentObject private var project: ProjectState
    @ObservedObject private var recents = RecentProjects.shared
    @ObservedObject private var updater = AppUpdater.shared

    enum ViewMode { case grid, list }
    enum SortKey { case name, date }
    @State private var mode: ViewMode = .grid
    @State private var sortKey: SortKey = .date
    /// 默认按时间倒序——最近打开的排最前，这是「最近文件」该有的默认
    @State private var sortAsc = false
    @State private var search = ""
    @State private var renaming: URL? = nil
    @State private var renameText = ""
    /// 正在走 esc 取消。挡住紧随其后的失焦回调，别把取消又变成确认
    @State private var cancelingRename = false
    @State private var errorMessage: String?

    private var filtered: [RecentProject] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let base = q.isEmpty ? recents.items
                             : recents.items.filter { $0.name.lowercased().contains(q) }
        return base.sorted { a, b in
            let ascending: Bool
            switch sortKey {
            case .name:
                // localizedStandardCompare：中文按拼音、数字按数值大小，
                // 不会出现 "文件10" 排在 "文件2" 前面
                ascending = a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .date:
                ascending = a.openedAt < b.openedAt
            }
            return sortAsc ? ascending : !ascending
        }
    }

    /// 点列头：同一列再点就反向，换列则用那一列的默认方向
    /// （名称默认 A→Z，时间默认新→旧）
    private func toggleSort(_ key: SortKey) {
        if sortKey == key {
            sortAsc.toggle()
        } else {
            sortKey = key
            sortAsc = (key == .name)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 点空白处确认改名。加在最外层并用 simultaneousGesture：普通 .onTapGesture
        // 会把点击吃掉，卡片、按钮、列头排序就都点不动了
        .simultaneousGesture(TapGesture().onEnded {
            if let url = renaming, let item = recents.items.first(where: { $0.url == url }) {
                commitRename(item)
            }
        })
        // esc 取消改名，名字保持原样。没在改名时什么都不做（欢迎页不响应 esc）
        .onExitCommand { cancelRename() }
        .windowMaterial()
        .ignoresSafeArea()
        // 欢迎页阶段把窗口缩到 860x560：它铺满整个窗口，而主窗口默认 1280x780，
        // 一屏就两个按钮加几张缩略图，空得离谱。选完文件恢复原尺寸再进主界面
        .onAppear {
            WelcomeWindowSizer.shrink(windowID)
            // 静默检查：没更新就什么都不显示，不打扰
            Task { await updater.check(silent: true) }
        }
        // 尺寸恢复由 ContentView 的 onChange 负责（要在消失动画之前做）；
        // 这里留一手兜底：窗口被直接关掉时也能清掉记录
        .onDisappear { WelcomeWindowSizer.restore(windowID) }
    }

    // MARK: - 左侧

    /// 侧栏。样式跟主界面的素材栏一致：独立的圆角卡片浮在左边，
    /// 顶部留出跟主界面同高的标题栏行放交通灯
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 交通灯行。欢迎页现在铺满整个窗口，没有它就没法关/最小化窗口
            HStack {
                TrafficLightsView()
                    .padding(.leading, 12)
                Spacer()
            }
            .frame(height: 28)

            Spacer().frame(height: 18)

            sidebarButton(icon: "newFile", title: "新建项目", isSVG: true) { project.showNewProjectSheet = true }
            sidebarButton(icon: "folder", title: "打开项目", isSVG: true) { openExistingProject() }

            Spacer()

            if let err = errorMessage {
                Text(err)
                    .font(.system(size: 10))
                    .foregroundColor(.red.opacity(0.85))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .fixedSize(horizontal: false, vertical: true)
            }

            updateCard

            sidebarButton(icon: "settings", title: "设置", isSVG: true) {
                // 只开设置，不退欢迎页——用户还没选文件，不该把主界面放出来。
                // 设置面板的 overlay 排在欢迎页之后，会盖在它上面
                project.showSettings = true
            }
            .padding(.bottom, 12)
        }
        .frame(width: 220)
        .frame(maxHeight: .infinity)
        .panelSurface(.sidebar)
        .softPanelShadow()
        .padding(8)
    }

    /// 更新卡片。只在真有新版时出现，没有更新就完全不占位置
    @ViewBuilder
    private var updateCard: some View {
        switch updater.phase {
        case .available(let version):
            Button { updater.startUpdate() } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("点击安装更新")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color.labelPrimary)
                        Text(displayVersion(version))
                            .font(.system(size: 10))
                            .foregroundColor(Color.labelSecondary)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color.labelSecondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.bottom, 8)

        case .downloading(let progress):
            updateProgressCard(text: "正在下载更新", progress: progress)

        case .installing:
            updateProgressCard(text: "正在安装…", progress: nil)

        case .upToDate(let msg):
            noticeCard(icon: "checkmark.circle.fill", color: .green.opacity(0.85), text: msg)

        case .failed(let msg):
            noticeCard(icon: "exclamationmark.triangle.fill",
                       color: .orange.opacity(0.9), text: msg)

        case .idle, .checking:
            EmptyView()
        }
    }

    /// 提示卡片（已是最新 / 出错）。带 X 可以手动关掉
    private func noticeCard(icon: String, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundColor(color)
                Text(text)
                    .font(.system(size: 10.5))
                    .foregroundColor(Color.labelPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 2)
                Button { updater.dismissFailure() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(Color.labelSecondary)
                        .frame(width: 16, height: 16)
                        .background(Color.white.opacity(0.1))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    /// 下载/安装进度。带 X 可以中途取消
    private func updateProgressCard(text: String, progress: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color.labelPrimary)
                Spacer(minLength: 4)
                if let p = progress {
                    Text("\(Int(p * 100))%")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundColor(Color.labelSecondary)
                }
                Button { updater.cancel() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(Color.labelSecondary)
                        .frame(width: 16, height: 16)
                        .background(Color.white.opacity(0.1))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("取消")
            }
            ProgressView(value: progress ?? 0, total: 1)
                .progressViewStyle(.linear)
                .tint(Color.accent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    /// tag 是 v4.3.6 这种，显示成 "V 4.3.6"
    private func displayVersion(_ tag: String) -> String {
        "V " + tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
    }

    private func sidebarButton(icon: String, title: String, isSVG: Bool = false,
                               action: @escaping () -> Void) -> some View {
        SidebarRow(icon: icon, title: title, isSVG: isSVG, action: action)
    }

    // MARK: - 右侧

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Text("最近")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(Color.labelPrimary)
                Spacer()
                viewModeSwitch
                searchField
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 26)

            if recents.items.isEmpty {
                emptyState(text: "还没有最近文件")
            } else if filtered.isEmpty {
                emptyState(text: "没有匹配「\(search)」的项目")
            } else {
                ScrollView {
                    if mode == .grid { gridBody } else { listBody }
                }
                // 空白处右键：清空整个列表
                .contextMenu {
                    Button("清空最近列表", role: .destructive) { recents.clearAll() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .panelSurfaceClear(.content)
        .padding(.vertical, 8)
        .padding(.trailing, 8)
    }

    private var viewModeSwitch: some View {
        HStack(spacing: 2) {
            modeButton(.grid, symbol: "gridView", help: "缩略图")
            modeButton(.list, symbol: "listView", help: "列表")
        }
        .padding(3)
        .background(Color.white.opacity(0.08))
        .clipShape(Capsule())
    }

    private func modeButton(_ m: ViewMode, symbol: String, help: String) -> some View {
        Button { mode = m } label: {
            Image(nsImage: SidebarSVGIcon.load(symbol))
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 13, height: 13)
                .foregroundColor(mode == m ? Color.labelPrimary : Color.labelSecondary)
                .frame(width: 30, height: 22)
                .background(mode == m ? Color.white.opacity(0.15) : Color.clear)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(nsImage: SidebarSVGIcon.load("search"))
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 10, height: 10)
                .foregroundColor(Color.labelSecondary)
            TextField("搜索", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(Color.labelPrimary)
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(Color.labelSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(width: 160, height: 26)
        .background(Color.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func emptyState(text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 30, weight: .thin))
                .foregroundColor(Color.labelSecondary.opacity(0.5))
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(Color.labelSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 两种视图

    private var gridBody: some View {
        // min == max：列宽**固定**，只有列数随窗口宽度变。
        // 给一个区间的话（比如 112~142）SwiftUI 会拉伸卡片去填满整行，
        // 拖窗口时封面尺寸跟着变，看着很晃
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 142, maximum: 142), spacing: 16)],
                  alignment: .leading, spacing: 16) {
            ForEach(filtered) { item in
                RecentCard(item: item,
                           thumbnail: recents.thumbnails[item.url],
                           renaming: renaming == item.url,
                           renameText: $renameText,
                           onOpen: { open(item) },
                           onCommitRename: { commitRename(item) })
                    .onAppear { recents.loadThumbnail(for: item.url) }
                    .contextMenu { menu(for: item) }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
    }

    private var listBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sortHeader("名称", key: .name)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("位置")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color.labelSecondary)
                    .frame(width: 220, alignment: .leading)
                sortHeader("最近打开时间", key: .date)
                    .frame(width: 110, alignment: .leading)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 6)

            Divider().background(Color.white.opacity(0.08))
                .padding(.bottom, 8)   // 表头和第一行贴太紧

            ForEach(Array(filtered.enumerated()), id: \.element.id) { idx, item in
                RecentRow(item: item,
                          thumbnail: recents.thumbnails[item.url],
                          renaming: renaming == item.url,
                          renameText: $renameText,
                          onOpen: { open(item) },
                          onCommitRename: { commitRename(item) })
                    // 斑马纹垫在行自己的 hover 背景之下，hover 时被盖住
                    .background(idx % 2 == 1 ? Color.white.opacity(0.035) : Color.clear)
                    .onAppear { recents.loadThumbnail(for: item.url) }
                    .contextMenu { menu(for: item) }
            }
        }
        .padding(.bottom, 20)
    }

    /// 可点击的排序列头。当前排序列显示方向箭头
    private func sortHeader(_ title: String, key: SortKey) -> some View {
        Button { toggleSort(key) } label: {
            HStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(sortKey == key ? Color.labelPrimary : Color.labelSecondary)
                if sortKey == key {
                    Image(systemName: sortAsc ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(Color.labelPrimary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func menu(for item: RecentProject) -> some View {
        Button("打开") { open(item) }
        Divider()
        Button("重命名") {
            renameText = item.name
            renaming = item.url
        }
        Button("在 Finder 中显示") {
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
        }
        Divider()
        Button("从最近列表移除") { recents.remove(item.url) }
        Button("清空最近列表", role: .destructive) { recents.clearAll() }
    }

    // MARK: - 动作

    private func open(_ item: RecentProject) {
        guard item.exists else {
            errorMessage = "文件已不在原位置：\(item.url.lastPathComponent)"
            return
        }
        errorMessage = nil
        openInWindow(item.url)
    }

    private func commitRename(_ item: RecentProject) {
        // esc 取消时 TextField 会先失焦，失焦回调紧跟着就来——不挡住的话
        // 取消完又被当成确认提交一次，等于 esc 无效
        guard !cancelingRename else { return }
        defer { renaming = nil }
        if let err = RecentProjects.shared.rename(item.url, to: renameText) {
            errorMessage = err
        } else {
            errorMessage = nil
        }
    }

    /// esc：放弃改名，名字保持原样
    private func cancelRename() {
        guard renaming != nil else { return }
        cancelingRename = true
        renaming = nil
        // 失焦回调是下一个 runloop 才到，这一拍之后再解锁
        DispatchQueue.main.async { cancelingRename = false }
    }

    private func openExistingProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "bcj") ?? .json]
        panel.prompt = "打开"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openInWindow(url)
    }

    /// 打开项目一律走新窗口，不顶掉当前窗口的内容。
    /// 例外：这个窗口自己还停在欢迎页（没打开过任何项目），那就地打开，
    /// 否则用户点一下会多出一个空欢迎页窗口挂在那儿
    private func openInWindow(_ url: URL) {
        if let (_, existing) = WindowManager.shared.existingWindow(for: url) {
            WindowManager.shared.focus(existing)
        } else if project.projectFileURL == nil {
            project.openProject(url: url)
        } else {
            WindowManager.shared.newWindow(.openProject(url))
        }
    }
}

// MARK: - 侧栏行

private struct SidebarRow: View {
    let icon: String
    let title: String
    /// true 表示 icon 是项目自带 SVG 的名字，false 表示 SF Symbol 名。
    /// 文件夹这类在别处已有专用图标的，统一走 SVG，不跟 SF Symbol 混用
    var isSVG: Bool = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            // spacing 就是眼睛看到的间距：图标容器宽度跟图标本身一致（14），
            // 不再多留两侧空白。之前容器 18pt 比图标宽 4pt，spacing 10 实际看着是 12
            HStack(spacing: 4) {
                Group {
                    if isSVG {
                        Image(nsImage: SidebarSVGIcon.load(icon))
                            .renderingMode(.template)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 13))
                    }
                }
                    .foregroundColor(Color.labelPrimary)
                    .frame(width: 14)
                Text(title)
                    .font(.system(size: 12.5))
                    .foregroundColor(Color.labelPrimary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(hover ? Color.white.opacity(0.08) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .onHover { hover = $0 }
    }
}

// MARK: - 缩略图卡片

private struct RecentCard: View {
    let item: RecentProject
    let thumbnail: NSImage?
    let renaming: Bool
    @Binding var renameText: String
    let onOpen: () -> Void
    let onCommitRename: () -> Void
    @State private var hover = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Color.white.opacity(0.06)
                if let img = thumbnail {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "film")
                        .font(.system(size: 22, weight: .thin))
                        .foregroundColor(Color.labelSecondary.opacity(0.45))
                }
                if !item.exists {
                    // 文件被移走/删掉了，标出来，省得点了才发现打不开
                    Color.black.opacity(0.45)
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 20, weight: .light))
                        .foregroundColor(.white.opacity(0.8))
                }
            }
            // 裁剪必须加在**定好尺寸的容器**上：.fill 会让图片撑出容器，
            // 把 clipShape 加在 Image 上裁的是图片自己的框，图片照样溢出卡片、
            // 把下面的文件名压住（第一版就是这个现象）
            .frame(height: 78)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(hover ? Color.accent : Color.white.opacity(0.08),
                              lineWidth: hover ? 1.5 : 0.5))

            if renaming {
                TextField("", text: $renameText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Color.white.opacity(0.12))
                    .cornerRadius(5)
                    .focused($focused)
                    .onAppear { DispatchQueue.main.async { focused = true } }
                    .onSubmit(onCommitRename)
                    .onChange(of: focused) { if !focused { onCommitRename() } }
            } else {
                Text(item.name)
                    .font(.system(size: 11.5))
                    .foregroundColor(item.exists ? Color.labelPrimary : Color.labelSecondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2, perform: onOpen)
    }
}

// MARK: - 列表行

private struct RecentRow: View {
    let item: RecentProject
    let thumbnail: NSImage?
    let renaming: Bool
    @Binding var renameText: String
    let onOpen: () -> Void
    let onCommitRename: () -> Void
    @State private var hover = false
    @FocusState private var focused: Bool

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Color.white.opacity(0.06)
                if let img = thumbnail {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "film")
                        .font(.system(size: 10, weight: .thin))
                        .foregroundColor(Color.labelSecondary.opacity(0.45))
                }
            }
            .frame(width: 42, height: 28)
            .clipShape(RoundedRectangle(cornerRadius: 4))   // 同上：裁容器，不裁图片

            if renaming {
                TextField("", text: $renameText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.white.opacity(0.12))
                    .cornerRadius(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .focused($focused)
                    .onAppear { DispatchQueue.main.async { focused = true } }
                    .onSubmit(onCommitRename)
                    .onChange(of: focused) { if !focused { onCommitRename() } }
            } else {
                Text(item.name)
                    .font(.system(size: 12))
                    .foregroundColor(item.exists ? Color.labelPrimary : Color.labelSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text(item.url.deletingLastPathComponent().lastPathComponent)
                .font(.system(size: 11))
                .foregroundColor(Color.labelSecondary)
                .lineLimit(1).truncationMode(.middle)
                .frame(width: 220, alignment: .leading)

            Text(Self.dateFmt.string(from: item.openedAt))
                .font(.system(size: 11).monospacedDigit())
                .foregroundColor(Color.labelSecondary)
                .frame(width: 110, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .frame(height: 40)
        .background(hover ? Color.white.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2, perform: onOpen)
    }
}

// MARK: - 欢迎页阶段的窗口尺寸

/// 欢迎页铺满整个窗口，而主窗口默认 1280×780、最小 1100×680——那个尺寸下
/// 欢迎页大片留白。这里在欢迎页出现时把窗口缩到 860×560，退出时还原。
///
/// 要先放开 minSize 再 setContentSize：minSize 是硬约束，不放开的话
/// 设 860 会被夹回 1100，看起来像没生效。
enum WelcomeWindowSizer {
    /// 默认宽度 = 一行正好 4 个封面：
    ///   网格 142×4 + 间距 16×3 = 616
    /// + 内容区左右 padding 20×2 = 40
    /// + 侧栏 220 + 它的 padding 8×2 = 236
    /// + 内容区右外边距 8
    /// = 900
    private static let welcomeSize = NSSize(width: 900, height: 560)
    /// 最窄 = 一行 2 个封面：网格 142×2 + 间距 16 = 300，+40+236+8 = 584。
    /// 再窄侧栏就要被压缩了（它是固定 220，不该跟着变）
    static let minWidth: CGFloat = 584
    static let minHeight: CGFloat = 460
    private static let welcomeMinSize = NSSize(width: minWidth, height: minHeight)
    /// **按窗口**存原始尺寸。之前是全局一份，多窗口下第二个窗口调 shrink 时
    /// 看到 savedFrame 已有值就直接返回，欢迎页尺寸就不生效了；
    /// 而且拿窗口用的是 NSApp.windows.first，多窗口下经常拿到别人那个
    nonisolated(unsafe) private static var saved: [WindowID: (frame: NSRect, minSize: NSSize)] = [:]

    @MainActor static func shrink(_ id: WindowID) {
        guard let w = WindowManager.shared.window(for: id) else { return }
        guard saved[id] == nil else { return }   // 已经缩过，别把缩后的尺寸当原始值存下来
        saved[id] = (w.frame, w.minSize)
        w.minSize = welcomeMinSize
        w.setContentSize(welcomeSize)
        // 不用 NSWindow.center()，它明显偏上，理由见 centerOnScreen
        w.centerOnScreen()
    }

    @MainActor static func restore(_ id: WindowID) {
        guard let w = WindowManager.shared.window(for: id), let s = saved[id] else { return }
        w.minSize = s.minSize
        w.setFrame(s.frame, display: true, animate: false)
        saved[id] = nil
    }

    /// 窗口关掉时清掉它的记录，免得 id 复用（不会发生）或长期泄漏
    @MainActor static func forget(_ id: WindowID) { saved[id] = nil }
}

// MARK: - 右下角更新卡片

/// 主界面里的更新提示。跟欢迎页那张卡内容一致，只是摆在右下角气泡区，
/// 跟导出/识别那些任务卡片同一套位置和节奏。
/// 只在「用户主动点了检查更新」之后才出现——启动时的静默检查不弹这个。
struct UpdateBubble: View {
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        Group {
            switch updater.phase {
            case .available(let version):
                card {
                    Button { updater.startUpdate() } label: {
                        HStack(spacing: 10) {
                            ZStack {
                                Circle().fill(Color.accent.opacity(0.2)).frame(width: 28, height: 28)
                                Image(systemName: "arrow.down.circle")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(Color.accent)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("点击安装更新")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(Color.labelPrimary)
                                Text("V " + version.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")))
                                    .font(.system(size: 10))
                                    .foregroundColor(Color.labelSecondary)
                            }
                            Spacer(minLength: 6)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(Color.labelSecondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

            case .downloading(let p):
                card { progressRow(text: "正在下载更新", progress: p) }

            case .installing:
                card { progressRow(text: "正在安装，稍后自动重启…", progress: nil) }

            case .upToDate(let msg):
                card { noticeRow(icon: "checkmark.circle.fill",
                                 color: .green.opacity(0.85), text: msg) }

            case .failed(let msg):
                card { noticeRow(icon: "xmark.circle.fill",
                                 color: .red.opacity(0.85), text: msg) }

            case .idle, .checking:
                EmptyView()
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: updater.phase)
    }

    private func noticeRow(icon: String, color: Color, text: String) -> some View {
                    HStack(spacing: 10) {
                        Image(systemName: icon)
                            .font(.system(size: 13))
                            .foregroundColor(color)
                        Text(text)
                            .font(.system(size: 11))
                            .foregroundColor(Color.labelPrimary)
                            .lineLimit(2)
                        Spacer(minLength: 6)
                        Button { updater.dismissFailure() } label: {
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

    private func progressRow(text: String, progress: Double?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color.labelPrimary)
                Spacer(minLength: 4)
                if let p = progress {
                    Text("\(Int(p * 100))%")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundColor(Color.labelSecondary)
                }
                Button { updater.cancel() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(Color.labelSecondary)
                        .frame(width: 16, height: 16)
                        .background(Color.white.opacity(0.1))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("取消")
            }
            ProgressView(value: progress ?? 0, total: 1)
                .progressViewStyle(.linear)
                .tint(Color.accent)
        }
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(width: 260)
            .background(Color(red: 0.16, green: 0.16, blue: 0.17))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .opacity))
    }
}
