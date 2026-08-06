import SwiftUI
import UniformTypeIdentifiers

struct MediaLibraryView: View {
    @EnvironmentObject private var project: ProjectState
    @State private var isDragOver = false

    private var isTransitionTab: Bool { project.mediaLibraryTab == "transition" }
    private var isTextTab: Bool { project.mediaLibraryTab == "text" }
    private var isShapeTab: Bool { project.mediaLibraryTab == "shape" }
    private var isAITab: Bool { project.mediaLibraryTab == "ai" }

    private var selectedAssetType: AssetType {
        switch project.mediaLibraryTab {
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
                Text(tabName(project.mediaLibraryTab))
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
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .padding(.top, 8)
            .padding(.bottom, 8)

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

                    MediaToolBtn(svgName: "sort", help: "排序") {
                        showSortNSMenu(project: project)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }

            // Asset list + drag-drop target
            ZStack {
                if isShapeTab {
                    ShapePanel()
                } else if isTextTab {
                    TextLayerPanel()
                } else if isTransitionTab {
                    TransitionPanel()
                } else if filteredAssets.isEmpty {
                    emptyState
                } else {
                    ScrollView(showsIndicators: false) {
                        if selectedAssetType == .image {
                            // 2-column grid for images
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 4),
                                                GridItem(.flexible(), spacing: 4)], spacing: 4) {
                                ForEach(filteredAssets) { asset in
                                    AssetRow(assetID: asset.id)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.bottom, 8)
                        } else if selectedAssetType == .video {
                            // 2-column grid for videos
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 4),
                                                GridItem(.flexible(), spacing: 4)], spacing: 4) {
                                ForEach(filteredAssets) { asset in
                                    AssetRow(assetID: asset.id)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.bottom, 8)
                        } else {
                            VStack(spacing: 2) {
                                ForEach(filteredAssets) { asset in
                                    AssetRow(assetID: asset.id)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.bottom, 8)
                        }
                    }
                }

                // Drag overlay
                if isDragOver {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.accent, lineWidth: 1.5)
                        .background(Color.accent.opacity(0.06).cornerRadius(10))
                        .overlay {
                            VStack(spacing: 8) {
                                Image(systemName: "arrow.down.circle")
                                    .font(.system(size: 26, weight: .ultraLight))
                                Text("松开以导入")
                                    .font(.system(size: 11))
                            }
                            .foregroundColor(Color.accent)
                        }
                        .padding(10)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $isDragOver) { providers in
                for p in providers {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        DispatchQueue.main.async { project.importFile(url) }
                    }
                }
                return true
            }

            Spacer()
            }
            } // else (non-AI tabs)
        }
    }

    // 左侧竖排图标标签栏
    private var verticalTabBar: some View {
        VStack(spacing: 4) {
            tabBtnSVG("video")
            tabBtnSVG("audio")
            tabBtnSVG("image")
            tabBtnSVG("subtitle")
            tabBtnSVG("transition")
            tabBtnSVG("text")
            tabBtnSVG("shape")
            Spacer()
            tabBtnAI()
            importExportMenuBtn
        }
        .padding(.top, 10)
        .padding(.bottom, 14)
        .padding(.horizontal, 6)
        .frame(minWidth: 44, maxWidth: 44, alignment: .center)
        .frame(maxHeight: .infinity)
    }

    private func tabName(_ tab: String) -> String {
        switch tab {
        case "video": return "视频"
        case "audio": return "音频"
        case "image": return "图片"
        case "subtitle": return "字幕"
        case "transition": return "转场"
        case "text": return "文字"
        case "shape": return "图形"
        case "ai": return "AI"
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
        .help("AI")
    }

    private var emptyState: some View {
        let icon: String = {
            switch project.mediaLibraryTab {
            case "video":    return "film"
            case "audio":    return "music.note"
            case "image":    return "photo"
            case "subtitle": return "captions.bubble"
            default:         return "photo.badge.plus"
            }
        }()
        return VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .ultraLight))
                .foregroundColor(Color.labelSecondary.opacity(0.30))
            Text("拖入文件或点击导入")
                .font(.system(size: 11))
                .foregroundColor(Color.labelSecondary.opacity(0.45))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // 导入/导出合并菜单按钮
    private var importExportMenuBtn: some View {
        Button {
            let menu = NSMenu()
            let importItem = NSMenuItem(title: "导入素材", action: #selector(NSApp.sendAction(_:to:from:)), keyEquivalent: "")
            importItem.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: nil)
            importItem.isEnabled = project.projectFileURL != nil
            importItem.target = nil
            importItem.representedObject = "import" as NSString
            let exportItem = NSMenuItem(title: "导出 MP4", action: #selector(NSApp.sendAction(_:to:from:)), keyEquivalent: "")
            exportItem.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
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
            panel.urls.forEach { project.importFile($0) }
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
            if asset.type == .video || asset.type == .image {
                videoAssetCard
            } else {
                normalAssetRow
            }
        }
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
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 16))
                                    .foregroundColor(.orange)
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
                            videoMiniBtn(icon: "arrow.triangle.2.circlepath") { relinkAsset() }
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

    private var normalAssetRow: some View {
        HStack(spacing: 10) {
            if asset.fileExists {
                Image(nsImage: SidebarSVGIcon.load(asset.type.svgIcon))
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
                    .foregroundColor(asset.type.color)
                    .frame(width: 20)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.orange)
                    .frame(width: 20)
            }

            VStack(alignment: .leading, spacing: 2) {
                if isRenaming {
                    nameEditor(fontSize: 12)
                } else {
                    Text(asset.name)
                        .font(.system(size: 12))
                        .foregroundColor(asset.fileExists ? Color.labelPrimary : Color.labelSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(asset.name)
                }

                if !asset.fileExists {
                    Text("素材丢失")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
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
                        miniBtn(icon: "arrow.triangle.2.circlepath") { relinkAsset() }
                    }
                    miniBtn(icon: "trash") { confirmDeleteAsset() }
                }
            }
        }
        .padding(.horizontal, 8)
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
    private func miniBtn(icon: String, action: @escaping () -> Void) -> some View {
        MiniBtnView(icon: icon, action: action)
    }

    @ViewBuilder
    private func videoMiniBtn(icon: String, action: @escaping () -> Void) -> some View {
        VideoMiniBtnView(icon: icon, action: action)
    }
}

private struct MiniBtnView: View {
    let icon: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .light))
                .foregroundColor(Color.labelSecondary)
                .frame(width: 26, height: 26)
                .background(hovering ? Color.white.opacity(0.12) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct VideoMiniBtnView: View {
    let icon: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: hovering ? .medium : .light))
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
            panel.urls.forEach { project.importFile($0) }
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
                Image(systemName: "waveform.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color.accent)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("转换成语音")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color.labelPrimary)
                    .lineLimit(1)

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
    let state: ProjectState.RemoveBackgroundState
    let onCancel: () -> Void
    @State private var xHovering = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.accent.opacity(0.2)).frame(width: 28, height: 28)
                Image(systemName: "scissors")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color.accent)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("去除背景中")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color.labelPrimary)
                    .lineLimit(1)
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
        if s < 60 { return "还需不到 1 分钟" }
        let totalMinutes = Int((s / 60).rounded())
        if totalMinutes < 60 { return "还需约 \(totalMinutes) 分钟" }
        let h = totalMinutes / 60, m = totalMinutes % 60
        return m == 0 ? "还需约 \(h) 小时" : "还需约 \(h) 小时 \(m) 分"
    }
    @State private var xHovering = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.accent.opacity(0.2)).frame(width: 28, height: 28)
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color.accent)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("清晰度提升中…")
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

    private var stageText: String {
        switch state {
        case .downloading: return "下载分离模型…"
        case .running(_, let stage): return stage
        default: return ""
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.accent.opacity(0.2)).frame(width: 28, height: 28)
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color.accent)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("分离音轨 · \(stageText)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color.labelPrimary)
                    .lineLimit(1)
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
                Image(systemName: "waveform")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color.accent)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("语音识别")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color.labelPrimary)
                    .lineLimit(1)

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
    let progress: Double
    let onCancel: () -> Void
    @State private var xHovering = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.accent.opacity(0.2)).frame(width: 28, height: 28)
                Image(systemName: "rectangle.split.3x1")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color.accent)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("智能分割")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color.labelPrimary)
                    .lineLimit(1)

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
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.orange.opacity(0.2)).frame(width: 28, height: 28)
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.orange)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("正在生成倒放视频...")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color.labelPrimary)
                    .lineLimit(1)

                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(.orange)
                    .frame(height: 14)
            }
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
    let progress: Double
    let onCancel: () -> Void
    @State private var xHovering = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.purple.opacity(0.2)).frame(width: 28, height: 28)
                Image(systemName: "brain")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.purple)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("大模型分析")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color.labelPrimary)
                    .lineLimit(1)

                GeometryReader { geo in
                    HStack(spacing: 6) {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .tint(.purple)
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
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12, weight: .semibold))
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

private struct TextLayerPanel: View {
    @EnvironmentObject private var project: ProjectState

    var body: some View {
        VStack(spacing: 0) {
            if project.textTemplates.isEmpty {
                VStack(spacing: 10) {
                    Text("T")
                        .font(.system(size: 32, weight: .bold, design: .serif))
                        .foregroundColor(Color.labelSecondary.opacity(0.30))
                    Text("右键文字片段\n「保存为文字模板」")
                        .font(.system(size: 11))
                        .foregroundColor(Color.labelSecondary.opacity(0.45))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(project.textTemplates) { tmpl in
                            TextTemplateCard(template: tmpl)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
                    .padding(.bottom, 8)
                }
            }
        }
    }
}

private struct TextTemplateCard: View {
    let template: TextTemplate
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
        .padding(.horizontal, 8)
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
            if let clipID = project.selectedTextClipID {
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
                        .padding(.horizontal, 10)
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
                .padding(.horizontal, 8)
            }
            .padding(.top, 6)
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
                ZStack {
                    // 底层灰色色块
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(white: 0.22))
                    // 叠加层：灰白色块做转场动画
                    transitionOverlay
                }
                .frame(height: 44)
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

    @ViewBuilder
    private var transitionOverlay: some View {
        let p = phase
        switch type {
        case .dissolve:
            // 右侧浅灰块淡入淡出
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(white: 0.55))
                .opacity(p)
        case .fadeToBlack:
            // 黑色遮罩淡入淡出
            Color.black.opacity(p)
        case .pushLeft:
            // 浅灰块从右推入
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(white: 0.55))
                .offset(x: (1 - p) * 80)
        case .pushRight:
            // 浅灰块从左推入
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(white: 0.55))
                .offset(x: -(1 - p) * 80)
        case .pushUp:
            // 浅灰块从下推入
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(white: 0.55))
                .offset(y: (1 - p) * 50)
        case .pushDown:
            // 浅灰块从上推入
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(white: 0.55))
                .offset(y: -(1 - p) * 50)
        case .zoom:
            // 浅灰块从放大缩回 + 淡入
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(white: 0.55))
                .scaleEffect(1.5 - 0.5 * p)
                .opacity(p)
        case .slideLeft:
            // 浅灰块从右滑入覆盖
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(white: 0.55))
                .offset(x: (1 - p) * 80)
        case .slideRight:
            // 浅灰块从左滑入覆盖
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(white: 0.55))
                .offset(x: -(1 - p) * 80)
        case .slideUp:
            // 浅灰块从下滑入覆盖
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(white: 0.55))
                .offset(y: (1 - p) * 50)
        case .slideDown:
            // 浅灰块从上滑入覆盖
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(white: 0.55))
                .offset(y: -(1 - p) * 50)
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

private struct ShapePanel: View {
    @EnvironmentObject private var project: ProjectState

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8),
                                GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(ShapeType.allCases, id: \.self) { type in
                    ShapeCard(type: type) { project.addShapeAtPlayhead(type: type) }
                }
            }
            .padding(.horizontal, 8)
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
                    let r = CGRect(x: geo.size.width * 0.2, y: geo.size.height * 0.28,
                                   width: geo.size.width * 0.6, height: geo.size.height * 0.44)
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
        .onHover { hover = $0 }
        .gesture(TapGesture(count: 2).onEnded { onAdd() })
        .help("双击添加\(type.label)")
    }
}

// MARK: - Sidebar SVG Icons

enum SidebarSVGIcon {
    static var cache: [String: NSImage] = [:]

    static let svgs: [String: String] = [
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
        "transition": """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path fill-rule="evenodd" d="M18.6167689,4.70645855 C19.8886673,3.48853479 22,4.39000644 22,6.15099022 L22,17.8490098 C22,19.6099936 19.8886673,20.5114652 18.6167689,19.2935414 L12.6906977,13.6193034 C12.303938,13.2489794 11.6941061,13.2490254 11.3074024,13.6194078 L5.38323109,19.2935414 C4.11133267,20.5114652 2,19.6099936 2,17.8490098 L2,6.15099022 C2,4.39000644 4.11133267,3.48853479 5.38323109,4.70645855 L11.3074593,10.3797512 C11.6941482,10.7500609 12.3038959,10.750107 12.6906407,10.3798556 L18.6167689,4.70645855 Z" fill="black"/></svg>
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
