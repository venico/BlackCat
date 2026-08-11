import SwiftUI

struct WhisperModelPickerSheet: View {
    @EnvironmentObject private var project: ProjectState
    @Environment(\.dismiss) private var dismiss
    @State private var selected: WhisperTranscriber.ModelSize = .small

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text("语音识别模型")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color.labelPrimary)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color.labelSecondary)
                        .frame(width: 26, height: 26)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider().background(Color.divider)

            // Content
            VStack(alignment: .leading, spacing: 12) {
                Text("首次使用需下载语音识别模型，请选择合适的模型：")
                    .font(.system(size: 11))
                    .foregroundColor(Color.labelSecondary)

                VStack(spacing: 6) {
                    ForEach(WhisperTranscriber.ModelSize.allCases, id: \.rawValue) { model in
                        modelRow(model)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            Divider().background(Color.divider)

            // Action row
            HStack(spacing: 16) {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("取消").font(.system(size: 13))
                        .foregroundColor(Color.labelSecondary)
                        .frame(width: 80, height: 36)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)

                Button {
                    project.selectedWhisperModel = selected
                    dismiss()
                    project.downloadModelAndTranscribe()
                } label: {
                    Text("下载并识别")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.black)
                        .frame(width: 120, height: 36)
                        .background(Color.accent)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 460)
        .background(Color.black.opacity(0.30))
        .floatingPanelMaterial()
        .onAppear { selected = project.selectedWhisperModel }
    }

    private func modelRow(_ model: WhisperTranscriber.ModelSize) -> some View {
        let isSelected = selected == model
        let downloaded = FileManager.default.fileExists(
            atPath: WhisperTranscriber.downloadedModelURL(model).path)
        return Button {
            selected = model
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? Color.accent : Color.labelSecondary)
                    .font(.system(size: 14))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(model.displayName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color.labelPrimary)
                        if model == .small {
                            Text("推荐")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.black)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.accent)
                                .cornerRadius(3)
                        }
                        if downloaded {
                            Text("已下载")
                                .font(.system(size: 9))
                                .foregroundColor(.green)
                        }
                    }
                    Text(model.sizeDesc)
                        .font(.system(size: 10))
                        .foregroundColor(Color.labelSecondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color.accent.opacity(0.1) : Color.white.opacity(0.04))
            .cornerRadius(7)
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(isSelected ? Color.accent.opacity(0.4) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }
}

// MARK: - 识别方式选择

/// 识别前问一句：要不要顺带让大模型校对。
/// 放在这个文件里跟模型选择弹窗做伴——都是语音识别流程上的前置弹窗。
/// 模型和 Key 都复用「设置 → AI 生成」里配好的那套，不再单独一份配置
struct TranscribeOptionsSheet: View {
    @EnvironmentObject private var project: ProjectState
    @ObservedObject private var settings = AppSettings.shared

    /// 关掉自己。overlay 呈现，没有 sheet 的 dismiss 可用
    private func dismiss() { project.showTranscribeOptions = false }

    /// 「AI 生成」里归类为文字生成的模型
    private var textModels: [AIVideoService.Provider] {
        AIVideoService.Provider.allCases.filter { $0.category == .text }
    }

    private func hasKey(_ p: AIVideoService.Provider) -> Bool {
        !settings.providerAPIKey(for: p.rawValue).trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 配好 Key 的模型。一个都没有时第二项不可用
    private var readyModels: [AIVideoService.Provider] { textModels.filter(hasKey) }

    private var selectedModel: AIVideoService.Provider? {
        AIVideoService.Provider(rawValue: project.transcribeAIModel)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("语音识别")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color.labelPrimary)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color.labelSecondary)
                        .frame(width: 26, height: 26)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 4)

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("识别方式")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color.labelPrimary)
                    optionCard(title: "直接识别",
                           detail: "本地识别，不联网",
                           enabled: true) { start(useAI: false) }
                }

                VStack(alignment: .leading, spacing: 8) {
                    // 跟设置页的 sectionTitle 一致：13pt semibold 白字
                    Text("校对模型")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color.labelPrimary)

                    if readyModels.isEmpty {
                        // 一个都没配：下拉换成一条跳转，点了直接开「AI 生成」
                        Button {
                            dismiss()
                            NotificationCenter.default.post(name: .showSettings,
                                                            object: SettingsView.aiTabIndex)
                        } label: {
                            HStack {
                                Text("去配置")
                                    .font(.system(size: 12))
                                    .foregroundColor(Color.accent)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(Color.labelSecondary)
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 32)
                            .background(Color.white.opacity(0.06))
                            .cornerRadius(7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    } else {
                        IPicker(selection: Binding(
                            get: { project.transcribeAIModel },
                            set: { project.transcribeAIModel = $0 }
                        ), options: readyModels.map { ($0.rawValue, $0.displayName) }, height: 32)
                    }

                    optionCard(title: "识别 + AI 校对",
                               detail: "修正错别字，合并被切碎的句子。不改时间轴",
                               enabled: !readyModels.isEmpty) { start(useAI: true) }
                }
            }
            .padding(20)
        }
        .frame(width: 400)
        // 底色 + 材质跟导出/设置完全一致；圆角描边阴影由 ContentView 那层加
        .background(Color.black.opacity(0.30))
        .floatingPanelMaterial()
        .onAppear {
            // 选中的模型没配 Key 就换成第一个配好的，免得点了才报错
            if let m = selectedModel, hasKey(m) { return }
            if let first = readyModels.first { project.transcribeAIModel = first.rawValue }
        }
        .onExitCommand { dismiss() }
    }

    private func start(useAI: Bool) {
        dismiss()
        // 等 sheet 收完再开跑，否则识别进度提示会被关闭动画盖住
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            project.autoTranscribeSelectedClip(useAI: useAI)
        }
    }

    private func optionCard(title: String, detail: String, enabled: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(enabled ? Color.labelPrimary : Color.labelSecondary)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(Color.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Color.white.opacity(enabled ? 0.07 : 0.03))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
