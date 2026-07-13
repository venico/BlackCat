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
                GeometryReader { geo in
                    AIChatPanel()
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            } else {
            VStack(spacing: 0) {
            // Section header
            HStack {
                Text(tabName(project.mediaLibraryTab))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color.labelSecondary)
                    .textCase(.uppercase)
                Spacer()
                MediaToolBtn(icon: "paintbrush", enabled: !project.mediaAssets.isEmpty, help: "清空素材库") {
                    project.showClearLibraryConfirm = true
                }
                MediaToolBtn(icon: "arrow.clockwise", help: "刷新素材库") {
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
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 10))
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

                    MediaToolBtn(icon: "arrow.up.arrow.down", help: "排序") {
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
            tabBtn("video", icon: "film")
            tabBtn("audio", icon: "music.note")
            tabBtn("image", icon: "photo")
            tabBtn("subtitle", icon: "captions.bubble")
            tabBtnBowtie("transition")
            tabBtnT("text")
            tabBtnShape("shape")
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
    private func tabBtnT(_ tab: String) -> some View {
        let isActive = project.mediaLibraryTab == tab
        Button { project.mediaLibraryTab = tab } label: {
            Text("T")
                .font(.system(size: 15, weight: .bold, design: .serif))
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
    private func tabBtnBowtie(_ tab: String) -> some View {
        let isActive = project.mediaLibraryTab == tab
        Button { project.mediaLibraryTab = tab } label: {
            BowtieIcon(size: 14, color: isActive ? .white : Color.labelSecondary)
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
            Image(nsImage: AITabIcon.render(size: 16))
                .renderingMode(.template)
                .foregroundColor(isActive ? .white : Color.labelSecondary)
                .frame(width: 30, height: 30)
                .background(isActive ? Color.white.opacity(0.15) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help("AI")
    }

    @ViewBuilder
    private func tabBtnShape(_ tab: String) -> some View {
        let isActive = project.mediaLibraryTab == tab
        Button { project.mediaLibraryTab = tab } label: {
            Image(systemName: "square.on.circle")
                .font(.system(size: 14, weight: .medium))
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
    private func tabBtn(_ tab: String, icon: String) -> some View {
        let isActive = project.mediaLibraryTab == tab
        Button { project.mediaLibraryTab = tab } label: {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(isActive ? .white : Color.labelSecondary)
                .frame(width: 30, height: 30)
                .background(isActive ? Color.white.opacity(0.15) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(tabName(tab))
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
        Menu {
            Button {
                guard project.projectFileURL != nil else { return }
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = true
                panel.canChooseFiles = true
                panel.canChooseDirectories = true
                panel.allowedContentTypes = []
                panel.begin { r in
                    guard r == .OK else { return }
                    panel.urls.forEach { project.importFile($0) }
                }
            } label: {
                Label("导入素材", systemImage: "square.and.arrow.down")
            }
            .disabled(project.projectFileURL == nil)

            Button {
                project.showExportSheet = true
            } label: {
                Label("导出 MP4", systemImage: "square.and.arrow.up")
            }
            .disabled(project.projectFileURL == nil)
        } label: {
            Image(nsImage: ImportExportIcon.render(size: 15))
                .frame(width: 30, height: 30)
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 30, height: 30)
        .help("导入 / 导出")
    }
}

// MARK: - Import/Export Icon

private enum AITabIcon {
    static func render(size: CGFloat) -> NSImage {
        let s = size
        let img = NSImage(size: NSSize(width: s, height: s))
        img.lockFocus()
        NSColor.black.setStroke()
        NSColor.black.setFill()

        let lw: CGFloat = 1.2
        let p: CGFloat = 0.5
        let r: CGFloat = 2.5
        let cutX = s * 0.6
        let cutY = s * 0.6

        let box = NSBezierPath()
        box.lineWidth = lw; box.lineCapStyle = .round; box.lineJoinStyle = .round
        box.move(to: NSPoint(x: s - p, y: s - cutY))
        box.line(to: NSPoint(x: s - p, y: s - p - r))
        box.appendArc(withCenter: NSPoint(x: s - p - r, y: s - p - r), radius: r, startAngle: 0, endAngle: 90)
        box.line(to: NSPoint(x: p + r, y: s - p))
        box.appendArc(withCenter: NSPoint(x: p + r, y: s - p - r), radius: r, startAngle: 90, endAngle: 180)
        box.line(to: NSPoint(x: p, y: p + r))
        box.appendArc(withCenter: NSPoint(x: p + r, y: p + r), radius: r, startAngle: 180, endAngle: 270)
        box.line(to: NSPoint(x: cutX, y: p))
        box.stroke()

        let tri = NSBezierPath()
        let cx = s * 0.42
        let cy = s * 0.5
        let ts: CGFloat = s * 0.28
        let tr: CGFloat = 1.0
        let tA = NSPoint(x: cx - ts * 0.5, y: cy + ts)
        let tB = NSPoint(x: cx - ts * 0.5, y: cy - ts)
        let tC = NSPoint(x: cx + ts * 0.9, y: cy)
        tri.move(to: NSPoint(x: (tA.x + tB.x) / 2, y: (tA.y + tB.y) / 2))
        tri.appendArc(from: tB, to: tC, radius: tr)
        tri.appendArc(from: tC, to: tA, radius: tr)
        tri.appendArc(from: tA, to: tB, radius: tr)
        tri.close()
        tri.fill()

        let sx = s * 0.82
        let sy = s * 0.18
        let sr: CGFloat = s * 0.18
        let si: CGFloat = sr * 0.35
        let star = NSBezierPath()
        star.move(to: NSPoint(x: sx, y: sy + sr))
        star.line(to: NSPoint(x: sx - si, y: sy + si))
        star.line(to: NSPoint(x: sx - sr, y: sy))
        star.line(to: NSPoint(x: sx - si, y: sy - si))
        star.line(to: NSPoint(x: sx, y: sy - sr))
        star.line(to: NSPoint(x: sx + si, y: sy - si))
        star.line(to: NSPoint(x: sx + sr, y: sy))
        star.line(to: NSPoint(x: sx + si, y: sy + si))
        star.close()
        star.fill()

        img.unlockFocus()
        img.isTemplate = true
        return img
    }
}

private enum ImportExportIcon {
    static func render(size: CGFloat) -> NSImage {
        let s = size
        let w = s * 1.15
        let img = NSImage(size: NSSize(width: w, height: s))
        img.lockFocus()

        NSColor.secondaryLabelColor.setStroke()
        let lw: CGFloat = 1.3
        let p: CGFloat = 0.5
        let r: CGFloat = 2.5
        let boxR = s - p
        let gapHi = s * 0.66
        let gapLo = s * 0.16

        let box = NSBezierPath()
        box.lineWidth = lw; box.lineCapStyle = .round; box.lineJoinStyle = .round
        box.move(to: NSPoint(x: boxR, y: gapHi))
        box.line(to: NSPoint(x: boxR, y: s - p - r))
        box.appendArc(withCenter: NSPoint(x: boxR - r, y: s - p - r), radius: r, startAngle: 0, endAngle: 90)
        box.line(to: NSPoint(x: p + r, y: s - p))
        box.appendArc(withCenter: NSPoint(x: p + r, y: s - p - r), radius: r, startAngle: 90, endAngle: 180)
        box.line(to: NSPoint(x: p, y: p + r))
        box.appendArc(withCenter: NSPoint(x: p + r, y: p + r), radius: r, startAngle: 180, endAngle: 270)
        box.line(to: NSPoint(x: boxR - r, y: p))
        box.appendArc(withCenter: NSPoint(x: boxR - r, y: p + r), radius: r, startAngle: 270, endAngle: 360)
        box.line(to: NSPoint(x: boxR, y: gapLo))
        box.stroke()

        let ay1 = s * 0.48
        let ay2 = s * 0.34
        let ax = s * 0.66
        let bx = w - p
        let hl: CGFloat = 1.7

        let a1 = NSBezierPath()
        a1.lineWidth = lw; a1.lineCapStyle = .round; a1.lineJoinStyle = .round
        a1.move(to: NSPoint(x: ax, y: ay1))
        a1.line(to: NSPoint(x: bx, y: ay1))
        a1.move(to: NSPoint(x: bx - hl, y: ay1 + hl))
        a1.line(to: NSPoint(x: bx, y: ay1))
        a1.stroke()

        let a2 = NSBezierPath()
        a2.lineWidth = lw; a2.lineCapStyle = .round; a2.lineJoinStyle = .round
        a2.move(to: NSPoint(x: bx, y: ay2))
        a2.line(to: NSPoint(x: ax, y: ay2))
        a2.move(to: NSPoint(x: ax + hl, y: ay2 - hl))
        a2.line(to: NSPoint(x: ax, y: ay2))
        a2.stroke()

        img.unlockFocus()
        return img
    }
}

// MARK: - Asset Row

private struct AssetRow: View {
    @EnvironmentObject private var project: ProjectState
    let assetID: UUID
    @State private var hovered = false

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
            }
            if !asset.fileExists {
                Button("重新关联文件…") { relinkAsset() }
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
            Text(asset.name)
                .font(.system(size: 11))
                .foregroundColor(asset.fileExists ? Color.labelPrimary : Color.labelSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.vertical, 5)
                .help(asset.name)
        }
        .padding(4)
    }

    // MARK: Normal asset row — audio / subtitle

    private var normalAssetRow: some View {
        HStack(spacing: 10) {
            if asset.fileExists {
                Image(systemName: asset.type.icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(asset.type.color)
                    .frame(width: 20)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.orange)
                    .frame(width: 20)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(asset.name)
                    .font(.system(size: 12))
                    .foregroundColor(asset.fileExists ? Color.labelPrimary : Color.labelSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(asset.name)

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
    let icon: String
    var enabled: Bool = true
    var help: String = ""
    let action: () -> Void
    @State private var hov = false
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
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

// MARK: - Bowtie Transition Icon

private struct BowtieIcon: View {
    let size: CGFloat
    let color: Color

    var body: some View {
        Canvas { ctx, sz in
            let w = sz.width, h = sz.height
            let mx = w / 2
            let inset = w * 0.08
            var left = Path()
            left.move(to: CGPoint(x: inset, y: 0))
            left.addLine(to: CGPoint(x: mx, y: h / 2))
            left.addLine(to: CGPoint(x: inset, y: h))
            left.closeSubpath()
            var right = Path()
            right.move(to: CGPoint(x: w - inset, y: 0))
            right.addLine(to: CGPoint(x: mx, y: h / 2))
            right.addLine(to: CGPoint(x: w - inset, y: h))
            right.closeSubpath()
            ctx.fill(left, with: .color(color))
            ctx.fill(right, with: .color(color))
        }
        .frame(width: size, height: size)
    }
}
