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

    static var generateTools: [AgentToolSpec] {
        [
            AgentToolSpec(
                name: "generate_image",
                description: """
                用 AI 生成一张图片。**提交后立刻返回，不会等它画完** —— \
                结果进后台任务，完成后会自动加进素材库，那时候再叫你放到时间轴上。
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "prompt": ["type": "string", "description": "画什么。越具体越好"],
                        "ratio": ["type": "string", "description": "画面比例，比如 1:1、16:9、9:16"]
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
                        "ratio": ["type": "string", "description": "16:9、9:16、1:1"]
                    ] as [String: Any],
                    "required": ["prompt"]
                ],
                risk: .dangerous),

            AgentToolSpec(
                name: "generate_audio",
                description: "用 AI 生成音频（音乐、音效）。提交后立刻返回。",
                parameters: [
                    "type": "object",
                    "properties": ["prompt": ["type": "string"]] as [String: Any],
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
            let provider = AIVideoService.provider(for: category)
            guard !AppSettings.shared.providerAPIKey(for: provider.rawValue)
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .fail("「\(provider.displayName)」还没配 API Key，去设置 → AI 设置里填上再试。")
            }

            // 任务 id 要在回调里用到，而 id 是这个调用的返回值 ——
            // 先占一个盒子，提交完填进去，回调再从盒子里取。
            // 回调里现造一个新 id 的话，跟提交时登记的那条对不上，
            // 面板上那条会永远停在「进行中」
            let box = TaskIDBox()
            let id = svc.generateForCanvas(
                prompt: prompt,
                provider: provider,
                duration: args["duration"] as? String ?? "5",
                aspectRatio: args["ratio"] as? String ?? "16:9",
                imageRatio: args["ratio"] as? String ?? "1:1"
            ) { result in
                Task { @MainActor in
                    guard let tid = box.id else { return }
                    switch result {
                    case .success(let url):
                        // 生成完直接进素材库，用户不用再手动导一次
                        project.importFile(url)
                        AgentBackgroundTasks.shared.finish(id: tid, url: url)
                    case .failure(let err):
                        AgentBackgroundTasks.shared.fail(id: tid, err.localizedDescription)
                    }
                }
            }
            box.id = id
            AgentBackgroundTasks.shared.add(
                id: id, title: String(prompt.prefix(24)), kind: category)
            return .ok("""
                已经交给「\(provider.displayName)」去做了（后台任务，几十秒到几分钟）。
                不用在这儿等它 —— 做完会自动进素材库，用户在聊天框左上角能看到进度。
                接着做别的，或者告诉用户等好了叫你放进时间轴。
                """)

        case "list_background_tasks":
            let items = AgentBackgroundTasks.shared.items
            guard !items.isEmpty else { return .ok("后台没有任务。") }
            var s = "后台任务：\n"
            for it in items {
                let state: String
                switch it.state {
                case .running: state = "进行中（已经 \(Int(Date().timeIntervalSince(it.startedAt))) 秒）"
                case .done:    state = "已完成，素材已进库"
                case .failed(let m): state = "失败：\(m)"
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
