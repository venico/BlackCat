import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import AppKit
import AVFoundation

extension NSImage {
    /// 等比缩放到 maxSize 以内，不放大
    func aiThumbnail(maxSize: CGFloat) -> NSImage {
        let s = self.size
        guard s.width > 0, s.height > 0 else { return self }
        let scale = min(maxSize / s.width, maxSize / s.height, 1)
        let newSize = NSSize(width: s.width * scale, height: s.height * scale)
        let img = NSImage(size: newSize)
        img.lockFocus()
        self.draw(in: NSRect(origin: .zero, size: newSize), from: .zero, operation: .copy, fraction: 1)
        img.unlockFocus()
        return img
    }
}

final class AIVideoService: ObservableObject {
    static let shared = AIVideoService()

    /// 声明顺序 = 菜单里的分组顺序（`allCases` 按声明序）。
    /// 只有 AI 面板和设置页两处菜单遍历它，别处都是按 `== .video` 这类精确匹配，
    /// 所以调顺序不影响逻辑
    enum ProviderCategory: String, CaseIterable {
        // 这一类就是 Agent 用的模型：要支持工具调用，剪辑助手全靠它
        case text = "Agent 模型"
        case image = "图片生成"
        case audio = "声音生成"
        case video = "视频生成"
    }

    /// 某种类型该用哪个模型：优先读用户为这个类型单独记的那个（设置里存的，
    /// 每种类型各记各的），没有/不匹配就退回该类型里随便一个能用的，
    /// 实在没有才兜底成全局 selectedProvider。
    ///
    /// **需要「这个类型的模型」时必须走这个，不能直接用 `selectedProvider`**——
    /// 那是 AI 面板顶部全局选的，可能是任何类型。画布「重试」按钮最初就是
    /// 直接拿 selectedProvider，结果文字卡片重试时全局正好切到了图片模型，
    /// 报错「Image2 不支持文字生成」
    /// 这家的 API Key 到底存在哪。
    ///
    /// 大多数按 `providerKey.<rawValue>` 存，但火山方舟那两家（Seedance /
    /// Seedream）在设置界面里共用一个 `seedanceApiKey` —— 照 rawValue 去查
    /// Seedream 永远是空，会误报「还没配 Key」
    static func apiKey(for provider: Provider, settings: AppSettings = .shared) -> String {
        switch provider {
        case .seedance, .seedance15, .seedream:
            return settings.seedanceApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        default:
            return settings.providerAPIKey(for: provider.rawValue)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// 用户没选过时按这个顺序挑。**显式写死，不靠 enum 的声明顺序** ——
    /// 那个顺序是按接入时间排的，中间插一家新的就会悄悄改掉所有人的默认模型。
    /// 没列进来的（以后新接的）排在后面，不会漏
    static func defaultOrder(for category: ProviderCategory) -> [Provider] {
        switch category {
        case .image: return [.seedream, .nanobanana2, .gptImage2, .grokImage]
        case .video: return [.kling, .seedance, .runway, .minimax, .grokVideo]
        case .audio: return [.elevenlabs, .openaiTTS, .fishAudio, .minimaxTTS]
        // 文字走不到这儿 —— provider(for:) 里对 .text 特判成「跟随聊天框的选择」。
        // 这条只是聊天框那个下拉恰好选着图片/视频模型时的最后兜底
        case .text:  return [.claude, .gpt56, .deepseek_ai, .qwen, .glm, .grok, .kimi]
        }
    }

    /// 火山方舟那两个 Seedream 型号的官方模型名。
    /// 两者能力差一大截：Pro 只有「单图生成」，Lite 才带「组图生成」
    enum SeedreamModel {
        static let pro = "doubao-seedream-5-0-pro-260628"
        static let lite = "doubao-seedream-5-0-260128"
    }

    /// 用户没点名模型时，图片该找谁、用它的哪个型号。
    ///
    /// 顺序按**要几张**分两套：
    /// - 一张：Image2 → Seedream 5.0 Pro → Seedream 5.0 Lite
    /// - 多张：Image2 → Seedream 5.0 Lite（Pro 官方就出不了多张，直接跳过）
    ///
    /// 只挑配了 Key 的。一个都没配就返回 nil，交给上面那套通用逻辑去报错
    static func autoImagePick(count: Int, settings: AppSettings = .shared)
        -> (provider: Provider, model: String?)? {
        let order: [(Provider, String?)] = count > 1
            ? [(.gptImage2, nil), (.seedream, SeedreamModel.lite)]
            : [(.gptImage2, nil), (.seedream, SeedreamModel.pro), (.seedream, SeedreamModel.lite)]
        return order.first { !apiKey(for: $0.0, settings: settings).isEmpty }
            .map { (provider: $0.0, model: $0.1) }
    }

    /// 一次请求最多能出几张。**按官方公布的能力来，不是拍脑袋**：
    ///
    /// - Image2：OpenAI 图片接口的 `n`，1~10
    /// - Seedream：看选的是哪个子模型。官方模型列表里
    ///   `doubao-seedream-5-0-pro` 的能力只有「单图生成」，没有「组图生成」；
    ///   `5-0`(lite) / `4-5` / `4-0` 才带组图，上限 15（含参考图）
    /// - 其余各家没核实过，一律按 1 算，宁可少给不要瞎给
    /// `model` 是自动挑出来的型号；不传就按用户在下拉里选的那个算
    static func maxImages(for provider: Provider, model: String? = nil,
                          settings: AppSettings = .shared) -> Int {
        switch provider {
        case .gptImage2:
            return 10
        case .seedream:
            // 自定义接入点（ep-xxxxx）看不出是哪一版，就按下拉里选的那个算
            let picked = (model ?? settings.providerModel(for: provider.rawValue)).lowercased()
            let isPro = picked.isEmpty || picked.contains("pro")
            return isPro ? 1 : 15
        default:
            return 1
        }
    }

    static func provider(for category: ProviderCategory, settings: AppSettings = .shared) -> Provider {
        // 用户明确选过的最大 —— 哪怕它没配 Key，也该按他选的报错，而不是偷偷换一家
        let saved = settings.canvasProvider(for: category.rawValue)
        if let p = Provider(rawValue: saved), p.category == category, !p.isHidden {
            return p
        }
        // 文字（Agent 模型）不按写死的顺序挑，**跟着聊天框底部那个下拉走** ——
        // 那才是用户眼里「现在用的是哪个模型」，给它定个默认顺序只会跟界面对不上。
        // 但要挡一道类型：全局选中的可能是图片模型，直接拿会报「Image2 不支持文字生成」
        if category == .text {
            let picked = AIVideoService.shared.selectedProvider
            if picked.category == .text, !picked.isHidden { return picked }
        }

        let matching = Provider.allCases.filter { !$0.isHidden && $0.category == category }
        let preferred = defaultOrder(for: category).filter { !$0.isHidden && $0.category == category }
        let ordered = preferred + matching.filter { !preferred.contains($0) }

        // **先挑配了 Key 的**。原来只取顺序第一个，结果用户给另一家配了 Key 也用不上：
        // 默认落在 seedream 上，直接报「seedream 还没配 API Key」，
        // 而他其实配好了 gpt-image-2
        if let configured = ordered.first(where: { !apiKey(for: $0).isEmpty }) {
            return configured
        }
        // 一家都没配，返回顺序第一个，让下游报「这家没配 Key」
        return ordered.first ?? AIVideoService.shared.selectedProvider
    }

    enum Provider: String, CaseIterable, Identifiable {
        // 视频生成
        case kling = "kling"
        case seedance = "seedance"
        case seedance15 = "seedance15"
        case runway = "runway"
        case minimax = "minimax"
        case vidu = "vidu"
        case veo3 = "veo3"
        case grokVideo = "grok-video"
        // 图片生成
        case seedream = "seedream"
        case nanobanana2 = "nanobanana2"
        case gptImage2 = "gpt-image-2"
        case flux = "flux"
        case sd3 = "sd3"
        case wanxiang = "wanxiang"
        case grokImage = "grok-image"
        // 声音生成
        case elevenlabs = "elevenlabs"
        case openaiTTS = "openai-tts"
        case fishAudio = "fish-audio"
        case suno = "suno"
        case minimaxTTS = "minimax-tts"
        // 文字生成（与「视频分析」那套 LLM 保持同一组五家）
        case claude = "claude"
        case gpt56 = "gpt-5.6"
        case deepseek_ai = "deepseek-ai"
        case qwen = "qwen"
        case glm = "glm"
        case grok = "grok"
        case kimi = "kimi"

        var id: String { rawValue }

        /// 文字类模型的子模型清单。第一个是默认值。
        /// 名单由产品指定，不自动跟随各家 API 的全量列表 —— 只放实际会用到的几档
        /// 子模型：(界面显示名, API 的 model 取值)。
        ///
        /// 两者必须分开 —— 之前直接把显示名发出去，中转站报
        /// 「Model "Opus5" is not supported by any configured account in this group」。
        /// Claude 四个 id 取自 Anthropic 官方模型表；其余几家按各自命名规律小写化，
        /// 中转站若用了别的名字，在设置里填接口地址那家的模型名以它为准
        var subModels: [(label: String, id: String)] {
            switch self {
            case .claude:
                return [("Fable5", "claude-fable-5"), ("Opus5", "claude-opus-5"),
                        ("Sonnet5", "claude-sonnet-5"), ("Opus4.6", "claude-opus-4-6")]
            case .gpt56:
                return [("GPT-6-Astra", "gpt-6-astra"),
                        ("GPT-5.6-Sol", "gpt-5.6-sol"), ("GPT-5.6-Terra", "gpt-5.6-terra"),
                        ("GPT-5.5", "gpt-5.5")]
            case .deepseek_ai:
                return [("Deepseek-V4-Flash", "deepseek-v4-flash"),
                        ("Deepseek-V4-Pro", "deepseek-v4-pro")]
            case .qwen:
                return [("Qwen3.8-Max", "qwen3.8-max"), ("Qwen3.7-Max", "qwen3.7-max"),
                        ("Qwen3.7-Plus", "qwen3.7-plus"), ("Qwen3.7-Flash", "qwen3.7-flash")]
            case .glm:
                return [("GLM-5.3", "glm-5.3"), ("GLM-5.3-Flash", "glm-5.3-flash"),
                        ("GLM-5.2", "glm-5.2")]
            case .kling:
                // model_name 的官方写法只核实到 kling-v3；turbo/omni 两个是按
                // kling-v2.5-turbo 那套命名规律推的，对不上就在设置里改
                return [("Kling 3.0 Turbo", "kling-v3-turbo"),
                        ("Kling 3.0", "kling-v3"),
                        ("Kling 3.0 Omni", "kling-v3-omni")]
            case .minimax:
                return [("MiniMax-H3", "MiniMax-H3")]
            case .minimaxTTS:
                return [("speech-2.8-hd", "speech-2.8-hd"), ("speech-2.8-turbo", "speech-2.8-turbo")]
            case .grok:
                return [("Grok-4.6", "grok-4.6")]
            case .grokImage:
                return [("grok-imagine-image-2.0", "grok-imagine-image-2.0"),
                        ("grok-imagine-image-quality", "grok-imagine-image-quality"),
                        ("grok-imagine-image", "grok-imagine-image")]
            case .grokVideo:
                return [("grok-imagine-video-1.5", "grok-imagine-video-1.5"),
                        ("grok-imagine-video", "grok-imagine-video")]
            case .kimi:
                return [("Kimi-K3", "kimi-k3")]
            case .nanobanana2:
                // 同 Seedance：id 只是「用哪一栏接入点」的标记，
                // 真正发出去的模型名在设置里填
                return [("Nanobanana 2", "2"), ("Nanobanana Pro", "pro")]
            case .gptImage2:
                return [("gpt-image-2", "gpt-image-2")]
            case .seedream:
                // id 直接就是官方模型名，可以不建接入点直接发。
                // **Pro 没有组图能力**（官方模型列表里它只有「单图生成」，
                // lite / 4.5 / 4.0 那几个才带「组图生成」），所以要一次多张只能选 lite
                return [("Seedream 5.0 Pro", SeedreamModel.pro),
                        ("Seedream 5.0 Lite", SeedreamModel.lite)]
            case .seedance:
                // 这里的 id 不是模型名，是「用哪个接入点」的标记 ——
                // 火山方舟要按模型分别建接入点，真正发出去的是设置里填的 ep-xxxxx
                return [("Seedance2.0", "2.0"), ("Seedance2.5", "2.5")]
            default:
                return []
            }
        }

        /// 推理强度档位：(界面文案, API 取值)。第一项为该家默认。
        ///
        /// 各家档位不一样，是按官方文档来的：
        /// - Claude：low / medium / high(默认) / max
        /// - OpenAI GPT-5.6：none / low / medium(默认) / high / xhigh / max
        /// - DeepSeek V4：OpenAI 兼容路径推荐 high / max，默认 high
        /// - 通义千问：low / medium / xhigh（对应思考预算 4K / 16K / 256K）
        /// - 智谱 GLM-5.3：low / high / max(默认)，且不允许关闭思考
        var reasoningLevels: [(label: String, value: String)] {
            switch self {
            case .claude:
                return [("高 high", "high"), ("中 medium", "medium"), ("轻度 low", "low"),
                        ("很高 xhigh", "xhigh"), ("极高 max", "max")]
            case .gpt56:
                return [("中 medium", "medium"), ("轻度 low", "low"), ("高 high", "high"),
                        ("极高 xhigh", "xhigh"), ("最高 max", "max"), ("关闭 none", "none")]
            case .deepseek_ai:
                return [("高 high", "high"), ("极高 max", "max")]
            case .qwen:
                return [("中 medium", "medium"), ("轻度 low", "low"), ("极高 xhigh", "xhigh")]
            case .glm:
                return [("极高 max", "max"), ("高 high", "high"), ("轻度 low", "low")]
            case .grok:
                // xhigh 只有 grok-4.6 及以后认，老模型会按 high 处理
                return [("高 high", "high"), ("中 medium", "medium"),
                        ("轻度 low", "low"), ("极高 xhigh", "xhigh")]
            case .kimi:
                // K3 的思考关不掉，只能调强度
                return [("极高 max", "max"), ("高 high", "high"), ("轻度 low", "low")]
            default:
                return []
            }
        }

        var category: ProviderCategory {
            switch self {
            case .kling, .seedance, .seedance15, .runway, .minimax, .vidu, .veo3, .grokVideo: return .video
            case .seedream, .nanobanana2, .gptImage2, .flux, .sd3, .wanxiang, .grokImage: return .image
            case .elevenlabs, .openaiTTS, .fishAudio, .suno, .minimaxTTS: return .audio
            case .claude, .gpt56, .deepseek_ai, .qwen, .glm, .grok, .kimi: return .text
            }
        }

        var displayName: String {
            switch self {
            case .kling: return "可灵 (Kling)"
            case .seedance: return "Seedance"
            case .seedance15: return "Seedance 1.5 Pro"
            case .runway: return "Runway Gen-4"
            case .minimax: return "MiniMax"
            case .vidu: return "Vidu"
            case .veo3: return "Veo 3"
            case .seedream: return "Seedream"
            case .nanobanana2: return "Gemini"
            case .gptImage2: return "Image2"
            case .flux: return "Flux"
            case .sd3: return "Stable Diffusion 3"
            case .wanxiang: return "通义万相"
            case .elevenlabs: return "ElevenLabs"
            case .openaiTTS: return "OpenAI TTS"
            case .fishAudio: return "Fish Audio"
            case .suno: return "Suno"
            case .minimaxTTS: return "MiniMax"
            case .claude: return "Claude"
            case .gpt56: return "Chatgpt"
            case .deepseek_ai: return "DeepSeek"
            case .qwen: return "Qwen"
            case .glm: return "Glm"
            case .grok, .grokImage, .grokVideo: return "Grok"
            case .kimi: return "Kimi"
            }
        }

        /// 暂时不在菜单里露出的模型 —— 手上没有可用账号，没法测通就先不上，
        /// 以后能测了把对应 case 从这里删掉即可（代码路径都还在）
        var isHidden: Bool {
            switch self {
            case .seedance15, .vidu, .veo3, .flux, .sd3, .wanxiang, .suno: return true
            case .grokImage, .grokVideo: return true
            case .nanobanana2: return true
            case .elevenlabs, .openaiTTS, .runway, .kling: return true
            default: return false
            }
        }

        static func providers(for category: ProviderCategory) -> [Provider] {
            allCases.filter { $0.category == category && !$0.isHidden }
        }

        var needsAccessKey: Bool {
            switch self {
            case .seedance, .seedance15, .seedream: return false
            default: return true
            }
        }
        var needsSecretKey: Bool {
            switch self {
            case .kling: return true
            default: return false
            }
        }
        var accessKeyLabel: String {
            switch self {
            case .kling: return "Access Key"
            default: return "API Key"
            }
        }
        var secretKeyLabel: String { "Secret Key" }

        var supportsWebSearch: Bool {
            category == .text
        }

        /// 当前选中的子模型 id。参考素材的额度**按子模型分**（Seedance 2.5 比 2.0
        /// 宽松得多），所以下面几个上限都要先看它。
        /// 没选过就取第一个 —— 跟界面上下拉的默认显示保持一致
        private var currentSubModelID: String {
            let saved = AppSettings.shared.providerModel(for: rawValue)
            if subModels.contains(where: { $0.id == saved }) { return saved }
            return subModels.first?.id ?? ""
        }

        var maxReferenceImages: Int {
            switch self {
            // Seedance 2.5 的额度比 2.0 大一截，得按子模型分
            case .seedance: return currentSubModelID == "2.5" ? 30 : 9
            case .seedance15: return 9
            case .minimax: return 9
            case .kling, .runway, .vidu, .veo3: return 1
            case .seedream: return 10
            case .gptImage2: return 16
            case .nanobanana2, .flux, .sd3, .wanxiang: return 1
            default: return 0
            }
        }

        var maxReferenceVideos: Int {
            switch self {
            case .seedance: return currentSubModelID == "2.5" ? 10 : 3
            case .seedance15, .minimax: return 3
            default: return 0
            }
        }

        var maxReferenceAudios: Int {
            switch self {
            case .seedance: return currentSubModelID == "2.5" ? 10 : 3
            case .seedance15, .minimax: return 3
            default: return 0
            }
        }

        var supportsFirstFrame: Bool {
            switch self {
            case .kling, .seedance, .seedance15, .runway, .minimax, .vidu, .veo3: return true
            default: return false
            }
        }

        var supportsLastFrame: Bool {
            switch self {
            case .kling, .seedance, .seedance15: return true
            default: return false
            }
        }

        /// 参考内容总数上限（图 + 视频 + 音频）
        var maxReferenceTotal: Int {
            switch self {
            case .seedance: return currentSubModelID == "2.5" ? 50 : 12
            case .seedance15, .minimax: return 12
            default: return max(maxReferenceImages, 1)
            }
        }
    }

    enum TaskStatus: Equatable {
        case idle
        case generating(progress: String)
        case downloading(progress: Double)
        case completed(url: URL)
        case completedImage(url: URL)
        case completedAudio(url: URL)
        case failed(error: String)
    }

    /// 用户消息携带的参考内容/首尾帧，用于气泡底部回显和一键回填输入区
    enum AttachmentKind: String, Codable {
        case image, video, audio, firstFrame, lastFrame
    }

    struct Attachment: Identifiable, Codable, Equatable {
        var id: UUID = UUID()
        var url: URL
        var kind: AttachmentKind
        var bookmark: Data?

        /// 优先用 bookmark 解析，兼容用户移动过文件的情况
        func resolvedURL() -> URL? {
            if let bm = bookmark {
                var stale = false
                if let u = try? URL(resolvingBookmarkData: bm, options: [], relativeTo: nil, bookmarkDataIsStale: &stale),
                   FileManager.default.fileExists(atPath: u.path) { return u }
            }
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    struct ChatMessage: Identifiable {
        let id: UUID
        let role: Role
        var content: String
        var videoURL: URL?
        var imageURL: URL?
        var audioURL: URL?
        var videoBookmark: Data?
        var imageBookmark: Data?
        var audioBookmark: Data?
        var attachments: [Attachment] = []
        /// Agent 那一轮的执行步骤/耗时/用量，翻历史和重启后靠它显示
        var agentSteps: [ConversationRecord.AgentStepRecord]?
        var agentElapsed: Double?
        var agentTokens: Int?
        var status: TaskStatus
        let timestamp: Date

        enum Role { case user, assistant }

        init(id: UUID = UUID(), role: Role, content: String, videoURL: URL? = nil, imageURL: URL? = nil, audioURL: URL? = nil, status: TaskStatus = .idle) {
            self.id = id
            self.role = role
            self.content = content
            self.videoURL = videoURL
            self.imageURL = imageURL
            self.audioURL = audioURL
            self.status = status
            self.timestamp = Date()
        }

        func resolvedVideoURL() -> URL? {
            if let bm = videoBookmark, let url = Self.resolve(bm), FileManager.default.fileExists(atPath: url.path) { return url }
            if let url = videoURL, FileManager.default.fileExists(atPath: url.path) { return url }
            return nil
        }
        func resolvedImageURL() -> URL? {
            if let bm = imageBookmark, let url = Self.resolve(bm), FileManager.default.fileExists(atPath: url.path) { return url }
            if let url = imageURL, FileManager.default.fileExists(atPath: url.path) { return url }
            return nil
        }
        func resolvedAudioURL() -> URL? {
            if let bm = audioBookmark, let url = Self.resolve(bm), FileManager.default.fileExists(atPath: url.path) { return url }
            if let url = audioURL, FileManager.default.fileExists(atPath: url.path) { return url }
            return nil
        }
        private static func resolve(_ data: Data) -> URL? {
            var stale = false
            return try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        }
    }

    struct ConversationRecord: Identifiable, Codable {
        let id: UUID
        var title: String
        /// 用户手动改过名字。改过之后自动保存就不再按内容重算标题了 ——
        /// 画布每隔一会儿存一次，每次都重算的话，刚改的名字下一次保存就被冲掉
        var titleIsCustom: Bool = false
        let createdAt: Date
        var entries: [Entry]
        /// 画布类会话带这一份；聊天会话是 nil。
        /// 一张画布 = 一条会话记录，历史列表里两种混排、各自打标
        var canvas: CanvasSnapshot?

        var isCanvas: Bool { canvas != nil }

        init(id: UUID, title: String, createdAt: Date,
             entries: [Entry], canvas: CanvasSnapshot? = nil, titleIsCustom: Bool = false) {
            self.id = id
            self.title = title
            self.createdAt = createdAt
            self.entries = entries
            self.canvas = canvas
            self.titleIsCustom = titleIsCustom
        }

        /// **手写解码，每个字段都 decodeIfPresent**。
        ///
        /// 自动生成的 Codable 缺一个键就抛错，那条记录整个解不出来 ——
        /// 2026-08-21 给 CanvasNode 加字段就是这么把用户 21 条历史冲掉的。
        /// 往这个结构加字段，照着加一行就行
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // id 是**必需**的：没有 id 就不是一条记录。
            // 这里也容错的话，任何一个 JSON 对象都能解成一条空记录，
            // 坏数据不再被跳过，而是变成历史里一条莫名其妙的「未命名」
            id = try c.decode(UUID.self, forKey: .id)
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? "未命名"
            titleIsCustom = try c.decodeIfPresent(Bool.self, forKey: .titleIsCustom) ?? false
            createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
            entries = try c.decodeIfPresent([Entry].self, forKey: .entries) ?? []
            canvas = try c.decodeIfPresent(CanvasSnapshot.self, forKey: .canvas)
        }

        /// 画布存盘的样子。节点/连线/视口都在里面
        struct CanvasSnapshot: Codable {
            var nodes: [CanvasNode] = []
            var edges: [CanvasEdge] = []
            var groups: [CanvasGroup] = []
            var producedAssets: [CanvasState.ProducedAsset] = []
            var zoom: CGFloat = 1
            var offsetX: CGFloat = 0
            var offsetY: CGFloat = 0

            init() {}

            init(nodes: [CanvasNode], edges: [CanvasEdge], groups: [CanvasGroup],
                 producedAssets: [CanvasState.ProducedAsset],
                 zoom: CGFloat, offsetX: CGFloat, offsetY: CGFloat) {
                self.nodes = nodes
                self.edges = edges
                self.groups = groups
                self.producedAssets = producedAssets
                self.zoom = zoom
                self.offsetX = offsetX
                self.offsetY = offsetY
            }

            /// **手写解码，每个字段都 decodeIfPresent**。
            /// 自动生成的 Codable 缺一个键就抛错，整条会话记录跟着解不出来 ——
            /// 2026-08-21 加字段冲掉用户 21 条历史就是这么来的。
            /// 往这个结构加字段，照着加一行就行
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                nodes = try c.decodeIfPresent([CanvasNode].self, forKey: .nodes) ?? []
                edges = try c.decodeIfPresent([CanvasEdge].self, forKey: .edges) ?? []
                groups = try c.decodeIfPresent([CanvasGroup].self, forKey: .groups) ?? []
                producedAssets = try c.decodeIfPresent([CanvasState.ProducedAsset].self,
                                                       forKey: .producedAssets) ?? []
                zoom = try c.decodeIfPresent(CGFloat.self, forKey: .zoom) ?? 1
                offsetX = try c.decodeIfPresent(CGFloat.self, forKey: .offsetX) ?? 0
                offsetY = try c.decodeIfPresent(CGFloat.self, forKey: .offsetY) ?? 0
            }
        }

        struct Entry: Identifiable, Codable {
            let id: UUID
            let isUser: Bool
            let text: String
            let videoPath: String?
            var imagePath: String?
            var audioPath: String?
            var videoBookmark: Data?
            var imageBookmark: Data?
            var audioBookmark: Data?
            /// optional：旧会话记录没有这个字段，解码时为 nil
            var attachments: [Attachment]?
            /// Agent 这一轮调过哪些工具。存下来，翻历史时才知道它当时改了什么
            var agentSteps: [AgentStepRecord]?
            /// 这一轮跑了多久、烧了多少 token。旧记录没有，解码为 nil
            var agentElapsed: Double?
            var agentTokens: Int?
            /// 失败/取消的原因。存下来重开才认得出这是失败态 ——
            /// 不存的话读回来一律当普通回复，图标和颜色都没了
            var failedError: String?
        }

        /// 一次工具调用的留痕
        /// Equatable 是给 SwiftUI 用的：步骤列表每半秒会因为计时器重算一次，
        /// 能逐条比出「这行没变」才不会连带重画里面的长文本
        struct AgentStepRecord: Identifiable, Codable, Equatable {
            var id = UUID()
            var tool: String
            var summary: String
            var isError: Bool = false
            /// 下面三样是 v5.8.5 之后加的，**都得是 Optional** ——
            /// 旧存档里没有这几个键，非 Optional 会让整份记录解不出来
            var args: String?
            var detail: String?
            var thinking: String?
        }
    }

    // MARK: - 输入区状态
    // 素材库和 AI 面板是互斥 tab，AIChatPanel 每次切回来都会重建。
    // 这些状态必须放在 singleton 上，否则用户选好的参考内容/模式会在切 tab 时丢失。

    enum RefContentType { case image, video, audio }

    struct RefContent: Identifiable {
        let id = UUID()
        let url: URL
        let type: RefContentType
        let thumbnail: NSImage
    }

    enum ImageInputMode: String {
        case reference, frames
        var label: String {
            switch self {
            case .reference: return "参考内容"
            case .frames: return "首尾帧"
            }
        }
    }

    @Published var referenceContents: [RefContent] = []
    @Published var firstFrameImage: (url: URL, image: NSImage)? = nil
    @Published var lastFrameImage: (url: URL, image: NSImage)? = nil
    @Published var imageMode: ImageInputMode = .reference
    /// 输入框里还没发出去的草稿，和挂在上面的附件。
    ///
    /// **必须放这儿，不能留在 AIChatPanel 的 @State 里** —— 面板是按标签页
    /// 条件渲染的，切去素材库/效果再回来视图就重建了，@State 全丢。
    /// 而「切过去从素材库拖个素材到参考区」正是常规操作
    /// 这一轮发给 Agent 的参考内容快照。
    ///
    /// 界面上那份（`referenceContents`）发完就清空了，而生成工具是**异步**跑的，
    /// 等它执行时早没了 —— 所以单独留一份给工具读
    var agentRoundReferences: [RefContent] = []
    var agentRoundFirstFrame: URL?
    var agentRoundLastFrame: URL?

    /// 这一轮已经提交过哪几类生成任务。**一轮每类只放行一次**。
    ///
    /// 模型总爱多提交：用户取消了一个再要 3 张，它交「1 张（补做的）+ 3 张」；
    /// 提示词里写死「取消就是不要了，不要补做」也照样补。
    /// 要多张走 count 参数，所以这道拦截不会误伤
    var agentRoundGenerated: Set<ProviderCategory> = []

    /// 从用户这轮原话里解析出来的张数（「生成3张海报」→ 3）。
    ///
    /// **不指望模型传 count**：实测跟它说「用户说了几张就传几」，它照样第一次
    /// 只调 1 张、第二次再调一次，被一轮一次的拦截挡下，最后只出 1 张。
    /// 这里自己认数字，不看它脸色
    var agentRoundImageCount: Int?

    /// 认「3张 / 三张 / 3幅 / 3个」这类说法。认不出返回 nil
    static func parseImageCount(from text: String) -> Int? {
        let cn = ["一": 1, "两": 2, "二": 2, "三": 3, "四": 4, "五": 5,
                  "六": 6, "七": 7, "八": 8, "九": 9, "十": 10]
        let unit = "张|幅|个|副"
        if let m = text.range(of: "\\d+\\s*(\(unit))", options: .regularExpression),
           let n = Int(text[m].filter(\.isNumber)) {
            return n
        }
        for (word, n) in cn {
            if text.range(of: "\(word)\\s*(\(unit))", options: .regularExpression) != nil {
                return n
            }
        }
        return nil
    }

    @Published var agentInputText: String = ""
    @Published var agentAttachments: [AgentAttachment] = []

    // MARK: - 每条会话自己的输入状态
    //
    // 草稿、附件、参考内容原来是单例上的**一份**，侧栏和画布卡片共用 ——
    // 在普通会话里粘的附件会跑到画布的聊天里去。改成切会话时存走 / 取回。

    private struct InputDraft {
        var text = ""
        var attachments: [AgentAttachment] = []
        var references: [RefContent] = []
        var firstFrame: (url: URL, image: NSImage)?
        var lastFrame: (url: URL, image: NSImage)?
        var imageMode: ImageInputMode = .reference
        // 生成参数也是各会话各一套。nil = 这条会话没设过，沿用当前值
        var duration: String?
        var ratio: String?
        var imageRatio: String?
        var resolution: String?
        var agentMode: AgentMode?
        var provider: Provider?
        /// 子模型 / 推理强度是按供应商存的，整份带走
        var providerModels: [String: String]?
        var providerReasonings: [String: String]?
    }
    private var inputDrafts: [UUID: InputDraft] = [:]

    /// 把手上这份存到当前会话名下
    private func stashInputDraft() {
        guard let id = currentConversationId else { return }
        inputDrafts[id] = InputDraft(text: agentInputText,
                                     attachments: agentAttachments,
                                     references: referenceContents,
                                     firstFrame: firstFrameImage,
                                     lastFrame: lastFrameImage,
                                     imageMode: imageMode,
                                     duration: settings.aiDuration,
                                     ratio: settings.aiRatio,
                                     imageRatio: settings.aiImageRatio,
                                     resolution: settings.aiResolution,
                                     agentMode: settings.agentMode,
                                     provider: selectedProvider,
                                     providerModels: settings.snapshotProviderModels(),
                                     providerReasonings: settings.snapshotProviderReasonings())
    }

    /// 换成这条会话自己那份（没有就是空的）
    private func restoreInputDraft(_ id: UUID) {
        // Agent 的运行状态也各会话一份，镜像跟着切 ——
        // 不切的话 A 会话在跑，B 的发送按钮也显示成「停止」
        // 这条路径本来就在主线程上跑，同步切 —— 用 Task 异步切会晚一拍，
        // 界面先闪一下上一条会话的运行状态
        MainActor.assumeIsolated { AgentRunner.shared.switchTo(id) }
        let d = inputDrafts[id] ?? InputDraft()
        agentInputText = d.text
        agentAttachments = d.attachments
        referenceContents = d.references
        firstFrameImage = d.firstFrame
        lastFrameImage = d.lastFrame
        imageMode = d.imageMode
        // 生成参数写回全局那份：界面各处照旧读 settings，不用改读取点。
        // 没设过（nil）就不动，沿用当前值
        if let v = d.duration { settings.aiDuration = v }
        if let v = d.ratio { settings.aiRatio = v }
        if let v = d.imageRatio { settings.aiImageRatio = v }
        if let v = d.resolution { settings.aiResolution = v }
        if let v = d.agentMode { settings.agentMode = v }
        if let v = d.provider { selectedProvider = v }
        // 这两份必须整份写回（包括「没记录就清空」），
        // 否则上一条会话选的子模型会渗到这条来
        if let m = d.providerModels { settings.restoreProviderModels(m) }
        if let r = d.providerReasonings { settings.restoreProviderReasonings(r) }
    }

    // 三张表管着「这文件算不算素材」：拖入、粘贴、导入、落成画布卡片都查它。
    // 按 ffmpeg 实际能吃的常见容器列，不要只列最眼熟那几个 ——
    // 漏一个的表现是「拖进去 / 粘进去毫无反应」，用户根本不知道为什么
    static let imageExts: Set<String> = [
        "jpg","jpeg","jfif","png","gif","bmp","tif","tiff","webp","heic","heif","avif","ico"
    ]
    static let videoExts: Set<String> = [
        "mp4","mov","m4v","avi","mkv","webm","flv","wmv","mpg","mpeg","m2v",
        "ts","m2ts","mts","3gp","3g2","ogv","asf","vob","rm","rmvb","f4v","divx"
    ]
    static let audioExts: Set<String> = [
        "mp3","wav","m4a","aac","flac","ogg","oga","opus","wma","aiff","aif","aifc",
        "ac3","eac3","amr","ape","caf","mka","wv","dts","mp2","au","voc"
    ]

    enum AddReferenceResult {
        case added
        case duplicate
        case unsupportedType
        case limitReached(String)
    }

    /// 把素材加进当前模式对应的占位。UI 层不必显示，AI 面板重建后状态仍在。
    @discardableResult
    /// `provider` 传 nil 就是下拉选的那家；打了 `/` 命令时要把**命令点名的那家**
    /// 传进来 —— 上限、首尾帧支不支持都得按它算，不然拿 Agent 模型去问
    /// 「能塞几张参考图」，答案永远是 0
    func addToReference(url: URL, provider: Provider? = nil) -> AddReferenceResult {
        // 优先用「此刻真正生效的模型」—— 用户 `/` 点名了哪家就是哪家。
        // 只看 selectedProvider 的话，点名视频模型后加视频素材会被判成不支持
        let p = provider ?? activeUIProvider ?? selectedProvider
        let ext = url.pathExtension.lowercased()
        let type: RefContentType
        if Self.imageExts.contains(ext) { type = .image }
        else if Self.videoExts.contains(ext) { type = .video }
        else if Self.audioExts.contains(ext) { type = .audio }
        else { return .unsupportedType }

        if p.category == .video && imageMode == .frames {
            return addAsFrame(url: url, type: type, provider: p)
        }
        return addAsReference(url: url, type: type, provider: p)
    }

    enum LibraryAcceptResult {
        case reference          // 收进了参考区
        case attachment         // 收进了附件
        case duplicate
        case unsupported
        case limitReached(String)
    }

    /// 素材库右键「添加到 AI 参考」该往哪放。**按输入框此刻的状态判**：
    ///
    /// - 打了 `/` 命令 → 按点名那家的参考规则收进参考区，那家收不下就落到附件
    /// - 没打命令 → 直接当附件收（附件连视频音频都收，等打了命令再收进参考区）
    ///
    /// 不这么分的话，没打命令时只能按面板全局选的模型判 —— 它可能是个图片模型，
    /// 视频素材就被判成「不支持当前素材类型」，可附件区明明收得下
    func acceptLibraryAsset(url: URL) -> LibraryAcceptResult {
        if let p = activeUIProvider {
            let takesReference = p.maxReferenceTotal > 0
                || (p.category == .video && imageMode == .frames && p.supportsFirstFrame)
            if takesReference {
                switch addToReference(url: url, provider: p) {
                case .added:                 return .reference
                case .duplicate:             return .duplicate
                case .limitReached(let m):   return .limitReached(m)
                case .unsupportedType:       break   // 这家不收这类，往下落到附件
                }
            }
        }
        guard AgentAttachmentIO.accepts(url) else { return .unsupported }
        guard !agentAttachments.contains(where: { $0.url == url }) else { return .duplicate }
        guard let a = AgentAttachmentIO.make(url) else { return .unsupported }
        agentAttachments.append(a)
        return .attachment
    }

    /// 首尾帧模式：先点的进首帧，后点的进尾帧，都满了从首帧重新开始
    private func addAsFrame(url: URL, type: RefContentType,
                            provider: Provider) -> AddReferenceResult {
        guard type == .image, let img = NSImage(contentsOf: url) else { return .unsupportedType }
        let thumb = img.aiThumbnail(maxSize: 200)
        if firstFrameImage == nil {
            firstFrameImage = (url, thumb)
        } else if provider.supportsLastFrame && lastFrameImage == nil {
            lastFrameImage = (url, thumb)
        } else {
            // 两个都满了：这一张不再顶掉已有的，交回上层当附件收
            return .limitReached("首尾帧都占满了")
        }
        return .added
    }

    private func addAsReference(url: URL, type: RefContentType,
                                provider: Provider) -> AddReferenceResult {
        guard !referenceContents.contains(where: { $0.url == url }) else { return .duplicate }

        let limit: Int
        let name: String
        switch type {
        case .image: limit = provider.maxReferenceImages; name = "图片"
        case .video: limit = provider.maxReferenceVideos; name = "视频"
        case .audio: limit = provider.maxReferenceAudios; name = "音频"
        }
        guard limit > 0 else { return .unsupportedType }
        guard referenceContents.count < provider.maxReferenceTotal else {
            return .limitReached("参考内容总数上限 \(provider.maxReferenceTotal) 个")
        }
        guard referenceContents.filter({ $0.type == type }).count < limit else {
            return .limitReached("\(name)上限 \(limit) 个")
        }

        let thumb: NSImage
        switch type {
        case .image: thumb = (NSImage(contentsOf: url) ?? Self.audioPlaceholderThumbnail()).aiThumbnail(maxSize: 200)
        case .video: thumb = Self.videoFrameThumbnail(url: url)
        case .audio: thumb = Self.audioPlaceholderThumbnail()
        }
        referenceContents.append(RefContent(url: url, type: type, thumbnail: thumb))
        return .added
    }

    static func videoFrameThumbnail(url: URL) -> NSImage {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 200, height: 200)
        if let cg = try? gen.copyCGImage(at: .zero, actualTime: nil) {
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
        let img = NSImage(size: NSSize(width: 48, height: 48))
        img.lockFocus()
        NSColor.darkGray.setFill()
        NSBezierPath.fill(NSRect(origin: .zero, size: img.size))
        img.unlockFocus()
        return img
    }

    static func audioPlaceholderThumbnail() -> NSImage {
        let size = NSSize(width: 48, height: 48)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor(white: 0.2, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 6, yRadius: 6).fill()
        if let s = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 20, weight: .light)
            let configured = s.withSymbolConfiguration(config) ?? s
            configured.draw(in: NSRect(x: (48 - 28) / 2, y: (48 - 28) / 2, width: 28, height: 28))
        }
        img.unlockFocus()
        return img
    }

    // MARK: - 生成任务

    /// 任务来自哪儿。聊天面板一次只发一个、且要靠 `isGenerating` 锁输入框；
    /// 画布会同时发一堆，不能让它把聊天面板锁住
    enum TaskSource: Equatable {
        case chat
        case canvas
        /// Agent 派下来的。这类不往会话里插气泡，进度走后台任务面板
        case agent
    }

    /// 一个在跑的生成任务
    struct RunningGeneration: Identifiable {
        let id: UUID
        /// 结果要回填到哪个会话的哪条消息
        let convId: UUID
        let msgId: UUID
        let source: TaskSource
        let category: ProviderCategory
        var handle: Task<Void, Never>?
    }

    /// 当前任务 id，沿 async 调用链自动传递。
    ///
    /// 各家 `generateWithXxx` 内部有 41 处 `updateAssistantStatus(...)` 报进度，
    /// 它们都是无参调用、靠「最后一条还在跑的助手消息」定位 —— 并发时必然串台。
    /// 用 TaskLocal 把任务 id 带下去，这 41 处一个都不用改签名
    enum Context {
        @TaskLocal static var taskID: UUID?
    }

    @Published var messages: [ChatMessage] = []
    @Published var selectedProvider: Provider = .kling

    /// 聊天框此刻真正生效的模型：`/` 点名了就是点名那个，没点名就等于 selectedProvider。
    /// 由 AIChatPanel 同步进来，给面板外面的入口（素材库右键之类）判断用
    @Published var activeUIProvider: Provider?

    /// 在跑的生成任务，按 id 存。画布上会同时跑很多个，
    /// 原来那个 `isGenerating` 布尔 + 单个 generatingMessageId 只够伺候一个任务
    @Published private(set) var runningTasks: [UUID: RunningGeneration] = [:]

    /// 聊天面板照旧「一次只发一个」，所以这里只看聊天来源的任务 ——
    /// 画布上那些任务不该把聊天输入框锁住
    var isGenerating: Bool { runningTasks.values.contains { $0.source == .chat } }
    @Published var webSearchEnabled = false
    @Published var history: [ConversationRecord] = []
    @Published var currentConversationId: UUID? = nil
    /// 当前是停在历史列表还是某条会话里。**不能放面板的 @State** ——
    /// 切到素材库再切回来，面板整个重建，状态一重置就弹回列表了
    @Published var showChatHistory = true

    private let settings = AppSettings.shared

    private init() {
        if let p = Provider(rawValue: settings.aiProvider) {
            selectedProvider = p
        }
        loadHistory()
        selectFirstConversation()
    }

    /// 启动时把第一条标成选中（列表里有底色），**页面仍停在历史列表**。
    ///
    /// 只设 id 不载 messages 是不行的 —— 那会让「当前是哪条」和手里的消息对不上，
    /// 点进去看到的是别人的记录。所以照常走 loadConversation，
    /// 只是不切页面。这会儿 messages 还是空的，它开头那次
    /// saveCurrentConversation 不会写任何东西
    private func selectFirstConversation() {
        guard let first = history.first else { return }
        loadConversation(first.id)
    }

    /// 发起一次生成，返回任务 id（画布要用它做取消/重试和依赖调度）。
    /// `source` 默认 `.chat`，聊天面板的调用点一个字都不用改
    @discardableResult
    /// `provider` 传 nil 就是下拉里选的那家；打了 `/命令` 时必须把**命令点名的那家**
    /// 传进来。不传的坑：用户打 `/gpt-image-2` 挂了参考图，请求却发给了下拉里的
    /// 文字模型 —— 界面显示「正在生成回复」，模型回一句「请先上传参考图」
    func sendPrompt(_ prompt: String, provider: Provider? = nil, duration: String = "5", aspectRatio: String = "16:9", resolution: String = "720P", imageRatio: String = "1:1", referenceImages: [URL] = [], referenceVideos: [URL] = [], referenceAudios: [URL] = [], firstFrame: URL? = nil, lastFrame: URL? = nil, source: TaskSource = .chat) -> UUID {
        var userMsg = ChatMessage(role: .user, content: prompt)
        var atts: [Attachment] = []
        atts += referenceImages.map { Attachment(url: $0, kind: .image, bookmark: createBookmark(for: $0)) }
        atts += referenceVideos.map { Attachment(url: $0, kind: .video, bookmark: createBookmark(for: $0)) }
        atts += referenceAudios.map { Attachment(url: $0, kind: .audio, bookmark: createBookmark(for: $0)) }
        if let f = firstFrame { atts.append(Attachment(url: f, kind: .firstFrame, bookmark: createBookmark(for: f))) }
        if let l = lastFrame { atts.append(Attachment(url: l, kind: .lastFrame, bookmark: createBookmark(for: l))) }
        userMsg.attachments = atts
        messages.append(userMsg)

        let category = (provider ?? selectedProvider).category
        let progressText: String
        switch category {
        case .video: progressText = "正在生成视频…"
        case .image: progressText = "正在生成图片…"
        case .audio: progressText = "正在生成音频…"
        case .text:  progressText = "正在生成回复…"
        }

        let assistantMsg = ChatMessage(role: .assistant, content: progressText, status: .generating(progress: "提交任务中"))
        let msgId = assistantMsg.id
        messages.append(assistantMsg)

        saveCurrentConversation()
        let convId = currentConversationId!

        let taskID = UUID()
        // 先登记再启动：Task 体要等这段同步代码跑完才轮得到（都在主线程串行），
        // 所以内部第一时间读 runningTasks 也能读到自己
        runningTasks[taskID] = RunningGeneration(id: taskID, convId: convId, msgId: msgId,
                                                 source: source, category: category, handle: nil)

        let provider = provider ?? selectedProvider
        let useSearch = webSearchEnabled && provider.supportsWebSearch
        let handle = Task { @MainActor in
            await Context.$taskID.withValue(taskID) {
            do {
                switch category {
                case .video:
                    let url = try await generateVideo(provider: provider, prompt: prompt, duration: duration, aspectRatio: aspectRatio, resolution: resolution, referenceImages: referenceImages, referenceVideos: referenceVideos, referenceAudios: referenceAudios, firstFrame: firstFrame, lastFrame: lastFrame)
                    applyGenerationResult(convId: convId, msgId: msgId, content: "视频生成完成", mediaURL: url, status: .completed(url: url))
                case .image:
                    let url = try await generateImage(provider: provider, prompt: prompt, referenceImages: referenceImages, ratio: imageRatio)
                    applyGenerationResult(convId: convId, msgId: msgId, content: "图片生成完成", mediaURL: url, status: .completedImage(url: url))
                case .audio:
                    let url = try await generateAudio(provider: provider, prompt: prompt)
                    applyGenerationResult(convId: convId, msgId: msgId, content: "音频生成完成", mediaURL: url, status: .completedAudio(url: url))
                case .text:
                    let text = try await generateText(provider: provider, prompt: prompt, webSearch: useSearch)
                    applyGenerationResult(convId: convId, msgId: msgId, content: text, mediaURL: nil, status: .idle)
                }
            } catch is CancellationError {
                applyGenerationResult(convId: convId, msgId: msgId, content: "已取消", mediaURL: nil, status: .failed(error: "已取消生成"))
            } catch {
                applyGenerationResult(convId: convId, msgId: msgId, content: "生成失败: \(error.localizedDescription)", mediaURL: nil, status: .failed(error: error.localizedDescription))
            }
            runningTasks.removeValue(forKey: taskID)
            }
        }
        runningTasks[taskID]?.handle = handle
        return taskID
    }

    // MARK: - 画布生成

    /// 画布节点的生成。跟 `sendPrompt` 的区别是**不碰 messages 和会话** ——
    /// 产物要落到节点上，不该在聊天面板里冒出一条消息。
    /// 进度和结果都通过回调给调用方，任务本身仍登记在 `runningTasks` 里（能取消、能查状态）。
    @discardableResult
    func generateForCanvas(prompt: String,
                           provider: Provider,
                           duration: String = "5",
                           aspectRatio: String = "16:9",
                           resolution: String = "720P",
                           imageRatio: String = "1:1",
                           referenceImages: [URL] = [],
                           referenceVideos: [URL] = [],
                           referenceAudios: [URL] = [],
                           firstFrame: URL? = nil,
                           lastFrame: URL? = nil,
                           modelOverride: String? = nil,
                           onFinish: @escaping (Result<URL, Error>) -> Void) -> UUID {
        let taskID = UUID()
        let category = provider.category
        // convId/msgId 这里用不上，塞占位值 —— RunningGeneration 的字段是给聊天那条路用的
        runningTasks[taskID] = RunningGeneration(id: taskID, convId: UUID(), msgId: UUID(),
                                                 source: .canvas, category: category, handle: nil)

        let handle = Task { @MainActor in
            await Context.$taskID.withValue(taskID) {
                do {
                    let url: URL
                    switch category {
                    case .video:
                        url = try await generateVideo(provider: provider, prompt: prompt,
                                                      duration: duration, aspectRatio: aspectRatio,
                                                      resolution: resolution,
                                                      referenceImages: referenceImages,
                                                      referenceVideos: referenceVideos,
                                                      referenceAudios: referenceAudios,
                                                      firstFrame: firstFrame, lastFrame: lastFrame)
                    case .image:
                        url = try await generateImage(provider: provider, prompt: prompt,
                                                      referenceImages: referenceImages, ratio: imageRatio,
                                                      modelOverride: modelOverride)
                    case .audio:
                        url = try await generateAudio(provider: provider, prompt: prompt)
                    case .text:
                        // 文本节点不走生成，它就是个提示词输入框
                        throw AIError.apiError("文本节点不需要生成")
                    }
                    // **拿到结果也得再验一次有没有被取消。**
                    // `Task.cancel()` 只是竖个标志，请求要是已经跑完了，
                    // 底下的 await 根本不会抛 —— 用户点了取消，图照样出、照样进素材库。
                    // 这一句让它走 catch 的取消分支，结果直接丢掉
                    try Task.checkCancellation()
                    onFinish(.success(url))
                } catch {
                    onFinish(.failure(error))
                }
                runningTasks.removeValue(forKey: taskID)
            }
        }
        runningTasks[taskID]?.handle = handle
        return taskID
    }

    /// 画布上的文本节点生成。产出是文字，不是文件，所以单开一个入口
    @discardableResult
    func generateTextForCanvas(prompt: String, provider: Provider,
                               onFinish: @escaping (Result<String, Error>) -> Void) -> UUID {
        let taskID = UUID()
        runningTasks[taskID] = RunningGeneration(id: taskID, convId: UUID(), msgId: UUID(),
                                                 source: .canvas, category: .text, handle: nil)
        let useSearch = webSearchEnabled && provider.supportsWebSearch
        let handle = Task { @MainActor in
            await Context.$taskID.withValue(taskID) {
                do {
                    let text = try await generateText(provider: provider, prompt: prompt, webSearch: useSearch)
                    onFinish(.success(text))
                } catch {
                    onFinish(.failure(error))
                }
                runningTasks.removeValue(forKey: taskID)
            }
        }
        runningTasks[taskID]?.handle = handle
        return taskID
    }

    /// 某条消息对应的任务还在跑吗。消息气泡上的取消按钮靠它决定显不显示
    func runningTask(forMessage msgId: UUID) -> RunningGeneration? {
        runningTasks.values.first { $0.msgId == msgId }
    }

    /// 取消某条消息对应的那个任务
    func cancelTask(forMessage msgId: UUID) {
        guard let task = runningTask(forMessage: msgId) else { return }
        cancel(taskID: task.id)
    }

    /// 仅供单元测试：直接塞一个在跑的任务，省得真去打 API
    func testHook_insertRunningTask(_ task: RunningGeneration) {
        assert(DiagLog.isUnitTesting, "testHook 只能在测试里用")
        runningTasks[task.id] = task
    }

    /// 取消一个任务
    func cancel(taskID: UUID) {
        let had = runningTasks[taskID]?.handle != nil
        DiagLog.log("[生成] 取消任务 \(taskID.uuidString.prefix(8))："
                    + (had ? "已向它发出取消" : "**找不到它的执行句柄，取消发不出去**"))
        runningTasks[taskID]?.handle?.cancel()
        runningTasks.removeValue(forKey: taskID)
    }

    /// 取消全部在跑的任务（关窗、退出时用）
    func cancelAllGenerations() {
        for (_, task) in runningTasks { task.handle?.cancel() }
        runningTasks.removeAll()
    }

    private func applyGenerationResult(convId: UUID, msgId: UUID, content: String, mediaURL: URL?, status: TaskStatus) {
        if currentConversationId == convId {
            if let idx = messages.firstIndex(where: { $0.id == msgId }) {
                messages[idx].content = content
                messages[idx].status = status
                switch status {
                case .completed(let url):
                    messages[idx].videoURL = url
                    messages[idx].videoBookmark = createBookmark(for: url)
                case .completedImage(let url):
                    messages[idx].imageURL = url
                    messages[idx].imageBookmark = createBookmark(for: url)
                case .completedAudio(let url):
                    messages[idx].audioURL = url
                    messages[idx].audioBookmark = createBookmark(for: url)
                default: break
                }
            }
            saveCurrentConversation()
        } else {
            if let histIdx = history.firstIndex(where: { $0.id == convId }) {
                var videoPath: String? = nil
                var imagePath: String? = nil
                var audioPath: String? = nil
                var videoBookmark: Data? = nil
                var imageBookmark: Data? = nil
                var audioBookmark: Data? = nil
                switch status {
                case .completed(let url):
                    videoPath = url.path; videoBookmark = createBookmark(for: url)
                case .completedImage(let url):
                    imagePath = url.path; imageBookmark = createBookmark(for: url)
                case .completedAudio(let url):
                    audioPath = url.path; audioBookmark = createBookmark(for: url)
                default: break
                }
                var failedError: String? = nil
                if case .failed(let e) = status { failedError = e }
                var entry = ConversationRecord.Entry(id: msgId, isUser: false, text: content, videoPath: videoPath)
                entry.imagePath = imagePath
                entry.audioPath = audioPath
                entry.videoBookmark = videoBookmark
                entry.imageBookmark = imageBookmark
                entry.audioBookmark = audioBookmark
                entry.failedError = failedError
                if let eIdx = history[histIdx].entries.firstIndex(where: { $0.id == msgId }) {
                    history[histIdx].entries[eIdx] = entry
                } else {
                    history[histIdx].entries.append(entry)
                }
                saveHistoryToDisk()
            }
        }
    }

    func clearHistory() {
        saveCurrentConversation()
        messages.removeAll()
        currentConversationId = nil
    }

    // MARK: - 画布会话

    /// 新建一张画布，返回它的会话 id
    @discardableResult
    func newCanvasConversation() -> UUID {
        // 手上那条先存了再走，顺手把消息清空 —— 只改 id 不清 messages 的话，
        // 新画布的聊天区里会挂着上一条会话的记录（画布里那张卡片直接就看得见）
        saveCurrentConversation()
        stashInputDraft()
        let id = UUID()
        history.insert(ConversationRecord(id: id, title: "未命名画布", createdAt: Date(),
                                          entries: [], canvas: .init()), at: 0)
        // 画布跟聊天一样算「当前会话」，否则历史列表的高亮会一直停在上次那条对话上
        currentConversationId = id
        restoreInputDraft(id)       // 新会话：草稿附件都是空的
        messages.removeAll()
        saveHistoryToDisk()
        return id
    }

    /// 保存一张画布的当前状态
    func saveCanvas(_ snapshot: ConversationRecord.CanvasSnapshot, id: UUID, title: String) {
        guard let i = history.firstIndex(where: { $0.id == id }) else { return }
        history[i].canvas = snapshot
        // 用户自己起过名字就别再按内容改回去
        if !history[i].titleIsCustom { history[i].title = title }
        saveHistoryToDisk()
    }

    func canvasRecord(_ id: UUID) -> ConversationRecord? {
        history.first { $0.id == id && $0.isCanvas }
    }

    /// 新建一条聊天会话。**立刻在历史里落一条** ——
    /// 原来是等发了第一条消息才建，用户点「新建」后历史列表没反应，
    /// 看着像没生效
    func newConversation() {
        saveCurrentConversation()
        stashInputDraft()
        messages.removeAll()
        let id = UUID()
        history.insert(ConversationRecord(id: id, title: "新对话", createdAt: Date(),
                                          entries: [], canvas: nil), at: 0)
        currentConversationId = id
        restoreInputDraft(id)       // 新会话：草稿附件都是空的
        saveHistoryToDisk()
    }

    // MARK: - Agent 会话

    /// 用户那条消息先落进会话，Agent 回答回来再补一条
    @discardableResult
    /// 造一条附件记录。书签一起带上 —— 用户之后挪了文件也还认得
    func makeAttachment(url: URL, kind: AttachmentKind) -> Attachment {
        Attachment(url: url, kind: kind, bookmark: createBookmark(for: url))
    }

    /// `attachments` 是这一轮挂上去的参考图 / 参考内容 / 普通附件。
    /// 不带的话发出去的气泡是光秃秃一行字，翻记录根本看不出当时给了什么图
    func appendUserEntry(_ text: String, attachments: [Attachment] = []) -> UUID {
        if currentConversationId == nil { newConversation() }
        var msg = ChatMessage(role: .user, content: text)
        msg.attachments = attachments
        messages.append(msg)
        persist(msg, isUser: true, steps: nil)
        return msg.id
    }

    /// Agent 的回答 + 它这一轮调过哪些工具
    /// 生成完了往会话里插一张卡片。
    ///
    /// **不占位**：提交时就插一条「正在生成…」跟左上角那个后台任务标签
    /// 说的是同一件事，两处一起转没意义。做完了再出现卡片就行
    func appendAgentMedia(url: URL, category: ProviderCategory) {
        if currentConversationId == nil { newConversation() }
        var msg: ChatMessage
        switch category {
        case .image:
            msg = ChatMessage(role: .assistant, content: "图片生成完成",
                              imageURL: url, status: .completedImage(url: url))
            msg.imageBookmark = createBookmark(for: url)
        case .audio:
            msg = ChatMessage(role: .assistant, content: "音频生成完成",
                              audioURL: url, status: .completedAudio(url: url))
            msg.audioBookmark = createBookmark(for: url)
        default:
            msg = ChatMessage(role: .assistant, content: "视频生成完成",
                              videoURL: url, status: .completed(url: url))
            msg.videoBookmark = createBookmark(for: url)
        }
        messages.append(msg)
        let conv = currentConversationId ?? UUID()
        applyGenerationResult(convId: conv, msgId: msg.id, content: msg.content,
                              mediaURL: url, status: msg.status)
    }

    /// 生成失败或被取消，往会话里留一条。
    ///
    /// 进行中那条占位是去掉了（跟左上角后台任务标签重复），但**结束态得有** ——
    /// 不然点了取消，聊天里什么都没发生，看着像没取消掉
    /// 往会话里记一句普通说明（不是报错）。
    ///
    /// 后台任务结束得让模型知道 —— 它只清楚自己提交过，之后是成了、砸了、
    /// 还是被用户取消了，一概看不到。不留痕的话用户再说一遍同样的需求，
    /// 它当没做过又提交一个，任务就这么一轮一轮累加上去
    func appendAgentNote(_ text: String) {
        if currentConversationId == nil { newConversation() }
        let msg = ChatMessage(role: .assistant, content: text)
        messages.append(msg)
        persist(msg, isUser: false, steps: nil)
    }

    func appendAgentFailure(_ text: String) {
        if currentConversationId == nil { newConversation() }
        let msg = ChatMessage(role: .assistant, content: text,
                              status: .failed(error: text))
        messages.append(msg)
        persist(msg, isUser: false, steps: nil)
    }

    /// Agent 开跑就先占一条空回复：步骤要实时长在这条气泡里，
    /// 等跑完再 append 的话，整个过程用户看不到东西
    func beginAgentReply() -> UUID {
        if currentConversationId == nil { newConversation() }
        let msg = ChatMessage(role: .assistant, content: "")
        messages.append(msg)
        return msg.id
    }

    /// 跑完了，把正文和这一轮的步骤填进那条占位回复，同时落盘
    /// 兜底：把模型伪造的执行记录从回复里抠掉。
    ///
    /// 模型有时一个工具都没调，却照着历史里的记录格式编一段
    /// 「`<tool_log>` · generate_image(…) → 已提交后台任务」出来，用户信以为真、
    /// 等一个根本不存在的任务。提示词和历史格式都改过，仍不能保证它老实，
    /// 所以真调过工具才允许出现这种段落，没调过就整段删掉
    static func stripFakeToolLog(_ text: String, didCallTools: Bool) -> String {
        guard !didCallTools else { return text }
        var s = text
        // 成对标签整块删；只有开标签没闭合的，从标签处截断
        while let open = s.range(of: "<tool_log>") {
            if let close = s.range(of: "</tool_log>", range: open.upperBound..<s.endIndex) {
                s.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                s = String(s[s.startIndex..<open.lowerBound])
                break
            }
        }
        if let r = s.range(of: "[系统记录·你上一轮实际执行过的工具]") {
            s = String(s[s.startIndex..<r.lowerBound])
        }
        let out = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if out != text.trimmingCharacters(in: .whitespacesAndNewlines) {
            DiagLog.log("[会话] 这一轮一个工具都没调，回复里却带着伪造的执行记录，已删掉那段")
        }
        return out
    }

    func finishAgentReply(id: UUID, text: String,
                          steps: [ConversationRecord.AgentStepRecord],
                          elapsed: TimeInterval = 0, tokens: Int = 0) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        let clean = Self.stripFakeToolLog(text, didCallTools: !steps.isEmpty)
        messages[i].content = clean.isEmpty ? "（没有输出）" : clean
        DiagLog.log("[会话] 存回复：步骤 \(steps.count) 步"
                  + (steps.isEmpty ? "" : "（\(steps.map(\.tool).joined(separator: "、"))）"))
        messages[i].agentSteps = steps.isEmpty ? nil : steps
        messages[i].agentElapsed = elapsed > 0 ? elapsed : nil
        messages[i].agentTokens = tokens > 0 ? tokens : nil
        persist(messages[i], isUser: false, steps: steps.isEmpty ? nil : steps)
    }

    private func persist(_ msg: ChatMessage, isUser: Bool,
                         steps: [ConversationRecord.AgentStepRecord]?) {
        guard let cid = currentConversationId,
              let i = history.firstIndex(where: { $0.id == cid }) else { return }
        var entry = ConversationRecord.Entry(id: msg.id, isUser: isUser,
                                             text: msg.content, videoPath: nil)
        entry.agentSteps = steps
        entry.agentElapsed = msg.agentElapsed
        entry.agentTokens = msg.agentTokens
        if case .failed(let e) = msg.status { entry.failedError = e }
        history[i].entries.append(entry)
        // 会话标题还是「新对话」时，拿用户第一句话当标题
        if isUser, !history[i].titleIsCustom,
           history[i].title == "新对话" || history[i].title.isEmpty {
            history[i].title = String(msg.content.prefix(20))
        }
        saveHistoryToDisk()
    }

    func loadConversation(_ id: UUID) {
        saveCurrentConversation()
        stashInputDraft()
        guard let conv = history.first(where: { $0.id == id }) else { return }
        currentConversationId = conv.id
        restoreInputDraft(conv.id)
        messages = conv.entries.map { entry in
            if entry.isUser {
                var msg = ChatMessage(id: entry.id, role: .user, content: entry.text)
                msg.attachments = entry.attachments ?? []
                return msg
            } else {
                if let url = resolveMediaURL(path: entry.videoPath, bookmark: entry.videoBookmark) {
                    var msg = ChatMessage(id: entry.id, role: .assistant, content: entry.text, videoURL: url, status: .completed(url: url))
                    msg.videoBookmark = entry.videoBookmark
                    return msg
                } else if let url = resolveMediaURL(path: entry.imagePath, bookmark: entry.imageBookmark) {
                    var msg = ChatMessage(id: entry.id, role: .assistant, content: entry.text, imageURL: url, status: .completedImage(url: url))
                    msg.imageBookmark = entry.imageBookmark
                    return msg
                } else if let url = resolveMediaURL(path: entry.audioPath, bookmark: entry.audioBookmark) {
                    var msg = ChatMessage(id: entry.id, role: .assistant, content: entry.text, audioURL: url, status: .completedAudio(url: url))
                    msg.audioBookmark = entry.audioBookmark
                    return msg
                } else {
                    var msg = ChatMessage(id: entry.id, role: .assistant, content: entry.text,
                                          status: entry.failedError.map { .failed(error: $0) } ?? .idle)
                    msg.agentSteps = entry.agentSteps
                    msg.agentElapsed = entry.agentElapsed
                    msg.agentTokens = entry.agentTokens
                    return msg
                }
            }
        }
        // 切回一个还在生成的会话时，把它那条占位消息补回来。
        // 多任务之后同一个会话可能挂着好几条，逐个补
        for task in runningTasks.values where task.convId == id {
            guard !messages.contains(where: { $0.id == task.msgId }) else { continue }
            let text: String
            switch task.category {
            case .video: text = "正在生成视频…"
            case .image: text = "正在生成图片…"
            case .audio: text = "正在生成音频…"
            case .text:  text = "正在生成回复…"
            }
            messages.append(ChatMessage(id: task.msgId, role: .assistant, content: text,
                                        status: .generating(progress: "生成中，请等待…")))
        }
    }

    func deleteConversation(_ id: UUID) {
        if currentConversationId == id {
            messages.removeAll()
            currentConversationId = nil
        }
        history.removeAll { $0.id == id }
        saveHistoryToDisk()
    }

    /// 重命名。空标题不写 —— 列表里顶一行空名字，找不着这条记录了
    func renameConversation(_ id: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = history.firstIndex(where: { $0.id == id }) else { return }
        history[i].title = trimmed
        history[i].titleIsCustom = true
        saveHistoryToDisk()
    }

    func saveCurrentConversation() {
        let validMessages = messages.filter { msg in
            if msg.role == .user { return true }
            if case .generating = msg.status { return false }
            if case .downloading = msg.status { return false }
            return true
        }
        guard !validMessages.isEmpty else { return }

        let entries = validMessages.map { msg -> ConversationRecord.Entry in
            var videoPath: String? = nil
            var imagePath: String? = nil
            var audioPath: String? = nil
            var videoBookmark: Data? = nil
            var imageBookmark: Data? = nil
            var audioBookmark: Data? = nil
            switch msg.status {
            case .completed(let url):
                videoPath = url.path
                videoBookmark = createBookmark(for: url)
            case .completedImage(let url):
                imagePath = url.path
                imageBookmark = createBookmark(for: url)
            case .completedAudio(let url):
                audioPath = url.path
                audioBookmark = createBookmark(for: url)
            default: break
            }
            var entry = ConversationRecord.Entry(id: msg.id, isUser: msg.role == .user, text: msg.content, videoPath: videoPath)
            entry.imagePath = imagePath
            entry.audioPath = audioPath
            entry.videoBookmark = videoBookmark
            entry.imageBookmark = imageBookmark
            entry.audioBookmark = audioBookmark
            entry.attachments = msg.attachments.isEmpty ? nil : msg.attachments
            // **步骤/耗时/用量/失败原因必须一起带上**：这个方法是拿 messages 全量
            // 重建 entries 再整个覆盖回去的，漏掉的字段等于被清空 ——
            // finishAgentReply 刚 persist 好的步骤，会在切会话/关窗时被冲成 nil。
            // 现象是「跑的时候步骤条在，重启就没了」（存档 337 条一条步骤都没剩下）
            entry.agentSteps = msg.agentSteps
            entry.agentElapsed = msg.agentElapsed
            entry.agentTokens = msg.agentTokens
            if case .failed(let e) = msg.status { entry.failedError = e }
            return entry
        }
        let title = String((validMessages.first(where: { $0.role == .user })?.content ?? "对话").prefix(30))

        if let cid = currentConversationId, let idx = history.firstIndex(where: { $0.id == cid }) {
            history[idx].entries = entries
            // 用户自己起过名就别按内容改回去。这个方法每次切会话都会跑一遍，
            // 原来无条件覆盖 —— 重命名完随便点进另一条，名字就被冲回
            // 「第一条消息的前 30 字」。saveCanvas 和 persist 都有这道，唯独这儿漏了
            if !history[idx].titleIsCustom { history[idx].title = title }
        } else {
            let conv = ConversationRecord(id: UUID(), title: title, createdAt: Date(), entries: entries)
            history.insert(conv, at: 0)
            currentConversationId = conv.id
        }
        saveHistoryToDisk()
    }

    private var historyFileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BlackCat")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ai_conversations.json")
    }

    private func saveHistoryToDisk() {
        // 读失败过就别写了 —— 空列表写下去等于把用户的历史全抹了
        guard !historyLoadFailed else {
            DiagLog.log("[AI历史] 上次加载失败，拒绝写盘（避免覆盖已有记录）")
            return
        }
        guard let data = try? JSONEncoder().encode(history) else { return }
        // 写之前留一份上一版。这个文件是用户几十条对话，值这点磁盘
        let backup = historyFileURL.deletingPathExtension().appendingPathExtension("bak.json")
        if let old = try? Data(contentsOf: historyFileURL), !old.isEmpty {
            try? old.write(to: backup)
        }
        try? data.write(to: historyFileURL)
    }

    /// 加载历史失败过。**失败之后一律不许写盘** ——
    /// 2026-08-21 就是这么丢的：给 CanvasNode 加了几个字段，旧记录缺键、
    /// 整个数组解不出来，`try?` 静默吞掉变成空列表，用户一操作就把 29 条覆盖成 1 条
    private(set) var historyLoadFailed = false

    private func loadHistory() {
        guard let data = try? Data(contentsOf: historyFileURL) else { return }
        do {
            history = try JSONDecoder().decode([ConversationRecord].self, from: data)
        } catch {
            // 整条数组解不动时，退一步逐条解 —— 坏一条不该连累其余的
            historyLoadFailed = true
            DiagLog.log("[AI历史] 整体解码失败：\(error)")
            if let raw = try? JSONSerialization.jsonObject(with: data) as? [Any] {
                var salvaged: [ConversationRecord] = []
                for item in raw {
                    guard let d = try? JSONSerialization.data(withJSONObject: item),
                          let rec = try? JSONDecoder().decode(ConversationRecord.self, from: d)
                    else { continue }
                    salvaged.append(rec)
                }
                history = salvaged
                DiagLog.log("[AI历史] 逐条抢救回 \(salvaged.count)/\(raw.count) 条")
                // 抢救到东西就允许继续写盘，否则宁可只读不写
                historyLoadFailed = salvaged.isEmpty
            }
        }
    }

    // MARK: - API 调用

    private func generateVideo(provider: Provider, prompt: String, duration: String, aspectRatio: String, resolution: String, referenceImages: [URL], referenceVideos: [URL] = [], referenceAudios: [URL] = [], firstFrame: URL?, lastFrame: URL?) async throws -> URL {
        switch provider {
        case .kling:
            return try await generateWithKling(prompt: prompt, duration: duration, aspectRatio: aspectRatio, referenceImage: referenceImages.first ?? firstFrame, lastFrame: lastFrame)
        case .runway:
            return try await generateWithRunway(prompt: prompt, duration: duration, aspectRatio: aspectRatio, referenceImage: referenceImages.first ?? firstFrame)
        case .seedance:
            let ver = AppSettings.shared.providerModel(for: provider.rawValue)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let is25 = ver == "2.5"
            var ep = (is25 ? settings.seedance25Endpoint : settings.seedanceEndpoint)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // 方舟的 model 字段既收接入点 ID 也收官方 Model ID，2.5 留空就用官方的
            if ep.isEmpty && is25 { ep = "doubao-seedance-2-5-260628" }
            guard !ep.isEmpty else {
                throw AIError.missingAPIKey("请先在设置中填写 Seedance \(is25 ? "2.5" : "2.0") 的接入点 ID")
            }
            return try await generateWithSeedance(model: ep, prompt: prompt, duration: duration, aspectRatio: aspectRatio, resolution: resolution, referenceImages: referenceImages, referenceVideos: referenceVideos, referenceAudios: referenceAudios, firstFrame: firstFrame, lastFrame: lastFrame)
        case .seedance15:
            let ep = settings.seedance15Endpoint
            guard !ep.isEmpty else { throw AIError.missingAPIKey("请先在设置中填写 Seedance 1.5 Pro 的接入点 ID") }
            return try await generateWithSeedance(model: ep, prompt: prompt, duration: duration, aspectRatio: aspectRatio, resolution: resolution, referenceImages: referenceImages, referenceVideos: referenceVideos, referenceAudios: referenceAudios, firstFrame: firstFrame, lastFrame: lastFrame)
        case .minimax:
            return try await generateWithMiniMax(prompt: prompt, duration: duration, aspectRatio: aspectRatio,
                                                 resolution: resolution,
                                                 referenceImages: referenceImages,
                                                 referenceVideos: referenceVideos,
                                                 referenceAudios: referenceAudios,
                                                 firstFrame: firstFrame, lastFrame: lastFrame)
        case .vidu:
            return try await generateWithVidu(prompt: prompt, duration: duration, aspectRatio: aspectRatio, referenceImage: referenceImages.first ?? firstFrame)
        case .veo3:
            return try await generateWithVeo3(prompt: prompt, duration: duration, aspectRatio: aspectRatio, referenceImage: referenceImages.first ?? firstFrame)
        case .grokVideo:
            return try await generateWithGrokVideo(prompt: prompt, duration: duration, aspectRatio: aspectRatio)
        default:
            throw AIError.missingAPIKey("\(provider.displayName) 尚未支持，敬请期待")
        }
    }

    // MARK: - Kling API

    private func generateWithKling(prompt: String, duration: String, aspectRatio: String, referenceImage: URL? = nil, lastFrame: URL? = nil) async throws -> URL {
        // 可灵现在有两套鉴权：API Key 适用于所有模型（含 3.0），
        // Access Key + Secret Key 只对旧版 API 有效。填了 API Key 就优先用它，
        // 没填才回退到旧的 JWT 签名，免得动了老配置
        let apiKey = settings.providerAPIKey(for: Provider.kling.rawValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let token: String
        if !apiKey.isEmpty {
            token = apiKey
        } else {
            let accessKey = settings.aiAccessKey
            let secretKey = settings.aiSecretKey
            guard !accessKey.isEmpty, !secretKey.isEmpty else {
                throw AIError.missingAPIKey("请先在设置中填写可灵的 API Key（或旧版的 Access Key / Secret Key）")
            }
            token = try generateKlingJWT(accessKey: accessKey, secretKey: secretKey)
        }

        let hasImage = referenceImage != nil
        let taskId = try await createKlingTask(token: token, prompt: prompt, duration: duration, aspectRatio: aspectRatio, referenceImage: referenceImage, lastFrame: lastFrame)

        updateAssistantStatus(.generating(progress: "生成中，请等待…"))

        let videoURLString = try await pollKlingTask(token: token, taskId: taskId, endpoint: hasImage ? "image2video" : "text2video")

        updateAssistantStatus(.downloading(progress: 0))
        let localURL = try await downloadFile(from: videoURLString, filename: "kling_\(taskId).mp4")

        return localURL
    }

    private func generateKlingJWT(accessKey: String, secretKey: String) throws -> String {
        let header = ["alg": "HS256", "typ": "JWT"]
        let now = Int(Date().timeIntervalSince1970)
        let payload: [String: Any] = [
            "iss": accessKey,
            "exp": now + 1800,
            "nbf": now - 5,
            "iat": now
        ]

        let headerData = try JSONSerialization.data(withJSONObject: header)
        let payloadData = try JSONSerialization.data(withJSONObject: payload)

        let headerB64 = headerData.base64URLEncoded()
        let payloadB64 = payloadData.base64URLEncoded()

        let signingInput = "\(headerB64).\(payloadB64)"
        guard let signingData = signingInput.data(using: .utf8),
              let keyData = secretKey.data(using: .utf8) else {
            throw AIError.invalidKey
        }

        let signature = hmacSHA256(data: signingData, key: keyData)
        let signatureB64 = signature.base64URLEncoded()

        return "\(headerB64).\(payloadB64).\(signatureB64)"
    }

    private func hmacSHA256(data: Data, key: Data) -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: symmetricKey)
        return Data(mac)
    }

    private func createKlingTask(token: String, prompt: String, duration: String, aspectRatio: String, referenceImage: URL? = nil, lastFrame: URL? = nil) async throws -> String {
        let hasImage = referenceImage != nil
        // 设置里填了接口地址就走它（中转/自建），只取 base 再拼两条路径
        let klingBase: String = {
            let raw = AppSettings.shared.providerBaseURL(for: Provider.kling.rawValue)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return "https://api.klingai.com" }
            var b = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
            if let r = b.range(of: "/v1/") { b = String(b[b.startIndex..<r.lowerBound]) }
            else if b.hasSuffix("/v1") { b = String(b.dropLast(3)) }
            return b
        }()
        let klingModel = chosenModel(.kling, fallback: "kling-v3")
        let endpoint = hasImage ? "\(klingBase)/v1/videos/image2video" : "\(klingBase)/v1/videos/text2video"
        let url = URL(string: endpoint)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "model_name": klingModel,
            "prompt": prompt,
            "duration": duration,
            "aspect_ratio": aspectRatio,
            "mode": "std"
        ]
        if let imgURL = referenceImage, let b64 = imageToBase64(imgURL) {
            body["image"] = b64
        }
        if let tailURL = lastFrame, let b64 = imageToBase64(tailURL) {
            body["tail_image"] = b64
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "未知错误"
            throw AIError.apiError(msg)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let dataObj = json?["data"] as? [String: Any],
              let taskId = dataObj["task_id"] as? String else {
            throw AIError.apiError("无法解析任务 ID")
        }
        return taskId
    }

    private func pollKlingTask(token: String, taskId: String, endpoint: String = "text2video") async throws -> String {
        let base: String = {
            let raw = AppSettings.shared.providerBaseURL(for: Provider.kling.rawValue)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return "https://api.klingai.com" }
            var b = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
            if let r = b.range(of: "/v1/") { b = String(b[b.startIndex..<r.lowerBound]) }
            else if b.hasSuffix("/v1") { b = String(b.dropLast(3)) }
            return b
        }()
        let url = URL(string: "\(base)/v1/videos/\(endpoint)/\(taskId)")!
        for _ in 0..<120 {
            try await Task.sleep(nanoseconds: 5_000_000_000)

            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, _) = try await URLSession.shared.data(for: request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let dataObj = json?["data"] as? [String: Any],
                  let status = dataObj["task_status"] as? String else { continue }

            if status == "succeed" {
                if let result = dataObj["task_result"] as? [String: Any],
                   let videos = result["videos"] as? [[String: Any]],
                   let videoURL = videos.first?["url"] as? String {
                    return videoURL
                }
                throw AIError.apiError("任务成功但无视频 URL")
            } else if status == "failed" {
                let msg = (dataObj["task_status_msg"] as? String) ?? "生成失败"
                throw AIError.apiError(msg)
            }

            await MainActor.run {
                updateAssistantStatus(.generating(progress: "生成中…"))
            }
        }
        throw AIError.timeout
    }

    // MARK: - Runway API

    private func generateWithRunway(prompt: String, duration: String, aspectRatio: String, referenceImage: URL? = nil) async throws -> URL {
        let apiKey = settings.aiAccessKey
        guard !apiKey.isEmpty else {
            throw AIError.missingAPIKey("请先在设置中填写 Runway API Key")
        }

        let taskId = try await createRunwayTask(apiKey: apiKey, prompt: prompt, duration: duration, aspectRatio: aspectRatio, referenceImage: referenceImage)

        updateAssistantStatus(.generating(progress: "生成中，请等待…"))

        let videoURLString = try await pollRunwayTask(apiKey: apiKey, taskId: taskId)

        updateAssistantStatus(.downloading(progress: 0))
        let localURL = try await downloadFile(from: videoURLString, filename: "runway_\(taskId).mp4")

        return localURL
    }

    private func createRunwayTask(apiKey: String, prompt: String, duration: String, aspectRatio: String, referenceImage: URL? = nil) async throws -> String {
        let hasImage = referenceImage != nil
        let endpoint = hasImage ? "https://api.dev.runwayml.com/v1/image_to_video" : "https://api.dev.runwayml.com/v1/text_to_video"
        let url = URL(string: endpoint)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2024-11-06", forHTTPHeaderField: "X-Runway-Version")

        let durationInt = Int(duration) ?? 5
        var body: [String: Any] = [
            "model": "gen4_turbo",
            "promptText": prompt,
            "duration": durationInt,
            "ratio": aspectRatio.replacingOccurrences(of: ":", with: "x")
        ]
        if let imgURL = referenceImage, let b64 = imageToBase64DataURI(imgURL) {
            body["promptImage"] = b64
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResp = response as? HTTPURLResponse, (200...299).contains(httpResp.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "未知错误"
            throw AIError.apiError(msg)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let taskId = json?["id"] as? String else {
            throw AIError.apiError("无法解析任务 ID")
        }
        return taskId
    }

    private func pollRunwayTask(apiKey: String, taskId: String) async throws -> String {
        let url = URL(string: "https://api.dev.runwayml.com/v1/tasks/\(taskId)")!
        for _ in 0..<120 {
            try await Task.sleep(nanoseconds: 5_000_000_000)

            var request = URLRequest(url: url)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("2024-11-06", forHTTPHeaderField: "X-Runway-Version")

            let (data, _) = try await URLSession.shared.data(for: request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let status = json?["status"] as? String else { continue }

            if status == "SUCCEEDED" {
                if let output = json?["output"] as? [String],
                   let videoURL = output.first {
                    return videoURL
                }
                throw AIError.apiError("任务成功但无视频 URL")
            } else if status == "FAILED" {
                let msg = (json?["failure"] as? String) ?? "生成失败"
                throw AIError.apiError(msg)
            }
        }
        throw AIError.timeout
    }

    // MARK: - Seedance API

    private func generateWithSeedance(model: String, prompt: String, duration: String, aspectRatio: String, resolution: String = "", referenceImages: [URL] = [], referenceVideos: [URL] = [], referenceAudios: [URL] = [], firstFrame: URL? = nil, lastFrame: URL? = nil) async throws -> URL {
        let apiKey = settings.seedanceApiKey
        guard !apiKey.isEmpty else {
            throw AIError.missingAPIKey("请先在设置中填写 Seedance API Key")
        }

        let taskId = try await createSeedanceTask(apiKey: apiKey, model: model, prompt: prompt, duration: duration, aspectRatio: aspectRatio, resolution: resolution, referenceImages: referenceImages, referenceVideos: referenceVideos, referenceAudios: referenceAudios, firstFrame: firstFrame, lastFrame: lastFrame)

        updateAssistantStatus(.generating(progress: "生成中，请等待…"))

        let videoURLString = try await pollSeedanceTask(apiKey: apiKey, taskId: taskId)

        updateAssistantStatus(.downloading(progress: 0))
        let localURL = try await downloadFile(from: videoURLString, filename: "seedance_\(taskId).mp4")

        return localURL
    }

    private func createSeedanceTask(apiKey: String, model: String, prompt: String, duration: String, aspectRatio: String, resolution: String = "", referenceImages: [URL] = [], referenceVideos: [URL] = [], referenceAudios: [URL] = [], firstFrame: URL? = nil, lastFrame: URL? = nil) async throws -> String {
        let url = URL(string: "https://ark.cn-beijing.volces.com/api/v3/contents/generations/tasks")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // 火山文档：首尾帧（role=first_frame/last_frame）与多模态参考（role=reference_image）
        // 是互斥场景，role 必填。之前完全没传 role，参考图才不生效。
        var reqContent: [[String: Any]] = []
        let useFrames = firstFrame != nil || lastFrame != nil

        if useFrames {
            if let f = firstFrame, let b64 = compressedImageDataURI(f, maxDimension: 2048) {
                reqContent.append(["type": "image_url", "image_url": ["url": b64], "role": "first_frame"])
            }
            if let l = lastFrame, let b64 = compressedImageDataURI(l, maxDimension: 2048) {
                reqContent.append(["type": "image_url", "image_url": ["url": b64], "role": "last_frame"])
            }
        } else {
            for imgURL in referenceImages {
                if let b64 = compressedImageDataURI(imgURL, maxDimension: 2048) {
                    reqContent.append(["type": "image_url", "image_url": ["url": b64], "role": "reference_image"])
                }
            }
            for vidURL in referenceVideos {
                if let b64 = fileToBase64DataURI(vidURL, mime: "video/mp4") {
                    reqContent.append(["type": "video_url", "video_url": ["url": b64], "role": "reference_video"])
                }
            }
            for audURL in referenceAudios {
                if let b64 = fileToBase64DataURI(audURL, mime: "audio/mpeg") {
                    reqContent.append(["type": "input_audio", "input_audio": ["url": b64], "role": "reference_audio"])
                }
            }
        }
        reqContent.append(["type": "text", "text": prompt])
        // 方舟的规格参数是顶层字段（也可以写成提示词末尾的 --ratio 之类），
        // 之前塞在 parameters 对象里，服务端根本不认，比例/时长/分辨率一直是默认值
        var body: [String: Any] = [
            "model": model,
            "content": reqContent,
            "duration": max(1, Int(duration) ?? 5),
            "watermark": false
        ]
        // 有首帧时画幅由首帧决定，再指定 ratio 会冲突
        if firstFrame == nil { body["ratio"] = aspectRatio }
        let res = resolution.isEmpty ? settings.aiResolution : resolution
        if !res.isEmpty { body["resolution"] = res.lowercased() }   // 480p / 720p / 1080p
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResp = response as? HTTPURLResponse, (200...299).contains(httpResp.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "未知错误"
            throw AIError.apiError(msg)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let taskId = json?["id"] as? String else {
            throw AIError.apiError("无法解析任务 ID")
        }
        return taskId
    }

    private func pollSeedanceTask(apiKey: String, taskId: String) async throws -> String {
        let url = URL(string: "https://ark.cn-beijing.volces.com/api/v3/contents/generations/tasks/\(taskId)")!
        for _ in 0..<120 {
            try await Task.sleep(nanoseconds: 5_000_000_000)

            var request = URLRequest(url: url)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

            let (data, _) = try await URLSession.shared.data(for: request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let status = json?["status"] as? String else { continue }

            if status == "succeeded" {
                if let content = json?["content"] as? [String: Any],
                   let videoURL = content["video_url"] as? String {
                    return videoURL
                }
                throw AIError.apiError("任务成功但无视频 URL")
            } else if status == "failed" {
                let error = json?["error"] as? [String: Any]
                let msg = (error?["message"] as? String) ?? "生成失败"
                throw AIError.apiError(msg)
            }

            await MainActor.run {
                updateAssistantStatus(.generating(progress: "生成中…"))
            }
        }
        throw AIError.timeout
    }

    // MARK: - 图片尺寸

    /// 把 "16:9" 这类比例换算成像素宽高，长边贴近 targetLong，并对齐到 step 的整数倍
    /// 方舟出图的尺寸。
    ///
    /// 它对 size 的要求是**总像素**落在 [2560×1440, 4096×4096] 之间，不是限制长边 ——
    /// 按长边 2048 算的话，16:9 只有 2048×1152（235 万像素），不到下限会直接 400。
    /// 所以这里按面积推，再各自对齐到 64 的倍数
    private func arkImageSize(ratio: String) -> (w: Int, h: Int) {
        let parts = ratio.split(separator: ":").compactMap { Double($0) }
        let r: Double = (parts.count == 2 && parts[0] > 0 && parts[1] > 0) ? parts[0] / parts[1] : 1
        let target = 2048.0 * 2048.0          // 落在上下限中间，留足余量
        func align(_ v: Double) -> Int { max(64, Int((v / 64).rounded()) * 64) }
        var w = align((target * r).squareRoot())
        var h = align((target / r).squareRoot())
        // 单边不超过 4096
        if w > 4096 { h = align(Double(h) * 4096 / Double(w)); w = 4096 }
        if h > 4096 { w = align(Double(w) * 4096 / Double(h)); h = 4096 }
        // 极端比例下仍可能不够总像素下限，整体放大补上
        let minPixels = 2560.0 * 1440.0
        let cur = Double(w * h)
        if cur < minPixels {
            let k = (minPixels / cur).squareRoot() * 1.02
            w = min(4096, align(Double(w) * k))
            h = min(4096, align(Double(h) * k))
        }
        return (w, h)
    }

    private func pixelSize(ratio: String, targetLong: Int, step: Int = 64) -> (w: Int, h: Int) {
        let parts = ratio.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else {
            return (targetLong, targetLong)
        }
        let (rw, rh) = (parts[0], parts[1])
        var w: Double, h: Double
        if rw >= rh {
            w = Double(targetLong)
            h = w * rh / rw
        } else {
            h = Double(targetLong)
            w = h * rw / rh
        }
        func align(_ v: Double) -> Int { max(step, Int((v / Double(step)).rounded()) * step) }
        return (align(w), align(h))
    }

    /// Stability SD3 的 aspect_ratio 只接受固定枚举，取数值最接近的一个
    private static func sd3AspectRatio(_ ratio: String) -> String {
        let allowed = ["21:9", "16:9", "3:2", "5:4", "1:1", "4:5", "2:3", "9:16", "9:21"]
        func value(_ s: String) -> Double? {
            let p = s.split(separator: ":").compactMap { Double($0) }
            guard p.count == 2, p[1] > 0 else { return nil }
            return p[0] / p[1]
        }
        guard let target = value(ratio) else { return "1:1" }
        if allowed.contains(ratio) { return ratio }
        return allowed.min(by: { abs((value($0) ?? 1) - target) < abs((value($1) ?? 1) - target) }) ?? "1:1"
    }

    /// OpenAI 图片接口只接受三种尺寸，按比例取最接近的
    /// 把界面上的比例换成 OpenAI 的 size 参数。
    ///
    /// gpt-image-2 收任意尺寸（宽高各须被 16 整除、比例 1:3~3:1），所以按比例实算，
    /// 21:9 这种宽幅也能真出宽幅；gpt-image-1 只认三个固定档，只能就近归档
    private func openAISize(ratio: String, model: String = "") -> String {
        let parts = ratio.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts[1] > 0 else { return "1024x1024" }
        let r = parts[0] / parts[1]

        guard model.contains("gpt-image-2") else {
            if r > 1.15 { return "1536x1024" }
            if r < 0.87 { return "1024x1536" }
            return "1024x1024"
        }

        // 比例超出 1:3~3:1 会被拒，先夹住
        let clamped = min(3.0, max(1.0 / 3.0, r))
        // 面积对齐官方标准档（1536×1024≈1.57M 像素），再各自取 16 的倍数
        let area = 1536.0 * 1024.0
        func align16(_ v: Double) -> Int { max(256, Int((v / 16).rounded()) * 16) }
        var w = align16((area * clamped).squareRoot())
        var h = align16((area / clamped).squareRoot())
        // 官方上限 3840×2160，超过 2560×1440 属实验性，这里不越过上限
        if w > 3840 { w = 3840 }
        if h > 2160 { h = 2160 }
        return "\(w)x\(h)"
    }

    // MARK: - 图片生成

    private func generateImage(provider: Provider, prompt: String, referenceImages: [URL] = [], ratio: String = "1:1",
                               modelOverride: String? = nil) async throws -> URL {
        // Seedream 与 Seedance 同属火山方舟，共用 seedanceApiKey
        if provider == .seedream {
            return try await generateWithSeedream(prompt: prompt, referenceImages: referenceImages, ratio: ratio,
                                                  modelOverride: modelOverride)
        }
        let apiKey = settings.providerAPIKey(for: provider.rawValue)
        guard !apiKey.isEmpty else {
            throw AIError.missingAPIKey("请先在设置中填写 \(provider.displayName) 的 API Key")
        }
        switch provider {
        case .nanobanana2:
            return try await generateWithNanobanana2(prompt: prompt, referenceImages: referenceImages, ratio: ratio)
        case .gptImage2:
            return try await generateWithGPTImage(apiKey: apiKey, prompt: prompt, referenceImages: referenceImages, ratio: ratio)
        case .flux:
            return try await generateWithFlux(apiKey: apiKey, prompt: prompt, ratio: ratio)
        case .sd3:
            return try await generateWithSD3(apiKey: apiKey, prompt: prompt, ratio: ratio)
        case .wanxiang:
            return try await generateWithWanxiang(apiKey: apiKey, prompt: prompt, ratio: ratio)
        case .grokImage:
            return try await generateWithGrokImage(apiKey: apiKey, prompt: prompt, ratio: ratio)
        default:
            throw AIError.missingAPIKey("\(provider.displayName) 不支持图片生成")
        }
    }

    // MARK: - Seedream 5.0 Pro (火山方舟)

    private func generateWithSeedream(prompt: String, referenceImages: [URL] = [], ratio: String = "1:1",
                                      modelOverride: String? = nil) async throws -> URL {
        let apiKey = settings.seedanceApiKey
        guard !apiKey.isEmpty else {
            throw AIError.missingAPIKey("请先在设置中填写火山方舟 API Key")
        }
        // 接入点填了以它为准（用户自己建的 ep-xxxxx），没填就用下拉里选的官方模型名。
        // 以前这里必须填才能用，其实火山方舟直接发模型名就行，没必要逼人先去建接入点
        let custom = settings.seedreamEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let ids = Provider.seedream.subModels.map(\.id)
        let picked = settings.providerModel(for: Provider.seedream.rawValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 存的可能是早先版本留下的旧值（那会儿 id 是 "seedream"），认不出就回到第一个
        let fromMenu = ids.contains(picked) ? picked : (ids.first ?? "")
        // 自动挑出来的型号最优先 —— 用户要三张时是靠它落到 Lite 上的，
        // 让下拉里存的 Pro 盖过去就白挑了
        let ep = modelOverride ?? (custom.isEmpty ? fromMenu : custom)
        guard !ep.isEmpty else {
            throw AIError.missingAPIKey("请先在设置里选一个 Seedream 模型，或填自己的接入点 ID")
        }

        let url = URL(string: "https://ark.cn-beijing.volces.com/api/v3/images/generations")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 同步接口，2K 出图常超过 URLSession 默认的 60s
        request.timeoutInterval = 300

        let sz = arkImageSize(ratio: ratio)
        var body: [String: Any] = [
            "model": ep,
            "prompt": prompt,
            "size": "\(sz.w)x\(sz.h)",
            "response_format": "url",
            "watermark": false
        ]
        // 参考图：单张传字符串，多张传数组
        let refs = referenceImages.compactMap { compressedImageDataURI($0) }
        if refs.count == 1 {
            body["image"] = refs[0]
        } else if refs.count > 1 {
            body["image"] = refs
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        await MainActor.run { updateAssistantStatus(.generating(progress: "生成图片中…")) }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let err as URLError where err.code == .timedOut {
            throw AIError.apiError("Seedream 请求超时（已等待 300 秒）。请检查接入点 ID 是否为图片生成模型、网络是否可达火山方舟")
        }
        guard let httpResp = response as? HTTPURLResponse, (200...299).contains(httpResp.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "未知错误"
            throw AIError.apiError("Seedream: \(msg)")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let arr = json?["data"] as? [[String: Any]], let first = arr.first else {
            throw AIError.apiError("Seedream 返回数据格式错误")
        }

        // url 或 b64_json 两种返回形式
        if let imgURL = first["url"] as? String {
            await MainActor.run { updateAssistantStatus(.downloading(progress: 0)) }
            return try await downloadFile(from: imgURL, filename: "seedream_\(UUID().uuidString.prefix(8)).png")
        }
        if let b64 = first["b64_json"] as? String, let decoded = Data(base64Encoded: b64) {
            let saveDir = AppSettings.shared.effectiveProjectDir.appendingPathComponent("AI生成")
            try FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
            let dest = saveDir.appendingPathComponent("seedream_\(UUID().uuidString.prefix(8)).png")
            try decoded.write(to: dest)
            return dest
        }
        throw AIError.apiError("Seedream 返回数据格式错误")
    }

    // MARK: - Nanobanana 2 (Google)

    private func generateWithNanobanana2(prompt: String, referenceImages: [URL] = [], ratio: String = "1:1") async throws -> URL {
        var apiKey = settings.providerAPIKey(for: Provider.nanobanana2.rawValue)
        if apiKey.isEmpty { apiKey = settings.providerAPIKey(for: Provider.veo3.rawValue) }
        guard !apiKey.isEmpty else {
            throw AIError.missingAPIKey("请先在设置中填写 Google AI 的 API Key")
        }

        // 模型名从设置里取（子模型下拉切的就是这两栏），留空用官方 id
        let isPro = AppSettings.shared.providerModel(for: Provider.nanobanana2.rawValue)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "pro"
        let configured = (isPro ? settings.nanobananaProEndpoint : settings.nanobananaEndpoint)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Nano Banana 2 / Pro 在 API 里的正式名字是 Gemini 3.x Image
        let modelName = configured.isEmpty
            ? (isPro ? "gemini-3-pro-image" : "gemini-3.1-flash-image") : configured

        let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Interactions API：Key 走 header，还要带版本号，少一个都会 4xx
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("2026-05-20", forHTTPHeaderField: "Api-Revision")
        // 同步接口，出图常超过 URLSession 默认的 60s
        request.timeoutInterval = 300

        var input: [[String: Any]] = []
        // 参考图排在文字前面，跟官方示例一致
        if let imgURL = referenceImages.first {
            let mime: String
            let imgData: Data?
            if let compressed = compressedImageData(imgURL) {
                mime = "image/jpeg"
                imgData = compressed
            } else {
                mime = imgURL.pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg"
                imgData = try? Data(contentsOf: imgURL)
            }
            if let imgData {
                input.append(["type": "image", "mime_type": mime, "data": imgData.base64EncodedString()])
            }
        }
        input.append(["type": "text", "text": prompt])

        let body: [String: Any] = [
            "model": modelName,
            "input": input,
            "response_format": [
                "type": "image",
                "mime_type": "image/png",
                "aspect_ratio": ratio,
                "image_size": "2K"
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        await MainActor.run { updateAssistantStatus(.generating(progress: "生成图片中…")) }

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: request)
        } catch let err as URLError where err.code == .timedOut {
            throw AIError.apiError("Gemini 请求超时（已等待 300 秒），请检查网络是否可达 Google API")
        }
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw AIError.apiError(Self.describeFailure(data: data, http: resp as? HTTPURLResponse,
                                                        endpoint: "v1beta/interactions"))
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        // 出图在 output_image.data，base64
        if let out = json?["output_image"] as? [String: Any],
           let b64 = out["data"] as? String, let decoded = Data(base64Encoded: b64) {
            let saveDir = AppSettings.shared.effectiveProjectDir.appendingPathComponent("AI生成")
            try FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
            let dest = saveDir.appendingPathComponent("gemini_\(UUID().uuidString.prefix(8)).png")
            try decoded.write(to: dest)
            return dest
        }
        // 兜底：中转站若还在用旧的 generateImages 格式
        if let images = json?["generatedImages"] as? [[String: Any]],
           let imageData = images.first?["image"] as? [String: Any],
           let b64 = imageData["imageBytes"] as? String,
           let decoded = Data(base64Encoded: b64) {
            let saveDir = AppSettings.shared.effectiveProjectDir.appendingPathComponent("AI生成")
            try FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
            let dest = saveDir.appendingPathComponent("nanobanana2_\(UUID().uuidString.prefix(8)).png")
            try decoded.write(to: dest)
            return dest
        }

        throw AIError.apiError("Nanobanana 2 返回数据格式错误")
    }

    // MARK: - GPT-Image-2

    private func generateWithGPTImage(apiKey: String, prompt: String, referenceImages: [URL] = [], ratio: String = "1:1") async throws -> URL {
        await MainActor.run { updateAssistantStatus(.generating(progress: "生成图片中…")) }
        // 设置里填了接口地址就走中转。生图和改图是两个路径，
        // 所以这里只取 base（把 /v1/... 之后的部分砍掉再各自拼）
        let apiBase: String = {
            let raw = AppSettings.shared.providerBaseURL(for: Provider.gptImage2.rawValue)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return "https://api.openai.com" }
            var b = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
            if let r = b.range(of: "/v1/") { b = String(b[b.startIndex..<r.lowerBound]) }
            else if b.hasSuffix("/v1") { b = String(b.dropLast(3)) }
            return b
        }()
        let modelName = chosenModel(.gptImage2, fallback: "gpt-image-1")
        let size = openAISize(ratio: ratio, model: modelName)

        let data: Data
        let resp: URLResponse

        do {
            if referenceImages.isEmpty {
                let url = URL(string: "\(apiBase)/v1/images/generations")!
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                // 同步接口，出图常超过 URLSession 默认的 60s
                request.timeoutInterval = 300
                let body: [String: Any] = ["model": modelName, "prompt": prompt, "n": 1, "size": size]
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                (data, resp) = try await URLSession.shared.data(for: request)
            } else {
                let url = URL(string: "\(apiBase)/v1/images/edits")!
                let boundary = UUID().uuidString
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
                request.timeoutInterval = 300

                var body = Data()
                func appendField(_ name: String, _ value: String) {
                    body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
                }
                appendField("model", modelName)
                appendField("prompt", prompt)
                appendField("n", "1")
                appendField("size", size)
                for (i, imgURL) in referenceImages.prefix(4).enumerated() {
                    let mime: String
                    let fname: String
                    let imgData: Data?
                    if let compressed = compressedImageData(imgURL) {
                        mime = "image/jpeg"
                        fname = "ref\(i).jpg"
                        imgData = compressed
                    } else {
                        let ext = imgURL.pathExtension.lowercased()
                        mime = ext == "png" ? "image/png" : "image/jpeg"
                        fname = "ref\(i).\(ext.isEmpty ? "png" : ext)"
                        imgData = try? Data(contentsOf: imgURL)
                    }
                    if let imgData {
                        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"image[]\"; filename=\"\(fname)\"\r\nContent-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
                        body.append(imgData)
                        body.append("\r\n".data(using: .utf8)!)
                    }
                }
                body.append("--\(boundary)--\r\n".data(using: .utf8)!)
                request.httpBody = body
                (data, resp) = try await URLSession.shared.data(for: request)
            }
        } catch let err as URLError where err.code == .timedOut {
            throw AIError.apiError("GPT-Image 请求超时（已等待 300 秒），请检查网络是否可达 OpenAI API")
        }

        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any]
            throw AIError.apiError((msg?["message"] as? String) ?? "GPT-Image 请求失败")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let results = json?["data"] as? [[String: Any]],
              let b64 = results.first?["b64_json"] as? String,
              let imgData = Data(base64Encoded: b64) else {
            if let results = json?["data"] as? [[String: Any]],
               let urlStr = results.first?["url"] as? String {
                await MainActor.run { updateAssistantStatus(.downloading(progress: 0)) }
                return try await downloadFile(from: urlStr, filename: "gpt_image_\(UUID().uuidString.prefix(8)).png")
            }
            throw AIError.apiError("GPT-Image 返回数据格式错误")
        }

        let saveDir = AppSettings.shared.effectiveProjectDir.appendingPathComponent("AI生成")
        try FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
        let dest = saveDir.appendingPathComponent("gpt_image_\(UUID().uuidString.prefix(8)).png")
        try imgData.write(to: dest)
        return dest
    }

    // MARK: - Flux (BFL API)

    private func generateWithFlux(apiKey: String, prompt: String, ratio: String = "1:1") async throws -> URL {
        let url = URL(string: "https://api.bfl.ml/v1/flux-pro-1.1")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Key \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // BFL 要求宽高是 32 的倍数
        let sz = pixelSize(ratio: ratio, targetLong: 1440, step: 32)
        let body: [String: Any] = ["prompt": prompt, "width": sz.w, "height": sz.h]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw AIError.apiError("Flux 请求失败")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let taskId = json?["id"] as? String else {
            throw AIError.apiError("Flux 未返回任务 ID")
        }

        await MainActor.run { updateAssistantStatus(.generating(progress: "生成图片中…")) }

        let resultURL = URL(string: "https://api.bfl.ml/v1/get_result?id=\(taskId)")!
        for _ in 0..<120 {
            try await Task.sleep(nanoseconds: 3_000_000_000)
            var pollReq = URLRequest(url: resultURL)
            pollReq.setValue("Key \(apiKey)", forHTTPHeaderField: "Authorization")
            let (pData, _) = try await URLSession.shared.data(for: pollReq)
            let pJson = try JSONSerialization.jsonObject(with: pData) as? [String: Any]
            let status = pJson?["status"] as? String ?? ""
            if status == "Ready", let imgURL = (pJson?["result"] as? [String: Any])?["sample"] as? String {
                await MainActor.run { updateAssistantStatus(.downloading(progress: 0)) }
                return try await downloadFile(from: imgURL, filename: "flux_\(taskId.prefix(8)).png")
            } else if status == "Error" {
                throw AIError.apiError("Flux 生成失败")
            }
        }
        throw AIError.timeout
    }

    // MARK: - Stable Diffusion 3

    private func generateWithSD3(apiKey: String, prompt: String, ratio: String = "1:1") async throws -> URL {
        let url = URL(string: "https://api.stability.ai/v2beta/stable-image/generate/sd3")!
        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // 同步接口，出图常超过 URLSession 默认的 60s
        request.timeoutInterval = 300

        var bodyData = Data()
        func addField(_ name: String, _ value: String) {
            bodyData.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        addField("prompt", prompt)
        addField("model", "sd3.5-large")
        addField("output_format", "png")
        addField("aspect_ratio", Self.sd3AspectRatio(ratio))
        bodyData.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = bodyData

        await MainActor.run { updateAssistantStatus(.generating(progress: "生成图片中…")) }

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: request)
        } catch let err as URLError where err.code == .timedOut {
            throw AIError.apiError("SD3 请求超时（已等待 300 秒），请检查网络是否可达 Stability API")
        }
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let errJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            throw AIError.apiError((errJson?["message"] as? String) ?? "SD3 请求失败 (\((resp as? HTTPURLResponse)?.statusCode ?? 0))")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let imgB64 = json?["image"] as? String, let imgData = Data(base64Encoded: imgB64) else {
            throw AIError.apiError("SD3 返回数据格式错误")
        }

        let saveDir = AppSettings.shared.effectiveProjectDir.appendingPathComponent("AI生成")
        try FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
        let dest = saveDir.appendingPathComponent("sd3_\(UUID().uuidString.prefix(8)).png")
        try imgData.write(to: dest)
        return dest
    }

    // MARK: - 通义万相

    private func generateWithWanxiang(apiKey: String, prompt: String, ratio: String = "1:1") async throws -> URL {
        let url = URL(string: "https://dashscope.aliyuncs.com/api/v1/services/aigc/text2image/image-synthesis")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("enable", forHTTPHeaderField: "X-DashScope-Async")

        // 通义万相尺寸用 * 分隔，且要求 64 的倍数
        let sz = pixelSize(ratio: ratio, targetLong: 1280)
        let body: [String: Any] = [
            "model": "wanx-v1",
            "input": ["prompt": prompt],
            "parameters": ["n": 1, "size": "\(sz.w)*\(sz.h)"]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw AIError.apiError("通义万相请求失败")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let output = json?["output"] as? [String: Any],
              let taskId = output["task_id"] as? String else {
            throw AIError.apiError("通义万相未返回任务 ID")
        }

        await MainActor.run { updateAssistantStatus(.generating(progress: "生成图片中…")) }

        let pollBase = URL(string: "https://dashscope.aliyuncs.com/api/v1/tasks/\(taskId)")!
        for _ in 0..<120 {
            try await Task.sleep(nanoseconds: 3_000_000_000)
            var pollReq = URLRequest(url: pollBase)
            pollReq.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            let (pData, _) = try await URLSession.shared.data(for: pollReq)
            let pJson = try JSONSerialization.jsonObject(with: pData) as? [String: Any]
            let pOutput = pJson?["output"] as? [String: Any]
            let status = pOutput?["task_status"] as? String ?? ""
            if status == "SUCCEEDED" {
                if let results = pOutput?["results"] as? [[String: Any]],
                   let imgURL = results.first?["url"] as? String {
                    await MainActor.run { updateAssistantStatus(.downloading(progress: 0)) }
                    return try await downloadFile(from: imgURL, filename: "wanxiang_\(taskId.prefix(8)).png")
                }
                throw AIError.apiError("通义万相返回无图片")
            } else if status == "FAILED" {
                throw AIError.apiError((pOutput?["message"] as? String) ?? "通义万相生成失败")
            }
        }
        throw AIError.timeout
    }

    // MARK: - 音频生成

    /// 字幕转语音用：直接把一段文本合成成音频文件。
    /// 跟 AI 面板那条生成链路分开 —— 这里不碰会话历史，也不动面板状态
    func synthesizeSpeech(text: String, provider: Provider) async throws -> URL {
        guard provider.category == .audio else {
            throw AIError.apiError("\(provider.displayName) 不是语音模型")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AIError.apiError("字幕内容为空")
        }
        return try await generateAudio(provider: provider, prompt: trimmed)
    }

    private func generateAudio(provider: Provider, prompt: String) async throws -> URL {
        let apiKey = settings.providerAPIKey(for: provider.rawValue)
        guard !apiKey.isEmpty else {
            throw AIError.missingAPIKey("请先在设置中填写 \(provider.displayName) 的 API Key")
        }
        switch provider {
        case .elevenlabs:
            return try await generateWithElevenLabs(apiKey: apiKey, prompt: prompt)
        case .openaiTTS:
            return try await generateWithOpenAITTS(apiKey: apiKey, prompt: prompt)
        case .fishAudio:
            return try await generateWithFishAudio(apiKey: apiKey, prompt: prompt)
        case .suno:
            return try await generateWithSuno(apiKey: apiKey, prompt: prompt)
        case .minimaxTTS:
            return try await generateWithMiniMaxTTS(apiKey: apiKey, prompt: prompt)
        default:
            throw AIError.missingAPIKey("\(provider.displayName) 不支持音频生成")
        }
    }

    // MARK: - ElevenLabs TTS

    private func generateWithElevenLabs(apiKey: String, prompt: String) async throws -> URL {
        let voiceId = "21m00Tcm4TlvDq8ikWAM"
        let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // TTS 默认 60s 超时，长文本容易踩线；批量转换里一条挂住会拖慢整批
        request.timeoutInterval = 120
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // 语速：ElevenLabs 塞在 voice_settings.speed 里，接口范围 0.25~4.0
        var voiceSettings: [String: Any] = ["stability": 0.5, "similarity_boost": 0.75]
        if abs(settings.ttsSpeed - 1.0) > 0.01 {
            voiceSettings["speed"] = min(4.0, max(0.25, settings.ttsSpeed))
        }
        let body: [String: Any] = [
            "text": prompt,
            "model_id": "eleven_multilingual_v2",
            "voice_settings": voiceSettings
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        await MainActor.run { updateAssistantStatus(.generating(progress: "生成音频中…")) }

        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw AIError.apiError("ElevenLabs 请求失败 (\((resp as? HTTPURLResponse)?.statusCode ?? 0))")
        }

        let saveDir = AppSettings.shared.effectiveProjectDir.appendingPathComponent("AI生成")
        try FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
        let dest = saveDir.appendingPathComponent("elevenlabs_\(UUID().uuidString.prefix(8)).mp3")
        try data.write(to: dest)
        return dest
    }

    // MARK: - OpenAI TTS

    private func generateWithOpenAITTS(apiKey: String, prompt: String) async throws -> URL {
        let url = URL(string: "https://api.openai.com/v1/audio/speech")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // TTS 默认 60s 超时，长文本容易踩线；批量转换里一条挂住会拖慢整批
        request.timeoutInterval = 120
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = ["model": "tts-1-hd", "input": prompt, "voice": "alloy", "response_format": "mp3"]
        // 语速：OpenAI 是顶层 speed，接口范围 0.25~4.0
        if abs(settings.ttsSpeed - 1.0) > 0.01 {
            body["speed"] = min(4.0, max(0.25, settings.ttsSpeed))
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        await MainActor.run { updateAssistantStatus(.generating(progress: "生成音频中…")) }

        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw AIError.apiError("OpenAI TTS 请求失败")
        }

        let saveDir = AppSettings.shared.effectiveProjectDir.appendingPathComponent("AI生成")
        try FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
        let dest = saveDir.appendingPathComponent("openai_tts_\(UUID().uuidString.prefix(8)).mp3")
        try data.write(to: dest)
        return dest
    }

    // MARK: - Grok（xAI）

    /// 选中子模型的名字，没选过就用清单第一项
    private func chosenModel(_ provider: Provider, fallback: String) -> String {
        let saved = AppSettings.shared.providerModel(for: provider.rawValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !saved.isEmpty { return saved }
        return provider.subModels.first?.id ?? fallback
    }

    /// xAI 出图。走 OpenAI 兼容的 images/generations，
    /// 设置里填了接口地址就用那个（中转站）
    private func generateWithGrokImage(apiKey: String, prompt: String, ratio: String) async throws -> URL {
        let custom = Self.normalizedEndpoint(
            AppSettings.shared.providerBaseURL(for: Provider.grokImage.rawValue),
            defaultPath: "/v1/images/generations")
        let endpoint = custom.isEmpty ? "https://api.x.ai/v1/images/generations" : custom
        guard let url = URL(string: endpoint) else {
            throw AIError.missingAPIKey("Grok 的接口地址无效：\(endpoint)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": chosenModel(.grokImage, fallback: "grok-imagine-image-2.0"),
            "prompt": prompt,
            "n": 1,
            "aspect_ratio": ratio,
            "resolution": "2k"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        await MainActor.run { updateAssistantStatus(.generating(progress: "生成图片中…")) }

        let (data, resp) = try await URLSession.shared.data(for: request)
        let http = resp as? HTTPURLResponse
        guard http?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["data"] as? [[String: Any]], let first = arr.first else {
            throw AIError.apiError(Self.describeFailure(data: data, http: http, endpoint: endpoint))
        }
        // 有的实现回 url，有的回 b64_json，两种都收
        if let link = first["url"] as? String {
            return try await downloadFile(from: link, filename: "grok_\(UUID().uuidString.prefix(8)).png")
        }
        if let b64 = first["b64_json"] as? String, let img = Data(base64Encoded: b64) {
            let saveDir = AppSettings.shared.effectiveProjectDir.appendingPathComponent("AI生成")
            try FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
            let dest = saveDir.appendingPathComponent("grok_\(UUID().uuidString.prefix(8)).png")
            try img.write(to: dest)
            return dest
        }
        throw AIError.apiError(Self.describeFailure(data: data, http: http, endpoint: endpoint))
    }

    /// xAI 出视频。异步接口：先提交拿 request_id，再轮询到 status=done 取链接
    private func generateWithGrokVideo(prompt: String, duration: String, aspectRatio: String) async throws -> URL {
        let apiKey = settings.providerAPIKey(for: Provider.grokVideo.rawValue)
        guard !apiKey.isEmpty else {
            throw AIError.missingAPIKey("请先在设置中填写 Grok 的 API Key")
        }
        // 中转站填的是 base，补上官方路径；两个请求要落在同一台机器上，所以从 base 推轮询地址
        let custom = Self.normalizedEndpoint(
            AppSettings.shared.providerBaseURL(for: Provider.grokVideo.rawValue),
            defaultPath: "/v1/videos/generations")
        let endpoint = custom.isEmpty ? "https://api.x.ai/v1/videos/generations" : custom
        guard let url = URL(string: endpoint) else {
            throw AIError.missingAPIKey("Grok 的接口地址无效：\(endpoint)")
        }
        let pollBase = endpoint.hasSuffix("/generations")
            ? String(endpoint.dropLast("/generations".count))
            : "https://api.x.ai/v1/videos"

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // duration 官方范围 1~15s；resolution 取 480p/720p/1080p
        let secs = min(15, max(1, Int(duration) ?? 5))
        let res: String = {
            switch settings.aiResolution.lowercased() {
            case let r where r.contains("1080"): return "1080p"
            case let r where r.contains("480"): return "480p"
            default: return "720p"
            }
        }()
        let body: [String: Any] = [
            "model": chosenModel(.grokVideo, fallback: "grok-imagine-video-1.5"),
            "prompt": prompt,
            "duration": secs,
            "aspect_ratio": aspectRatio,
            "resolution": res
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        await MainActor.run { updateAssistantStatus(.generating(progress: "提交任务中…")) }

        let (data, resp) = try await URLSession.shared.data(for: request)
        let http = resp as? HTTPURLResponse
        guard http?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let requestID = json["request_id"] as? String else {
            throw AIError.apiError(Self.describeFailure(data: data, http: http, endpoint: endpoint))
        }

        // 轮询：出片通常要几十秒到几分钟，10 分钟还没好就当超时
        let deadline = Date().addingTimeInterval(600)
        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 5_000_000_000)
            guard let pollURL = URL(string: "\(pollBase)/\(requestID)") else { break }
            var poll = URLRequest(url: pollURL)
            poll.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            let (pd, pr) = try await URLSession.shared.data(for: poll)
            guard let pjson = try? JSONSerialization.jsonObject(with: pd) as? [String: Any] else { continue }
            let status = (pjson["status"] as? String) ?? ""
            switch status {
            case "done":
                if let video = pjson["video"] as? [String: Any], let link = video["url"] as? String {
                    return try await downloadFile(from: link, filename: "grok_\(UUID().uuidString.prefix(8)).mp4")
                }
                throw AIError.apiError(Self.describeFailure(data: pd, http: pr as? HTTPURLResponse, endpoint: "videos/\(requestID)"))
            case "failed", "expired":
                throw AIError.apiError("Grok 出片\(status == "expired" ? "已过期" : "失败")")
            default:
                await MainActor.run { updateAssistantStatus(.generating(progress: "生成视频中…")) }
            }
        }
        throw AIError.timeout
    }

    // MARK: - MiniMax TTS

    /// MiniMax 语音合成（T2A v2）。
    ///
    /// 跟别家不一样的地方：返回的不是音频二进制，是 `data.audio` 里的一串 hex
    /// （官方 format 默认就是 hex），要自己解码成 mp3；
    /// 而且 HTTP 200 不代表成功，业务错误码在 base_resp 里
    private func generateWithMiniMaxTTS(apiKey: String, prompt: String) async throws -> URL {
        let ttsBase = Self.minimaxBase(for: .minimaxTTS)
        guard let url = URL(string: "\(ttsBase)/v1/t2a_v2") else {
            throw AIError.missingAPIKey("MiniMax 的接口地址无效：\(ttsBase)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let model: String = {
            let saved = AppSettings.shared.providerModel(for: Provider.minimaxTTS.rawValue)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !saved.isEmpty { return saved }
            return Provider.minimaxTTS.subModels.first?.id ?? "speech-2.8-hd"
        }()

        var voiceSetting: [String: Any] = ["voice_id": "male-qn-qingse", "vol": 1.0, "pitch": 0]
        // 语速范围 0.5~2.0，跟字幕转语音那套共用同一个设置
        voiceSetting["speed"] = min(2.0, max(0.5, settings.ttsSpeed))

        let body: [String: Any] = [
            "model": model,
            "text": prompt,
            "stream": false,
            "voice_setting": voiceSetting,
            "audio_setting": ["sample_rate": 32000, "bitrate": 128000, "format": "mp3"]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        await MainActor.run { updateAssistantStatus(.generating(progress: "生成音频中…")) }

        let (data, resp) = try await URLSession.shared.data(for: request)
        let http = resp as? HTTPURLResponse
        guard http?.statusCode == 200 else {
            throw AIError.apiError(Self.describeFailure(data: data, http: http, endpoint: "t2a_v2"))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.apiError(Self.describeFailure(data: data, http: http, endpoint: "t2a_v2"))
        }
        // HTTP 200 不代表成功，业务错误码在 base_resp 里
        if let base = json["base_resp"] as? [String: Any],
           let code = base["status_code"] as? Int, code != 0 {
            let msg = base["status_msg"] as? String ?? "未知错误"
            throw AIError.apiError("MiniMax TTS 失败（\(code)）：\(msg)")
        }
        guard let d = json["data"] as? [String: Any], let hex = d["audio"] as? String,
              let audio = Data(hexEncoded: hex), !audio.isEmpty else {
            throw AIError.apiError(Self.describeFailure(data: data, http: http, endpoint: "t2a_v2"))
        }

        let saveDir = AppSettings.shared.effectiveProjectDir.appendingPathComponent("AI生成")
        try FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
        let dest = saveDir.appendingPathComponent("minimax_tts_\(UUID().uuidString.prefix(8)).mp3")
        try audio.write(to: dest)
        return dest
    }

    // MARK: - Fish Audio TTS

    private func generateWithFishAudio(apiKey: String, prompt: String) async throws -> URL {
        let url = URL(string: "https://api.fish.audio/v1/tts")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // TTS 默认 60s 超时，长文本容易踩线；批量转换里一条挂住会拖慢整批
        request.timeoutInterval = 120
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // model 是必填 header，缺了直接被拒。s2.1-pro-free 对应免费开发者层
        request.setValue("s2.1-pro-free", forHTTPHeaderField: "model")

        // reference_id 只接受真实音色模型 ID，没选音色就不传，走服务端默认
        var body: [String: Any] = ["text": prompt, "format": "mp3"]
        // 语速：Fish Audio 走 prosody.speed，接口范围 0.5~2.0
        let speed = settings.ttsSpeed
        if abs(speed - 1.0) > 0.01 {
            body["prosody"] = ["speed": min(2.0, max(0.5, speed))]
        }
        let voiceID = await MainActor.run { AppSettings.shared.fishActiveModelID }
        if !voiceID.isEmpty { body["reference_id"] = voiceID }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        await MainActor.run { updateAssistantStatus(.generating(progress: "生成音频中…")) }

        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let detail = String(data: data, encoding: .utf8) ?? ""
            NSLog("[FishAudio] HTTP %d: %@", code, detail)
            throw AIError.apiError("Fish Audio 请求失败 (\(code))"
                                   + (detail.isEmpty ? "" : "：\(detail.prefix(300))"))
        }

        let saveDir = AppSettings.shared.effectiveProjectDir.appendingPathComponent("AI生成")
        try FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
        let dest = saveDir.appendingPathComponent("fish_audio_\(UUID().uuidString.prefix(8)).mp3")
        try data.write(to: dest)
        return dest
    }

    // MARK: - Suno

    private func generateWithSuno(apiKey: String, prompt: String) async throws -> URL {
        let url = URL(string: "https://studio-api.suno.ai/api/external/generate/")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // TTS 默认 60s 超时，长文本容易踩线；批量转换里一条挂住会拖慢整批
        request.timeoutInterval = 120
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["topic": prompt, "tags": "pop"]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw AIError.apiError("Suno 请求失败")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let taskId = json?["id"] as? String else {
            if let clips = json?["clips"] as? [[String: Any]],
               let audioURL = clips.first?["audio_url"] as? String {
                await MainActor.run { updateAssistantStatus(.downloading(progress: 0)) }
                return try await downloadFile(from: audioURL, filename: "suno_\(UUID().uuidString.prefix(8)).mp3")
            }
            throw AIError.apiError("Suno 未返回任务信息")
        }

        await MainActor.run { updateAssistantStatus(.generating(progress: "生成音乐中…")) }

        let pollURL = URL(string: "https://studio-api.suno.ai/api/external/clips/?ids=\(taskId)")!
        for _ in 0..<120 {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            var pollReq = URLRequest(url: pollURL)
            pollReq.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            let (pData, _) = try await URLSession.shared.data(for: pollReq)
            if let clips = (try? JSONSerialization.jsonObject(with: pData)) as? [[String: Any]],
               let clip = clips.first,
               let status = clip["status"] as? String {
                if status == "complete", let audioURL = clip["audio_url"] as? String {
                    await MainActor.run { updateAssistantStatus(.downloading(progress: 0)) }
                    return try await downloadFile(from: audioURL, filename: "suno_\(taskId.prefix(8)).mp3")
                } else if status == "error" {
                    throw AIError.apiError("Suno 生成失败")
                }
            }
        }
        throw AIError.timeout
    }

    // MARK: - 文字生成

    /// 发一段 prompt 给文字模型，拿回复。
    /// 字幕 AI 校对也走这里——共用「AI 生成」里配好的模型和 Key，不再单独一套配置
    func generateText(provider: Provider, prompt: String, webSearch: Bool = false) async throws -> String {
        let apiKey = settings.providerAPIKey(for: provider.rawValue)
        guard !apiKey.isEmpty else {
            throw AIError.missingAPIKey("请先在设置中填写 \(provider.displayName) 的 API Key")
        }

        var finalPrompt = prompt
        // 自带联网的几家走各自的原生能力：搜索在服务端跑，不用配 Brave/Tavily，
        // 模型自己决定搜什么词、能多轮搜，效果比外挂拼提示词好。
        // 其余几家（DeepSeek 的原生搜索只在 Anthropic 端点上且未文档化、
        // Kimi 的 $web_search 要写工具调用循环）先走外挂
        let nativeSearchProviders: Set<Provider> = [.qwen, .glm, .grok, .claude]
        // 走中转时不用原生：服务端工具（Claude 的 web_search、智谱的 web_search 配置对象、
        // xAI 的 web_search）多数中转站不透传，实测分别报
        // 「tools[0].web_search can not be null」「422」和静默忽略。
        // 填了自定义接口地址就一律改走外挂，稳妥优先
        let viaRelay = !AppSettings.shared.providerBaseURL(for: provider.rawValue)
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let useNativeSearch = webSearch && nativeSearchProviders.contains(provider) && !viaRelay
        let qwenNativeSearch = webSearch && provider == .qwen

        // 路由日志放在分叉之前 —— 记在下游的话，走外挂那几家永远显示「关」，
        // 因为外挂是先搜完拼进提示词、再发请求，下游根本不知道联网开着
        if webSearch {
            DiagLog.log("[联网] \(provider.displayName) → "
                        + (useNativeSearch ? "原生搜索"
                           : "外挂 \(settings.searchEngine.rawValue)"
                             + (viaRelay && nativeSearchProviders.contains(provider) ? "（走中转，原生不可用）" : "")))
        }

        if webSearch && !useNativeSearch {
            await MainActor.run { updateAssistantStatus(.generating(progress: "正在搜索…")) }
            do {
                let results = try await webSearchQuery(prompt)
                let peek = results.replacingOccurrences(of: "\n", with: " ").prefix(200)
                DiagLog.log("[联网] 外挂搜索拿到 \(results.count) 字：\(peek)…")

                // 只做两件事：用标签把检索结果跟用户问题分开，让模型基于结果整理作答。
                // 另外点明结果是刚取的 —— 不说的话模型容易拿"我的知识截止到 X 年"当理由拒答
                finalPrompt = """
                下面是刚刚通过搜索引擎检索到的网络内容。

                <search_results>
                \(results)
                </search_results>

                请基于上面的检索结果回答用户的问题：
                - 这些结果是刚获取的实时信息，不受你训练数据截止时间的限制
                - 归纳整理后作答，涉及具体事实时注明来源链接
                - 如果检索结果里确实没有能回答该问题的内容，如实说明没检索到，不要编造

                用户问题：\(prompt)
                """
            } catch {
                // 搜不到就照常回答，但要留痕，不然「点了联网却没联网」查不出原因
                DiagLog.log("[联网] 外挂搜索失败：\(error.localizedDescription)")
            }
        }

        // 设置里填了自定义 Base URL 就用它（第三方中转/代理），留空走官方
        // 用户可能只填 base（https://api.apikey.fun），补上标准路径
        let custom = Self.normalizedEndpoint(
            AppSettings.shared.providerBaseURL(for: provider.rawValue),
            defaultPath: "/v1/chat/completions")

        // 设置里填了模型名就用它（切子模型 / 中转站模型名不同），留空用默认
        // 子模型在聊天输入框那排下拉里选，存在 settings 里
        let chosen = AppSettings.shared.providerModel(for: provider.rawValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        func pick(_ fallback: String) -> String {
            if !chosen.isEmpty {
                // 旧版本把显示名当 API 名存了（"Opus5"），存量配置在这里换成真 id，
                // 否则请求打过去是「Model "Opus5" is not supported」
                if let m = provider.subModels.first(where: { $0.label == chosen }) { return m.id }
                return chosen
            }
            return provider.subModels.first?.id ?? fallback
        }

        // 推理强度：用户没在下拉里选过就不传，让各家用自己的默认值
        let effort = AppSettings.shared.providerReasoning(for: provider.rawValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let (endpoint, model): (String, String)
        switch provider {
        case .claude:
            return try await generateWithClaude(apiKey: apiKey, prompt: finalPrompt,
                                                baseURL: custom,
                                                model: pick("claude-opus-5"),
                                                effort: effort,
                                                webSearch: useNativeSearch)
        case .gpt56:
            endpoint = custom.isEmpty ? "https://api.openai.com/v1/chat/completions" : custom
            model = pick("gpt-4o")
        case .deepseek_ai:
            endpoint = custom.isEmpty ? "https://api.deepseek.com/chat/completions" : custom
            model = pick("deepseek-chat")
        case .qwen:
            endpoint = custom.isEmpty
                ? "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions" : custom
            model = pick("qwen-max")
        case .glm:
            endpoint = custom.isEmpty
                ? "https://open.bigmodel.cn/api/paas/v4/chat/completions" : custom
            model = pick("glm-4-flash")
        case .grok:
            endpoint = custom.isEmpty ? "https://api.x.ai/v1/chat/completions" : custom
            model = pick("grok-4.6")
        case .kimi:
            endpoint = custom.isEmpty ? "https://api.moonshot.ai/v1/chat/completions" : custom
            model = pick("kimi-k3")
        default:
            throw AIError.missingAPIKey("\(provider.displayName) 不支持文字生成")
        }

        // 两家的声明方式不同：智谱要带一个 web_search 配置对象，xAI 只要个 type
        var searchTools: [[String: Any]] = []
        if useNativeSearch {
            switch provider {
            case .glm:
                searchTools = [["type": "web_search",
                                "web_search": ["enable": "True", "search_result": "True", "count": "5"]]]
            case .grok:
                searchTools = [["type": "web_search"]]
            default: break
            }
        }

        return try await chatCompletion(apiKey: apiKey, endpoint: endpoint, model: model,
                                        prompt: finalPrompt, webSearch: qwenNativeSearch,
                                        searchTools: searchTools,
                                        reasoningEffort: effort,
                                        // 智谱要求显式打开思考开关，只给 reasoning_effort 不生效
                                        thinkingSwitch: provider == .glm,
                                        // 千问的 enable_thinking 是独立开关，联网搜索也依赖它
                                        thinkingFlag: provider == .qwen)
    }

    /// 归一化用户填的接口地址。
    ///
    /// 中转站文档给的通常是 base（`https://api.apikey.fun`），而请求需要完整路径。
    /// 只有 host、没有路径时按该格式的标准路径补全；已经带路径的原样用。
    /// 不补的话请求会打到根路径，返回的 HTML/错误页解析不出 JSON ——
    /// 表现就是「The data couldn't be read because it isn't in the correct format.」
    static func normalizedEndpoint(_ raw: String, defaultPath: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "" }
        while t.hasSuffix("/") { t.removeLast() }
        guard let u = URL(string: t), let scheme = u.scheme, !scheme.isEmpty else { return t }
        return (u.path.isEmpty || u.path == "/") ? t + defaultPath : t
    }

    /// 把 HTTP 状态码 + 响应体片段拼成人能看懂的错误。
    /// 原来只抛「返回格式错误」，用户拿到的是 JSONDecoder 那句
    /// 「The data couldn't be read...」，完全定位不到是地址填错还是 Key 无效
    static func describeFailure(data: Data, http: HTTPURLResponse?, endpoint: String) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let e = json["error"] as? [String: Any], let m = e["message"] as? String { return m }
            if let m = json["message"] as? String { return m }
        }
        let code = http.map { "HTTP \($0.statusCode)" } ?? "无响应"
        var body = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if body.count > 160 { body = String(body.prefix(160)) + "…" }
        if body.isEmpty { body = "响应为空" }
        return "\(code) · \(endpoint)\n\(body)"
    }

    private func generateWithClaude(apiKey: String, prompt: String,
                                    baseURL: String = "",
                                    model: String = "claude-opus-5",
                                    effort: String = "",
                                    webSearch: Bool = false) async throws -> String {
        // 第三方中转填了就用它。注意这些中转多数只兼容 OpenAI 格式，
        // 若填的是 /v1/chat/completions 这类地址，下面的 Anthropic 报文格式对不上 ——
        // 那种情况应该在「GPT-5.6」那栏填中转地址，而不是这里
        let custom = Self.normalizedEndpoint(baseURL, defaultPath: "/v1/messages")
        let endpoint = custom.isEmpty ? "https://api.anthropic.com/v1/messages" : custom
        guard let url = URL(string: endpoint) else {
            throw AIError.missingAPIKey("Claude 的接口地址无效：\(endpoint)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // 默认 60s 不够：高 effort 的深度思考本来就慢，叠加联网检索和中转还要更久
        request.timeoutInterval = 300
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "messages": [["role": "user", "content": prompt]]
        ]
        // Anthropic 的 effort 嵌在 output_config 里，不是顶层字段
        if !effort.isEmpty { body["output_config"] = ["effort": effort] }
        // 服务端搜索工具，Anthropic 那边跑，不用自己配搜索 Key
        if webSearch {
            body["tools"] = [["type": "web_search_20260209", "name": "web_search"]]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        DiagLog.log("[对话] model=\(model) 联网=\(webSearch ? "开(原生)" : "关")"
                    + (effort.isEmpty ? "" : " effort=\(effort)"))

        await MainActor.run { updateAssistantStatus(.generating(progress: "生成回复中…")) }

        let (data, resp) = try await URLSession.shared.data(for: request)
        let http = resp as? HTTPURLResponse
        guard http?.statusCode == 200 else {
            throw AIError.apiError(Self.describeFailure(data: data, http: http, endpoint: endpoint))
        }

        // 解析失败时把实际响应带出来 —— 只说「格式错误」的话，中转地址填错
        // （比如少了 /v1/messages）根本无从排查
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.apiError(Self.describeFailure(data: data, http: http, endpoint: endpoint))
        }
        // 开了联网时 content 里会混着 server_tool_use、web_search_tool_result 等块，
        // 正文不一定在第一个 —— 这里把所有 text 块拼起来
        if let content = json["content"] as? [[String: Any]] {
            let texts = content.compactMap { blk -> String? in
                guard (blk["type"] as? String) == "text" else { return nil }
                return blk["text"] as? String
            }
            if !texts.isEmpty { return texts.joined() }
        }
        guard let content = json["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String else {
            // 中转若只兼容 OpenAI 格式，返回的是 choices 而不是 content
            if let choices = json["choices"] as? [[String: Any]],
               let msg = choices.first?["message"] as? [String: Any],
               let t = msg["content"] as? String {
                return t
            }
            throw AIError.apiError(Self.describeFailure(data: data, http: http, endpoint: endpoint))
        }
        return text
    }

    private func chatCompletion(apiKey: String, endpoint: String, model: String, prompt: String,
                                webSearch: Bool = false,
                                searchTools: [[String: Any]] = [],
                                reasoningEffort: String = "",
                                thinkingSwitch: Bool = false,
                                thinkingFlag: Bool = false) async throws -> String {
        let url = URL(string: endpoint)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300      // 同上，深度思考 + 联网容易超过默认的 60s
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
            "max_tokens": 4096
        ]
        if !searchTools.isEmpty { body["tools"] = searchTools }
        if webSearch {
            body["enable_search"] = true
            // 不加 forced_search 的话模型会"自己判断要不要搜"，多数时候就不搜了；
            // enable_source 让响应带回搜索来源，便于排查到底搜没搜
            body["search_options"] = ["forced_search": true, "enable_source": true]
        }
        if !reasoningEffort.isEmpty {
            body["reasoning_effort"] = reasoningEffort
            if thinkingSwitch { body["thinking"] = ["type": "enabled"] }
        }
        // 千问的 max 系列要在思考模式下才支持联网搜索，光给 enable_search 不开思考不生效。
        // 但只在真要联网时才开 —— 平时也强制思考纯粹是变慢变贵
        if thinkingFlag && webSearch { body["enable_thinking"] = true }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        DiagLog.log("[对话] model=\(model) 联网=\((webSearch || !searchTools.isEmpty) ? "开(原生)" : "关")"
                    + (webSearch ? " enable_search=true forced_search=true" : "")
                    + (body["enable_thinking"] != nil ? " enable_thinking=true" : "")
                    + (reasoningEffort.isEmpty ? "" : " reasoning_effort=\(reasoningEffort)"))

        await MainActor.run { updateAssistantStatus(.generating(progress: "生成回复中…")) }

        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let errJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let errMsg = (errJson?["error"] as? [String: Any])?["message"] as? String
            throw AIError.apiError(errMsg ?? "\(model) 请求失败")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let choices = json?["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let text = msg["content"] as? String else {
            throw AIError.apiError("\(model) 返回格式错误")
        }
        return text
    }

    // MARK: - 联网搜索

    /// 给 Agent 调的入口。它自己决定搜什么词、搜几次，
    /// 不像老链路那样只在发请求前闷头搜一次
    func agentWebSearch(_ query: String) async throws -> String {
        try await webSearchQuery(query)
    }

    private func webSearchQuery(_ query: String) async throws -> String {
        switch settings.searchEngine {
        case .brave:
            return try await braveSearch(query)
        case .tavily:
            return try await tavilySearch(query)
        }
    }

    /// Brave 搜索。GET + `X-Subscription-Token` 头，结果在 web.results
    private func braveSearch(_ query: String) async throws -> String {
        let key = settings.braveSearchKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw AIError.missingAPIKey("请先在设置中填写 Brave Search API Key")
        }
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "https://api.search.brave.com/res/v1/web/search?q=\(encoded)&count=5") else {
            throw AIError.apiError("Brave 搜索地址拼接失败")
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(key, forHTTPHeaderField: "X-Subscription-Token")

        let (data, resp) = try await URLSession.shared.data(for: request)
        let http = resp as? HTTPURLResponse
        guard http?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let web = json["web"] as? [String: Any],
              let results = web["results"] as? [[String: Any]] else {
            throw AIError.apiError(Self.describeFailure(data: data, http: http, endpoint: "brave/web/search"))
        }
        let lines = results.prefix(5).enumerated().map { i, r -> String in
            let title = r["title"] as? String ?? ""
            let desc = r["description"] as? String ?? ""
            let link = r["url"] as? String ?? ""
            return "\(i + 1). \(title)\n\(desc)\n来源：\(link)"
        }
        return lines.joined(separator: "\n\n")
    }

    /// Tavily 搜索。POST + Bearer，结果在顶层 results；
    /// include_answer 让它顺带给一段摘要，省一轮模型自己归纳
    private func tavilySearch(_ query: String) async throws -> String {
        let key = settings.tavilySearchKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw AIError.missingAPIKey("请先在设置中填写 Tavily API Key")
        }
        let url = URL(string: "https://api.tavily.com/search")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": query,
            "max_results": 5,
            "include_answer": true
        ])

        let (data, resp) = try await URLSession.shared.data(for: request)
        let http = resp as? HTTPURLResponse
        guard http?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.apiError(Self.describeFailure(data: data, http: http, endpoint: "tavily/search"))
        }
        var out = ""
        if let answer = json["answer"] as? String, !answer.isEmpty {
            out += "摘要：\(answer)\n\n"
        }
        let results = (json["results"] as? [[String: Any]]) ?? []
        out += results.prefix(5).enumerated().map { i, r -> String in
            let title = r["title"] as? String ?? ""
            let content = r["content"] as? String ?? ""
            let link = r["url"] as? String ?? ""
            return "\(i + 1). \(title)\n\(content)\n来源：\(link)"
        }.joined(separator: "\n\n")
        guard !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIError.apiError(Self.describeFailure(data: data, http: http, endpoint: "tavily/search"))
        }
        return out
    }

    private func bingSearch(_ query: String) async throws -> String {
        let key = settings.bingSearchKey
        guard !key.isEmpty else {
            throw AIError.missingAPIKey("请先在设置中填写 Bing Search API Key")
        }

        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let url = URL(string: "https://api.bing.microsoft.com/v7.0/search?q=\(encoded)&count=5&mkt=zh-CN")!
        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")

        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw AIError.apiError("Bing 搜索请求失败")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let webPages = json?["webPages"] as? [String: Any],
              let results = webPages["value"] as? [[String: Any]] else {
            return ""
        }

        return results.prefix(5).enumerated().map { i, r in
            let title = r["name"] as? String ?? ""
            let snippet = r["snippet"] as? String ?? ""
            let url = r["url"] as? String ?? ""
            return "\(i+1). \(title)\n   \(snippet)\n   来源：\(url)"
        }.joined(separator: "\n\n")
    }

    private func googleSearch(_ query: String) async throws -> String {
        let key = settings.googleSearchKey
        let cx = settings.googleSearchCX
        guard !key.isEmpty, !cx.isEmpty else {
            throw AIError.missingAPIKey("请先在设置中填写 Google Search API Key 和 CX ID")
        }

        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let url = URL(string: "https://www.googleapis.com/customsearch/v1?key=\(key)&cx=\(cx)&q=\(encoded)&num=5")!

        let (data, resp) = try await URLSession.shared.data(for: URLRequest(url: url))
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw AIError.apiError("Google 搜索请求失败")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let items = json?["items"] as? [[String: Any]] else {
            return ""
        }

        return items.prefix(5).enumerated().map { i, r in
            let title = r["title"] as? String ?? ""
            let snippet = r["snippet"] as? String ?? ""
            let link = r["link"] as? String ?? ""
            return "\(i+1). \(title)\n   \(snippet)\n   来源：\(link)"
        }.joined(separator: "\n\n")
    }

    // MARK: - MiniMax 视频

    /// MiniMax 的接口根地址。
    ///
    /// 国内（platform.minimaxi.com）和海外（minimax.io）是两套独立系统，
    /// 账号和 Key 不通用 —— 拿国内的 Key 打海外地址会直接报
    /// 「invalid api key (2049)」。默认按国内走，设置里可以改
    static func minimaxBase(for provider: Provider) -> String {
        let raw = AppSettings.shared.providerBaseURL(for: provider.rawValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "https://api.minimaxi.com" }
        var b = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        for marker in ["/v2/", "/v1/"] {
            if let r = b.range(of: marker) { b = String(b[b.startIndex..<r.lowerBound]); break }
        }
        if b.hasSuffix("/v1") || b.hasSuffix("/v2") { b = String(b.dropLast(3)) }
        return b
    }

    /// MiniMax H3 出片。v2 接口跟老的 v1 差别很大：
    /// 提示词和参考素材都装在 `content` 数组里，轮询地址是 `/v2/query/.../{task_id}`，
    /// 成片链接直接在 `content.url`，不用再走一次 files/retrieve
    private func generateWithMiniMax(prompt: String, duration: String, aspectRatio: String,
                                     resolution: String = "",
                                     referenceImages: [URL] = [],
                                     referenceVideos: [URL] = [],
                                     referenceAudios: [URL] = [],
                                     firstFrame: URL? = nil, lastFrame: URL? = nil) async throws -> URL {
        let apiKey = settings.providerAPIKey(for: Provider.minimax.rawValue)
        guard !apiKey.isEmpty else {
            throw AIError.missingAPIKey("请先在设置中填写 MiniMax 的 API Key")
        }

        let base = Self.minimaxBase(for: .minimax)
        guard let url = URL(string: "\(base)/v2/video_generation") else {
            throw AIError.missingAPIKey("MiniMax 的接口地址无效：\(base)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var content: [[String: Any]] = [["type": "text", "text": prompt]]
        // 首尾帧和参考素材是两种不同的角色，别混着发：
        // 首尾帧决定画面从哪开始/结束，参考素材只是让模型保持主体一致
        if let f = firstFrame, let b64 = imageToBase64DataURI(f) {
            content.append(["type": "image_url", "image_url": ["url": b64], "role": "first_frame"])
        }
        if let l = lastFrame, let b64 = imageToBase64DataURI(l) {
            content.append(["type": "image_url", "image_url": ["url": b64], "role": "last_frame"])
        }
        for u in referenceImages {
            if let b64 = imageToBase64DataURI(u) {
                content.append(["type": "image_url", "image_url": ["url": b64], "role": "reference_image"])
            }
        }
        for u in referenceVideos {
            if let b64 = fileToBase64DataURI(u, mime: "video/mp4") {
                content.append(["type": "video_url", "video_url": ["url": b64], "role": "reference_video"])
            }
        }
        for u in referenceAudios {
            if let b64 = fileToBase64DataURI(u, mime: "audio/mpeg") {
                content.append(["type": "audio_url", "audio_url": ["url": b64]])
            }
        }

        // 官方只认 768P / 2K，界面上的 480P/720P 归到 768P，1080P/4K 归到 2K
        let picked = resolution.isEmpty ? settings.aiResolution : resolution
        let mmRes = (picked.contains("1080") || picked.uppercased().contains("4K")
                     || picked.uppercased().contains("2K")) ? "2K" : "768P"
        // 有首帧时画幅由首帧决定，官方要求填 adaptive
        let mmRatio = firstFrame == nil ? aspectRatio : "adaptive"

        let body: [String: Any] = [
            "model": chosenModel(.minimax, fallback: "MiniMax-H3"),
            "content": content,
            "duration": min(15, max(4, Int(duration) ?? 5)),          // 官方 4~15s
            "resolution": mmRes,
            "ratio": mmRatio
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: request)
        let http = resp as? HTTPURLResponse
        guard http?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let taskId = json["task_id"] as? String else {
            throw AIError.apiError(Self.describeFailure(data: data, http: http, endpoint: "v2/video_generation"))
        }

        await MainActor.run { updateAssistantStatus(.generating(progress: "生成视频中…")) }

        // 官方建议 10 秒一轮，最多等 20 分钟
        let pollURL = URL(string: "\(base)/v2/query/video_generation/\(taskId)")!
        for _ in 0..<120 {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 10_000_000_000)
            var pollReq = URLRequest(url: pollURL)
            pollReq.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            let (pData, pResp) = try await URLSession.shared.data(for: pollReq)
            guard let raw = try? JSONSerialization.jsonObject(with: pData) as? [String: Any] else { continue }
            // 有的返回把任务包在 task 里，有的直接摊平，两种都收
            let pJson = (raw["task"] as? [String: Any]) ?? raw

            // HTTP 200 不代表查成功：地址写错、鉴权过期都会在 base_resp 里给错误码。
            // 不检查的话这里会一声不响地空转到超时
            if let br = (pJson["base_resp"] ?? raw["base_resp"]) as? [String: Any],
               let code = br["status_code"] as? Int, code != 0 {
                let msg = br["status_msg"] as? String ?? "未知错误"
                throw AIError.apiError("MiniMax 查询失败（\(code)）：\(msg)")
            }

            let status = ((pJson["status"] as? String) ?? "").lowercased()
            switch status {
            case "succeeded", "success", "finished", "done":
                let c = (pJson["content"] as? [String: Any]) ?? (raw["content"] as? [String: Any])
                if let link = (c?["url"] as? String) ?? (c?["video_url"] as? String) {
                    await MainActor.run { updateAssistantStatus(.downloading(progress: 0)) }
                    return try await downloadFile(from: link, filename: "minimax_\(taskId.prefix(8)).mp4")
                }
                throw AIError.apiError(Self.describeFailure(data: pData, http: pResp as? HTTPURLResponse,
                                                            endpoint: "v2/query/video_generation"))
            case "failed", "fail":
                throw AIError.apiError("MiniMax 生成失败")
            case "cancelled", "canceled":
                throw AIError.apiError("MiniMax 任务已取消")
            default:
                // 把服务端报的状态原样显示出来。状态名对不上时至少能看出卡在哪一步，
                // 而不是永远停在「生成视频中…」
                let shown = status.isEmpty ? "等待中" : status
                DiagLog.log("[MiniMax] task=\(taskId) status=\(status.isEmpty ? "(空)" : status)")
                await MainActor.run { updateAssistantStatus(.generating(progress: "生成视频中…（\(shown)）")) }
                continue
            }
        }
        throw AIError.timeout
    }

    // MARK: - Vidu 视频

    private func generateWithVidu(prompt: String, duration: String, aspectRatio: String, referenceImage: URL? = nil) async throws -> URL {
        let apiKey = settings.providerAPIKey(for: Provider.vidu.rawValue)
        guard !apiKey.isEmpty else {
            throw AIError.missingAPIKey("请先在设置中填写 Vidu 的 API Key")
        }

        let url = URL(string: "https://api.vidu.com/v1/tasks")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var inputDict: [String: Any] = ["prompt": prompt]
        let taskType: String
        if let imgURL = referenceImage, let b64 = imageToBase64DataURI(imgURL) {
            taskType = "img2video"
            inputDict["image"] = ["url": b64]
        } else {
            taskType = "text2video"
        }
        let body: [String: Any] = [
            "type": taskType,
            "model": "vidu-2.0",
            "input": inputDict,
            "output_params": ["duration": Int(duration) ?? 4, "aspect_ratio": aspectRatio]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw AIError.apiError("Vidu 请求失败")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let taskId = json?["id"] as? String else {
            throw AIError.apiError("Vidu 未返回任务 ID")
        }

        await MainActor.run { updateAssistantStatus(.generating(progress: "生成视频中…")) }

        for _ in 0..<120 {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            let pollURL = URL(string: "https://api.vidu.com/v1/tasks/\(taskId)")!
            var pollReq = URLRequest(url: pollURL)
            pollReq.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            let (pData, _) = try await URLSession.shared.data(for: pollReq)
            let pJson = try JSONSerialization.jsonObject(with: pData) as? [String: Any]
            let status = pJson?["status"] as? String ?? ""
            if status == "success" {
                if let output = pJson?["output"] as? [String: Any],
                   let videoURL = output["video_url"] as? String {
                    await MainActor.run { updateAssistantStatus(.downloading(progress: 0)) }
                    return try await downloadFile(from: videoURL, filename: "vidu_\(taskId.prefix(8)).mp4")
                }
                throw AIError.apiError("Vidu 完成但无视频")
            } else if status == "failed" {
                throw AIError.apiError("Vidu 生成失败")
            }
        }
        throw AIError.timeout
    }

    // MARK: - Veo 3 (Google)

    private func generateWithVeo3(prompt: String, duration: String, aspectRatio: String, referenceImage: URL? = nil) async throws -> URL {
        let apiKey = settings.providerAPIKey(for: Provider.veo3.rawValue)
        guard !apiKey.isEmpty else {
            throw AIError.missingAPIKey("请先在设置中填写 Google AI 的 API Key")
        }

        let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/veo-3:generateVideos?key=\(apiKey)")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var parts: [[String: Any]] = []
        if let imgURL = referenceImage, let imgData = try? Data(contentsOf: imgURL) {
            let ext = imgURL.pathExtension.lowercased()
            let mime = ext == "png" ? "image/png" : "image/jpeg"
            parts.append(["inline_data": ["mime_type": mime, "data": imgData.base64EncodedString()]])
        }
        parts.append(["text": prompt])

        let body: [String: Any] = [
            "contents": [["parts": parts]],
            "generationConfig": [
                "aspectRatio": aspectRatio,
                "durationSeconds": Int(duration) ?? 5
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        await MainActor.run { updateAssistantStatus(.generating(progress: "提交 Veo 3 任务…")) }

        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "请求失败"
            throw AIError.apiError("Veo 3: \(msg)")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let opName = json?["name"] as? String else {
            if let videos = (json?["generatedVideos"] as? [[String: Any]]),
               let videoData = videos.first?["video"] as? [String: Any],
               let uri = videoData["uri"] as? String {
                await MainActor.run { updateAssistantStatus(.downloading(progress: 0)) }
                return try await downloadFile(from: uri, filename: "veo3_\(UUID().uuidString.prefix(8)).mp4")
            }
            throw AIError.apiError("Veo 3 未返回操作 ID")
        }

        await MainActor.run { updateAssistantStatus(.generating(progress: "生成视频中…")) }

        for _ in 0..<120 {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            let pollURL = URL(string: "https://generativelanguage.googleapis.com/v1beta/\(opName)?key=\(apiKey)")!
            let (pData, _) = try await URLSession.shared.data(for: URLRequest(url: pollURL))
            let pJson = try JSONSerialization.jsonObject(with: pData) as? [String: Any]
            if let done = pJson?["done"] as? Bool, done {
                if let response = pJson?["response"] as? [String: Any],
                   let videos = response["generatedVideos"] as? [[String: Any]],
                   let videoData = videos.first?["video"] as? [String: Any],
                   let uri = videoData["uri"] as? String {
                    await MainActor.run { updateAssistantStatus(.downloading(progress: 0)) }
                    return try await downloadFile(from: uri, filename: "veo3_\(UUID().uuidString.prefix(8)).mp4")
                }
                throw AIError.apiError("Veo 3 完成但无视频")
            }
            if let error = pJson?["error"] as? [String: Any] {
                throw AIError.apiError("Veo 3: \((error["message"] as? String) ?? "生成失败")")
            }
        }
        throw AIError.timeout
    }

    // MARK: - 下载文件

    private func downloadFile(from urlString: String, filename: String) async throws -> URL {
        guard let url = URL(string: urlString) else {
            throw AIError.apiError("无效的下载 URL")
        }

        let (tempURL, response) = try await URLSession.shared.download(from: url)
        guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
            throw AIError.apiError("下载失败")
        }

        let saveDir = AppSettings.shared.effectiveProjectDir.appendingPathComponent("AI生成")
        try FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)

        let destURL = saveDir.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: destURL)

        return destURL
    }

    private func downloadFileWithAuth(from urlString: String, apiKey: String, filename: String) async throws -> URL {
        guard let url = URL(string: urlString) else {
            throw AIError.apiError("无效的下载 URL")
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (tempURL, response) = try await URLSession.shared.download(for: request)
        guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
            throw AIError.apiError("下载失败")
        }

        let saveDir = AppSettings.shared.effectiveProjectDir.appendingPathComponent("AI生成")
        try FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)

        let destURL = saveDir.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: destURL)

        return destURL
    }

    // MARK: - Helpers

    /// 报进度。**按任务定位消息**，不能再用「最后一条还在跑的助手消息」——
    /// 并发跑的时候那样会把 A 的进度写到 B 头上
    private func updateAssistantStatus(_ status: TaskStatus) {
        if let tid = Context.taskID, let task = runningTasks[tid] {
            // 会话被切走了就只更新数据、不动当前消息列表
            guard currentConversationId == task.convId else { return }
            if let idx = messages.firstIndex(where: { $0.id == task.msgId }) {
                messages[idx].status = status
            }
            return
        }
        // 没有任务上下文（理论上不该走到这，留着兜底）
        if let idx = messages.lastIndex(where: { $0.role == .assistant && $0.status != .idle }) {
            messages[idx].status = status
        }
    }

    private func createBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private func resolveBookmark(_ data: Data) -> URL? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private func resolveMediaURL(path: String?, bookmark: Data?) -> URL? {
        if let bm = bookmark, let url = resolveBookmark(bm) {
            return url
        }
        if let p = path, FileManager.default.fileExists(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        return nil
    }

    private func imageToBase64(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return data.base64EncodedString()
    }

    private func imageToBase64DataURI(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let ext = url.pathExtension.lowercased()
        let mime: String
        switch ext {
        case "png": mime = "image/png"
        case "webp": mime = "image/webp"
        default: mime = "image/jpeg"
        }
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }

    /// 压缩参考图：原图直传会让请求体膨胀到几 MB，导致上传/服务端解码超时。失败返回 nil，调用方回退原图
    private func compressedImageData(_ url: URL, maxDimension: Int = 1536, quality: CGFloat = 0.85) -> Data? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// 压缩参考图后转 base64 data URI
    private func compressedImageDataURI(_ url: URL, maxDimension: Int = 1536, quality: CGFloat = 0.85) -> String? {
        guard let data = compressedImageData(url, maxDimension: maxDimension, quality: quality) else {
            return imageToBase64DataURI(url)
        }
        return "data:image/jpeg;base64,\(data.base64EncodedString())"
    }

    private func fileToBase64DataURI(_ url: URL, mime: String) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }

    enum AIError: LocalizedError {
        case missingAPIKey(String)
        case invalidKey
        case apiError(String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .missingAPIKey(let msg): return msg
            case .invalidKey: return "API Key 无效"
            case .apiError(let msg): return msg
            case .timeout: return "生成超时（超过10分钟）"
            }
        }
    }
}

// MARK: - Base64 URL Encoding

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// MiniMax TTS 返回的音频是 hex 字符串，Foundation 没有现成的解码
private extension Data {
    init?(hexEncoded hex: String) {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        func val(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30...0x39: return c - 0x30            // 0-9
            case 0x61...0x66: return c - 0x61 + 10       // a-f
            case 0x41...0x46: return c - 0x41 + 10       // A-F
            default: return nil
            }
        }
        var i = 0
        while i < chars.count {
            guard let hi = val(chars[i]), let lo = val(chars[i + 1]) else { return nil }
            bytes.append(hi << 4 | lo)
            i += 2
        }
        self.init(bytes)
    }
}
