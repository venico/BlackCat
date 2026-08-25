import SwiftUI

// MARK: - 节点

/// 画布上的一个节点（v5.1.0，B3）
///
/// 四种类型对应 AI 那四类产出。文本节点是纯输入，其余三类既可以上传/从素材库选，
/// 也可以由 AI 生成填进来（B4）。
struct CanvasNode: Identifiable, Equatable, Codable {

    enum Kind: String, Codable, CaseIterable {
        case text, image, video, audio

        var label: String {
            switch self {
            case .text: return "文本"
            case .image: return "图片"
            case .video: return "视频"
            case .audio: return "音频"
            }
        }

        /// 节点默认尺寸。音频是横条、文本是宽输入框，形状本身就提示了类型；
        /// 图片和视频按当前选的画面比例来 —— 卡片长什么样就是出片什么样
        func defaultSize(ratio: String? = nil) -> CGSize {
            switch self {
            case .text:  return CGSize(width: 280, height: 160)
            // 音频比原来矮三分之一：波形不需要那么高
            case .audio: return CGSize(width: 300, height: 80)
            case .image, .video:
                return Self.sizeFor(ratio: ratio ?? "1:1")
            }
        }

        /// **右边的 +**：拿这个节点当参考，能生成出什么。
        /// 文本能派生一切；图片能出图和视频；视频只能再出视频；音频只能出音频
        var canGenerate: [Kind] {
            switch self {
            case .text:  return [.text, .image, .video, .audio]
            case .image: return [.image, .video]
            case .video: return [.video]
            // 音频只往下接视频：拿一段音频去生成配套画面是成立的
            // （视频模型收音频当参考，`video.acceptsContext` 里本来就有 audio）；
            // 「音频再生成音频」没有实际用处，不列
            case .audio: return [.video]
            }
        }

        /// **左边的 +**：这个节点能接什么类型的上下文（谁能当它的参考）。
        ///
        /// 跟 `canGenerate` **不是**互为逆向，两张表各说各的事：
        /// 视频能拿文字/图片/视频/音频当参考，但反过来「音频能派生出什么」
        /// 只有音频和视频 —— 音频不会去生成图片或文字
        var acceptsContext: [Kind] {
            switch self {
            case .text:  return [.text]
            case .image: return [.text, .image]
            case .video: return [.text, .image, .video, .audio]
            case .audio: return [.text]
            }
        }

        /// 这类节点对应哪一类生成模型 —— 选正确的 provider 要按这个查，
        /// 不能直接拿 AI 面板顶部全局选中的那个（那个可能是任何类型）
        var providerCategory: AIVideoService.ProviderCategory {
            switch self {
            case .text:  return .text
            case .image: return .image
            case .video: return .video
            case .audio: return .audio
            }
        }

        /// 按比例算卡片尺寸。长边固定 300，短边跟着比例走
        static func sizeFor(ratio: String) -> CGSize {
            let parts = ratio.split(separator: ":").compactMap { Double($0) }
            guard parts.count == 2, parts[0] > 0, parts[1] > 0 else {
                return CGSize(width: 260, height: 260)
            }
            let r = parts[0] / parts[1]
            let long: CGFloat = 300
            return r >= 1
                ? CGSize(width: long, height: long / r)
                : CGSize(width: long * r, height: long)
        }
    }

    var id = UUID()
    var kind: Kind
    /// 画布内容坐标（不受缩放平移影响），指节点左上角
    var position: CGPoint
    var size: CGSize

    /// 文本节点的内容
    var text: String = ""
    /// 图片/视频/音频节点的素材。上传、从素材库选、AI 生成完，都填这里
    var assetID: UUID?
    var mediaPath: String?

    /// 生成状态
    var isGenerating: Bool = false
    /// 排队中：上游还没出结果，等它完成再开工
    var isWaiting: Bool = false
    /// 这次生成用的提示词（节点自己的输入框里那句）
    var prompt: String = ""
    /// 失败原因，节点上显示 + 可重试
    var failure: String?

    /// 处理进度（清晰度提升、分离音轨这类长任务）。
    /// 时间轴那边用通知卡片显示，画布上直接显示在卡片里 —— 逻辑一样，壳不同
    var progressText: String?
    var progress: Double?
    /// 这个节点用的画面比例。改比例时卡片跟着变形
    var ratio: String = "1:1"

    /// 卡片显示名。生成/上传时给一个「图片 1」「视频 2」这样的名字，
    /// 显示在卡片**上方的类型标签那一行**，卡片里不再放文件名
    var displayName: String = ""

    /// 所属分组。同一个 groupID 的卡片共用一块浅色底，选中、移动、删除都是整组一起
    var groupID: UUID?

    /// 视频卡片：上游的图片是当参考图用，还是当首帧/尾帧用。
    /// 存在节点上而不是全局 —— 每张视频卡片接的上游不同，用法本来就可以不一样
    var usesFrameMode: Bool = false

    // MARK: 文字卡片的样式

    /// 文字颜色（十六进制，跟字幕/文字图层那边一个写法）
    var textColorHex: String = "#FFFFFF"
    /// 标题级别：0 = 正文，1/2/3 = H1/H2/H3
    var headingLevel: Int = 0
    var bold: Bool = false
    var italic: Bool = false
    var underline: Bool = false
    var strikethrough: Bool = false

    /// 正文字号。标题按级别放大
    var fontSize: CGFloat {
        switch headingLevel {
        case 1:  return 22
        case 2:  return 18
        case 3:  return 15
        default: return 12
        }
    }

    /// 常规构造。写了 `init(from:)` 之后编译器就不再自动生成成员构造器了，得自己留一个
    init(id: UUID = UUID(), kind: Kind, position: CGPoint, size: CGSize) {
        self.id = id
        self.kind = kind
        self.position = position
        self.size = size
    }

    // MARK: - 解码容错

    /// **手写解码，每个字段都用 decodeIfPresent**。
    ///
    /// Swift 自动生成的 Codable 对「属性有默认值但 JSON 里缺这个键」并不宽容：
    /// 缺一个键就抛错，而 `[CanvasNode]` 里一条抛错整个数组就解不出来，
    /// 再往上整条会话记录、整个历史文件跟着完蛋。
    /// 2026-08-21 加文字样式字段时就是这么把用户 21 条历史冲掉的 ——
    /// 以后往这个结构加字段，照着下面加一行 decodeIfPresent 就行，不会再炸旧数据
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .text
        position = try c.decodeIfPresent(CGPoint.self, forKey: .position) ?? .zero
        size = try c.decodeIfPresent(CGSize.self, forKey: .size) ?? kind.defaultSize()
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        assetID = try c.decodeIfPresent(UUID.self, forKey: .assetID)
        mediaPath = try c.decodeIfPresent(String.self, forKey: .mediaPath)
        isGenerating = try c.decodeIfPresent(Bool.self, forKey: .isGenerating) ?? false
        isWaiting = try c.decodeIfPresent(Bool.self, forKey: .isWaiting) ?? false
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        failure = try c.decodeIfPresent(String.self, forKey: .failure)
        ratio = try c.decodeIfPresent(String.self, forKey: .ratio) ?? "1:1"
        textColorHex = try c.decodeIfPresent(String.self, forKey: .textColorHex) ?? "#FFFFFF"
        headingLevel = try c.decodeIfPresent(Int.self, forKey: .headingLevel) ?? 0
        bold = try c.decodeIfPresent(Bool.self, forKey: .bold) ?? false
        italic = try c.decodeIfPresent(Bool.self, forKey: .italic) ?? false
        underline = try c.decodeIfPresent(Bool.self, forKey: .underline) ?? false
        strikethrough = try c.decodeIfPresent(Bool.self, forKey: .strikethrough) ?? false
        progressText = try c.decodeIfPresent(String.self, forKey: .progressText)
        progress = try c.decodeIfPresent(Double.self, forKey: .progress)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        groupID = try c.decodeIfPresent(UUID.self, forKey: .groupID)
        usesFrameMode = try c.decodeIfPresent(Bool.self, forKey: .usesFrameMode) ?? false
    }

    /// 实际画多大。音频卡片高度**写死** —— 波形不需要那么高，
    /// 而且改 defaultSize 只影响新建的卡片，已经存在的还是老高度
    var renderSize: CGSize {
        kind == .audio ? CGSize(width: size.width, height: 80) : size
    }

    var mediaURL: URL? {
        guard let mediaPath else { return nil }
        return URL(fileURLWithPath: mediaPath)
    }

    var hasContent: Bool {
        switch kind {
        case .text: return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default: return mediaPath != nil
        }
    }

    var frame: CGRect { CGRect(origin: position, size: renderSize) }
}

// MARK: - 分组

/// 一组卡片。卡片身上记 `groupID`，这里只存组自己的信息（现在就一个名字）
struct CanvasGroup: Identifiable, Equatable, Codable {
    var id = UUID()
    var name: String = ""
    /// 用户手动拉过的框（内容坐标）。没拉过就是 nil，框跟着成员自动算；
    /// 拉过之后取它和成员包围盒的并集 —— 拉得再小也不会把卡片切在外面
    var rect: CGRect?
    /// 背景色（十六进制）。nil = 默认的浅灰白。画出来是半透明的，只带一点色调
    var colorHex: String?

    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }

    /// 跟 CanvasNode 一样手写容错解码 —— 往这个结构加字段时旧存档不会炸
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        rect = try c.decodeIfPresent(CGRect.self, forKey: .rect)
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex)
    }
}

// MARK: - 连线

/// 一条连线：上游节点作为下游节点的参考素材
struct CanvasEdge: Identifiable, Equatable, Codable {
    var id = UUID()
    var from: UUID
    var to: UUID
}

// MARK: - 连线的类型校验

enum CanvasConnectionRule {

    /// 能不能从 `from` 连到 `to`。
    ///
    /// 判据是**目标节点选的模型收不收这种参考**，不是凭空规定的 —— 直接吃
    /// `Provider` 上现成的 `maxReferenceImages/Videos/Audios` 矩阵：
    /// 图片模型的音频上限是 0，所以「图片不能参考音频」是算出来的，不是写死的。
    /// 类型不合的统一提示。分类型写「图片不能参考音频」这种更啰嗦，
    /// 而且用户拉线时本来就看得见两端是什么
    static let unsupportedMessage = "不支持此类型素材"

    static func check(from: CanvasNode.Kind,
                      to: CanvasNode.Kind,
                      provider: AIVideoService.Provider) -> Result {
        // 连线的方向是 from → to，语义是「from 当 to 的上下文」，
        // 所以查的是**目标**能接什么（`acceptsContext`），
        // 跟卡片左边那个 + 菜单里列的是同一份表
        guard to.acceptsContext.contains(from) else {
            return .rejected(unsupportedMessage)
        }

        // 类型放行之后，再看这家模型收不收得下这种参考
        let limit: Int
        switch from {
        case .image: limit = provider.maxReferenceImages
        case .video: limit = provider.maxReferenceVideos
        case .audio: limit = provider.maxReferenceAudios
        case .text:  limit = Int.max
        }
        guard limit > 0 else {
            return .rejected(unsupportedMessage)
        }
        return .allowed
    }

    enum Result: Equatable {
        case allowed
        case rejected(String)

        var isAllowed: Bool { self == .allowed }
        var message: String? {
            if case .rejected(let m) = self { return m }
            return nil
        }
    }
}
