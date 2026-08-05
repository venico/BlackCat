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
        static let seedance15Endpoint = "settings.ai.seedance15.endpoint"
        static let seedreamEndpoint = "settings.ai.seedream.endpoint"
        static let llmProvider = "settings.llm.provider"
        static let llmAPIKey = "settings.llm.apiKey"
        static let searchEngine = "settings.ai.searchEngine"
        static let bingSearchKey = "settings.ai.bing.searchKey"
        static let googleSearchKey = "settings.ai.google.searchKey"
        static let googleSearchCX = "settings.ai.google.searchCX"
        static let fishVoices = "settings.ai.fish.voices"
        static let fishSelectedVoice = "settings.ai.fish.selectedVoice"
        static let bgRemovalEngine = "settings.image.bgRemovalEngine"
        static let clarityEngine = "settings.video.clarityEngine"
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

    enum LLMProvider: String, CaseIterable {
        case openai = "OpenAI"
        case claude = "Claude"
        case deepseek = "DeepSeek"
        case glm = "GLM"

        var displayName: String {
            switch self {
            case .openai: return "OpenAI"
            case .claude: return "Claude"
            case .deepseek: return "DeepSeek"
            case .glm: return "智谱 GLM"
            }
        }

        var defaultModel: String {
            switch self {
            case .openai: return "gpt-4o-mini"
            case .claude: return "claude-sonnet-4-20250514"
            case .deepseek: return "deepseek-chat"
            case .glm: return "glm-4-flash"
            }
        }

        var baseURL: String {
            switch self {
            case .openai: return "https://api.openai.com/v1/chat/completions"
            case .claude: return "https://api.anthropic.com/v1/messages"
            case .deepseek: return "https://api.deepseek.com/chat/completions"
            case .glm: return "https://open.bigmodel.cn/api/paas/v4/chat/completions"
            }
        }

        var keyPlaceholder: String {
            switch self {
            case .openai: return "sk-..."
            case .claude: return "sk-ant-..."
            case .deepseek: return "sk-..."
            case .glm: return "输入 API Key"
            }
        }
    }

    @Published var llmProvider: LLMProvider {
        didSet { ud.set(llmProvider.rawValue, forKey: K.llmProvider) }
    }

    @Published var llmAPIKey: String {
        didSet { ud.set(llmAPIKey, forKey: K.llmAPIKey) }
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
    @Published var seedanceEndpoint: String {
        didSet { ud.set(seedanceEndpoint, forKey: K.seedanceEndpoint) }
    }
    @Published var seedance15Endpoint: String {
        didSet { ud.set(seedance15Endpoint, forKey: K.seedance15Endpoint) }
    }
    @Published var seedreamEndpoint: String {
        didSet { ud.set(seedreamEndpoint, forKey: K.seedreamEndpoint) }
    }

    // MARK: - 联网搜索

    enum SearchEngine: String, CaseIterable {
        case bing = "Bing"
        case google = "Google"
    }

    @Published var searchEngine: SearchEngine = .bing {
        didSet { ud.set(searchEngine.rawValue, forKey: K.searchEngine) }
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
    static var ttsProviders: [AIVideoService.Provider] {
        AIVideoService.Provider.allCases.filter { $0.category == .audio }
    }

    /// 图片去背使用的模型
    @Published var bgRemovalEngine: BackgroundRemover.Engine {
        didSet { ud.set(bgRemovalEngine.rawValue, forKey: K.bgRemovalEngine) }
    }

    /// 清晰度提升用哪个超分引擎
    enum ClarityEngine: String, CaseIterable {
        case system   // 系统自带（VTSuperResolutionScaler，macOS 26+）
        case builtIn  // 随 app 走的 FSRCNN

        var label: String {
            switch self {
            case .system:  return "系统超分"
            case .builtIn: return "轻量超分"
            }
        }

        var hint: String {
            switch self {
            case .system:
                return "画质更好；只支持放大 4 倍，素材分辨率需在 1920×1080 以内，要求 macOS 26 及以上"
            case .builtIn:
                return "随应用附带的轻量模型，速度快、任何系统都能用，但画质提升有限（接近高质量插值放大）"
            }
        }

        /// 系统超分只有 4 倍这一档
        var supportsX2: Bool { self == .builtIn }
    }

    @Published var clarityEngine: ClarityEngine {
        didSet { ud.set(clarityEngine.rawValue, forKey: K.clarityEngine) }
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
        objectWillChange.send()
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
        seedreamEndpoint = ud.string(forKey: K.seedreamEndpoint) ?? ""

        if let raw = ud.string(forKey: K.llmProvider),
           let prov = LLMProvider(rawValue: raw) {
            llmProvider = prov
        } else {
            llmProvider = .deepseek
        }
        llmAPIKey = ud.string(forKey: K.llmAPIKey) ?? ""

        if let raw = ud.string(forKey: K.searchEngine),
           let eng = SearchEngine(rawValue: raw) {
            searchEngine = eng
        } else {
            searchEngine = .bing
        }
        bingSearchKey = ud.string(forKey: K.bingSearchKey) ?? ""
        googleSearchKey = ud.string(forKey: K.googleSearchKey) ?? ""
        googleSearchCX = ud.string(forKey: K.googleSearchCX) ?? ""
    }
}
