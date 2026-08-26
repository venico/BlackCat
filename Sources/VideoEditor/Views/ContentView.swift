import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// initialAction 是不是「显示欢迎页」。写成自由函数是因为要在
/// StateObject 的初值闭包里用，那时还不能碰 self
private func isWelcome(_ action: ContentView.InitialAction?) -> Bool {
    if case .welcome = action { return true }
    return false
}

struct ContentView: View {
    /// 本视图属于哪个窗口。菜单命令按窗口路由，不是发给所有窗口
    @Environment(\.windowID) private var windowID

    /// 这个窗口起来之后要立刻做的事。
    /// **欢迎页只在 .welcome 时出现**——也就是只有 app 冷启动的第一个窗口。
    /// 新建、打开、关完所有窗口后再操作，都不该再退回启动页
    enum InitialAction {
        case welcome                                      // 冷启动
        case openProject(URL)
        case createProject(name: String, directory: URL)
        case promptNewProject                             // 开窗即弹「填项目名」表单
    }
    private let initialAction: InitialAction?

    @StateObject private var project: ProjectState

    init(initialAction: InitialAction? = nil) {
        self.initialAction = initialAction
        _project = StateObject(wrappedValue: {
            let p = ProjectState()
            // 默认不显示欢迎页，只有冷启动那次显式要。放在 StateObject 的初值里
            // 而不是 onAppear，避免首帧闪一下
            p.showWelcome = (initialAction == nil && AppDelegate.pendingOpenURLs.isEmpty)
                            || isWelcome(initialAction)
            return p
        }())
    }
    @StateObject private var exportManager = ExportManager.shared
    @State private var topHeight: CGFloat = 420
    @State private var isDraggingH = false
    @State private var sidebarVisible = true
    @State private var sidebarWidth: CGFloat = 260
    @State private var inspectorWidth: CGFloat = 280
    // Drag origin tracking (prevents cumulative translation bug)
    @State private var dragOriginSidebar: CGFloat = 260
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
                    ReverseVideoBubble(onCancel: { project.cancelReverseVideo() })
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
        // 识别方式选择。用 overlay 不用 .sheet：floatingPanelMaterial 走的是
        // .withinWindow 混合，采样的是**同窗口内下层的内容**；系统 sheet 是独立窗口，
        // 采样不到主界面，材质就成了一块不透的灰板。导出/设置都是 overlay，这里跟上
        .overlay {
            if project.showTranscribeOptions {
                // 蒙层只拦点击，不当关闭按钮 —— 选识别方式时误点一下就关掉太容易了。
                // 关闭走右上角 ✕ 或 Esc（onExitCommand）
                Color.black.opacity(0.4).ignoresSafeArea()
                TranscribeOptionsSheet()
                    .environmentObject(project)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.6), radius: 30, y: 10)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: project.showTranscribeOptions)
        .overlay {
            if project.showExportSheet {
                // 蒙层只拦点击，不当关闭按钮（同识别方式弹窗）。关闭走 ✕ 或 Esc
                Color.black.opacity(0.4).ignoresSafeArea()
                ExportSheetView().environmentObject(project)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.6), radius: 30, y: 10)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: project.showExportSheet)
        // 封面设计弹窗。跟导出那个一样挂 overlay，不用 .sheet ——
        // 系统 sheet 是独立窗口，floatingPanelMaterial 采样不到主界面
        .overlay {
            if project.showCoverDesigner {
                Color.black.opacity(0.4).ignoresSafeArea()
                CoverDesignerSheet().environmentObject(project)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.5))
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: project.showCoverDesigner)
        // 提示气泡本来画在主界面那层 ZStack 里，而弹窗是 overlay ——
        // overlay 永远盖在内容之上，弹窗一开提示就被压在底下看不见了。
        // 弹窗开着时把提示再画一层到最上面
        .overlay(alignment: .bottomTrailing) {
            if project.showCoverDesigner {
                VStack(alignment: .trailing, spacing: 8) {
                    ForEach(project.successToasts) { toast in
                        SuccessToastBubble(toast: toast,
                            onTap: { project.dismissSuccessToast(toast.id) },
                            onDismiss: { project.dismissSuccessToast(toast.id) })
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .opacity))
                    }
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.8),
                           value: project.successToasts.count)
                .padding(.trailing, 16)
                .padding(.bottom, 16)
            }
        }
        // AI 画布：全屏弹层，从下方升起，顶部留一条露出底层界面。
        // 同样挂 overlay 不用 .sheet（材质原因见 CanvasOverlay 顶部注释）
        .overlay {
            if project.showCanvas {
                CanvasOverlay(canvas: project.canvas)
                    .environmentObject(project)
            }
        }

        .canvasKeyMonitor(canvas: project.canvas, windowID: windowID, isActive: project.showCanvas)
        .onReceive(NotificationCenter.default.publisher(for: .showSettings)) { note in
            // object 带了标签下标就定位过去（字幕校对弹窗跳「AI 生成」用）
            SettingsView.pendingTab = (note.object as? Int) ?? 0
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
                }
            }
        }
        // 通知卡片要盖在欢迎页**之上**：上面那句 .opacity 会把主界面连同
        // 卡片一起藏起来，欢迎页触发的提示就看不见了
        .overlay(alignment: .bottomTrailing) {
            if project.showWelcome {
                VStack(alignment: .trailing, spacing: 8) {
                    ForEach(project.successToasts) { toast in
                        SuccessToastBubble(toast: toast,
                            onTap: { project.dismissSuccessToast(toast.id) },
                            onDismiss: { project.dismissSuccessToast(toast.id) })
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .opacity))
                    }
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.8),
                           value: project.successToasts.count)
                .padding(.trailing, 16)
                .padding(.bottom, 16)
            }
        }
        .overlay {
            if project.showSettings {
                // 蒙层只拦点击，不当关闭按钮（同识别方式弹窗）。关闭走 ✕ 或 Esc
                Color.black.opacity(0.4 * (settingsVisible ? 1 : 0))
                    .ignoresSafeArea()
                    .allowsHitTesting(settingsVisible)
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
        .sheet(isPresented: $project.showNewProjectSheet) {
            NewProjectSheet(onCancel: {
                project.showNewProjectSheet = false
                // 这个窗口是专为「新建」开出来的，用户取消了就把它收掉，
                // 别留一个既没项目也没欢迎页的空壳
                if case .promptNewProject = initialAction, project.projectFileURL == nil {
                    WindowManager.shared.close(windowID)
                }
            }, onCreate: { name, dir in
                project.showNewProjectSheet = false
                // 当前窗口还没打开任何项目就地建，否则开新窗口——
                // 不能把用户正在编辑的项目顶掉
                if project.projectFileURL == nil {
                    project.createNewProject(name: name, directory: dir)
                } else {
                    WindowManager.shared.newWindow(.createProject(name: name, directory: dir))
                }
            })
        }
        // 窗口的最小尺寸只能从这里声明：NSHostingView 会按 SwiftUI 内容的
        // 固有最小尺寸**反过来覆盖** window.minSize，直接设 window.minSize 会被冲掉
        // （实测设 584 后被改成 228）。加在 WelcomeView 上也没用——它在 overlay 里，
        // overlay 的内容不参与父视图的尺寸计算
        // 只在欢迎页时约束最小尺寸，主界面传 nil = 不加约束，维持原有行为。
        //
        // 为什么要写在这儿：NSHostingView 会按 SwiftUI 内容的固有最小尺寸
        // 反过来覆盖 window.minSize，直接设 window.minSize 会被冲掉；
        // 加在 WelcomeView 上也没用——它在 overlay 里，overlay 的内容不参与
        // 父视图的尺寸计算。
        // maxWidth/maxHeight 必须一起给 .infinity：只给 min 的话 SwiftUI 认为
        // 这个视图只想要最小尺寸，窗口会被直接压到 584 宽
        .frame(minWidth: project.showWelcome ? WelcomeWindowSizer.minWidth : nil,
               maxWidth: .infinity,
               minHeight: project.showWelcome ? WelcomeWindowSizer.minHeight : nil,
               maxHeight: .infinity)
        // 不给 showWelcome 加动画：欢迎页 → 主界面要一步到位。
        // 带动画的话窗口尺寸恢复和内容切换会错开，看着像被"撑开"，
        // 而且打开项目/新建项目两条路的观感还不一致
        // 回到 app 时重新盘一次「哪些素材文件没了」——
        // 用户很可能刚在 Finder 里挪了文件或改了名
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            project.refreshMissingAssets()
        }
        .onAppear {
            switch initialAction {
            case .openProject(let url):
                project.openProject(url: url)
            case .createProject(let name, let dir):
                project.createNewProject(name: name, directory: dir)
            case .promptNewProject:
                project.showNewProjectSheet = true
            case .welcome, nil:
                break
            }
            setupEscMonitor()
            // 关窗自动保存。**只存已经有文件路径的项目**。
            //
            // 没保存过的项目一律不存：saveProject(silent:) 在 projectFileURL == nil 时
            // 会自己拼「默认目录/项目名.bcj」，而新项目默认叫"未命名项目"——
            // 撞上同名文件就直接覆盖，别人的项目内容当场没了。
            // 实测踩过：一个空的欢迎页窗口关掉时，把桌面上同名的真实项目冲成了空轨道。
            WindowManager.shared.setWillClose({ [weak project] in
                guard let p = project, !p.isSaved, p.projectFileURL != nil else { return }
                p.saveProject(silent: true)
            }, for: windowID)
            // 按窗口注册：多个导出可以同时跑，各自的提示回到各自的窗口
            exportManager.registerHandlers(
                for: windowID,
                onSuccess: { [weak project] filename, url in
                    project?.showSuccessToast(icon: "checkmark",
                                              title: filename.truncatedFileName(maxVisualWidth: 24),
                                              subtitle: "导出完成", revealURL: url)
                },
                onCancel: { [weak project] filename in
                    project?.showSuccessToast(icon: "stop.fill", iconColor: .yellow,
                                              title: filename.truncatedFileName(maxVisualWidth: 24),
                                              subtitle: "已停止", autoCountdown: false)
                })
        }
        // 下面这些菜单命令都要先确认「是发给我这个窗口的」——
        // 不过滤的话多窗口下按一次保存会把所有打开的项目都存一遍
        .onReceive(NotificationCenter.default.publisher(for: MenuCommand.importFiles.notificationName)) { note in
            guard note.isFor(windowID), let urls = note.object as? [URL] else { return }
            project.importFiles(urls)
        }
        .onReceive(NotificationCenter.default.publisher(for: MenuCommand.newProject.notificationName)) { note in
            guard note.isFor(windowID) else { return }
            project.showNewProjectSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: MenuCommand.exportVideo.notificationName)) { note in
            guard note.isFor(windowID) else { return }
            project.showExportSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: MenuCommand.saveProject.notificationName)) { note in
            guard note.isFor(windowID) else { return }
            project.saveProject()
        }
        .onReceive(NotificationCenter.default.publisher(for: MenuCommand.openProject.notificationName)) { note in
            guard note.isFor(windowID) else { return }
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [.init(filenameExtension: "bcj") ?? .json]
            panel.prompt = "打开"
            if panel.runModal() == .OK, let url = panel.url {
                // 一律开新窗口，不动当前窗口里正在编辑的项目。
                // 已经开着的项目则聚焦过去，不重复开——两个窗口编辑同一份文件，
                // 后保存的那个会覆盖另一个
                if let (_, existing) = WindowManager.shared.existingWindow(for: url) {
                    WindowManager.shared.focus(existing)
                } else {
                    WindowManager.shared.newWindow(.openProject(url))
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: MenuCommand.openProjectFile.notificationName)) { note in
            guard note.isFor(windowID), let url = note.object as? URL else { return }
            project.openProject(url: url)
        }
        // 退出欢迎页时**立刻**把窗口尺寸恢复回去。
        // 不能等 WelcomeView 的 onDisappear：欢迎页有 0.25s 的消失动画，
        // onDisappear 在动画结束后才触发，那 0.25s 里主界面已经显示出来了、
        // 却还挤在 900×560 的小窗口里，然后窗口才"撑开"——看着就是卡了一下
        .onChange(of: project.showWelcome) { _, isShowing in
            if !isShowing { WelcomeWindowSizer.restore(windowID) }
        }
        // 项目路径回报给 WindowManager，「同一个项目不重复开窗」靠它判断
        .onChange(of: project.projectFileURL) { _, newValue in
            WindowManager.shared.setOpenedURL(newValue, for: windowID)
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
            let count = project.currentLibraryAssetType.map { t in
                project.mediaAssets.filter { $0.type == t }.count
            } ?? 0
            // 素材库 v5.1.0 起是全 app 一份，清空影响的不止当前项目 —— 这句必须说清楚
            Text("将从素材库移除 \(count) 个\(label)素材。素材库是所有项目共用的，"
                 + "别的项目里引用这些素材的片段会变成「文件丢失」。\n"
                 + "当前项目时间轴上引用它们的片段会一并删除，此操作可撤销。")
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
            // 文案在函数里拼好再进来。在 ViewBuilder 里写这段条件逻辑会让
            // 类型检查超时（unable to type-check this expression）
            Text(deleteAssetMessage(project.pendingDeleteAssetID))
        }
        .sheet(isPresented: $project.showWhisperModelPicker) {
            WhisperModelPickerSheet()
                .environmentObject(project)
        }
        .onAppear {
            // 兜底：正常路径下 createWindow() 已经消费掉了，这里只捞漏网的
            if !AppDelegate.pendingOpenURLs.isEmpty {
                let url = AppDelegate.pendingOpenURLs.removeFirst()
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

    /// 移除素材的确认文案。
    ///
    /// 素材库全 app 一份，删的是全局那条，别的项目也会受影响；
    /// 时间轴片段和画布卡片都会跟着删，所以**引用了什么要分别说清楚**。
    /// 本地文件一律不删
    private func deleteAssetMessage(_ id: UUID?) -> String {
        guard let id else { return "确定要移除该素材吗？" }
        let asset = project.mediaAssets.first(where: { $0.id == id })
        let name = asset?.name ?? ""
        let clips = project.clipCountForAsset(id)
        // 所有窗口的画布一起数 —— 删素材是全局的，只报自己这个窗口会少报
        let cards = CanvasState.totalNodeCount(usingAsset: id, path: asset?.url.path)
        var refs: [String] = []
        if clips > 0 { refs.append("时间轴上有 \(clips) 个片段") }
        if cards > 0 { refs.append("画布上有 \(cards) 张卡片") }
        if refs.isEmpty {
            return "「\(name)」将从素材库移除。素材库是所有项目共用的，"
                + "别的项目里引用它的片段会变成「文件丢失」。\n本地文件不会删除。"
        }
        return "「\(name)」将从素材库移除（所有项目共用一个素材库）。\n"
            + refs.joined(separator: "，") + "引用它，会一并删除，可撤销；\n"
            + "别的项目里的引用会变成「文件丢失」。本地文件不会删除。"
    }

    private func setupEscMonitor() {
        // 句柄交给 WindowManager 保管，跟窗口一起销毁（见 setEscMonitor 的说明）
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }
            // local monitor 是**进程级**的：每开一个窗口就多一个 monitor，各自捕获
            // 自己的 project。不按当前窗口过滤的话，按一次 esc 会把所有窗口的
            // 面板/欢迎页一起关掉（跟菜单命令当初那个「保存把所有项目都存一遍」同类）。
            // sheet 弹出时 key window 是 sheet 自己，所以 attachedSheet 也算本窗口
            let w = WindowManager.shared.window(for: windowID)
            guard w?.isKeyWindow == true || w?.attachedSheet?.isKeyWindow == true else {
                return event
            }
            // 新建项目表单开着时把 esc 让给它自己的 onExitCommand：那条路径除了关表单
            // 还要收掉「专为新建开出来的空窗口」，这里抢着处理会跳过那段清理。
            // 必须排在 showWelcome 前面——从欢迎页点新建时两个状态同时为真，
            // 顺序反了就成了「esc 关掉欢迎页、露出空主界面」，而表单还留在上面
            if project.showNewProjectSheet { return event }
            // 画布是最上层，esc 先关它。不光靠 CanvasOverlay 的 onExitCommand ——
            // 那个依赖 SwiftUI 焦点落在画布上，焦点跑到别处就不灵了
            if project.showCanvas { project.showCanvas = false; return nil }
            if project.showExportSheet { project.showExportSheet = false; return nil }
            if project.showSettings { closeSettings(); return nil }
            // 欢迎页的 esc 一律不接管：交给 SwiftUI，让 WelcomeView 的 onExitCommand
            // 去取消重命名。欢迎页本身不响应 esc（要关窗用左上角红灯或 ⌘W）——
            // 这里做过"esc 关窗"，但窗口焦点/事件分发上的坑绕不干净，改成手动关
            if project.showWelcome { return event }
            if project.showClearLibraryConfirm { project.showClearLibraryConfirm = false; return nil }
            if project.showAssetDeleteConfirm { project.showAssetDeleteConfirm = false; project.pendingDeleteAssetID = nil; return nil }
            return event
        }
        WindowManager.shared.setEscMonitor(monitor, for: windowID)
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
    /// 成功 / 失败 / 警告 / 停止 四种状态换成自绘 SVG，并锁定各自的标准色。
    /// 调用处传的仍是 SF Symbol 名（散在几十处，不逐个改），在这里统一映射；
    /// 表里没有的图标（waveform / sparkles / photo 之类的功能图标）照旧走 SF Symbol
    static let statusSVG: [String: (key: String, color: Color)] = [
        "checkmark":                     ("toastSuccess", Color(hex: "#30D158")),
        "checkmark.circle.fill":         ("toastSuccess", Color(hex: "#30D158")),
        "xmark.circle":                  ("toastFail",    Color(hex: "#FF4245")),
        "xmark.circle.fill":             ("toastFail",    Color(hex: "#FF4245")),
        "exclamationmark.triangle":      ("toastWarn",    Color(hex: "#FF9230")),
        "exclamationmark.triangle.fill": ("toastWarn",    Color(hex: "#FF9230")),
        "exclamationmark.circle.fill":   ("toastWarn",    Color(hex: "#FF9230")),
        "stop.fill":                     ("toastStop",    Color(hex: "#FF9230")),
        // AI 生成完的插入提示：用素材库侧边栏那套图标，颜色跟其他通知一样走主题黄
        "video":                         ("video",        Color.accent),
        "image":                         ("image",        Color.accent),
        "audio":                         ("audio",        Color.accent),
    ]

    let toast: ProjectState.SuccessToastItem
    let onTap: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill((SuccessToastBubble.statusSVG[toast.icon]?.color ?? toast.iconColor).opacity(0.2))
                        .frame(width: 28, height: 28)
                    if let sv = SuccessToastBubble.statusSVG[toast.icon] {
                        Image(nsImage: SidebarSVGIcon.load(sv.key, size: 16))
                            .renderingMode(.template)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 16, height: 16)
                            .foregroundColor(sv.color)
                    } else {
                        Image(systemName: toast.icon)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(toast.iconColor)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(toast.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color.labelPrimary)
                        .lineLimit(1)
                    // 没有副标题就整行不渲染 —— `Text("")` 照样占一行高度，
                    // 只有标题的卡片会因此显得标题贴在上半部分
                    if !toast.subtitle.isEmpty || toast.revealURL != nil {
                        Text(toast.subtitle + (toast.revealURL != nil ? " · 点击查看" : ""))
                            .font(.system(size: 10))
                            // 副标题跟状态色走（成功 #30D158 / 失败 #FF4245 / 警告·停止 #FF9230）；
                            // 可点击的那种仍用主题色，提示"这行能点"
                            .foregroundColor(toast.revealURL != nil
                                             ? Color.accent
                                             : (SuccessToastBubble.statusSVG[toast.icon]?.color ?? toast.iconColor))
                            .lineLimit(1)
                    }
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
    /// 卡片出现即开始计时，用于估算剩余时间
    @State private var startedAt = Date()

    private var progressValue: Double {
        project.translationTotal > 0
            ? Double(project.translationDone) / Double(project.translationTotal) : 0
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.accent.opacity(0.2))
                    .frame(width: 28, height: 28)
                Image(nsImage: TimelineSVGIcon.load("translate", size: 14))
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
                    .foregroundColor(Color.accent)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("翻译")
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
