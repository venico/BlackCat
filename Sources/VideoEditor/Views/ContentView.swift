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
    /// AI 创作那一列是否显示（左上角 / 右上角的收起按钮）
    @State private var sidebarVisible = true
    /// AI 创作那一列的宽度
    @State private var sidebarWidth: CGFloat = 300
    /// 素材库 / 效果那一栏的宽度（含左边 44 的竖图标栏）
    @State private var libraryWidth: CGFloat = 320
    /// 素材库 / 效果那一栏是否显示
    @State private var libraryVisible = true
    /// 窗口内容区的实际宽度。素材栏 / AI 栏 / 属性区按它收窄，保证预览不被挤没
    @State private var rootWidth: CGFloat = 0
    @State private var dragOriginLibrary: CGFloat = 320
    @State private var isDraggingLibrary = false
    @ObservedObject private var settings = AppSettings.shared
    @State private var inspectorWidth: CGFloat = InspectorLayout.defaultWidth
    // Drag origin tracking (prevents cumulative translation bug)
    @State private var dragOriginSidebar: CGFloat = 320
    @State private var isDraggingSidebar = false
    @State private var dragOriginInspector: CGFloat = 280
    @State private var isDraggingInspector = false
    @State private var dragOriginTop: CGFloat = 420
    @State private var settingsVisible = false

    // Height of the shared "title-bar" row that contains traffic lights + toggle
    /// 侧边栏顶部标题栏行的高度。34 = 交通灯 12pt + 上下各 11pt ——
    /// 那一行是居中排的，改这个数就等于改交通灯距上边缘的距离
    private let toolbarH: CGFloat = 34

    var body: some View {
        HStack(spacing: 0) {
            // ── AI 创作（左）：整列到底。窗口 → 布局 可以换到右边 ──
            if sidebarVisible && !settings.aiPanelOnRight { aiColumn(onRight: false, width: fitted.ai) }

            // ── 主区：上排 素材库/效果 · 预览 · 属性，下排时间轴横跨 ──
            GeometryReader { geo in
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            // 素材库 / 效果放在预览左边：边跟 AI 聊天边看素材
                            if libraryVisible { libraryColumn }
                            PlayerView()
                                .frame(maxWidth: .infinity)
                                .simultaneousGesture(TapGesture().onEnded {
                                    NSApp.keyWindow?.makeFirstResponder(nil)
                                })
                            // 预览区和属性区之间的分割线。**上下顶头** ——
                            InspectorView()
                                .frame(width: fitted.inspector)
                                // 分割线**画在属性区左边缘上**，不占 HStack 的一格 ——
                                // 占一格的话属性区左边就比右边多出这 1pt，
                                // 里面所有标题和控件都跟着偏 1pt
                                .overlay(alignment: .leading) {
                                    Rectangle()
                                        .fill(Color.white.opacity(0.10))
                                        .frame(width: 1)
                                        // 负边距把上半区自己的 8pt 顶部留白、以及下面那条
                                        // 8pt 拖动缝都补上，线才是真的上下顶头
                                        .padding(.top, -6)
                                        .padding(.bottom, -4)
                                }
                                // 拖宽度的热区**骑在线上**：左右各 4pt
                                .overlay(alignment: .leading) {
                                    Color.clear
                                        .frame(width: 8)
                                        .contentShape(Rectangle())
                                        .offset(x: -4)
                                        .zIndex(100)
                                        .onContinuousHover { phase in
                            if case .active = phase { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
                        }
                                        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                            .onChanged { v in
                                                if !isDraggingInspector { dragOriginInspector = fitted.inspector }
                                                isDraggingInspector = true
                                                inspectorWidth = min(max(dragOriginInspector - v.translation.width,
                                                                         InspectorLayout.minWidth),
                                                                     InspectorLayout.maxWidth)
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

                        // Drag handle — the 8px gap between top and bottom cards。
                        // 缝里画一条分割线：三块都不铺底色了，全靠线划界
                        Color.clear
                            .frame(height: 8)
                            .overlay(Rectangle().fill(Color.white.opacity(0.10)).frame(height: 1))
                            .contentShape(Rectangle())   // 线在正中，热区上下各 4pt
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
                            TimelineTabBar()
                                .fixedSize(horizontal: false, vertical: true)
                            TimelineToolbar()
                                .fixedSize(horizontal: false, vertical: true)
                            // 时间线全收起来时，轨道区也要空掉。
                            // 关掉最后一条时 activeTab 还指着那条已关闭的，
                            // 不判这一下的话标签栏空了、轨道却照样铺着内容
                            if project.tabs.contains(where: \.isTabOpen) {
                                TimelineView()
                                    .frame(maxHeight: .infinity)
                                    .clipped()
                            } else {
                                ClosedTimelinePlaceholder()
                                    .frame(maxHeight: .infinity)
                            }
                            CompoundBreadcrumb()
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxHeight: .infinity)
                        .simultaneousGesture(TapGesture().onEnded {
                            NSApp.keyWindow?.makeFirstResponder(nil)
                        })
                    }
                    .onAppear {
                        topHeight = geo.size.height * 0.60
                    }
                    // 素材栏和左边的 AI 栏都收起了：交通灯和两个开关浮在主区左上角
                    .overlay(alignment: .topLeading) {
                        if !libraryVisible && !aiOnLeftShown {
                            HStack(spacing: 10) {
                                TrafficLightsView()
                                panelToggles
                            }
                            .padding(.leading, 19)
                            .frame(height: toolbarH)
                            .padding(.top, 8)
                        }
                    }
            }

            // ── AI 创作（右） ──
            if sidebarVisible && settings.aiPanelOnRight { aiColumn(onRight: true, width: fitted.ai) }
        }
        // 量窗口宽度：几栏固定宽加起来超过窗口时按它收窄（不然整排撑出窗口、居中摆，
        // 左边空一块、右边那栏压到属性区和时间轴上）
        .background(GeometryReader { g in
            Color.clear
                .onAppear { rootWidth = g.size.width }
                .onChange(of: g.size.width) { _, w in rootWidth = w }
        })
        // AI 那一列收起来时撤掉它的拖入登记（不然拖到素材区的文件可能被它收走）
        .onChange(of: sidebarVisible) { _, visible in
            if !visible { FileDropRouter.unregister(windowID, kind: .aiChat) }
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
        // 画布是全屏盖上去的，主界面那层通知卡片被它整个压住了 ——
        // 跟封面设计器、欢迎页一样，在画布之上再画一层
        .overlay(alignment: .bottomTrailing) {
            if project.showCanvas {
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
        // 图片/视频全屏查看。**必须排在画布后面** ——
        // 画布里那张聊天卡片点出来的预览也得盖在画布上面
        .overlay {
            if let item = project.mediaPreview {
                MediaPreviewOverlay(item: item) { project.mediaPreview = nil }
            }
        }
        // 输入区 ＋ 菜单。挂最外层是因为它比侧栏宽，
        // 挂侧栏里溢出去的那半收不到鼠标、还会被时间轴压住
        .overlay {
            if let anchor = project.plusMenuAnchor {
                PlusMenuOverlay(anchor: anchor,
                                onPick: { project.plusMenuPick = $0
                                          project.plusMenuAnchor = nil },
                                onClose: { project.plusMenuAnchor = nil })
            }
        }

        .canvasKeyMonitor(canvas: project.canvas, windowID: windowID, isActive: project.showCanvas)
        .onReceive(NotificationCenter.default.publisher(for: .showSettings)) { note in
            // 这条通知是广播的（菜单、快捷键、各处「去设置」按钮都发它），
            // 只让当前窗口接，不然开着几个项目就弹几个设置
            guard WindowManager.shared.activeWindowID == windowID else { return }
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
                    project?.showSuccessToast(icon: "exportDone",
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
        .onReceive(NotificationCenter.default.publisher(for: MenuCommand.portraitLayout.notificationName)) { note in
            guard note.isFor(windowID) else { return }
            applyPortraitLayout()
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
            // 菜单在最上层，esc 先关它
            if project.plusMenuAnchor != nil { project.plusMenuAnchor = nil; return nil }
            // 预览层盖在画布之上，esc 也该先关它
            if project.mediaPreview != nil { project.mediaPreview = nil; return nil }
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

    /// AI 创作那一列。在左边时顶上一行是交通灯 + 收起按钮；在右边时顶上只放收起按钮
    @ViewBuilder
    private func aiColumn(onRight: Bool, width: CGFloat) -> some View {
        VStack(spacing: 0) {
            // 在左边时它就是最左边的面板：顶上一行交通灯 + 右上角两个面板开关；
            // 在右边时不要这一行（空着显得上面空一大块），只留跟主区一样的顶部留白
            if !onRight {
                HStack(spacing: 0) {
                    // 侧栏贴边后少了外面那圈 8pt，交通灯左移 8、上移 8 补回来，在窗口里的位置跟以前一样
                    TrafficLightsView()
                        .padding(.leading, 19)
                    Spacer()
                    panelToggles
                        .padding(.trailing, 11)
                }
                .frame(height: toolbarH)
                .padding(.top, 8)
            } else {
                Color.clear.frame(height: 14)
            }

            // 原来左边有 44 宽的图标栏垫着，独立成一列后补上左边距
            AIChatPanel()
                .padding(.leading, 12)
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .sidebarTint()
        // 跟主区之间一条分割线，画在靠主区那一边，上下顶头
        .overlay(alignment: onRight ? .leading : .trailing) {
            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(width: 1)
        }
        .simultaneousGesture(TapGesture().onEnded {
            // 刚在聊天气泡里选了文字（点、双击、拖选）就别清焦点：
            // 清掉之后 ⌘C 落不到气泡上，反被时间轴当成「复制片段」吃掉
            let fr = NSApp.keyWindow?.firstResponder
            if let tv = fr as? NSTextView, !tv.isEditable { return }
            NSApp.keyWindow?.makeFirstResponder(nil)
        })
        .transition(.move(edge: onRight ? .trailing : .leading).combined(with: .opacity))
        // 拖宽手柄在靠主区那一边。**不能 offset 到边缘外面**：紧挨着的主区画在上层，推出去的部分会被它盖掉
        .overlay(alignment: onRight ? .leading : .trailing) {
            Color.clear
                .frame(width: 8)
                .contentShape(Rectangle())
                .zIndex(100)
                .onContinuousHover { phase in
                    if case .active = phase { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
                }
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { v in
                        if !isDraggingSidebar { dragOriginSidebar = fitted.ai }
                        isDraggingSidebar = true
                        let dx = onRight ? -v.translation.width : v.translation.width
                        sidebarWidth = min(max(dragOriginSidebar + dx, 240), 700)
                    }
                    .onEnded { _ in
                        isDraggingSidebar = false
                        NSCursor.arrow.set()
                    }
                )
        }
    }

    /// 素材库 / 效果那一栏（左边竖图标栏切换）。是窗口最左边一栏时（AI 在右边或收起），
    /// 顶上一行放交通灯；AI 收起时收起按钮也在这一行（点它把 AI 放出来）
    private var libraryColumn: some View {
        VStack(spacing: 0) {
            // 是最左边的面板时：顶上一行交通灯 + 右上角两个面板开关
            if !aiOnLeftShown {
                HStack(spacing: 10) {
                    TrafficLightsView()
                    Spacer()
                    panelToggles
                }
                .padding(.leading, 19)
                .padding(.trailing, 11)
                .frame(height: toolbarH)
            }
            // 素材库六个分类 + 效果四个分类平铺（原来是左边两个图标 + 里面一排胶囊标签）
            LibraryCategoryGrid()
                .padding(.leading, 10)
                .padding(.trailing, 10)
                .padding(.top, aiOnLeftShown ? 6 : 0)
                .padding(.bottom, 2)

            // 宽度传下去给宫格算列数。**必须从这儿给** ——
            // 素材区自己拿 GeometryReader 量的话，量到的宽度会被
            // 自己算出来的列数影响，绕成环、拉窄时列减不回来。
            // 列宽算法里扣了 44 的图标栏，图标栏挪走了，这里补回去（再扣掉左边距 10）
            MediaLibraryView(sidebarWidth: fitted.library - 10 + 44, showsTabRail: false)
                .padding(.leading, 10)
        }
        .frame(width: fitted.library)
        .frame(maxHeight: .infinity)
        // 跟预览之间的分割线，上下顶头（补上主区顶上那 8pt 和下面拖动缝的一半）
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(width: 1)
                .padding(.top, -8)
                .padding(.bottom, -4)
        }
        .simultaneousGesture(TapGesture().onEnded {
            NSApp.keyWindow?.makeFirstResponder(nil)
        })
        .overlay(alignment: .trailing) {
            Color.clear
                .frame(width: 8)
                .contentShape(Rectangle())
                .zIndex(100)
                .onContinuousHover { phase in
                    if case .active = phase { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
                }
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { v in
                        if !isDraggingLibrary { dragOriginLibrary = fitted.library }
                        isDraggingLibrary = true
                        libraryWidth = min(max(dragOriginLibrary + v.translation.width, 200), 1200)
                    }
                    .onEnded { _ in
                        isDraggingLibrary = false
                        NSCursor.arrow.set()
                    }
                )
        }
    }

    /// 预览区至少留这么宽
    private static let minPreviewWidth: CGFloat = 420

    /// 按窗口宽度收窄后的各栏宽度。拖出来的宽度是「想要的」，窗口不够时依次收窄：
    /// 素材栏（最窄 200）→ AI 栏（最窄 240）→ 属性区（到它的最小宽度）
    private var fitted: (library: CGFloat, ai: CGFloat, inspector: CGFloat) {
        var lib = libraryVisible ? libraryWidth : 0
        var ai = sidebarVisible ? sidebarWidth : 0
        var insp = inspectorWidth
        guard rootWidth > 0 else { return (libraryWidth, sidebarWidth, inspectorWidth) }
        var over = lib + ai + insp + Self.minPreviewWidth - rootWidth
        func take(_ v: inout CGFloat, floor: CGFloat) {
            guard over > 0, v > floor else { return }
            let d = min(over, v - floor)
            v -= d
            over -= d
        }
        if libraryVisible { take(&lib, floor: 200) }
        if sidebarVisible { take(&ai, floor: 240) }
        take(&insp, floor: InspectorLayout.minWidth)
        return (libraryVisible ? lib : libraryWidth, sidebarVisible ? ai : sidebarWidth, insp)
    }

    /// 素材区放得下十个分类一行的宽度（格子最窄 46 × 10 + 间距 2 × 9 + 左右各 10，再留一点余量）
    private static let libraryOneRowWidth: CGFloat = 510

    /// 窗口 → 布局 → 竖屏模式：一次性调好，之后各栏照常能拖。
    /// 当前项目比例改成 9:16；属性区缩到最窄；AI 栏缩到 260；
    /// 预览刚好装下竖屏画面（最窄 minPreviewWidth，播放控制条不挤）；剩下的宽度给素材区（至少放得下分类一行）
    private func applyPortraitLayout() {
        if project.previewAspectRatio != "9:16" {
            project.previewAspectRatio = "9:16"
            project.rebuildTimelinePreview()
        }
        libraryVisible = true
        inspectorWidth = InspectorLayout.minWidth
        if sidebarVisible { sidebarWidth = 260 }
        guard rootWidth > 0 else { libraryWidth = Self.libraryOneRowWidth; return }
        // 减掉播放控制条和上下留白，剩下的是画面能用的高度
        let h = max(topHeight - 60, 120)
        let preview = max(h * 9 / 16 + 32, Self.minPreviewWidth)
        let ai: CGFloat = sidebarVisible ? 260 : 0
        libraryWidth = min(max(rootWidth - ai - inspectorWidth - preview, Self.libraryOneRowWidth), 1200)
    }

    /// AI 创作在左边且显示着：它就是最左边的面板
    private var aiOnLeftShown: Bool { sidebarVisible && !settings.aiPanelOnRight }

    /// 两个面板开关：素材库与效果、AI 创作。始终放在最左边那个面板的右上角
    private var panelToggles: some View {
        HStack(spacing: 2) {
            panelToggle(image: SidebarSVGIcon.load("folderFill"), on: libraryVisible,
                        help: libraryVisible ? "隐藏素材库和效果" : "显示素材库和效果") {
                libraryVisible.toggle()
            }
            panelToggle(image: SidebarSVGIcon.load("ai"), on: sidebarVisible,
                        help: sidebarVisible ? "隐藏 AI 创作" : "显示 AI 创作") {
                sidebarVisible.toggle()
            }
        }
    }

    private func panelToggle(image: NSImage, on: Bool, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 15, height: 15)
                // 打开着的亮一些，收起的暗
                .foregroundColor(on ? Color.labelPrimary : Color.labelSecondary.opacity(0.6))
                .frame(width: 28, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
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
        // 导出完成：用素材库那个导出图标，比通用的对勾一眼认得出是导出
        "exportDone":                    ("exportFile",   Color(hex: "#30D158")),
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
