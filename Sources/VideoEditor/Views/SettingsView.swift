import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @EnvironmentObject var project: ProjectState
    @State private var modelStates: [WhisperTranscriber.ModelSize: ModelState] = [:]
    @State private var selectedTab = 0
    var dismiss: () -> Void

    enum ModelState {
        case notDownloaded, downloaded, downloading(Double), failed(String)
    }

    @State private var sceneDetectState: ModelState = .notDownloaded
    @State private var demucsState: ModelState = .notDownloaded
    @State private var biRefNetStates: [BiRefNetModel: ModelState] = [:]
    @State private var clarityModelStates: [ClarityModel: ModelState] = [:]
    // 分离产物占用，进设置页和每次清理后刷新
    @State private var separatedFiles: [URL] = []
    @State private var separatedBytes: Int64 = 0
    @State private var cleanHint: String? = nil
    private let tabs = ["通用", "视频", "图片", "音频", "字幕", "AI 生成"]

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
                    case 1: sceneDetectTab
                    case 2: imageTab
                    case 3: audioTab
                    case 4: subtitleTab
                    case 5: aiVideoTab
                    default: EmptyView()
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
        }
        .frame(width: 540, height: 520)
        .background(Color(red: 0.13, green: 0.13, blue: 0.14))
        .onAppear { refreshModelStates(); refreshSceneDetectState(); refreshDemucsState(); refreshSeparated(); refreshBiRefNetStates(); refreshClarityModelStates() }
    }

    /// 标签页内的一级标题，用来分块
    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(Color.labelPrimary)
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

    // MARK: - 图片

    private var imageTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("去除背景")

            Text("抠图模型")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color.labelSecondary)

            BGEnginePicker(selection: Binding(
                get: { settings.bgRemovalEngine },
                set: { settings.bgRemovalEngine = $0 }
            ))


            if settings.bgRemovalEngine.needsDownload {
                pathRow(label: "模型存储位置", path: BiRefNetModel.supportDir,
                        placeholder: "", defaultDir: BiRefNetModel.supportDir) { _ in }

                Text("可用模型")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color.labelSecondary)

                VStack(spacing: 4) {
                    ForEach(BiRefNetModel.allCases) { model in
                        biRefNetRow(model)
                    }
                }
            }

        }
    }

    private func biRefNetRow(_ model: BiRefNetModel) -> some View {
        let isSelected = settings.biRefNetModel == model
        let state = biRefNetStates[model] ?? .notDownloaded

        return HStack(spacing: 10) {
            Button {
                if case .downloaded = state { settings.biRefNetModel = model }
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
                Button { deleteBiRefNet(model) } label: {
                    Text("已下载")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.green.opacity(0.8))
                        .padding(.horizontal, 8).frame(height: 24)
                        .background(Color.green.opacity(0.1))
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .help("点击删除该模型")
            case .notDownloaded:
                if model.isAvailableForDownload {
                    Button { downloadBiRefNet(model) } label: {
                        Text("下载")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Color.accent)
                            .padding(.horizontal, 10).frame(height: 24)
                            .background(Color.accent.opacity(0.15))
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("暂无下载源")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color.labelSecondary.opacity(0.6))
                        .padding(.horizontal, 8).frame(height: 24)
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(4)
                }
            case .downloading(let pct):
                HStack(spacing: 6) {
                    ProgressView(value: pct).frame(width: 50).tint(Color.accent)
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
                        .lineLimit(1).frame(maxWidth: 80)
                    Button { downloadBiRefNet(model) } label: {
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
        .padding(.vertical, 7)
        .background(Color.white.opacity(isSelected ? 0.06 : 0.02))
        .cornerRadius(7)
    }

    private func refreshBiRefNetStates() {
        for m in BiRefNetModel.allCases {
            if case .downloading = biRefNetStates[m] { continue }
            biRefNetStates[m] = m.isDownloaded ? .downloaded : .notDownloaded
        }
    }

    private func downloadBiRefNet(_ model: BiRefNetModel) {
        biRefNetStates[model] = .downloading(0)
        Task {
            do {
                try await model.download { pct in
                    DispatchQueue.main.async { biRefNetStates[model] = .downloading(pct) }
                }
                await MainActor.run {
                    biRefNetStates[model] = .downloaded
                    settings.biRefNetModel = model
                }
            } catch {
                await MainActor.run { biRefNetStates[model] = .failed(error.localizedDescription) }
            }
        }
    }

    private func deleteBiRefNet(_ model: BiRefNetModel) {
        try? model.delete()
        refreshBiRefNetStates()
    }

    // MARK: - 音频

    private var audioTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("分离音轨")

            pathRow(label: "模型存储位置", path: AudioSeparator.supportDir,
                    placeholder: "", defaultDir: AudioSeparator.supportDir) { _ in }

            Text("分离模型")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color.labelSecondary)

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Demucs v4 (6 轨)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color.labelPrimary)
                    Text("分离人声/鼓/贝斯/吉他/钢琴/其他，约 55 MB")
                        .font(.system(size: 10))
                        .foregroundColor(Color.labelSecondary)
                }

                Spacer()

                switch demucsState {
                case .downloaded:
                    Text("已下载")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.green.opacity(0.8))
                        .padding(.horizontal, 8).frame(height: 24)
                        .background(Color.green.opacity(0.1))
                        .cornerRadius(4)
                case .notDownloaded:
                    Button { downloadDemucsModel() } label: {
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
                        Button { downloadDemucsModel() } label: {
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

            if !AudioSeparator.demucsReady {
                Text("未检测到分离组件 demucs.cpp.main，功能暂不可用。")
                    .font(.system(size: 10))
                    .foregroundColor(.orange.opacity(0.8))
            }

            Text("生成哪些音轨")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color.labelSecondary)

            VStack(spacing: 4) {
                ForEach(AudioSeparator.Stem.allCases, id: \.rawValue) { stem in
                    stemRow(stem)
                }
            }


            Text("分离产物")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color.labelSecondary)

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(separatedFiles.isEmpty
                         ? "暂无分离产物"
                         : "\(separatedFiles.count) 个文件 · \(formatBytes(separatedBytes))")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color.labelPrimary)
                    Text(cleanHint ?? "分离出的音频只增不删，清理时会保留当前项目正在使用的文件")
                        .font(.system(size: 10))
                        .foregroundColor(cleanHint == nil ? Color.labelSecondary : Color.accent.opacity(0.9))
                }

                Spacer()

                Button {
                    NSWorkspace.shared.open(AudioSeparator.separatedDir)
                } label: {
                    Text("打开目录")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color.labelPrimary)
                        .padding(.horizontal, 8).frame(height: 24)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .disabled(separatedFiles.isEmpty)
                .opacity(separatedFiles.isEmpty ? 0.4 : 1)

                Button { cleanSeparated() } label: {
                    Text("清理")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color.accent)
                        .padding(.horizontal, 10).frame(height: 24)
                        .background(Color.accent.opacity(0.15))
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .disabled(separatedFiles.isEmpty)
                .opacity(separatedFiles.isEmpty ? 0.4 : 1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.04))
            .cornerRadius(7)
        }
    }

    private func formatBytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    private func refreshSeparated() {
        separatedFiles = AudioSeparator.separatedFiles()
        separatedBytes = AudioSeparator.totalSize(of: separatedFiles)
        // 清理结果只对本次操作有效，重开设置页不该看到上次的残留提示
        cleanHint = nil
    }

    /// 当前项目引用到的文件路径。复合片段递归展平后一起收集——宁可漏删也不能误删
    private func usedFilePaths() -> Set<String> {
        var paths = Set<String>()
        func add(_ url: URL?) {
            if let url { paths.insert(url.standardizedFileURL.path) }
        }
        for asset in project.mediaAssets { add(asset.url) }
        for track in project.audioTracks { for clip in track.clips { add(clip.url) } }
        for track in project.videoTracks { for clip in track.clips { add(clip.url) } }
        for track in project.compoundTracks {
            for compound in track.clips {
                let flat = compound.flattened()
                for sub in flat.audioTracks { for clip in sub.clips { add(clip.url) } }
                for sub in flat.videoTracks { for clip in sub.clips { add(clip.url) } }
            }
        }
        return paths
    }

    private func cleanSeparated() {
        refreshSeparated()
        let used = usedFilePaths()
        let removable = separatedFiles.filter { !used.contains($0.standardizedFileURL.path) }
        guard !removable.isEmpty else {
            cleanHint = "\(separatedFiles.count) 个文件都在当前项目中使用，没有可清理的"
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "清理分离产物"
        alert.informativeText = """
        将把 \(removable.count) 个文件（\(formatBytes(AudioSeparator.totalSize(of: removable)))）移到废纸篓。

        当前项目正在使用的文件会保留，但其他项目引用的文件不在检查范围内。文件在废纸篓里可以还原。
        """
        alert.addButton(withTitle: "移到废纸篓")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let result = AudioSeparator.trashFiles(removable)
        refreshSeparated()
        cleanHint = result.failed == 0
            ? "已把 \(result.moved) 个文件移到废纸篓"
            : "已移出 \(result.moved) 个，\(result.failed) 个失败（详见控制台）"
    }

    private func stemRow(_ stem: AudioSeparator.Stem) -> some View {
        let isOn = settings.separateKeepStems.contains(stem.rawValue)
        return Button {
            var keep = settings.separateKeepStems
            if let idx = keep.firstIndex(of: stem.rawValue) {
                // 至少保留一轨，否则输出会是全静音
                if keep.count > 1 { keep.remove(at: idx) }
            } else {
                keep.append(stem.rawValue)
            }
            settings.separateKeepStems = keep
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundColor(isOn ? Color.accent : Color.labelSecondary.opacity(0.5))

                VStack(alignment: .leading, spacing: 1) {
                    Text(stem.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color.labelPrimary)
                    Text(stem.hint)
                        .font(.system(size: 10))
                        .foregroundColor(Color.labelSecondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.white.opacity(isOn ? 0.06 : 0.02))
            .cornerRadius(7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func refreshDemucsState() {
        if case .downloading = demucsState { return }
        demucsState = AudioSeparator.modelReady ? .downloaded : .notDownloaded
    }

    private func downloadDemucsModel() {
        demucsState = .downloading(0)
        Task {
            do {
                try await AudioSeparator.downloadModel { pct in
                    DispatchQueue.main.async { demucsState = .downloading(pct) }
                }
                await MainActor.run { demucsState = .downloaded }
            } catch {
                await MainActor.run { demucsState = .failed(error.localizedDescription) }
            }
        }
    }

    // MARK: - 字幕

    private var subtitleTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            translateSection

            sectionTitle("语音识别字幕")

            whisperSection

            sectionTitle("字幕转语音")

            ttsSection
        }
    }

    /// 字幕转语音。跟上面的语音识别正好反过来：一个语音变字幕，一个字幕变语音
    private var ttsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("语音合成模型")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color.labelSecondary)

            TTSProviderPicker(selection: Binding(
                get: { settings.ttsProvider },
                set: { settings.ttsProvider = $0 }
            ))

            apiKeyField(
                label: "API Key",
                placeholder: "输入 \(settings.ttsProvider.displayName) API Key",
                text: Binding(
                    get: { settings.providerAPIKey(for: settings.ttsProvider.rawValue) },
                    set: { settings.setProviderAPIKey($0, for: settings.ttsProvider.rawValue) }
                )
            )

            if settings.ttsProvider == .fishAudio {
                fishVoiceSection
            }

            ICapsuleSlider(label: "语速", value: Binding(
                get: { settings.ttsSpeed },
                set: { settings.ttsSpeed = $0 }
            ), range: 0.5...2.0, decimals: 2, unit: "x", labelWidth: 28)

            Button {
                settings.ttsAutoFit.toggle()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: settings.ttsAutoFit ? "checkmark.square.fill" : "square")
                        .font(.system(size: 13))
                        .foregroundColor(settings.ttsAutoFit ? Color.accent : Color.labelSecondary.opacity(0.5))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("自动对齐字幕时长")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color.labelPrimary)
                        Text("生成后把超长的压到字幕长度，变速不变调")
                            .font(.system(size: 10))
                            .foregroundColor(Color.labelSecondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.white.opacity(settings.ttsAutoFit ? 0.06 : 0.02))
                .cornerRadius(7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)


            Text("TTS 语速通常比原声慢，生成的语音多半比字幕长。语速调到 1.1~1.3 可从源头缓解；剩下对不齐的由自动对齐压到位。需要压到 1.6 倍以上的不会强压（太快听不清），完成后会告诉你有几条。")
                .font(.system(size: 10))
                .foregroundColor(Color.labelSecondary.opacity(0.6))
        }
    }

    private var whisperSection: some View {
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

    private var translateSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("字幕翻译")

            SSection(title: "翻译引擎") {
                IPicker(selection: Binding(
                    get: { settings.translateProvider.displayName },
                    set: { name in
                        if let p = AppSettings.TranslateProvider.allCases.first(where: { $0.displayName == name }) {
                            settings.translateProvider = p
                        }
                    }
                ), options: AppSettings.TranslateProvider.allCases.map { ($0.displayName, $0.displayName) }, height: 32)

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

    // MARK: - 视频

    private var sceneDetectTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("智能分割")

            pathRow(label: "组件存储位置", path: SceneDetector.supportDir, placeholder: "", defaultDir: SceneDetector.supportDir) { _ in }

            Text("检测组件")
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


            sectionTitle("清晰度提升")

            ForEach(ClarityModel.allCases) { model in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.displayName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color.labelPrimary)
                        Text(model.sizeDesc)
                            .font(.system(size: 10))
                            .foregroundColor(Color.labelSecondary)
                    }
                    Spacer()
                    clarityModelStatusView(model)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.04))
                .cornerRadius(7)
            }


            sectionTitle("AI 剪辑")

            SSection(title: "") {
                IPicker(selection: Binding(
                    get: { settings.llmProvider.displayName },
                    set: { name in
                        if let p = AppSettings.LLMProvider.allCases.first(where: { $0.displayName == name }) {
                            settings.llmProvider = p
                        }
                    }
                ), options: AppSettings.LLMProvider.allCases.map { ($0.displayName, $0.displayName) }, height: 32)

                apiKeyField(
                    label: "API Key",
                    placeholder: settings.llmProvider.keyPlaceholder,
                    text: Binding(
                        get: { settings.llmAPIKey },
                        set: { settings.llmAPIKey = $0 }
                    )
                )

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

    @ViewBuilder
    private func clarityModelStatusView(_ model: ClarityModel) -> some View {
        let state = clarityModelStates[model] ?? .notDownloaded
        switch state {
        case .downloaded:
            Text("已安装")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.green.opacity(0.8))
                .padding(.horizontal, 8).frame(height: 24)
                .background(Color.green.opacity(0.1))
                .cornerRadius(4)
        case .notDownloaded:
            Button { downloadClarityModel(model) } label: {
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
                Button { downloadClarityModel(model) } label: {
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

    private func refreshClarityModelStates() {
        for model in ClarityModel.allCases {
            if case .downloading = clarityModelStates[model] { continue }
            clarityModelStates[model] = model.isDownloaded ? .downloaded : .notDownloaded
        }
    }

    private func downloadClarityModel(_ model: ClarityModel) {
        clarityModelStates[model] = .downloading(0)
        Task {
            do {
                try await model.download { pct in
                    DispatchQueue.main.async { clarityModelStates[model] = .downloading(pct) }
                }
                await MainActor.run { clarityModelStates[model] = .downloaded }
            } catch {
                await MainActor.run { clarityModelStates[model] = .failed(error.localizedDescription) }
            }
        }
    }

    // MARK: - AI 生成

    private var aiVideoTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("生成模型")

            SSection(title: "") {
                AIProviderPicker(selection: Binding(
                    get: { settings.aiProvider },
                    set: { settings.aiProvider = $0 }
                ))
            }

            if let provider = AIVideoService.Provider(rawValue: settings.aiProvider) {
                if provider == .seedream {
                    apiKeyField(
                        label: "API Key",
                        placeholder: "输入火山方舟 API Key",
                        text: Binding(get: { settings.seedanceApiKey }, set: { settings.seedanceApiKey = $0 })
                    )
                    endpointField(
                        label: "接入点 ID / 模型名",
                        placeholder: "ep-xxxxx 或 doubao-seedream-...",
                        text: Binding(get: { settings.seedreamEndpoint }, set: { settings.seedreamEndpoint = $0 })
                    )
                    Text("与 Seedance 共用火山方舟 API Key；接入点 ID 在「接入点管理」中创建")
                        .font(.system(size: 10))
                        .foregroundColor(Color.labelSecondary.opacity(0.6))
                } else if provider == .seedance || provider == .seedance15 {
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
                } else if provider == .kling {
                    apiKeyField(
                        label: "Access Key",
                        placeholder: "输入 Access Key",
                        text: Binding(get: { settings.aiAccessKey }, set: { settings.aiAccessKey = $0 })
                    )
                    apiKeyField(
                        label: "Secret Key",
                        placeholder: "输入 Secret Key",
                        text: Binding(get: { settings.aiSecretKey }, set: { settings.aiSecretKey = $0 })
                    )
                } else if provider == .runway {
                    apiKeyField(
                        label: "API Key",
                        placeholder: "输入 Runway API Key",
                        text: Binding(get: { settings.aiAccessKey }, set: { settings.aiAccessKey = $0 })
                    )
                } else if provider == .fishAudio {
                    apiKeyField(
                        label: "API Key",
                        placeholder: "输入 Fish Audio API Key",
                        text: Binding(
                            get: { settings.providerAPIKey(for: provider.rawValue) },
                            set: { settings.setProviderAPIKey($0, for: provider.rawValue) }
                        )
                    )
                    fishVoiceSection
                } else {
                    apiKeyField(
                        label: "API Key",
                        placeholder: "输入 \(provider.displayName) API Key",
                        text: Binding(
                            get: { settings.providerAPIKey(for: provider.rawValue) },
                            set: { settings.setProviderAPIKey($0, for: provider.rawValue) }
                        )
                    )
                    if provider.category == .text {
                        Text("文字生成使用标准 Chat Completions 接口")
                            .font(.system(size: 10))
                            .foregroundColor(Color.labelSecondary.opacity(0.6))
                    }
                }
            }

            sectionTitle("联网搜索引擎")

            SSection(title: "") {
                SearchEnginePicker(selection: Binding(
                    get: { settings.searchEngine },
                    set: { settings.searchEngine = $0 }
                ))

                if settings.searchEngine == .bing {
                    apiKeyField(
                        label: "Bing Search Key",
                        placeholder: "输入 Bing Web Search API Key",
                        text: Binding(get: { settings.bingSearchKey }, set: { settings.bingSearchKey = $0 })
                    )
                } else {
                    apiKeyField(
                        label: "Google API Key",
                        placeholder: "输入 Google Custom Search API Key",
                        text: Binding(get: { settings.googleSearchKey }, set: { settings.googleSearchKey = $0 })
                    )
                    apiKeyField(
                        label: "搜索引擎 ID (CX)",
                        placeholder: "输入 Google CX ID",
                        text: Binding(get: { settings.googleSearchCX }, set: { settings.googleSearchCX = $0 })
                    )
                }

                Text("填写后，文字生成模型可开启联网搜索获取实时信息")
                    .font(.system(size: 10))
                    .foregroundColor(Color.labelSecondary.opacity(0.6))
            }

        }
    }

    // MARK: - Fish Audio 音色模型

    private var fishVoiceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("音色模型")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color.labelSecondary)
                Spacer()
                Button {
                    settings.fishVoices.append(AppSettings.FishVoice())
                } label: {
                    Text("+ 添加")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color.accent)
                        .padding(.horizontal, 8).frame(height: 22)
                        .background(Color.accent.opacity(0.15))
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
            }

            ForEach($settings.fishVoices) { $voice in
                fishVoiceRow($voice)
            }

        }
    }

    private func fishVoiceRow(_ voice: Binding<AppSettings.FishVoice>) -> some View {
        let vid = voice.wrappedValue.id
        let isOn = settings.fishSelectedVoice == vid.uuidString
        return HStack(spacing: 6) {
            Button {
                settings.fishSelectedVoice = isOn ? "" : vid.uuidString
            } label: {
                Image(systemName: isOn ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 12))
                    .foregroundColor(isOn ? Color.accent : Color.labelSecondary.opacity(0.5))
            }
            .buttonStyle(.plain)

            TextField("模型 ID", text: voice.modelID)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(Color.labelPrimary)
                .padding(.horizontal, 6)
                .frame(height: 24)
                .background(Color.white.opacity(0.06))
                .cornerRadius(5)

            TextField("备注", text: voice.note)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(Color.labelPrimary)
                .padding(.horizontal, 6)
                .frame(width: 96, height: 24)
                .background(Color.white.opacity(0.06))
                .cornerRadius(5)

            Button {
                // 删的正好是选中项时要一并清掉选中，否则会指向已不存在的音色
                if isOn { settings.fishSelectedVoice = "" }
                settings.fishVoices.removeAll { $0.id == vid }
            } label: {
                Image(nsImage: TimelineSVGIcon.load("delete", size: 12))
                    .renderingMode(.template)
                    .foregroundColor(Color.labelSecondary)
                    .frame(width: 20, height: 24)
            }
            .buttonStyle(.plain)
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
                    Image(nsImage: SidebarSVGIcon.load("folder"))
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 14, height: 14)
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

private struct AIProviderPicker: View {
    @Binding var selection: String
    @State private var hov = false

    private var currentLabel: String {
        AIVideoService.Provider(rawValue: selection)?.displayName ?? selection
    }

    var body: some View {
        Button(action: showMenu) {
            HStack(spacing: 6) {
                Text(currentLabel)
                    .font(.system(size: 12))
                    .foregroundColor(Color.labelPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Color.labelSecondary)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32)
            .background(Color.white.opacity(hov ? 0.10 : 0.06))
            .cornerRadius(7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hov = $0 }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.minimumWidth = 220
        IPickerItemHandler.shared.actions.removeAll()
        var tag = 0
        for cat in AIVideoService.ProviderCategory.allCases {
            let header = NSMenuItem(title: cat.rawValue, action: nil, keyEquivalent: "")
            header.isEnabled = false
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            header.attributedTitle = NSAttributedString(string: cat.rawValue, attributes: attrs)
            menu.addItem(header)

            for provider in AIVideoService.Provider.providers(for: cat) {
                let item = NSMenuItem(title: provider.displayName,
                                      action: #selector(IPickerItemHandler.pick(_:)),
                                      keyEquivalent: "")
                item.target = IPickerItemHandler.shared
                item.tag = tag
                item.indentationLevel = 1
                let sel = selection
                IPickerItemHandler.shared.actions[tag] = { [self] in selection = provider.rawValue }
                let title = NSMutableAttributedString(string: provider.displayName, attributes: [
                    .font: NSFont.systemFont(ofSize: 13)
                ])
                if provider.rawValue == sel {
                    title.append(NSAttributedString(string: "  ✓", attributes: [
                        .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                        .foregroundColor: NSColor.white
                    ]))
                }
                item.attributedTitle = title
                menu.addItem(item)
                tag += 1
            }
            menu.addItem(.separator())
        }
        if menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.numberOfItems - 1) }
        let view = NSApp.keyWindow?.contentView ?? NSView()
        if let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        } else {
            menu.popUp(positioning: nil, at: .zero, in: view)
        }
    }
}

private struct TTSProviderPicker: View {
    @Binding var selection: AIVideoService.Provider
    @State private var hov = false

    var body: some View {
        Button(action: showMenu) {
            HStack(spacing: 6) {
                Text(selection.displayName)
                    .font(.system(size: 12))
                    .foregroundColor(Color.labelPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Color.labelSecondary)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32)
            .background(Color.white.opacity(hov ? 0.10 : 0.06))
            .cornerRadius(7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hov = $0 }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.minimumWidth = 180
        IPickerItemHandler.shared.actions.removeAll()
        for (tag, p) in AppSettings.ttsProviders.enumerated() {
            let item = NSMenuItem(title: p.displayName,
                                  action: #selector(IPickerItemHandler.pick(_:)),
                                  keyEquivalent: "")
            item.target = IPickerItemHandler.shared
            item.tag = tag
            IPickerItemHandler.shared.actions[tag] = { [self] in selection = p }
            let title = NSMutableAttributedString(string: p.displayName, attributes: [
                .font: NSFont.systemFont(ofSize: 13)
            ])
            if p == selection {
                title.append(NSAttributedString(string: "  ✓", attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: NSColor.white
                ]))
            }
            item.attributedTitle = title
            menu.addItem(item)
        }
        guard let view = NSApp.keyWindow?.contentView else { return }
        if let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        } else {
            menu.popUp(positioning: nil, at: .zero, in: view)
        }
    }
}

private struct BGEnginePicker: View {
    @Binding var selection: BackgroundRemover.Engine
    @State private var hov = false

    var body: some View {
        Button(action: showMenu) {
            HStack(spacing: 6) {
                Text(selection.label)
                    .font(.system(size: 12))
                    .foregroundColor(Color.labelPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Color.labelSecondary)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32)
            .background(Color.white.opacity(hov ? 0.10 : 0.06))
            .cornerRadius(7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hov = $0 }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.minimumWidth = 180
        IPickerItemHandler.shared.actions.removeAll()
        for (tag, eng) in BackgroundRemover.Engine.allCases.enumerated() {
            let item = NSMenuItem(title: eng.label,
                                  action: #selector(IPickerItemHandler.pick(_:)),
                                  keyEquivalent: "")
            item.target = IPickerItemHandler.shared
            item.tag = tag
            IPickerItemHandler.shared.actions[tag] = { [self] in selection = eng }
            let title = NSMutableAttributedString(string: eng.label, attributes: [
                .font: NSFont.systemFont(ofSize: 13)
            ])
            if eng == selection {
                title.append(NSAttributedString(string: "  ✓", attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: NSColor.white
                ]))
            }
            item.attributedTitle = title
            menu.addItem(item)
        }
        guard let view = NSApp.keyWindow?.contentView else { return }
        if let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        } else {
            menu.popUp(positioning: nil, at: .zero, in: view)
        }
    }
}

private struct SearchEnginePicker: View {
    @Binding var selection: AppSettings.SearchEngine
    @State private var hov = false

    var body: some View {
        Button(action: showMenu) {
            HStack(spacing: 6) {
                Text(selection.rawValue)
                    .font(.system(size: 12))
                    .foregroundColor(Color.labelPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Color.labelSecondary)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32)
            .background(Color.white.opacity(hov ? 0.10 : 0.06))
            .cornerRadius(7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hov = $0 }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.minimumWidth = 180
        IPickerItemHandler.shared.actions.removeAll()
        for (tag, eng) in AppSettings.SearchEngine.allCases.enumerated() {
            let item = NSMenuItem(title: eng.rawValue,
                                  action: #selector(IPickerItemHandler.pick(_:)),
                                  keyEquivalent: "")
            item.target = IPickerItemHandler.shared
            item.tag = tag
            IPickerItemHandler.shared.actions[tag] = { [self] in selection = eng }
            let title = NSMutableAttributedString(string: eng.rawValue, attributes: [
                .font: NSFont.systemFont(ofSize: 13)
            ])
            if eng == selection {
                title.append(NSAttributedString(string: "  ✓", attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: NSColor.white
                ]))
            }
            item.attributedTitle = title
            menu.addItem(item)
        }

        guard let view = NSApp.keyWindow?.contentView else { return }
        if let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        } else {
            menu.popUp(positioning: nil, at: .zero, in: view)
        }
    }
}
