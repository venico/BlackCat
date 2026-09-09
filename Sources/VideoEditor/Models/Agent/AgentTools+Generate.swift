// AgentTools+Generate.swift
//
// 生成类工具：文生图、文生视频、文生音频、字幕转语音。
//
// 两条规矩：
//   · **算危险操作**。每调一次都真金白银花钱，自动模式下要先问过用户；
//     不拦的话模型自作主张连生十张，钱花了人还不知道
//   · **提交完就返回，不干等**。生成要几十秒到几分钟，干等会把整轮对话卡死。
//     任务丢进 AgentBackgroundTasks，聊天框左上角能看进度，完成了给张卡片

import Foundation

extension AgentToolbox {

    /// 这一类有哪些模型。没配 Key 的也列，但标出来 ——
    /// 用户点名了没配的那个，得让模型能说清楚是缺 Key 而不是没这个模型
    static func modelList(_ cat: AIVideoService.ProviderCategory) -> String {
        let names = AIVideoService.Provider.allCases
            .filter { !$0.isHidden && $0.category == cat }
            .map { p -> String in
                AIVideoService.apiKey(for: p).isEmpty
                    ? p.rawValue + "（未配 Key）" : p.rawValue
            }
        return names.isEmpty ? "（没有可用的）" : names.joined(separator: "、")
    }

    /// 把用户随口说的名字对到具体供应商上。
    /// 「image2」要能落到 gpt-image-2，所以连字符空格下划线全抹掉再比
    static func matchProvider(_ want: String,
                              _ cat: AIVideoService.ProviderCategory) -> AIVideoService.Provider? {
        func norm(_ s: String) -> String {
            s.lowercased()
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: " ", with: "")
        }
        let key = norm(want)
        guard !key.isEmpty else { return nil }
        let pool = AIVideoService.Provider.allCases.filter { !$0.isHidden && $0.category == cat }
        if let hit = pool.first(where: { norm($0.rawValue) == key || norm($0.displayName) == key }) {
            return hit
        }
        return pool.first {
            let r = norm($0.rawValue), d = norm($0.displayName)
            return r.contains(key) || key.contains(r) || d.contains(key) || key.contains(d)
        }
    }

    static var generateTools: [AgentToolSpec] {
        [
            AgentToolSpec(
                name: "generate_image",
                description: """
                用 AI 生成一张图片。**提交后立刻返回，不会等它画完** —— \
                结果进后台任务，完成后会自动加进素材库，那时候再叫你放到时间轴上。

                **用户要几张就调几次，一张就只调一次。** 不要为了保险同一个提示词\
                多调几家模型 —— 每调一次都真金白银花用户的钱。某一家失败了软件会\
                问用户要不要换一家重试，轮不到你先铺开。用户点名了某个模型就只用那个。
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "prompt": ["type": "string", "description": "画什么。越具体越好"],
                        "ratio": ["type": "string", "description": "画面比例，比如 1:1、16:9、9:16"],
                        "model": ["type": "string",
                                  "description": "指定用哪个模型。配好 Key 的有："
                                      + Self.modelList(.image) + "。用户没点名就别传，走项目设置里的默认"],
                        "count": ["type": "integer",
                                  "description": "生成几张。**用户说了几张就传几**（「来三张」传 3），"
                                      + "没说数量就别传，默认 1 张。上限跟模型走："
                                      + "Image2 最多 10 张；Seedream 5.0 Pro 只能 1 张，"
                                      + "5.0 Lite 最多 15 张。要超了会自动收到上限，并告诉你收成了几张"]
                    ] as [String: Any],
                    "required": ["prompt"]
                ],
                risk: .dangerous),

            AgentToolSpec(
                name: "generate_video",
                description: "用 AI 生成一段视频。同样是提交后立刻返回，不等它渲完。",
                parameters: [
                    "type": "object",
                    "properties": [
                        "prompt": ["type": "string"],
                        "duration": ["type": "string", "description": "秒数，一般是 5 或 10"],
                        "ratio": ["type": "string", "description": "16:9、9:16、1:1"],
                        "model": ["type": "string",
                                  "description": "指定用哪个模型。配好 Key 的有："
                                      + Self.modelList(.video) + "。用户没点名就别传"]
                    ] as [String: Any],
                    "required": ["prompt"]
                ],
                risk: .dangerous),

            AgentToolSpec(
                name: "generate_audio",
                description: "用 AI 生成音频（音乐、音效）。提交后立刻返回。",
                parameters: [
                    "type": "object",
                    "properties": [
                        "prompt": ["type": "string"],
                        // 图片/视频都能点名模型，音频原来漏了这个参数，
                        // 用户说「用 elevenlabs 生成」根本传不下来
                        "model": ["type": "string",
                                  "description": "指定用哪个模型。配好 Key 的有："
                                      + Self.modelList(.audio) + "。用户没点名就别传"]
                    ] as [String: Any],
                    "required": ["prompt"]
                ],
                risk: .dangerous),

            AgentToolSpec(
                name: "list_background_tasks",
                description: "看后台那些生成任务跑到哪了。用户问「好了没」的时候查它。",
                parameters: ["type": "object", "properties": [:] as [String: Any]],
                risk: .readOnly),
        ]
    }

    /// 换一家还有没有意义。**内容被审核挡下来的换谁都一样** ——
    /// 再提交一次只是多花一次钱、多等几十秒，还是同样的拒绝
    static func worthSwitchingProvider(_ err: Error) -> Bool {
        let t = err.localizedDescription.lowercased()
        let hopeless = ["审核", "违规", "敏感", "不合规", "safety", "content policy",
                        "content_policy", "prohibited", "nsfw", "blocked", "moderation"]
        return !hopeless.contains { t.contains($0) }
    }

    /// 下一个「配了 Key 且还没试过」的。按 defaultOrder 的顺序来，
    /// 没列进那张表的（以后新接的）排在后面
    static func nextUsableProvider(category: AIVideoService.ProviderCategory,
                                   tried: [AIVideoService.Provider]) -> AIVideoService.Provider? {
        let ordered = AIVideoService.defaultOrder(for: category)
            .filter { !$0.isHidden && $0.category == category }
        let rest = AIVideoService.Provider.allCases
            .filter { !$0.isHidden && $0.category == category && !ordered.contains($0) }
        return (ordered + rest).first {
            !tried.contains($0) && !AIVideoService.apiKey(for: $0).isEmpty
        }
    }

    /// 提交一次生成。`allowFallback` 为真时，失败会自动挑下一个配了 Key 的重来，
    /// `tried` 记着已经试过谁，防止在几家之间来回打转
    @MainActor
    @discardableResult
    static func submitGeneration(category: AIVideoService.ProviderCategory,
                                 prompt: String,
                                 args: [String: Any],
                                 provider: AIVideoService.Provider,
                                 project: ProjectState,
                                 allowFallback: Bool,
                                 tried: [AIVideoService.Provider],
                                 modelOverride: String? = nil,
                                 previousTaskID: UUID? = nil) -> UUID {
        let svc = AIVideoService.shared
        // 任务 id 要在回调里用到，而 id 是这个调用的返回值 ——
        // 先占一个盒子，提交完填进去，回调再从盒子里取。
        // 回调里现造一个新 id 的话，跟提交时登记的那条对不上，
        // 面板上那条会永远停在「进行中」
        // 用户在输入框上边那排挂着的参考内容要带上 —— 原来一张都没往下传，
        // 表现就是「我明明给了参考图，模型还让我上传」
        let refs = svc.agentRoundReferences
        let refImages = refs.filter { $0.type == .image }.map(\.url)
        let refVideos = refs.filter { $0.type == .video }.map(\.url)
        let refAudios = refs.filter { $0.type == .audio }.map(\.url)

        let box = TaskIDBox()
        let id = svc.generateForCanvas(
            prompt: prompt,
            provider: provider,
            duration: args["duration"] as? String ?? "5",
            aspectRatio: args["ratio"] as? String ?? "16:9",
            imageRatio: args["ratio"] as? String ?? "1:1",
            referenceImages: refImages,
            referenceVideos: refVideos,
            referenceAudios: refAudios,
            firstFrame: svc.agentRoundFirstFrame,
            lastFrame: svc.agentRoundLastFrame,
            modelOverride: modelOverride
        ) { result in
            Task { @MainActor in
                guard let tid = box.id else { return }
                switch result {
                case .success(let url):
                    if project.showCanvas {
                        // 画布里干的活，产物就落在画布上（它内部也会进素材库）
                        let kind: CanvasNode.Kind = category == .video ? .video : .image
                        project.canvas.dropGeneratedMedia(url: url, kind: kind)
                    } else {
                        // 生成完直接进素材库，用户不用再手动导一次
                        project.importFile(url)
                    }
                    svc.appendAgentMedia(url: url, category: category)
                    AgentBackgroundTasks.shared.finish(id: tid, url: url)
                case .failure(let err):
                    // 三个条件缺一个就不问换家，而三个都不在界面上露脸 ——
                    // 不打这条日志的话，用户只看到「没变成待确认」，谁也说不清卡在哪
                    let switchable = Self.worthSwitchingProvider(err)
                    let nextOne = Self.nextUsableProvider(category: category, tried: tried)
                    DiagLog.log("[生成] \(provider.displayName) 失败。"
                                + "允许换家=\(allowFallback) 换了有意义=\(switchable) "
                                + "下一家=\(nextOne?.displayName ?? "没有配了 Key 的") "
                                + "已试过=\(tried.map(\.displayName).joined(separator: "/"))")

                    // 取消绝不换家 —— 用户就是要它停
                    if allowFallback, !err.isUserCancellation, switchable, let next = nextOne {
                        let reason = "「\(provider.displayName)」没成：" + err.localizedDescription
                        DiagLog.log("[生成] \(reason)，可改用「\(next.displayName)」")
                        let again: () -> Void = {
                            _ = Self.submitGeneration(category: category, prompt: prompt, args: args,
                                                      provider: next, project: project,
                                                      allowFallback: true, tried: tried + [next],
                                                      previousTaskID: tid)
                        }
                        // 全权模式才自己换。自动模式下每次生成都花钱，得他点头
                        if AppSettings.shared.agentMode == .full {
                            svc.appendAgentFailure(reason + "，改用「\(next.displayName)」再试一次")
                            again()
                        } else {
                            svc.appendAgentFailure(
                                reason + "。后台任务那儿可以点「改用 \(next.displayName)」再试。")
                            AgentBackgroundTasks.shared.askRetry(
                                id: tid, reason: reason,
                                nextName: next.displayName, retry: again)
                        }
                        return
                    }
                    // 用户点的取消，卡片上记一笔就够了 —— 会话里那句
                    //「用户取消了…」是 cancel() 写的，这儿再报一条「已取消」就成了两条
                    if err.isUserCancellation {
                        // 界面上要有那条橙色「已取消」，但它**不会进模型的历史**
                        // （rebuildAgentHistory 里专门滤掉了）—— 让模型看见的话，
                        // 它会把取消当成没办成的事主动补做
                        svc.appendAgentFailure("已取消")
                        AgentBackgroundTasks.shared.fail(id: tid, "已被用户取消")
                        return
                    }
                    var text = err.localizedDescription
                    // 本来该问「换一家吗」却没问的，把原因说出来 ——
                    // 不说的话用户只会觉得「说好的自动换家呢」
                    if allowFallback, switchable, nextOne == nil {
                        text += "\n（这一类里没有别的配了 Key 的模型可换，"
                            + "去设置 → AI 设置里给另一家填上 Key 就能自动接手）"
                    }
                    svc.appendAgentFailure(text)
                    AgentBackgroundTasks.shared.fail(id: tid, text)
                }
            }
        }
        box.id = id
        let title = String(prompt.prefix(24))
        if let old = previousTaskID {
            AgentBackgroundTasks.shared.replace(
                oldID: old, newID: id,
                title: title + "（改用 \(provider.displayName)）", kind: category)
        } else {
            AgentBackgroundTasks.shared.add(id: id, title: title, kind: category)
        }
        return id
    }

    @MainActor
    static func runGenerateTool(_ name: String, args: [String: Any],
                                project: ProjectState) -> AgentToolResult? {
        let svc = AIVideoService.shared
        switch name {
        case "generate_image", "generate_video", "generate_audio":
            guard let prompt = args["prompt"] as? String, !prompt.isEmpty else {
                return .fail("缺 prompt")
            }
            let category: AIVideoService.ProviderCategory =
                name == "generate_image" ? .image : (name == "generate_video" ? .video : .audio)

            // 用户点名了就按名字找，没点名走项目设置里的默认
            // **一轮里每类只准调一次**。要几张走 count，所以拦掉第二次不会少给。
            // 不拦的话：用户取消一个再要 3 张，它交「1 张补做 + 3 张」＝ 4 个任务，
            // 提示词里写「取消就是不要了、不要补做」也不管用
            guard !svc.agentRoundGenerated.contains(category) else {
                return .fail("""
                    这一轮已经提交过「\(category.rawValue)」任务了，一轮只接一次。
                    要多张不是多调几次，是**一次调用里把 count 写成张数**。
                    另外用户取消掉的任务就是不要了，不用补做。
                    """)
            }

            let named = (args["model"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let namedProvider = named.isEmpty ? nil : Self.matchProvider(named, category)

            // 要几张先算出来 —— 挑模型要看这个数。模型有时把数字塞成字符串，两种都认。
            // 它没传就用聊天框那排下拉里选的；用户话里说了数量以他说的为准
            // 优先信从用户原话里解析出来的数量 —— 模型传的 count 经常是它自己
            // 拆出来的「先来 1 张」，跟用户说的对不上
            let asked = (category == .image ? svc.agentRoundImageCount : nil)
                ?? (args["count"] as? Int)
                ?? (args["count"] as? String).flatMap { Int($0) }
                ?? (category == .image ? AppSettings.shared.aiImageCount : 1)

            // 没点名模型时，图片按张数挑：一张走 Image2 → 5.0 Pro → 5.0 Lite，
            // 多张走 Image2 → 5.0 Lite（Pro 官方出不了多张）
            var modelOverride: String? = nil
            var provider: AIVideoService.Provider
            if let p = namedProvider {
                provider = p
            } else if category == .image,
                      let pick = AIVideoService.autoImagePick(count: asked) {
                provider = pick.provider
                modelOverride = pick.model
            } else {
                provider = AIVideoService.provider(for: category)
            }
            guard !AIVideoService.apiKey(for: provider).isEmpty else {
                return .fail("「\(provider.displayName)」还没配 API Key，去设置 → AI 设置里填上再试。")
            }

            // **只有「这一次点名要了某家」才不换**。
            //
            // 面板里选的那个不算数 —— 它的意思是「默认先用哪家」，不是
            // 「失败了也别换」。曾经把它也算进来，结果用户在画布里选过 Seedream，
            // 之后在聊天里生图被版权拦下时死活不问换家，而他压根不记得自己指定过什么
            // （日志实据：允许换家=false 换了有意义=true 下一家=Image2）。
            // 换家本来就还要他点头，放宽是安全的
            let allowFallback = namedProvider == nil

            let cap = AIVideoService.maxImages(for: provider, model: modelOverride)
            let count = max(1, min(asked, cap))
            // 自动挑到具体型号时报型号名（「Seedream 5.0 Lite」），
            // 只报「Seedream」的话用户看不出到底走了 Pro 还是 Lite
            let usedName = modelOverride
                .flatMap { m in provider.subModels.first { $0.id == m }?.label }
                ?? provider.displayName
            // 一张一个任务。Seedream lite 那种「组图」是一次请求出多张、图之间还带关联，
            // 这里图的是各自独立、失败也只砸一张，对海报这类需求更合适
            for _ in 0..<count {
                _ = Self.submitGeneration(category: category, prompt: prompt, args: args,
                                          provider: provider, project: project,
                                          allowFallback: allowFallback, tried: [provider],
                                          modelOverride: modelOverride)
            }
            // 真提交出去了才占名额 —— 没配 Key 之类的早退不该把这一轮堵死
            svc.agentRoundGenerated.insert(category)
            let capNote = asked > cap
                ? "\n（你要了 \(asked) 张，但「\(usedName)」一次最多 \(cap) 张，"
                    + "已经按 \(cap) 张提交，记得如实告诉用户。）"
                : ""
            // 落点跟着场景走，说法也得跟着换 —— 在画布里还说「放进时间轴」，
            // 用户看着就是答非所问
            let where_ = project.showCanvas
                ? "做完会自己落到画布上"
                : "做完会自动进素材库"
            let next = project.showCanvas
                ? "接着做别的，或者告诉用户好了之后再接着往下连。"
                : "接着做别的，或者告诉用户等好了叫你放进时间轴。"
            return .ok("""
                已经交给「\(usedName)」去做了\(count > 1 ? "，一共 \(count) 张" : "")\
                （后台任务，几十秒到几分钟）。\(capNote)
                不用在这儿等它 —— \(where_)，聊天里也会出现那张卡片。
                \(next)
                """)

        case "list_background_tasks":
            // 只报这条会话自己派的 —— 画布之间互不相干，
            // 报出别人的任务只会让模型拿去乱回答
            let items = AgentBackgroundTasks.shared.currentItems
            guard !items.isEmpty else { return .ok("后台没有任务。") }
            var s = "后台任务：\n"
            for it in items {
                let state: String
                switch it.state {
                case .running: state = "进行中（已经 \(Int(Date().timeIntervalSince(it.startedAt))) 秒）"
                case .done:    state = "已完成，素材已进库"
                case .failed(let m): state = "失败：\(m)"
                case .needsConfirm(let reason, let nextName):
                    // 说清楚是在等用户点，别让模型以为还在跑、回头报「还在生成中」
                    state = "\(reason)。正等用户决定要不要改用「\(nextName)」重试，"
                        + "按钮在后台任务卡片上，他点了才会继续"
                }
                s += "- [\(it.kind.rawValue)] \(it.title) — \(state)\n"
            }
            return .ok(s)

        default: return nil
        }
    }
}

/// 装任务 id 的盒子。generateForCanvas 的回调在它返回 id 之前就可能被建好，
/// 靠这个把 id 传进去
@MainActor
final class TaskIDBox {
    var id: UUID?
}
