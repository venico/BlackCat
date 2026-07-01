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

        deeplAPIKey = ud.string(forKey: K.deeplAPIKey) ?? ""
        youdaoAppKey = ud.string(forKey: K.youdaoAppKey) ?? ""
        youdaoAppSecret = ud.string(forKey: K.youdaoAppSecret) ?? ""
        volcanoAccessKeyId = ud.string(forKey: K.volcanoAccessKeyId) ?? ""
        volcanoSecretAccessKey = ud.string(forKey: K.volcanoSecretAccessKey) ?? ""
    }
}
