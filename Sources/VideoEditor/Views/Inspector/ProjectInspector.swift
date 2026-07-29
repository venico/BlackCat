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

    private var isCustomSize: Bool { project.previewAspectRatio == ExportSettings.customAspect }

    private var computedSize: CGSize { project.previewRenderSize }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ISection(title: "项目") {
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
