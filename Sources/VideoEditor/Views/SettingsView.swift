import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var modelStates: [WhisperTranscriber.ModelSize: ModelState] = [:]
    @State private var selectedTab = 0
    var dismiss: () -> Void

    enum ModelState {
        case notDownloaded, downloaded, downloading(Double), failed(String)
    }

    @State private var sceneDetectState: ModelState = .notDownloaded
    private let tabs = ["保存位置", "语音识别", "字幕翻译", "视频分析", "视频生成"]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("设置")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color.labelSecondary)
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
            .padding(.top, 24)
            .padding(.bottom, 16)

            Divider().background(Color.divider)

            // 标签栏
            HStack(spacing: 0) {
                ForEach(0..<tabs.count, id: \.self) { i in
                    Button { selectedTab = i } label: {
                        Text(tabs[i])
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(selectedTab == i ? .white : Color.labelSecondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 26)
                            .background(selectedTab == i ? Color.white.opacity(0.15) : Color.clear)
                            .clipShape(Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Color.white.opacity(0.06))
            .clipShape(Capsule())
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch selectedTab {
                    case 0: saveTab
                    case 1: whisperTab
                    case 2: translateTab
                    case 3: sceneDetectTab
                    case 4: aiVideoTab
                    default: EmptyView()
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
        }
        .frame(width: 540, height: 520)
        .background(Color(red: 0.13, green: 0.13, blue: 0.14))
        .onAppear { refreshModelStates(); refreshSceneDetectState() }
    }

    // MARK: - 保存位置

    private var saveTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            pathRow(label: "项目保存位置", path: settings.projectSaveDir, placeholder: AppSettings.defaultSaveDir.path) { url in
                settings.projectSaveDir = url
            }
            pathRow(label: "导出保存位置", path: settings.exportSaveDir, placeholder: AppSettings.defaultSaveDir.path) { url in
                settings.exportSaveDir = url
            }

            SSection(title: "自动保存") {
                HStack(spacing: 8) {
                    ForEach(AppSettings.autoSaveOptions, id: \.value) { opt in
                        Button {
                            settings.autoSaveInterval = opt.value
                        } label: {
                            Text(opt.label)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(settings.autoSaveInterval == opt.value ? .black : Color.labelPrimary)
                                .frame(maxWidth: .infinity, minHeight: 32)
                                .background(settings.autoSaveInterval == opt.value ? Color.accent : Color.white.opacity(0.08))
                                .cornerRadius(7)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if settings.autoSaveInterval == 0 {
                    Text("关闭后需手动保存（⌘S）")
                        .font(.system(size: 10))
                        .foregroundColor(Color.accent.opacity(0.8))
                }
            }
        }
    }

    // MARK: - 语音识别

    private var whisperTab: some View {
        let displayDir = settings.whisperModelDir ?? WhisperTranscriber.supportDir
        return VStack(alignment: .leading, spacing: 12) {
            pathRow(label: "模型存储位置", path: displayDir, placeholder: "", defaultDir: WhisperTranscriber.supportDir) { url in
                settings.whisperModelDir = url
                refreshModelStates()
            }

            Text("识别模型")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color.labelSecondary)

            VStack(spacing: 4) {
                ForEach(WhisperTranscriber.ModelSize.allCases, id: \.rawValue) { model in
                    modelRow(model)
                }
            }
        }
    }

    // MARK: - 字幕翻译

    private var translateTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            SSection(title: "翻译引擎") {
                IPicker(selection: Binding(
                    get: { settings.translateProvider.displayName },
                    set: { name in
                        if let p = AppSettings.TranslateProvider.allCases.first(where: { $0.displayName == name }) {
                            settings.translateProvider = p
                        }
                    }
                ), options: AppSettings.TranslateProvider.allCases.map { ($0.displayName, $0.displayName) })

                if settings.translateProvider == .google {
                    Text("免费，无需配置")
                        .font(.system(size: 10))
                        .foregroundColor(Color.labelSecondary)
                }

                if settings.translateProvider == .apple {
                    if #available(macOS 15, *) {
                        Text("使用系统内置翻译，无需 API Key（需先在系统设置中下载语言包）")
                            .font(.system(size: 10))
                            .foregroundColor(Color.labelSecondary)
                    } else {
                        Text("Apple 翻译需要 macOS 15 或更高版本")
                            .font(.system(size: 10))
                            .foregroundColor(.orange.opacity(0.8))
                    }
                }

                if settings.translateProvider.needsAPIKey {
                    apiKeyField(
                        label: settings.translateProvider.keyLabel,
                        placeholder: settings.translateProvider.keyPlaceholder,
                        text: translateKeyBinding
                    )
                }

                if settings.translateProvider.needsSecretKey {
                    apiKeyField(
                        label: settings.translateProvider.secretLabel,
                        placeholder: settings.translateProvider.secretPlaceholder,
                        text: translateSecretBinding
                    )
                }
            }
        }
    }

    // MARK: - 视频分析

    private var sceneDetectTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            pathRow(label: "组件存储位置", path: SceneDetector.supportDir, placeholder: "", defaultDir: SceneDetector.supportDir) { _ in }

            Text("智能分割")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color.labelSecondary)

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("PySceneDetect")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color.labelPrimary)
                    Text("基于内容分析的智能场景切割（含 Python 运行时），\(SceneDetector.componentSize)")
                        .font(.system(size: 10))
                        .foregroundColor(Color.labelSecondary)
                }

                Spacer()

                switch sceneDetectState {
                case .downloaded:
                    Text("已安装")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.green.opacity(0.8))
                        .padding(.horizontal, 8).frame(height: 24)
                        .background(Color.green.opacity(0.1))
                        .cornerRadius(4)
                case .notDownloaded:
                    Button { downloadSceneDetect() } label: {
                        Text("下载")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Color.accent)
                            .padding(.horizontal, 10).frame(height: 24)
                            .background(Color.accent.opacity(0.15))
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                case .downloading(let pct):
                    HStack(spacing: 6) {
                        ProgressView(value: pct)
                            .frame(width: 50)
                            .tint(Color.accent)
                        Text("\(Int(pct * 100))%")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundColor(Color.labelSecondary)
                            .frame(width: 28)
                    }
                case .failed(let msg):
                    HStack(spacing: 6) {
                        Text(msg)
                            .font(.system(size: 9))
                            .foregroundColor(.red.opacity(0.8))
                            .lineLimit(1)
                            .frame(maxWidth: 80)
                        Button { downloadSceneDetect() } label: {
                            Text("重试")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(Color.accent)
                                .padding(.horizontal, 8).frame(height: 24)
                                .background(Color.accent.opacity(0.15))
                                .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.04))
            .cornerRadius(7)

            Text("安装后可在工具栏使用「智能分割」功能，自动检测视频场景切换点并分割片段。")
                .font(.system(size: 10))
                .foregroundColor(Color.labelSecondary)

            Divider().padding(.vertical, 4)

            SSection(title: "AI 剪辑") {
                IPicker(selection: Binding(
                    get: { settings.llmProvider.displayName },
                    set: { name in
                        if let p = AppSettings.LLMProvider.allCases.first(where: { $0.displayName == name }) {
                            settings.llmProvider = p
                        }
                    }
                ), options: AppSettings.LLMProvider.allCases.map { ($0.displayName, $0.displayName) })

                apiKeyField(
                    label: "API Key",
                    placeholder: settings.llmProvider.keyPlaceholder,
                    text: Binding(
                        get: { settings.llmAPIKey },
                        set: { settings.llmAPIKey = $0 }
                    )
                )

                Text("使用大模型分析视频字幕，自动识别精彩片段并裁剪。分析前确保语音识别功能可用。")
                    .font(.system(size: 10))
                    .foregroundColor(Color.labelSecondary)
            }
        }
    }

    private func refreshSceneDetectState() {
        if case .downloading = sceneDetectState { return }
        sceneDetectState = SceneDetector.isInstalled ? .downloaded : .notDownloaded
    }

    private func downloadSceneDetect() {
        sceneDetectState = .downloading(0)
        Task {
            do {
                try await SceneDetector.download { pct in
                    DispatchQueue.main.async { sceneDetectState = .downloading(pct) }
                }
                await MainActor.run { sceneDetectState = .downloaded }
            } catch {
                await MainActor.run { sceneDetectState = .failed(error.localizedDescription) }
            }
        }
    }

    // MARK: - 视频生成

    private var aiVideoTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            SSection(title: "生成模型") {
                IPicker(selection: Binding(
                    get: { settings.aiProvider },
                    set: { settings.aiProvider = $0 }
                ), options: AIVideoService.Provider.allCases.map { ($0.rawValue, $0.displayName) })
            }

            if let provider = AIVideoService.Provider(rawValue: settings.aiProvider) {
                if provider == .seedance || provider == .seedance15 {
                    apiKeyField(
                        label: "API Key",
                        placeholder: "输入火山方舟 API Key",
                        text: Binding(get: { settings.seedanceApiKey }, set: { settings.seedanceApiKey = $0 })
                    )
                    if provider == .seedance {
                        endpointField(
                            label: "接入点 ID",
                            placeholder: "ep-xxxxx...",
                            text: Binding(get: { settings.seedanceEndpoint }, set: { settings.seedanceEndpoint = $0 })
                        )
                    } else {
                        endpointField(
                            label: "接入点 ID",
                            placeholder: "ep-xxxxx...",
                            text: Binding(get: { settings.seedance15Endpoint }, set: { settings.seedance15Endpoint = $0 })
                        )
                    }
                    Text("在火山方舟「接入点管理」中为每个模型创建接入点，填入对应 ID")
                        .font(.system(size: 10))
                        .foregroundColor(Color.labelSecondary.opacity(0.6))
                } else {
                    apiKeyField(
                        label: provider.accessKeyLabel,
                        placeholder: "输入 \(provider.accessKeyLabel)",
                        text: Binding(get: { settings.aiAccessKey }, set: { settings.aiAccessKey = $0 })
                    )

                    if provider.needsSecretKey {
                        apiKeyField(
                            label: provider.secretKeyLabel,
                            placeholder: "输入 \(provider.secretKeyLabel)",
                            text: Binding(get: { settings.aiSecretKey }, set: { settings.aiSecretKey = $0 })
                        )
                    }
                }
            }

            Text("Key 仅保存在本地，不会上传到任何服务器")
                .font(.system(size: 10))
                .foregroundColor(Color.labelSecondary.opacity(0.6))
        }
    }

    // MARK: - 共用组件

    private func pathRow(label: String, path: URL?, placeholder: String, defaultDir: URL? = nil, onSelect: @escaping (URL?) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color.labelSecondary)
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 12, weight: .light))
                        .foregroundColor(Color.labelSecondary)
                    Text(path?.path ?? placeholder)
                        .font(.system(size: 11))
                        .foregroundColor(path == nil
                                         ? Color.labelSecondary.opacity(0.5)
                                         : Color.labelPrimary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(Color.white.opacity(0.06))
                .cornerRadius(7)

                Button {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.canCreateDirectories = true
                    panel.prompt = "选择"
                    if let dir = path ?? defaultDir {
                        panel.directoryURL = dir
                    }
                    if panel.runModal() == .OK { onSelect(panel.url) }
                } label: {
                    Text("选择")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color.labelPrimary)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(7)
                }
                .buttonStyle(.plain)

                if path != nil {
                    Button { onSelect(nil) } label: {
                        Text("重置")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color.labelSecondary)
                            .padding(.horizontal, 10)
                            .frame(height: 32)
                            .background(Color.white.opacity(0.06))
                            .cornerRadius(7)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func modelRow(_ model: WhisperTranscriber.ModelSize) -> some View {
        let isSelected = settings.selectedWhisperModel == model
        let state = modelStates[model] ?? .notDownloaded

        return HStack(spacing: 10) {
            Button {
                if case .downloaded = state {
                    settings.selectedWhisperModel = model
                }
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundColor(isSelected ? Color.accent : Color.labelSecondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                Text(model.displayName)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(Color.labelPrimary)
                Text(model.sizeDesc)
                    .font(.system(size: 10))
                    .foregroundColor(Color.labelSecondary)
            }

            Spacer()

            switch state {
            case .downloaded:
                Text("已下载")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.green.opacity(0.8))
                    .padding(.horizontal, 8).frame(height: 24)
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(4)
            case .notDownloaded:
                Button { downloadModel(model) } label: {
                    Text("下载")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color.accent)
                        .padding(.horizontal, 10).frame(height: 24)
                        .background(Color.accent.opacity(0.15))
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
            case .downloading(let pct):
                HStack(spacing: 6) {
                    ProgressView(value: pct)
                        .frame(width: 50)
                        .tint(Color.accent)
                    Text("\(Int(pct * 100))%")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundColor(Color.labelSecondary)
                        .frame(width: 28)
                }
            case .failed(let msg):
                HStack(spacing: 6) {
                    Text(msg)
                        .font(.system(size: 9))
                        .foregroundColor(.red.opacity(0.8))
                        .lineLimit(1)
                        .frame(maxWidth: 80)
                    Button { downloadModel(model) } label: {
                        Text("重试")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Color.accent)
                            .padding(.horizontal, 8).frame(height: 24)
                            .background(Color.accent.opacity(0.15))
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected ? Color.white.opacity(0.06) : Color.clear)
        .cornerRadius(7)
    }

    private func refreshModelStates() {
        for model in WhisperTranscriber.ModelSize.allCases {
            let url = modelFileURL(model)
            if FileManager.default.fileExists(atPath: url.path) {
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                let size = (attrs?[.size] as? Int) ?? 0
                modelStates[model] = size > model.minFileSize ? .downloaded : .notDownloaded
            } else {
                if case .downloading = modelStates[model] { continue }
                modelStates[model] = .notDownloaded
            }
        }
    }

    private func modelFileURL(_ model: WhisperTranscriber.ModelSize) -> URL {
        let dir = settings.whisperModelDir ?? WhisperTranscriber.supportDir
        return dir.appendingPathComponent(model.fileName)
    }

    private func downloadModel(_ model: WhisperTranscriber.ModelSize) {
        modelStates[model] = .downloading(0)
        Task {
            do {
                try await WhisperTranscriber.downloadModel(model) { pct in
                    DispatchQueue.main.async { modelStates[model] = .downloading(pct) }
                }
                await MainActor.run {
                    modelStates[model] = .downloaded
                    settings.selectedWhisperModel = model
                }
            } catch {
                await MainActor.run {
                    modelStates[model] = .failed(error.localizedDescription)
                }
            }
        }
    }

    private var translateKeyBinding: Binding<String> {
        switch settings.translateProvider {
        case .deepL:
            return Binding(get: { settings.deeplAPIKey }, set: { settings.deeplAPIKey = $0 })
        case .youdao:
            return Binding(get: { settings.youdaoAppKey }, set: { settings.youdaoAppKey = $0 })
        case .volcano:
            return Binding(get: { settings.volcanoAccessKeyId }, set: { settings.volcanoAccessKeyId = $0 })
        default:
            return .constant("")
        }
    }

    private var translateSecretBinding: Binding<String> {
        switch settings.translateProvider {
        case .youdao:
            return Binding(get: { settings.youdaoAppSecret }, set: { settings.youdaoAppSecret = $0 })
        case .volcano:
            return Binding(get: { settings.volcanoSecretAccessKey }, set: { settings.volcanoSecretAccessKey = $0 })
        default:
            return .constant("")
        }
    }

    private func endpointField(label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color.labelSecondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(Color.labelPrimary)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(Color.white.opacity(0.06))
                .cornerRadius(7)
        }
    }

    private func apiKeyField(label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color.labelSecondary)
            SecureField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(Color.labelPrimary)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(Color.white.opacity(0.06))
                .cornerRadius(7)
        }
    }
}

// MARK: - Section

private struct SSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !title.isEmpty {
                Text(title).font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color.labelSecondary).tracking(0.4)
            }
            content
        }
    }
}
