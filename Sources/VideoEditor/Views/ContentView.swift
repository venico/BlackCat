import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var project: ProjectState = {
        let p = ProjectState()
        if AppDelegate.pendingOpenURL != nil {
            p.showWelcome = false
        }
        return p
    }()
    @StateObject private var exportManager = ExportManager.shared
    @State private var topHeight: CGFloat = 420
    @State private var isDraggingH = false
    @State private var sidebarVisible = true
    @State private var sidebarWidth: CGFloat = 220
    @State private var inspectorWidth: CGFloat = 280
    // Drag origin tracking (prevents cumulative translation bug)
    @State private var dragOriginSidebar: CGFloat = 220
    @State private var isDraggingSidebar = false
    @State private var dragOriginInspector: CGFloat = 280
    @State private var isDraggingInspector = false
    @State private var dragOriginTop: CGFloat = 420
    @State private var settingsVisible = false

    // Height of the shared "title-bar" row that contains traffic lights + toggle
    private let toolbarH: CGFloat = 28

    var body: some View {
        HStack(spacing: 0) {

            // ── Sidebar ────────────────────────────────────────────
            if sidebarVisible {
                VStack(spacing: 0) {
                    // 标题栏行：自定义交通灯（SwiftUI）+ toggle 按钮
                    HStack(spacing: 0) {
                        TrafficLightsView()
                            .padding(.leading, 12)
                        Spacer()
                        toggleButton
                            .padding(.trailing, 12)
                    }
                    .frame(height: toolbarH)

                    // Content
                    MediaLibraryView()
                }
                .frame(width: sidebarWidth)
                .frame(maxHeight: .infinity)
                .panelSurface(.sidebar)
                .softPanelShadow()
                .simultaneousGesture(TapGesture().onEnded {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                })
                .padding(.top, 8)
                .padding(.leading, 8)
                .padding(.bottom, 8)
                .transition(.move(edge: .leading).combined(with: .opacity))
                // Sidebar right-edge drag handle (overlaps the 8px gap)
                .overlay(alignment: .trailing) {
                    Color.clear
                        .frame(width: 8)
                        .contentShape(Rectangle())
                        .offset(x: 8)
                        .zIndex(100)
                        .onContinuousHover { phase in
                            if case .active = phase { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
                        }
                        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { v in
                                if !isDraggingSidebar { dragOriginSidebar = sidebarWidth }
                                isDraggingSidebar = true
                                sidebarWidth = min(max(dragOriginSidebar + v.translation.width, 160), 400)
                            }
                            .onEnded { _ in
                                isDraggingSidebar = false
                                NSCursor.arrow.set()
                            }
                        )
                }
            }

            // ── Main content ───────────────────────────────────────
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        // Player + Inspector cards
                        HStack(spacing: 8) {
                            PlayerView()
                                .frame(maxWidth: .infinity)
                                .background(Color.previewBg)
                                // 预览区容器也要材质：容器透了却没铺材质的话，
                                // 它和中间那块纯黑的画布就都是黑的，安全区边界看不出来
                                .panelSurfaceClear(.content)
                                .simultaneousGesture(TapGesture().onEnded {
                                    NSApp.keyWindow?.makeFirstResponder(nil)
                                })
                            InspectorView()
                                .frame(width: inspectorWidth)
                                .background(Color.panelBg)
                                .panelSurfaceClear(.content)
                                // Inspector left-edge drag handle (overlaps the 8px gap)
                                .overlay(alignment: .leading) {
                                    Color.clear
                                        .frame(width: 8)
                                        .contentShape(Rectangle())
                                        .offset(x: -8)
                                        .zIndex(100)
                                        .onContinuousHover { phase in
                            if case .active = phase { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
                        }
                                        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                            .onChanged { v in
                                                if !isDraggingInspector { dragOriginInspector = inspectorWidth }
                                                isDraggingInspector = true
                                                inspectorWidth = min(max(dragOriginInspector - v.translation.width, 200), 450)
                                            }
                                            .onEnded { _ in
                                                isDraggingInspector = false
                                                NSCursor.arrow.set()
                                            }
                                        )
                                }
                        }
                        .frame(height: topHeight)
                        .padding(.top, 8)
                        .padding(.horizontal, 8)

                        // Drag handle — the 8px gap between top and bottom cards
                        Color.clear
                            .frame(height: 8)
                            .contentShape(Rectangle())
                            .zIndex(100)
                            .onContinuousHover { phase in if case .active = phase { NSCursor.resizeUpDown.set() } else { NSCursor.arrow.set() } }
                            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                .onChanged { v in
                                    if !isDraggingH { dragOriginTop = topHeight }
                                    isDraggingH = true
                                    let avail = geo.size.height - 24
                                    topHeight = (dragOriginTop + v.translation.height)
                                        .clamped(to: 180...(avail - 130))
                                }
                                .onEnded { _ in isDraggingH = false; NSCursor.arrow.set() }
                            )

                        // Timeline card
                        VStack(spacing: 0) {
                            TimelineToolbar()
                                .fixedSize(horizontal: false, vertical: true)
                            TimelineView()
                                .frame(maxHeight: .infinity)
                                .clipped()
                            CompoundBreadcrumb()
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxHeight: .infinity)
                        .background(Color.timelineBg)
                        .panelSurfaceClear(.content)
                        .simultaneousGesture(TapGesture().onEnded {
                            NSApp.keyWindow?.makeFirstResponder(nil)
                        })
                        .padding(.bottom, 8)
                        .padding(.horizontal, 8)
                    }
                    .onAppear {
                        topHeight = geo.size.height * 0.60
                    }

                    // 侧边栏收起时：交通灯 + toggle 在左上角
                    if !sidebarVisible {
                        HStack(spacing: 10) {
                            TrafficLightsView()
                            toggleButton
                        }
                        .padding(.leading, 12)
                        .padding(.top, 8)
                    }
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            VStack(alignment: .trailing, spacing: 8) {
                if !project.activeTasks.isEmpty {
                    TranscodeOverlay()
                        .environmentObject(project)
                }
                if project.isTranscribing || { if case .failed = project.transcribeState { return true } else { return false } }() {
                    TranscribeOverlay()
                        .environmentObject(project)
                }
                if project.isSeparatingAudio {
                    SeparateOverlay()
                        .environmentObject(project)
                }
                UpdateBubble()
                if project.isRemovingBackground {
                    RemoveBackgroundOverlay()
                        .environmentObject(project)
                }
                if project.isEnhancingClarity {
                    ClarityEnhanceOverlay()
                        .environmentObject(project)
                }
                if project.isGeneratingSpeech {
                    SpeechOverlay()
                        .environmentObject(project)
                }
                if project.isReversingVideo {
                    ReverseVideoBubble()
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .opacity))
                }
                if project.isDetectingScenes {
                    SceneDetectBubble(progress: project.sceneDetectProgress,
                                      onCancel: { project.cancelSceneDetect() })
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .opacity))
                }
                if project.isLLMAnalyzing {
                    LLMAnalyzeBubble(progress: project.llmAnalyzeProgress,
                                     onCancel: { project.cancelLLMAnalyze() })
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .opacity))
                }
                if project.translationTotal > 0 {
                    TranslationBubble()
                        .environmentObject(project)
                }
                if !exportManager.jobs.isEmpty {
                    ExportProgressOverlay(manager: exportManager)
                }
                ForEach(project.successToasts) { toast in
                    SuccessToastBubble(toast: toast,
                        onTap: {
                            if let url = toast.revealURL {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }
                            project.dismissSuccessToast(toast.id)
                        },
                        onDismiss: { project.dismissSuccessToast(toast.id) })
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .opacity))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: project.successToasts.count)
            .padding(.trailing, 16)
            .padding(.bottom, 16)
        }
        .environmentObject(project)
        .environmentObject(project.clock)
        .ignoresSafeArea()
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: sidebarVisible)
        .overlay {
            if project.showExportSheet {
                Color.black.opacity(0.4).ignoresSafeArea()
                    .onTapGesture { project.showExportSheet = false }
                ExportSheetView().environmentObject(project)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.6), radius: 30, y: 10)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: project.showExportSheet)
        .onReceive(NotificationCenter.default.publisher(for: .showSettings)) { _ in
            project.showSettings = true
        }
        // 窗口已改成透明（底色交给系统材质，跟着墙纸走），主界面自己得铺一层
        // 材质，否则会直接透到桌面
        .windowMaterial()
        // 欢迎页在场时把主界面整个盖住（不是半透明蒙层）——用户没选文件之前
        // 不该看到后面的素材栏和时间轴
        .opacity(project.showWelcome ? 0 : 1)
        .overlay {
            if project.showWelcome {
                ZStack {
                    Color(red: 0.10, green: 0.10, blue: 0.11).ignoresSafeArea()
                    WelcomeView()
                        .environmentObject(project)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }
        }
        .overlay {
            if project.showSettings {
                Color.black.opacity(0.4 * (settingsVisible ? 1 : 0))
                    .ignoresSafeArea()
                    .allowsHitTesting(settingsVisible)
                    .onTapGesture { closeSettings() }
                SettingsView(dismiss: { closeSettings() })
                    .environmentObject(project)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.6), radius: 30, y: 10)
                    .opacity(settingsVisible ? 1 : 0)
                    .scaleEffect(settingsVisible ? 1 : 0.95)
                    .onAppear {
                        withAnimation(.easeOut(duration: 0.2)) { settingsVisible = true }
                    }
            }
        }
        .animation(.easeOut(duration: 0.25), value: project.showWelcome)
        .onAppear {
            setupEscMonitor()
            exportManager.onSuccess = { [weak project] filename, url in
                project?.showSuccessToast(icon: "checkmark", title: filename.truncatedFileName(maxVisualWidth: 24), subtitle: "导出完成", revealURL: url)
            }
            exportManager.onCancel = { [weak project] filename in
                project?.showSuccessToast(icon: "stop.fill", iconColor: .yellow, title: filename.truncatedFileName(maxVisualWidth: 24), subtitle: "已停止", autoCountdown: false)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuImportFiles)) { note in
            if let urls = note.object as? [URL] {
                urls.forEach { project.importFile($0) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuExportVideo)) { _ in
            project.showExportSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuSaveProject)) { _ in
            project.saveProject()
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuNewProject)) { _ in
            project.showWelcome = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuOpenProject)) { _ in
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [.init(filenameExtension: "bcj") ?? .json]
            panel.prompt = "打开"
            if panel.runModal() == .OK, let url = panel.url {
                project.openProject(url: url)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuOpenProjectFile)) { note in
            if let url = note.object as? URL {
                project.openProject(url: url)
            }
        }
        .alert("清空\(project.currentLibraryAssetType?.label ?? "")素材", isPresented: $project.showClearLibraryConfirm) {
            Button("清空", role: .destructive) {
                if let type = project.currentLibraryAssetType {
                    project.clearMediaLibrary(type: type)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            let label = project.currentLibraryAssetType?.label ?? ""
            Text("将移除全部\(label)素材，并同时删除时间轴上引用它们的片段，此操作可撤销。")
        }
        .alert("确认移除素材", isPresented: $project.showAssetDeleteConfirm) {
            Button("移除", role: .destructive) {
                if let id = project.pendingDeleteAssetID {
                    project.removeAssetAndClips(assetID: id)
                    project.pendingDeleteAssetID = nil
                }
            }
            Button("取消", role: .cancel) { project.pendingDeleteAssetID = nil }
        } message: {
            if let id = project.pendingDeleteAssetID {
                let count = project.clipCountForAsset(id)
                let name = project.mediaAssets.first(where: { $0.id == id })?.name ?? ""
                if count > 0 {
                    Text("「\(name)」在时间轴上有 \(count) 个片段引用，移除素材将同时删除这些片段。")
                } else {
                    Text("确定要移除「\(name)」吗？")
                }
            } else {
                Text("确定要移除该素材吗？")
            }
        }
        .sheet(isPresented: $project.showWhisperModelPicker) {
            WhisperModelPickerSheet()
                .environmentObject(project)
        }
        .onAppear {
            if let url = AppDelegate.pendingOpenURL {
                AppDelegate.pendingOpenURL = nil
                project.showWelcome = false
                project.openProject(url: url)
            }
        }
    }

    private func closeSettings() {
        withAnimation(.easeOut(duration: 0.2)) { settingsVisible = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            project.showSettings = false
        }
    }

    private func setupEscMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }
            if project.showExportSheet { project.showExportSheet = false; return nil }
            if project.showSettings { closeSettings(); return nil }
            if project.showWelcome { project.showWelcome = false; return nil }
            if project.showClearLibraryConfirm { project.showClearLibraryConfirm = false; return nil }
            if project.showAssetDeleteConfirm { project.showAssetDeleteConfirm = false; project.pendingDeleteAssetID = nil; return nil }
            return event
        }
    }

    private var toggleButton: some View {
        Button { sidebarVisible.toggle() } label: {
            Image(nsImage: TimelineSVGIcon.load("sidebarToggle"))
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 15, height: 15)
                .foregroundColor(Color.labelSecondary)
                .frame(width: 28, height: 22)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Design Tokens
extension Color {
    /// 面板底色一律透明，底色完全交给系统材质（见 VisualEffectBackground.swift）。
    /// 之前叠了一层 black.opacity(0.28) 压暗，结果把材质对墙纸的采样压死了——
    /// 界面还是黑的，跟系统那种能透出墙纸色调的观感差很远。系统 app 就是不叠色
    static let panelBg        = Color.clear
    static let previewBg      = Color.clear
    static let timelineBg     = Color.clear
    /// 分隔线跟系统一致，用动态的 separatorColor 而不是自己调透明度
    static let divider        = Color.systemSeparator
    static let labelPrimary   = Color.white.opacity(0.88)
    static let labelSecondary = Color.white.opacity(0.45)
    static let accent         = Color(hex: "#F5B942")
    static let hoverBg        = Color.white.opacity(0.07)
}

extension Notification.Name {
    static let showSettings = Notification.Name("showSettings")
}

struct FocusTextField: View {
    @Binding var text: String
    var placeholder: String
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text,
                  prompt: Text(placeholder).foregroundColor(Color.labelSecondary.opacity(0.5)))
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundColor(Color.labelPrimary)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Color.white.opacity(0.06))
            .cornerRadius(7)
            .overlay(RoundedRectangle(cornerRadius: 7)
                .stroke(focused ? Color.accent : Color.clear, lineWidth: 1))
            .focused($focused)
    }
}

extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self { min(max(self, r.lowerBound), r.upperBound) }
}

// MARK: - Success Toast Bubble (右下角，带倒计时)

private struct SuccessToastBubble: View {
    let toast: ProjectState.SuccessToastItem
    let onTap: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(toast.iconColor.opacity(0.2))
                        .frame(width: 28, height: 28)
                    Image(systemName: toast.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(toast.iconColor)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(toast.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color.labelPrimary)
                        .lineLimit(1)
                    Text(toast.subtitle + (toast.revealURL != nil ? " · 点击查看" : ""))
                        .font(.system(size: 10))
                        .foregroundColor(toast.revealURL != nil ? Color.accent : toast.iconColor)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if toast.autoCountdown {
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.1), lineWidth: 2)
                            .frame(width: 22, height: 22)
                        Circle()
                            .trim(from: 0, to: CGFloat(toast.countdown) / 5.0)
                            .stroke(Color.labelSecondary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .frame(width: 22, height: 22)
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 1), value: toast.countdown)
                        Text("\(toast.countdown)")
                            .font(.system(size: 9, weight: .bold).monospacedDigit())
                            .foregroundColor(Color.labelSecondary)
                    }
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
        .buttonStyle(.plain)
    }
}

struct TranslationBubble: View {
    @EnvironmentObject private var project: ProjectState
    @State private var xHovering = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.accent.opacity(0.2))
                    .frame(width: 28, height: 28)
                Image(systemName: "translate")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color.accent)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("翻译")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color.labelPrimary)
                    .lineLimit(1)

                GeometryReader { geo in
                    HStack(spacing: 6) {
                        ProgressView(value: project.translationProgress)
                            .progressViewStyle(.linear)
                            .tint(Color.accent)
                        Text("\(Int(project.translationProgress * 100))%")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundColor(Color.labelSecondary)
                            .fixedSize()
                    }
                    .frame(width: geo.size.width)
                }
                .frame(height: 14)
            }

            Button { project.cancelTranslation() } label: {
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
