import Foundation

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let ud = UserDefaults.standard

    // MARK: - Keys

    private enum K {
        static let projectDir = "settings.projectSaveDir"
        static let exportDir = "settings.exportSaveDir"
        static let autoSaveInterval = "settings.autoSaveInterval"
        static let whisperModelDir = "settings.whisperModelDir"
        static let whisperModel = "settings.whisperModel"
        static let translateProvider = "settings.translateProvider"
        static let deeplAPIKey = "settings.translate.deepl.key"
        static let youdaoAppKey = "settings.translate.youdao.appKey"
        static let youdaoAppSecret = "settings.translate.youdao.appSecret"
        static let volcanoAccessKeyId = "settings.translate.volcano.accessKeyId"
        static let volcanoSecretAccessKey = "settings.translate.volcano.secretAccessKey"
        static let aiAccessKey = "settings.ai.accessKey"
        static let aiSecretKey = "settings.ai.secretKey"
        static let aiProvider = "settings.ai.provider"
        static let aiDuration = "settings.ai.duration"
        static let aiRatio = "settings.ai.ratio"
        static let aiResolution = "settings.ai.resolution"
        static let aiImageRatio = "settings.ai.imageRatio"
        static let separateKeepStems = "settings.audio.separateKeepStems"
        static let seedanceApiKey = "settings.ai.seedance.apiKey"
        static let seedanceEndpoint = "settings.ai.seedance.endpoint"
        static let llmBaseURL = "settings.llm.baseurl"
        /// 自定义 Base URL 的 key 前缀（按供应商存），留空表示走官方端点
        static func providerBaseURL(_ provider: String) -> String { "settings.ai.baseurl.\(provider)" }
        /// 自定义模型名（按供应商存），留空表示用该家的默认模型
        static func providerModel(_ provider: String) -> String { "settings.ai.model.\(provider)" }
        /// 推理强度（按供应商存），留空表示用该家默认
        static func providerReasoning(_ provider: String) -> String { "settings.ai.reasoning.\(provider)" }
        static let seedance15Endpoint = "settings.ai.seedance15.endpoint"
        static let seedance25Endpoint = "settings.ai.seedance25.endpoint"
        static let nanobananaEndpoint = "settings.ai.nanobanana.endpoint"
        static let nanobananaProEndpoint = "settings.ai.nanobananapro.endpoint"
        static let minimaxGroupID = "settings.ai.minimax.groupid"
        static let seedreamEndpoint = "settings.ai.seedream.endpoint"
        static let llmProvider = "settings.llm.provider"
        static let llmAPIKey = "settings.llm.apiKey"
        static let searchEngine = "settings.ai.searchEngine"
        static let bingSearchKey = "settings.ai.bing.searchKey"
        static let googleSearchKey = "settings.ai.google.searchKey"
        static let googleSearchCX = "settings.ai.google.searchCX"
        static let braveSearchKey = "settings.ai.brave.searchKey"
        static let tavilySearchKey = "settings.ai.tavily.searchKey"
        static let fishVoices = "settings.ai.fish.voices"
        static let fishSelectedVoice = "settings.ai.fish.selectedVoice"
        static let bgRemovalEngine = "settings.image.bgRemovalEngine"
        static let clarityEngine = "settings.video.clarityEngine"
        static let falAPIKey = "settings.video.fal.apiKey"
        static let ttsProvider = "settings.subtitle.ttsProvider"
        static let ttsSpeed = "settings.subtitle.ttsSpeed"
        static let ttsAutoFit = "settings.subtitle.ttsAutoFit"
        static let biRefNetModel = "settings.image.biRefNetModel"
    }

    // MARK: - Fish Audio 音色模型

    /// 用户在 Fish Audio 自建/收藏的音色。modelID 就是接口的 reference_id，note 是自己标的名字
    struct FishVoice: Codable, Identifiable, Equatable {
        var id = UUID()
        var modelID: String = ""
        var note: String = ""
    }

    // MARK: - 文件保存位置

    @Published var projectSaveDir: URL? {
        didSet { ud.set(projectSaveDir?.path, forKey: K.projectDir) }
    }

    @Published var exportSaveDir: URL? {
        didSet { ud.set(exportSaveDir?.path, forKey: K.exportDir) }
    }

    static let defaultSaveDir = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!

    var effectiveProjectDir: URL { projectSaveDir ?? Self.defaultSaveDir }
    var effectiveExportDir: URL { exportSaveDir ?? Self.defaultSaveDir }

    // MARK: - 自动保存频率（秒，0 = 关闭）

    @Published var autoSaveInterval: Double {
        didSet { ud.set(autoSaveInterval, forKey: K.autoSaveInterval) }
    }

    static let autoSaveOptions: [(label: String, value: Double)] = [
        ("关闭", 0),
        ("30 秒", 30),
        ("1 分钟", 60),
        ("3 分钟", 180),
        ("5 分钟", 300),
    ]

    // MARK: - 语音识别模型

    @Published var whisperModelDir: URL? {
        didSet { ud.set(whisperModelDir?.path, forKey: K.whisperModelDir) }
    }

    @Published var selectedWhisperModel: WhisperTranscriber.ModelSize {
        didSet { ud.set(selectedWhisperModel.rawValue, forKey: K.whisperModel) }
    }

    // MARK: - 翻译来源

    enum TranslateProvider: String, CaseIterable {
        case google = "Google Translate"
        case deepL = "DeepL"
        case apple = "Apple Translate"
        case youdao = "Youdao"
        case volcano = "Volcano"

        var displayName: String {
            switch self {
            case .google: return "Google 翻译"
            case .deepL: return "DeepL 翻译"
            case .apple: return "Apple 翻译"
            case .youdao: return "有道翻译"
            case .volcano: return "火山翻译"
            }
        }

        var needsAPIKey: Bool {
            switch self {
            case .google, .apple: return false
            case .deepL, .youdao, .volcano: return true
            }
        }

        var needsSecretKey: Bool {
            switch self {
            case .youdao, .volcano: return true
            default: return false
            }
        }

        var keyLabel: String {
            switch self {
            case .deepL: return "API Key"
            case .youdao: return "应用 ID"
            case .volcano: return "Access Key ID"
            default: return ""
            }
        }

        var secretLabel: String {
            switch self {
            case .youdao: return "应用密钥"
            case .volcano: return "Secret Access Key"
            default: return ""
            }
        }

        var keyPlaceholder: String {
            switch self {
            case .deepL: return "xxxxxxxx-xxxx-...:fx"
            case .youdao: return "输入应用 ID"
            case .volcano: return "输入 Access Key ID"
            default: return ""
            }
        }

        var secretPlaceholder: String {
            switch self {
            case .youdao: return "输入应用密钥"
            case .volcano: return "输入 Secret Access Key"
            default: return ""
            }
        }
    }

    @Published var translateProvider: TranslateProvider {
        didSet { ud.set(translateProvider.rawValue, forKey: K.translateProvider) }
    }

    @Published var deeplAPIKey: String {
        didSet { ud.set(deeplAPIKey, forKey: K.deeplAPIKey) }
    }
    @Published var youdaoAppKey: String {
        didSet { ud.set(youdaoAppKey, forKey: K.youdaoAppKey) }
    }
    @Published var youdaoAppSecret: String {
        didSet { ud.set(youdaoAppSecret, forKey: K.youdaoAppSecret) }
    }
    @Published var volcanoAccessKeyId: String {
        didSet { ud.set(volcanoAccessKeyId, forKey: K.volcanoAccessKeyId) }
    }
    @Published var volcanoSecretAccessKey: String {
        didSet { ud.set(volcanoSecretAccessKey, forKey: K.volcanoSecretAccessKey) }
    }

    // MARK: - 大模型分析

    /// 跟 AI 生成面板的文字类模型保持同一组（Claude / GPT / DeepSeek / 通义千问 / 智谱 GLM）
    enum LLMProvider: String, CaseIterable {
        case claude = "Claude"
        case openai = "OpenAI"
        case deepseek = "DeepSeek"
        case qwen = "Qwen"
        case glm = "GLM"
        case grok = "Grok"
        case kimi = "Kimi"

        var displayName: String {
            switch self {
            case .openai: return "Chatgpt"
            case .claude: return "Claude"
            case .deepseek: return "DeepSeek"
            case .qwen: return "Qwen"
            case .glm: return "Glm"
            case .grok: return "Grok"
            case .kimi: return "Kimi"
            }
        }

        var defaultModel: String {
            switch self {
            case .openai: return "gpt-4o-mini"
            case .claude: return "claude-sonnet-4-20250514"
            case .deepseek: return "deepseek-chat"
            case .qwen: return "qwen-max"
            case .glm: return "glm-4-flash"
            case .grok: return "grok-4.6"
            case .kimi: return "kimi-k3"
            }
        }

        /// 官方端点。实际请求走 `AppSettings.shared.effectiveLLMBaseURL`，
        /// 设置里填了自定义地址时以那个为准
        var baseURL: String {
            switch self {
            case .openai: return "https://api.openai.com/v1/chat/completions"
            case .claude: return "https://api.anthropic.com/v1/messages"
            case .deepseek: return "https://api.deepseek.com/chat/completions"
            case .qwen: return "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
            case .glm: return "https://open.bigmodel.cn/api/paas/v4/chat/completions"
            case .grok: return "https://api.x.ai/v1/chat/completions"
            case .kimi: return "https://api.moonshot.cn/v1/chat/completions"
            }
        }

        /// 对应 AI 生成面板里的供应商 key。两套配置共用同一份
        /// API Key / 接口地址 / 模型名 —— 在任一处填写，另一处自动生效
        var sharedProviderKey: String {
            switch self {
            case .claude:   return "claude"
            case .openai:   return "gpt-5.6"
            case .deepseek: return "deepseek-ai"
            case .qwen:     return "qwen"
            case .glm:      return "glm"
            case .grok:     return "grok"
            case .kimi:     return "kimi"
            }
        }

        var keyPlaceholder: String {
            switch self {
            case .openai: return "sk-..."
            case .claude: return "sk-ant-..."
            case .deepseek: return "sk-..."
            case .qwen: return "sk-..."
            case .glm: return "输入 API Key"
            case .grok: return "xai-..."
            case .kimi: return "sk-..."
            }
        }
    }

    /// 「视频分析」这套 LLM 的自定义接口地址（留空走官方）。
    /// 跟 AI 生成面板是两套独立配置，互不影响
    /// 同上，跟 AI 生成面板共享
    var llmModel: String {
        get { providerModel(for: llmProvider.sharedProviderKey) }
        set { setProviderModel(newValue, for: llmProvider.sharedProviderKey) }
    }

    /// 实际请求用的模型名
    var effectiveLLMModel: String {
        let custom = llmModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? llmProvider.defaultModel : custom
    }

    /// 同上，跟 AI 生成面板共享
    var llmBaseURL: String {
        get { providerBaseURL(for: llmProvider.sharedProviderKey) }
        set { setProviderBaseURL(newValue, for: llmProvider.sharedProviderKey) }
    }

    /// 实际发请求用的地址
    var effectiveLLMBaseURL: String {
        // 用户可能只填 base（https://api.apikey.fun）—— 补上该家的标准路径，
        // 否则请求打到根路径，返回的不是 JSON，报「数据格式不正确」
        let path = llmProvider == .claude ? "/v1/messages" : "/v1/chat/completions"
        let custom = AIVideoService.normalizedEndpoint(llmBaseURL, defaultPath: path)
        return custom.isEmpty ? llmProvider.baseURL : custom
    }

    @Published var llmProvider: LLMProvider {
        didSet { ud.set(llmProvider.rawValue, forKey: K.llmProvider) }
    }

    /// 「视频分析」的 API Key —— 实际读写的是**按供应商共享**的那份，
    /// 跟 AI 生成面板同一个存储位置：任一处填写，另一处自动生效
    var llmAPIKey: String {
        get { providerAPIKey(for: llmProvider.sharedProviderKey) }
        set { setProviderAPIKey(newValue, for: llmProvider.sharedProviderKey) }
    }

    // MARK: - AI 视频生成

    @Published var aiAccessKey: String {
        didSet { ud.set(aiAccessKey, forKey: K.aiAccessKey) }
    }
    @Published var aiSecretKey: String {
        didSet { ud.set(aiSecretKey, forKey: K.aiSecretKey) }
    }
    @Published var aiProvider: String {
        didSet { ud.set(aiProvider, forKey: K.aiProvider) }
    }
    @Published var aiDuration: String {
        didSet { ud.set(aiDuration, forKey: K.aiDuration) }
    }
    @Published var aiRatio: String {
        didSet { ud.set(aiRatio, forKey: K.aiRatio) }
    }
    @Published var aiResolution: String {
        didSet { ud.set(aiResolution, forKey: K.aiResolution) }
    }
    /// 图片生成比例，与视频比例独立存储，避免切模型时互相覆盖
    @Published var aiImageRatio: String {
        didSet { ud.set(aiImageRatio, forKey: K.aiImageRatio) }
    }
    /// 去背景音乐时保留哪些分离轨（存 Stem 的 rawValue）。
    /// 默认 人声 + 其他 + 鼓：打击类音效（脚步/关门/撞击）会被模型归到 drums，
    /// 不保留 drums 的话这些音效会跟着音乐一起消失。
    @Published var separateKeepStems: [Int] {
        didSet { ud.set(separateKeepStems, forKey: K.separateKeepStems) }
    }
    @Published var seedanceApiKey: String {
        didSet { ud.set(seedanceApiKey, forKey: K.seedanceApiKey) }
    }
    /// 推理强度。留空 = 用该家默认（各家档位见 Provider.reasoningLevels）
    func providerReasoning(for provider: String) -> String {
        ud.string(forKey: K.providerReasoning(provider)) ?? ""
    }

    func setProviderReasoning(_ level: String, for provider: String) {
        ud.set(level, forKey: K.providerReasoning(provider))
        objectWillChange.send()
    }

    /// 供应商的自定义模型名。留空 = 用该家的默认模型。
    /// 用来切子模型（claude-opus-5 / claude-sonnet-5 …），
    /// 也用于中转站 —— 它们暴露的模型名常跟官方不一致
    func providerModel(for provider: String) -> String {
        ud.string(forKey: K.providerModel(provider)) ?? ""
    }

    func setProviderModel(_ model: String, for provider: String) {
        ud.set(model, forKey: K.providerModel(provider))
        objectWillChange.send()
    }

    /// 供应商的自定义 Base URL。留空 = 用官方端点。
    /// 给第三方中转/代理用 —— 它们基本都兼容 OpenAI 的 Chat Completions 格式，
    /// 填个 `https://xxx/v1/chat/completions` 就能走通
    func providerBaseURL(for provider: String) -> String {
        ud.string(forKey: K.providerBaseURL(provider)) ?? ""
    }

    func setProviderBaseURL(_ url: String, for provider: String) {
        ud.set(url, forKey: K.providerBaseURL(provider))
        objectWillChange.send()
    }

    @Published var seedanceEndpoint: String {
        didSet { ud.set(seedanceEndpoint, forKey: K.seedanceEndpoint) }
    }
    @Published var seedance25Endpoint: String {
        didSet { ud.set(seedance25Endpoint, forKey: K.seedance25Endpoint) }
    }
    @Published var nanobananaEndpoint: String {
        didSet { ud.set(nanobananaEndpoint, forKey: K.nanobananaEndpoint) }
    }
    @Published var nanobananaProEndpoint: String {
        didSet { ud.set(nanobananaProEndpoint, forKey: K.nanobananaProEndpoint) }
    }
    /// MiniMax 的 GroupId —— TTS 接口要它，视频接口不用
    @Published var minimaxGroupID: String {
        didSet { ud.set(minimaxGroupID, forKey: K.minimaxGroupID) }
    }
    @Published var seedance15Endpoint: String {
        didSet { ud.set(seedance15Endpoint, forKey: K.seedance15Endpoint) }
    }
    @Published var seedreamEndpoint: String {
        didSet { ud.set(seedreamEndpoint, forKey: K.seedreamEndpoint) }
    }

    // MARK: - 联网搜索

    enum SearchEngine: String, CaseIterable {
        case brave = "Brave"
        case tavily = "Tavily"
    }

    @Published var searchEngine: SearchEngine = .brave {
        didSet { ud.set(searchEngine.rawValue, forKey: K.searchEngine) }
    }
    @Published var braveSearchKey: String {
        didSet { ud.set(braveSearchKey, forKey: K.braveSearchKey) }
    }
    @Published var tavilySearchKey: String {
        didSet { ud.set(tavilySearchKey, forKey: K.tavilySearchKey) }
    }
    @Published var bingSearchKey: String {
        didSet { ud.set(bingSearchKey, forKey: K.bingSearchKey) }
    }
    @Published var googleSearchKey: String {
        didSet { ud.set(googleSearchKey, forKey: K.googleSearchKey) }
    }
    @Published var googleSearchCX: String {
        didSet { ud.set(googleSearchCX, forKey: K.googleSearchCX) }
    }

    @Published var fishVoices: [FishVoice] {
        didSet { ud.set((try? JSONEncoder().encode(fishVoices)) ?? Data(), forKey: K.fishVoices) }
    }

    /// 选中音色的 UUID 字符串。空串或找不到对应项时走服务端默认音色
    @Published var fishSelectedVoice: String {
        didSet { ud.set(fishSelectedVoice, forKey: K.fishSelectedVoice) }
    }

    /// 字幕转语音用的模型。跟 AI 面板的 aiProvider 分开存 ——
    /// 那个多半选的是视频模型，混用会互相打架
    @Published var ttsProvider: AIVideoService.Provider {
        didSet { ud.set(ttsProvider.rawValue, forKey: K.ttsProvider) }
    }

    /// 当前 TTS 供应商；存量配置指向已隐藏的那家时退回可选清单的第一项，
    /// 否则界面显示着一个下拉里根本没有的名字，选不回来
    var effectiveTTSProvider: AIVideoService.Provider {
        Self.ttsProviders.contains(ttsProvider) ? ttsProvider : (Self.ttsProviders.first ?? ttsProvider)
    }

    /// 语速倍率。三家 TTS 都支持，只是参数路径不同：
    /// Fish Audio 是 prosody.speed，OpenAI 是 speed，ElevenLabs 是 voice_settings.speed
    @Published var ttsSpeed: Double {
        didSet { ud.set(ttsSpeed, forKey: K.ttsSpeed) }
    }

    /// 生成后是否自动变速对齐字幕时长
    @Published var ttsAutoFit: Bool {
        didSet { ud.set(ttsAutoFit, forKey: K.ttsAutoFit) }
    }

    /// 可选的语音模型
    /// 跟「AI 设置」里声音生成那栏用同一份清单 —— 那边隐藏掉的，这里也不该还能选
    static var ttsProviders: [AIVideoService.Provider] {
        AIVideoService.Provider.providers(for: .audio)
    }

    /// 图片去背使用的模型
    @Published var bgRemovalEngine: BackgroundRemover.Engine {
        didSet { ud.set(bgRemovalEngine.rawValue, forKey: K.bgRemovalEngine) }
    }

    /// 清晰度提升用哪个超分引擎
    enum ClarityEngine: String, CaseIterable {
        case system         // 系统自带（VTSuperResolutionScaler，macOS 26+）
        case builtIn        // 随 app 走的 FSRCNN
        case generalX4V3    // 本地 Real-ESRGAN general-x4v3：实拍
        case animeVideoV3   // 本地 Real-ESRGAN animevideov3：动漫·快
        case realCUGAN      // 本地 Real-CUGAN up4x：动漫·质量
        case flashVSR       // 云端 fal.ai：阿里 FlashVSR
        case seedVR2        // 云端 fal.ai：字节 SeedVR2

        var label: String {
            switch self {
            case .system:        return "系统超分"
            case .builtIn:       return "轻量超分"
            case .generalX4V3:   return "实拍增强"
            case .animeVideoV3:  return "动漫增强（快）"
            case .realCUGAN:     return "动漫增强（质量优先）"
            case .flashVSR:      return "FlashVSR（云端）"
            case .seedVR2:       return "SeedVR2（云端）"
            }
        }

        /// 下拉里的分组。同组的连着排，组间画一条分隔线
        enum Group { case local, cloud }
        var group: Group { isCloud ? .cloud : .local }

        /// 走本地 CoreML 模型的引擎对应哪个模型（系统超分和云端为 nil）。
        /// Real-CUGAN 有 2 倍和 4 倍两套权重，得按用户点的倍数取；
        /// 另外两个只有 x4，传什么倍数都返回同一个
        func proModel(scale: Int = 4) -> ClarityProModel? {
            switch self {
            case .generalX4V3:  return .generalX4V3
            case .animeVideoV3: return .animeVideoV3
            case .realCUGAN:    return scale == 2 ? .realCUGAN2x : .realCUGAN
            case .system, .builtIn, .flashVSR, .seedVR2: return nil
            }
        }

        /// 这个引擎用不用本地 CoreML 模型。只是判断类别，不涉及具体倍数
        var usesProModel: Bool { proModel() != nil }

        var hint: String {
            switch self {
            case .system:
                return "画质更好；只支持放大 4 倍，素材分辨率需在 1920×1080 以内，要求 macOS 26 及以上"
            case .builtIn:
                return "随应用附带的轻量模型，速度快、任何系统都能用，但画质提升有限（接近高质量插值放大）"
            case .generalX4V3:
                return "适合真人拍摄、纪录片、老录像，只支持放大 4 倍"
            case .animeVideoV3:
                return "适合动画片、二次元视频，本地引擎里速度最快，只支持放大 4 倍"
            case .realCUGAN:
                return "线条更锐利、保留景深虚化，比上一档慢一些，只支持放大 4 倍"
            case .flashVSR:
                return "适合真实拍摄素材和长片段"
            case .seedVR2:
                return "适合 AI 生成视频和重压缩素材"
            }
        }

        /// 走 fal.ai 云端跑的引擎——要 API Key、要联网、按量计费
        var isCloud: Bool { self == .flashVSR || self == .seedVR2 }

        /// fal.ai 上的 endpoint id（本地引擎为 nil）
        var falEndpoint: String? {
            switch self {
            case .flashVSR: return "fal-ai/flashvsr/upscale/video"
            case .seedVR2:  return "fal-ai/seedvr/upscale/video"
            case .system, .builtIn, .generalX4V3, .animeVideoV3, .realCUGAN: return nil
            }
        }

        /// 能不能选 2 倍。系统超分是 VTSuperResolutionScaler 的硬限制；
        /// Real-ESRGAN 那两个轻量分支上游只发布了 x4 权重，补不了
        var supportsX2: Bool {
            switch self {
            case .builtIn, .flashVSR, .seedVR2, .realCUGAN: return true
            case .system, .generalX4V3, .animeVideoV3: return false
            }
        }
    }

    @Published var clarityEngine: ClarityEngine {
        didSet { ud.set(clarityEngine.rawValue, forKey: K.clarityEngine) }
    }

    /// fal.ai 的 API Key，云端超分引擎用。跟其他云服务的 Key 一样存 UserDefaults
    @Published var falAPIKey: String {
        didSet { ud.set(falAPIKey, forKey: K.falAPIKey) }
    }

    /// 选用 BiRefNet 时具体用哪个权重
    @Published var biRefNetModel: BiRefNetModel {
        didSet { ud.set(biRefNetModel.rawValue, forKey: K.biRefNetModel) }
    }

    /// 生成时实际要传的 reference_id。空串表示不传该字段
    var fishActiveModelID: String {
        guard let v = fishVoices.first(where: { $0.id.uuidString == fishSelectedVoice }) else { return "" }
        return v.modelID.trimmingCharacters(in: .whitespaces)
    }

    func providerAPIKey(for provider: String) -> String {
        ud.string(forKey: "settings.ai.providerKey.\(provider)") ?? ""
    }

    func setProviderAPIKey(_ key: String, for provider: String) {
        ud.set(key, forKey: "settings.ai.providerKey.\(provider)")
        // 延后一拍再通知。在输入框 setter 里同步 send 会当场重建输入框，
        // 字就打不进去了（见 SettingsView.APIKeyField 的说明）
        DispatchQueue.main.async { [weak self] in self?.objectWillChange.send() }
    }

    // MARK: - Init

    private init() {
        if let p = ud.string(forKey: K.projectDir) { projectSaveDir = URL(fileURLWithPath: p) }
        else { projectSaveDir = nil }

        if let p = ud.string(forKey: K.exportDir) { exportSaveDir = URL(fileURLWithPath: p) }
        else { exportSaveDir = nil }

        let interval = ud.double(forKey: K.autoSaveInterval)
        autoSaveInterval = interval > 0 ? interval : 3.0

        if let p = ud.string(forKey: K.whisperModelDir) { whisperModelDir = URL(fileURLWithPath: p) }
        else { whisperModelDir = nil }

        if let raw = ud.string(forKey: K.whisperModel),
           let model = WhisperTranscriber.ModelSize(rawValue: raw) {
            selectedWhisperModel = model
        } else {
            selectedWhisperModel = .small
        }

        if let raw = ud.string(forKey: K.translateProvider),
           let prov = TranslateProvider(rawValue: raw) {
            translateProvider = prov
        } else {
            translateProvider = .google
        }

        if let d = ud.data(forKey: K.fishVoices),
           let list = try? JSONDecoder().decode([FishVoice].self, from: d) {
            fishVoices = list
        } else {
            fishVoices = []
        }
        fishSelectedVoice = ud.string(forKey: K.fishSelectedVoice) ?? ""
        bgRemovalEngine = BackgroundRemover.Engine(rawValue: ud.string(forKey: K.bgRemovalEngine) ?? "") ?? .system
        // 没存过时按这台机器的能力挑默认：能跑系统超分就用它（画质差距明显），
        // 否则回落到随包的轻量模型
        if let saved = ClarityEngine(rawValue: ud.string(forKey: K.clarityEngine) ?? "") {
            clarityEngine = saved
        } else if #available(macOS 26.0, *), AppleSuperResolution.isSupported {
            clarityEngine = .system
        } else {
            clarityEngine = .builtIn
        }
        falAPIKey = ud.string(forKey: K.falAPIKey) ?? ""
        ttsProvider = AIVideoService.Provider(rawValue: ud.string(forKey: K.ttsProvider) ?? "")
            .flatMap { $0.category == .audio ? $0 : nil } ?? .fishAudio
        let savedSpeed = ud.double(forKey: K.ttsSpeed)
        ttsSpeed = savedSpeed > 0 ? savedSpeed : 1.0
        ttsAutoFit = ud.object(forKey: K.ttsAutoFit) as? Bool ?? true
        biRefNetModel = BiRefNetModel(rawValue: ud.string(forKey: K.biRefNetModel) ?? "") ?? .lite

        deeplAPIKey = ud.string(forKey: K.deeplAPIKey) ?? ""
        youdaoAppKey = ud.string(forKey: K.youdaoAppKey) ?? ""
        youdaoAppSecret = ud.string(forKey: K.youdaoAppSecret) ?? ""
        volcanoAccessKeyId = ud.string(forKey: K.volcanoAccessKeyId) ?? ""
        volcanoSecretAccessKey = ud.string(forKey: K.volcanoSecretAccessKey) ?? ""

        aiAccessKey = ud.string(forKey: K.aiAccessKey) ?? ""
        aiSecretKey = ud.string(forKey: K.aiSecretKey) ?? ""
        aiProvider = ud.string(forKey: K.aiProvider) ?? "kling"
        aiDuration = ud.string(forKey: K.aiDuration) ?? "5"
        aiRatio = ud.string(forKey: K.aiRatio) ?? "16:9"
        aiResolution = ud.string(forKey: K.aiResolution) ?? "720P"
        aiImageRatio = ud.string(forKey: K.aiImageRatio) ?? "1:1"
        separateKeepStems = (ud.array(forKey: K.separateKeepStems) as? [Int]) ?? [3, 2, 0]
        seedanceApiKey = ud.string(forKey: K.seedanceApiKey) ?? ""
        seedanceEndpoint = ud.string(forKey: K.seedanceEndpoint) ?? ""
        seedance15Endpoint = ud.string(forKey: K.seedance15Endpoint) ?? ""
        seedance25Endpoint = ud.string(forKey: K.seedance25Endpoint) ?? ""
        nanobananaEndpoint = ud.string(forKey: K.nanobananaEndpoint) ?? ""
        nanobananaProEndpoint = ud.string(forKey: K.nanobananaProEndpoint) ?? ""
        minimaxGroupID = ud.string(forKey: K.minimaxGroupID) ?? ""
        seedreamEndpoint = ud.string(forKey: K.seedreamEndpoint) ?? ""

        if let raw = ud.string(forKey: K.llmProvider),
           let prov = LLMProvider(rawValue: raw) {
            llmProvider = prov
        } else {
            llmProvider = .deepseek
        }

        if let raw = ud.string(forKey: K.searchEngine),
           let eng = SearchEngine(rawValue: raw) {
            searchEngine = eng
        } else {
            searchEngine = .brave
        }
        bingSearchKey = ud.string(forKey: K.bingSearchKey) ?? ""
        googleSearchKey = ud.string(forKey: K.googleSearchKey) ?? ""
        braveSearchKey = ud.string(forKey: K.braveSearchKey) ?? ""
        tavilySearchKey = ud.string(forKey: K.tavilySearchKey) ?? ""
        googleSearchCX = ud.string(forKey: K.googleSearchCX) ?? ""
    }
}
