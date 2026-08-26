// ProjectInspector.swift
// 未选中任何片段时属性区显示的项目设置：名称、保存位置、画面比例/分辨率/输出尺寸、帧率、码率。
// 比例和分辨率与预览双向同步 —— 两边读写的是同一份 ProjectState 字段。
import SwiftUI
import AppKit

struct ProjectInspector: View {
    @EnvironmentObject private var project: ProjectState
    @ObservedObject private var settings = AppSettings.shared

    @State private var nameDraft: String = ""
    @State private var widthDraft: String = ""
    @State private var heightDraft: String = ""
    @FocusState private var sizeFieldFocused: Bool
    @State private var coverHovering = false

    private var isCustomSize: Bool { project.previewAspectRatio == ExportSettings.customAspect }

    private var computedSize: CGSize { project.previewRenderSize }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ISection(title: "项目") {
                fieldLabel("封面")
                coverEntry

                fieldLabel("项目名称")
                TextField("未命名项目", text: $nameDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(Color.labelPrimary)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(6)
                    .onSubmit { commitName() }
                    .onChange(of: nameDraft) { _ in commitName() }

                fieldLabel("保存位置")
                HStack(spacing: 6) {
                    Text(saveDirPath)
                        .font(.system(size: 10))
                        .foregroundColor(Color.labelPrimary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .frame(height: 28)
                        .background(Color.white.opacity(0.06))
                        .cornerRadius(6)
                    smallButton("选择") { pickSaveDir() }
                }
            }

            ISection(title: "画面") {
                fieldLabel("比例")
                IPicker(selection: Binding(
                    get: { project.previewAspectRatio },
                    set: { setAspect($0) }
                ), options: ExportSettings.aspectRatios.map { ($0, $0) }, height: 28)

                fieldLabel("分辨率")
                IPicker(selection: Binding(
                    get: { project.previewResolution },
                    set: { setResolution($0) }
                ), options: ExportSettings.resolutions.map { ($0, $0) }, height: 28)
                .disabled(isCustomSize)
                .opacity(isCustomSize ? 0.4 : 1)

                fieldLabel(isCustomSize ? "输出尺寸（自定义）" : "输出尺寸")
                HStack(spacing: 6) {
                    sizeField(text: $widthDraft, placeholder: "宽")
                    Text("×")
                        .font(.system(size: 10))
                        .foregroundColor(Color.labelSecondary)
                    sizeField(text: $heightDraft, placeholder: "高")
                }
                if !isCustomSize {
                    Text("按比例和分辨率自动计算，直接改数值会切到自定义")
                        .font(.system(size: 9))
                        .foregroundColor(Color.labelSecondary.opacity(0.7))
                }
            }

            ISection(title: "输出") {
                fieldLabel("帧率")
                HStack(spacing: 6) {
                    ForEach(ExportSettings.fpsOptions, id: \.self) { fps in
                        Button { project.projectFPS = fps } label: {
                            Text("\(fps)")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(project.projectFPS == fps ? .black : Color.labelPrimary)
                                .frame(maxWidth: .infinity, minHeight: 26)
                                .background(project.projectFPS == fps ? Color.accent : Color.white.opacity(0.08))
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack {
                    Text("码率")
                        .font(.system(size: 10))
                        .foregroundColor(Color.labelSecondary)
                    Spacer()
                    Text("\(project.projectBitrate) kbps")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundColor(Color.labelPrimary)
                }
                // 不用 step：macOS 上带 step 的 Slider 会画出刻度线，改为赋值时取整
                Slider(value: Binding(
                    get: { Double(project.projectBitrate) },
                    set: { project.projectBitrate = Int(($0 / 500).rounded()) * 500 }
                ), in: 1000...50000)
                .tint(Color.accent)
            }
        }
        .onAppear { syncDrafts() }
        .onChange(of: computedSize) { _ in syncSizeDrafts() }
        .onChange(of: project.projectName) { n in
            if n != nameDraft { nameDraft = n }
        }
        .onChange(of: project.focusCustomSizeField) { flag in
            guard flag else { return }
            sizeFieldFocused = true
            project.focusCustomSizeField = false
        }
    }

    // MARK: - 子视图

    private func fieldLabel(_ t: String) -> some View {
        Text(t)
            .font(.system(size: 10))
            .foregroundColor(Color.labelSecondary)
    }

    private func sizeField(text: Binding<String>, placeholder: String) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 11).monospacedDigit())
            .multilineTextAlignment(.center)
            .foregroundColor(Color.labelPrimary)
            .frame(height: 28)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(0.06))
            .cornerRadius(6)
            .focused($sizeFieldFocused)
            .onSubmit { commitSize() }
            .onChange(of: sizeFieldFocused) { focused in
                // 点进输入框就视为要自定义尺寸，省得先去比例下拉里选一次
                guard focused, project.previewAspectRatio != ExportSettings.customAspect else { return }
                let s = computedSize
                project.customOutputWidth = Int(s.width)
                project.customOutputHeight = Int(s.height)
                project.previewAspectRatio = ExportSettings.customAspect
            }
    }

    private func smallButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Color.labelPrimary)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Color.white.opacity(0.08))
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 数据

    /// 与欢迎页、导出面板同源：都取设置里的保存位置，默认桌面
    private var saveDirPath: String {
        settings.effectiveProjectDir.path
    }

    private func syncDrafts() {
        nameDraft = project.projectName
        syncSizeDrafts()
    }

    private func syncSizeDrafts() {
        let s = computedSize
        widthDraft  = String(Int(s.width))
        heightDraft = String(Int(s.height))
    }

    /// 封面入口。没设计过显示缺省图，hover 出「设计封面」按钮；
    /// 已经设置过的还多一个清除。**按钮画在块里**，不用 tooltip ——
    /// tooltip 会飘到面板外面去
    private var coverEntry: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06))
            if let img = coverImage {
                // fill + 裁切：铺满整个框，不在框里留黑边
                Color.clear.overlay(
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                )
                .clipped()
            } else {
                // 缺省态只放一个大图标，不写字 —— 上面本来就有「封面」那行标签
                Image(nsImage: SidebarSVGIcon.load("image", size: 34))
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 34, height: 34)
                    .foregroundColor(Color.labelSecondary.opacity(0.4))
            }

            // hover 才出的操作层：压暗 + 「设计封面」，右上角是清除
            if coverHovering {
                Color.black.opacity(0.45)
                Button { project.showCoverDesigner = true } label: {
                    Text("设计封面")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(Capsule().fill(Color.white.opacity(0.22)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)

                if project.cover != nil {
                    VStack {
                        HStack {
                            Spacer()
                            Button { clearCover() } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(width: 18, height: 18)
                                    .background(Circle().fill(Color.black.opacity(0.6)))
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .help("清除封面")
                        }
                        Spacer()
                    }
                    .padding(5)
                }
            }
        }
        // **裁剪和边框都要排在 aspectRatio 之前**：排在后面的话它们作用在外层那个
        // 满宽的 frame 上，而内容按比例缩在中间 —— 就是边框两侧空出一条的样子。
        //
        // 比例跟着项目设置走；限高 300，竖版项目（9:16 那种）按比例撑起来
        // 会占掉大半个属性区
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(Color.white.opacity(coverHovering ? 0.25 : 0.10)))
        .aspectRatio(coverAspect, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: 300)
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onHover { coverHovering = $0 }
        .padding(.bottom, 4)
    }

    /// 清除封面：清掉设计稿，顺手把渲染出来的那张 PNG 删掉，不留垃圾
    private func clearCover() {
        if let rel = project.cover?.renderedPath,
           let base = project.projectFileURL?.deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: base.appendingPathComponent(rel))
        }
        project.cover = nil
        project.isSaved = false
        project.scheduleAutoSave()
    }

    /// 框按**项目比例**画。封面渲染出来就是这个比例（`renderCover` 用的是
    /// `previewRenderSize`），所以两者本来就该贴合；
    /// 项目比例后来改过的旧封面，图按 fill 铺满裁切，不留空边
    private var coverAspect: CGFloat {
        let s = project.previewRenderSize
        guard s.width > 0, s.height > 0 else { return 16.0 / 9.0 }
        return s.width / s.height
    }

    /// 已经渲染好的封面图。相对路径存的，按项目文件所在目录还原
    private var coverImage: NSImage? {
        guard let rel = project.cover?.renderedPath else { return nil }
        let base = project.projectFileURL?.deletingLastPathComponent()
        let url = base.map { $0.appendingPathComponent(rel) } ?? URL(fileURLWithPath: rel)
        return NSImage(contentsOf: url)
    }

    private func commitName() {
        let t = nameDraft.trimmingCharacters(in: .whitespaces)
        project.projectName = t.isEmpty ? "未命名项目" : t
    }

    private func setAspect(_ v: String) {
        guard project.previewAspectRatio != v else { return }
        if v == ExportSettings.customAspect {
            // 切自定义时以当前算出的尺寸为起点，避免跳变
            let s = computedSize
            project.customOutputWidth = Int(s.width)
            project.customOutputHeight = Int(s.height)
        }
        project.previewAspectRatio = v
        project.rebuildTimelinePreview()
    }

    private func setResolution(_ v: String) {
        guard project.previewResolution != v else { return }
        project.previewResolution = v
        project.rebuildTimelinePreview()
    }

    /// 手改尺寸即视为自定义
    private func commitSize() {
        guard let w = Int(widthDraft.trimmingCharacters(in: .whitespaces)),
              let h = Int(heightDraft.trimmingCharacters(in: .whitespaces)),
              w >= 2, h >= 2 else {
            syncSizeDrafts()
            return
        }
        let ew = max(2, (w / 2) * 2), eh = max(2, (h / 2) * 2)
        project.customOutputWidth = ew
        project.customOutputHeight = eh
        if project.previewAspectRatio != ExportSettings.customAspect {
            project.previewAspectRatio = ExportSettings.customAspect
        }
        project.rebuildTimelinePreview()
        syncSizeDrafts()
    }

    private func pickSaveDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "选择项目保存位置"
        panel.begin { r in
            guard r == .OK, let url = panel.url else { return }
            DispatchQueue.main.async { settings.projectSaveDir = url }
        }
    }
}
