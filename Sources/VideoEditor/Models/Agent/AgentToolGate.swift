// AgentToolGate.swift
//
// 工具表按需挂载。
//
// 起因是实测：问一句「画布上有什么」，一来一回就花掉 18.8k token，
// 其中七八千是**工具表本身** —— 六十个工具的说明书每轮请求原样重发一遍，
// 跟问题多简单毫无关系。而这次任务实际只用到一个工具。
//
// 所以只把常用的那几个常驻，其余按用户这句话的意图分组挂。
// 光靠关键词不保险（「把它弄清楚点」谁也猜不到是要超分），
// 所以跟 MCP 那套一样走两条路：话里点到就自动挂，没点到但模型觉得需要，
// 它自己调 enable_tools 要。
//
// **激活是会话内累加的**：这一轮点亮的组，后面几轮都在，
// 免得模型刚要来又没了、下一步还得再要一次。

import Foundation

@MainActor
final class AgentToolGate {

    static let shared = AgentToolGate()

    enum Group: String, CaseIterable {
        case edit, canvas, generate, studio, media, script

        var label: String {
            switch self {
            case .edit:     return "剪辑"
            case .canvas:   return "画布"
            case .generate: return "生成"
            case .studio:   return "加工"
            case .media:    return "媒体"
            case .script:   return "脚本"
            }
        }

        /// 给模型看的一句话说明（进系统提示词，要短）
        var summary: String {
            switch self {
            case .edit:     return "往时间轴加东西、分割、移动、删片段、加字幕文字滤镜特效"
            case .canvas:   return "在 AI 画布上加卡片、连线、让卡片开始生成"
            case .generate: return "生成图片、视频、音频"
            case .studio:   return "转场、翻译字幕、字幕配音、清晰度提升、抠图、去背景音乐、场景切分、挑精彩片段、保存撤销重命名"
            case .media:    return "导出成片、语音识别、逐帧识别画面文字、裁剪片段"
            case .script:   return "跑命令行、装和跑 Skill"
            }
        }

        /// 话里出现这些词就自动挂上。宁可多挂一组，也别让它干不成活 ——
        /// 少挂的代价是任务失败，多挂的代价只是几百 token
        var keywords: [String] {
            switch self {
            case .edit:
                return ["时间轴", "时间线", "轨道", "片段", "字幕", "文字", "标题", "滤镜",
                        "特效", "调节", "分割", "切开", "删掉", "删除", "移动", "导入",
                        "加进", "放到", "素材库", "剪"]
            case .canvas:
                return ["画布", "卡片", "连线", "节点", "连到", "画板"]
            case .generate:
                return ["生成", "画一", "画个", "画张", "做一张", "做个视频", "配图",
                        "出图", "文生", "图生", "配音", "音效", "背景音乐", "bgm"]
            case .studio:
                return ["转场", "翻译", "配音", "朗读", "tts", "清晰", "超分", "画质",
                        "抠图", "去背景", "人声", "伴奏", "场景", "精彩", "高光",
                        "保存", "撤销", "重做", "重命名", "成组", "解组"]
            case .media:
                return ["导出", "输出", "成片", "识别", "语音", "转写", "字幕生成",
                        "ocr", "认字", "识字", "扫描", "裁剪", "裁掉", "掐头"]
            case .script:
                return ["命令", "终端", "脚本", "shell", "skill", "技能", "安装", "插件"]
            }
        }
    }

    private(set) var activated: Set<Group> = []

    /// 换会话时清一次，别把上一段对话点亮的组带过来
    func reset() { activated.removeAll() }

    func activate(matching prompt: String) {
        let text = prompt.lowercased()
        for g in Group.allCases where !activated.contains(g) {
            if g.keywords.contains(where: { text.contains($0) }) { activated.insert(g) }
        }
    }

    /// 模型自己要。名字写中文标签或英文 key 都认
    func enable(_ raw: String) -> AgentToolResult {
        let want = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard let g = Group.allCases.first(where: {
            $0.rawValue == want || $0.label == raw.trimmingCharacters(in: .whitespaces)
        }) else {
            let all = Group.allCases.map { "\($0.rawValue)（\($0.label)）" }.joined(separator: "、")
            return .fail("没有叫「\(raw)」的工具组。能要的是：\(all)")
        }
        activated.insert(g)
        return .ok("\(g.label)那组工具挂上来了，现在能用了：\(g.summary)。")
    }

    /// 这一组对应哪些工具
    @MainActor
    private func specs(of g: Group) -> [AgentToolSpec] {
        switch g {
        case .edit:
            // 在画布上要来这组时，「看轨道 / 看项目 / 截预览帧」也得一起给 ——
            // 光有「加片段」却看不见时间轴上现在有什么，它只能瞎放
            return (AgentToolbox.readTools.filter { Self.timelineOnlyNames.contains($0.name) }
                    + AgentToolbox.editTools)
                .filter { !Self.alwaysOnNames.contains($0.name) }
        case .canvas:   return AgentToolbox.canvasTools.filter { !Self.alwaysOnNames.contains($0.name) }
        case .generate: return AgentToolbox.generateTools
        case .studio:   return AgentToolbox.studioTools + AgentToolbox.studioTools2
        case .media:    return AgentToolbox.mediaTools
        case .script:   return AgentToolbox.shellTools + AgentToolbox.skillTools
        }
    }

    /// 不管在哪都留在手上的那几个：素材库谁都要用，记忆两条很短但随时会用到
    /// （用户随口一句「记住我喜欢…」，挂不上就只能干看着）
    static let alwaysOnNames: Set<String> = [
        "remember", "forget", "list_assets"
    ]

    /// 只在时间轴那边常驻的。**画布用不着** ——
    /// 在画布上聊天时挂着「看轨道」「截预览帧」纯属浪费，
    /// 真要放进时间轴，它自己调 enable_tools 要 edit 那组
    static let timelineOnlyNames: Set<String> = [
        "get_project", "list_tracks", "capture_frame", "seek"
    ]

    /// 网关工具本身。描述得短 —— 它是每轮都发的
    var gateTool: AgentToolSpec {
        let lines = Group.allCases.map { "\($0.rawValue)＝\($0.summary)" }.joined(separator: "；")
        return AgentToolSpec(
            name: "enable_tools",
            description: """
            手上没有能干这活的工具时，用这个把对应那组要过来，然后接着做。
            可选：\(lines)
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "group": ["type": "string", "description": "组名，比如 media、studio"]
                ] as [String: Any],
                "required": ["group"]
            ],
            risk: .readOnly)
    }

    /// 这一轮实际发给模型的工具表。
    ///
    /// **两边手上的家伙不一样**：在画布上聊天时，时间轴那套（看轨道、截预览帧）
    /// 一条都不挂，换成画布自己那组；在侧栏则反过来。
    /// 挂反了的代价不只是浪费 token —— 工具越多模型越容易挑错那个
    func tools(mode: AgentMode, inCanvas: Bool) -> [AgentToolSpec] {
        let shared = (AgentToolbox.readTools + AgentToolbox.editTools + AgentToolbox.canvasTools)
            .filter { Self.alwaysOnNames.contains($0.name) }
        var list: [AgentToolSpec] = shared + [gateTool]
        if inCanvas {
            // 画布上：画布那组直接给全，不用它开口要
            list += AgentToolbox.canvasTools
        } else {
            list += AgentToolbox.readTools.filter { Self.timelineOnlyNames.contains($0.name) }
        }
        // **顺序必须固定**：Set 的迭代顺序每次都可能不一样，工具表一换顺序，
        // 提示词缓存的前缀就对不上，整块几千 token 全部重新计费。
        // 实测就是这么漏的：五轮里有两轮命中、三轮从头再来
        for g in Group.allCases where activated.contains(g) { list += specs(of: g) }
        // 计划模式只读：挂上来的组里凡是会动项目的一律拿掉
        if mode == .plan { list = list.filter { $0.risk == .readOnly } }
        // 组之间有重叠（editTools 里也有只读的），去重按名字
        var seen = Set<String>()
        return list.filter { seen.insert($0.name).inserted }
    }

    /// 进系统提示词的那段。告诉模型「手上这些不是全部」。
    /// 画布场景下画布那组本来就全给了，别再列进「还没挂上来」里
    func promptSection(inCanvas: Bool) -> String {
        let idle = Group.allCases.filter {
            !activated.contains($0) && !(inCanvas && $0 == .canvas)
        }
        guard !idle.isEmpty else { return "" }
        let lines = idle.map { "  - \($0.rawValue)：\($0.summary)" }.joined(separator: "\n")
        return """

        ## 还没挂上来的工具
        你手上只有常用的那些。下面这几组还没挂，需要就调 enable_tools 要，
        要完接着干，**不要因为工具不在手上就说做不了**：
        \(lines)

        """
    }
}
