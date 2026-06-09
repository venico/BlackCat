import SwiftUI
import UniformTypeIdentifiers

struct MediaLibraryView: View {
    @EnvironmentObject private var project: ProjectState
    @State private var isDragOver = false

    private var isTransitionTab: Bool { project.mediaLibraryTab == "transition" }

    private var selectedAssetType: AssetType {
        switch project.mediaLibraryTab {
        case "audio": return .audio
        case "image": return .image
        case "subtitle": return .subtitle
        default: return .video
        }
    }

    private var filteredAssets: [MediaAsset] {
        project.mediaAssets.filter { $0.type == selectedAssetType }
    }

    private func countFor(_ type: AssetType) -> Int {
        project.mediaAssets.filter { $0.type == type }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            // Section header
            HStack {
                Text("素材库")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color.labelSecondary)
                    .textCase(.uppercase)
                Spacer()
                Button { project.showClearLibraryConfirm = true } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(project.mediaAssets.isEmpty ? Color.labelSecondary.opacity(0.3) : Color.labelSecondary)
                }
                .buttonStyle(.plain)
                .disabled(project.mediaAssets.isEmpty)
                .help("清空素材库")
                Button { project.refreshMediaLibrary() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color.labelSecondary)
                }
                .buttonStyle(.plain)
                .help("刷新素材库")
            }
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .padding(.top, 8)
            .padding(.bottom, 8)

            // Tab bar — Finder-style segmented icons
            HStack(spacing: 0) {
                tabBtn("video", icon: "film")
                tabBtn("audio", icon: "music.note")
                tabBtn("image", icon: "photo")
                tabBtn("subtitle", icon: "captions.bubble")
                tabBtn("transition", icon: "arrow.left.arrow.right")
            }
            .background(Color.white.opacity(0.06))
            .clipShape(Capsule())
            .padding(.horizontal, 8)
            .padding(.bottom, 6)

            // Asset list + drag-drop target
            ZStack {
                if isTransitionTab {
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

            // 转码进度已移至右下角全局浮层

            // Bottom actions
            VStack(spacing: 8) {
                ImportButton()
                ExportButton()
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private func tabBtn(_ tab: String, icon: String) -> some View {
        let isActive = project.mediaLibraryTab == tab
        Button { project.mediaLibraryTab = tab } label: {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isActive ? .white : Color.labelSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .background(isActive ? Color.white.opacity(0.15) : Color.clear)
                .clipShape(Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 28, weight: .ultraLight))
                .foregroundColor(Color.labelSecondary.opacity(0.30))
            Text("拖入文件或点击导入")
                .font(.system(size: 11))
                .foregroundColor(Color.labelSecondary.opacity(0.45))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    .frame(minHeight: 32, alignment: .topLeading)
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

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if project.transcribeState != .idle {
                TranscribeBubble(state: project.transcribeState) {
                    project.transcribeState = .idle
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: project.transcribeState)
    }
}

private struct TranscribeBubble: View {
    let state: ProjectState.TranscribeState
    let onDismiss: () -> Void
    @State private var hovering = false

    private var isBusy: Bool {
        switch state { case .running, .downloading: return true; default: return false }
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(iconBg).frame(width: 28, height: 28)
                if isBusy {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                } else {
                    Image(systemName: iconName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(iconFg)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("语音识别")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color.labelPrimary)
                    .lineLimit(1)
                Text(statusText)
                    .font(.system(size: 10))
                    .foregroundColor(statusColor)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !isBusy {
                Button(action: onDismiss) {
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

    private var iconName: String {
        switch state {
        case .done:   return "checkmark"
        case .failed: return "exclamationmark.triangle"
        default:      return "waveform"
        }
    }
    private var iconBg: Color {
        switch state {
        case .running, .downloading: return Color.accent.opacity(0.2)
        case .done:    return Color.green.opacity(0.2)
        case .failed:  return Color.red.opacity(0.2)
        case .idle:    return Color.clear
        }
    }
    private var iconFg: Color {
        switch state {
        case .done:   return .green
        case .failed: return .red.opacity(0.8)
        default:      return Color.accent
        }
    }
    private var statusText: String {
        switch state {
        case .downloading(let p): return "下载识别模型 \(Int(p * 100))%（约 466MB，仅首次）"
        case .running:       return "正在识别…"
        case .done(let n):   return "完成，生成 \(n) 条字幕"
        case .failed(let m): return m
        case .idle:          return ""
        }
    }
    private var statusColor: Color {
        switch state {
        case .done:   return .green
        case .failed: return .red.opacity(0.8)
        default:      return Color.labelSecondary
        }
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

// MARK: - Transition Panel

private struct TransitionPanel: View {
    @EnvironmentObject private var project: ProjectState

    private var selectedClipTransition: Transition? {
        guard let id = project.selectedTransitionClipID else { return nil }
        return project.videoTracks.flatMap(\.clips).first(where: { $0.id == id })?.inTransition
    }

    var body: some View {
        VStack(spacing: 0) {
            if project.selectedTransitionClipID == nil {
                // 未选中转场图标
                VStack(spacing: 10) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 28, weight: .ultraLight))
                        .foregroundColor(Color.labelSecondary.opacity(0.30))
                    Text("点击时间轴中片段间的\n菱形图标选择转场")
                        .font(.system(size: 11))
                        .foregroundColor(Color.labelSecondary.opacity(0.45))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 10) {
                        // 效果列表
                        Text("选择效果")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Color.labelSecondary)
                            .padding(.horizontal, 10)
                            .padding(.top, 4)

                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6),
                                            GridItem(.flexible(), spacing: 6)], spacing: 6) {
                            ForEach(TransitionType.allCases, id: \.self) { type in
                                TransitionPreviewCard(
                                    type: type,
                                    isSelected: selectedClipTransition?.type == type,
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
    }
}

// MARK: - Transition Preview Card

private struct TransitionPreviewCard: View {
    let type: TransitionType
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var phase: Double = 0
    @State private var hoverTask: Task<Void, Never>? = nil

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
            .background(isSelected ? Color.accent.opacity(0.15) : Color.clear)
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accent : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
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
