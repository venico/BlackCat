// AgentTools+Settings.swift
//
// 改软件设置。只放一张白名单：保存位置、自动保存、各引擎怎么选、生成默认值、界面偏好这类。
//
// **故意不放的**：各家 API Key（密钥只能用户自己填）、Agent 的运行模式和步数上限
// （让它自己给自己放权限、加步数，等于绕过用户定的规矩）。

import Foundation

extension AgentToolbox {

    /// 一条可改的设置。get 给当前值，set 收字符串、失败回原因
    private struct SettingEntry {
        let key: String
        let label: String
        let options: [String]?
        let get: @MainActor () -> String
        let set: @MainActor (String) -> String?
    }

    @MainActor
    private static func settingEntries(_ p: ProjectState) -> [SettingEntry] {
        let st = AppSettings.shared
        func dir(_ v: String) -> URL? {
            let u = URL(fileURLWithPath: (v as NSString).expandingTildeInPath)
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) && isDir.boolValue ? u : nil
        }
        func bool(_ v: String) -> Bool? { ["true", "1", "开", "on", "yes"].contains(v.lowercased()) ? true
            : (["false", "0", "关", "off", "no"].contains(v.lowercased()) ? false : nil) }
        func pick<E: RawRepresentable & CaseIterable>(_ t: E.Type, _ v: String) -> E? where E.RawValue == String {
            E.allCases.first { $0.rawValue == v }
        }
        func raws<E: RawRepresentable & CaseIterable>(_ t: E.Type) -> [String] where E.RawValue == String {
            E.allCases.map(\.rawValue)
        }
        return [
            SettingEntry(key: "project_dir", label: "项目默认保存位置", options: nil,
                         get: { st.effectiveProjectDir.path },
                         set: { v in guard let u = dir(v) else { return "文件夹不存在" }; st.projectSaveDir = u; return nil }),
            SettingEntry(key: "export_dir", label: "导出默认保存位置", options: nil,
                         get: { st.effectiveExportDir.path },
                         set: { v in guard let u = dir(v) else { return "文件夹不存在" }; st.exportSaveDir = u; return nil }),
            SettingEntry(key: "auto_save_interval", label: "自动保存间隔（秒，0 = 关）", options: nil,
                         get: { "\(Int(st.autoSaveInterval))" },
                         set: { v in guard let d = Double(v), d >= 0 else { return "要一个秒数" }; st.autoSaveInterval = d; return nil }),
            SettingEntry(key: "whisper_model", label: "语音识别模型", options: raws(WhisperTranscriber.ModelSize.self),
                         get: { st.selectedWhisperModel.rawValue },
                         set: { v in guard let m = pick(WhisperTranscriber.ModelSize.self, v) else { return "没有这个模型" }
                                st.selectedWhisperModel = m; return nil }),
            SettingEntry(key: "translate_provider", label: "翻译引擎", options: raws(AppSettings.TranslateProvider.self),
                         get: { st.translateProvider.rawValue },
                         set: { v in guard let m = pick(AppSettings.TranslateProvider.self, v) else { return "没有这个引擎" }
                                st.translateProvider = m; return nil }),
            SettingEntry(key: "translate_target", label: "默认翻译目标语言", options: nil,
                         get: { p.translationTargetLang },
                         set: { v in p.translationTargetLang = v; return nil }),
            SettingEntry(key: "search_engine", label: "联网搜索引擎", options: raws(AppSettings.SearchEngine.self),
                         get: { st.searchEngine.rawValue },
                         set: { v in guard let m = pick(AppSettings.SearchEngine.self, v) else { return "没有这个引擎" }
                                st.searchEngine = m; return nil }),
            SettingEntry(key: "bg_removal_engine", label: "抠图引擎", options: raws(BackgroundRemover.Engine.self),
                         get: { st.bgRemovalEngine.rawValue },
                         set: { v in guard let m = pick(BackgroundRemover.Engine.self, v) else { return "没有这个引擎" }
                                st.bgRemovalEngine = m; return nil }),
            SettingEntry(key: "birefnet_model", label: "BiRefNet 模型档位", options: raws(BiRefNetModel.self),
                         get: { st.biRefNetModel.rawValue },
                         set: { v in guard let m = pick(BiRefNetModel.self, v) else { return "没有这个档位" }
                                st.biRefNetModel = m; return nil }),
            SettingEntry(key: "clarity_engine", label: "清晰度提升引擎", options: raws(AppSettings.ClarityEngine.self),
                         get: { st.clarityEngine.rawValue },
                         set: { v in guard let m = pick(AppSettings.ClarityEngine.self, v) else { return "没有这个引擎" }
                                st.clarityEngine = m; return nil }),
            SettingEntry(key: "tts_speed", label: "字幕转语音语速（1 = 正常）", options: nil,
                         get: { String(format: "%.2f", st.ttsSpeed) },
                         set: { v in guard let d = Double(v), d > 0.3, d < 3 else { return "语速要在 0.3~3" }; st.ttsSpeed = d; return nil }),
            SettingEntry(key: "tts_auto_fit", label: "配音自动对齐字幕时长", options: ["true", "false"],
                         get: { "\(st.ttsAutoFit)" },
                         set: { v in guard let b = bool(v) else { return "要 true / false" }; st.ttsAutoFit = b; return nil }),
            SettingEntry(key: "subtitle_size_cjk", label: "新字幕默认中文字号", options: nil,
                         get: { "\(Int(st.subtitleFontSizeCJK))" },
                         set: { v in guard let d = Double(v), d >= 8 else { return "字号至少 8" }; st.subtitleFontSizeCJK = d; return nil }),
            SettingEntry(key: "subtitle_size_latin", label: "新字幕默认英文字号", options: nil,
                         get: { "\(Int(st.subtitleFontSizeLatin))" },
                         set: { v in guard let d = Double(v), d >= 8 else { return "字号至少 8" }; st.subtitleFontSizeLatin = d; return nil }),
            SettingEntry(key: "chat_font_size", label: "聊天界面字号", options: nil,
                         get: { "\(Int(st.chatFontSize))" },
                         set: { v in guard let d = Double(v), d >= 10, d <= 24 else { return "字号要在 10~24" }; st.chatFontSize = d; return nil }),
            SettingEntry(key: "agent_memory", label: "Agent 记忆开关", options: ["true", "false"],
                         get: { "\(st.agentMemoryEnabled)" },
                         set: { v in guard let b = bool(v) else { return "要 true / false" }; st.agentMemoryEnabled = b; return nil }),
            SettingEntry(key: "ai_video_duration", label: "AI 视频默认时长", options: nil,
                         get: { st.aiDuration }, set: { v in st.aiDuration = v; return nil }),
            SettingEntry(key: "ai_video_ratio", label: "AI 视频默认比例", options: nil,
                         get: { st.aiRatio }, set: { v in st.aiRatio = v; return nil }),
            SettingEntry(key: "ai_video_resolution", label: "AI 视频默认分辨率", options: nil,
                         get: { st.aiResolution }, set: { v in st.aiResolution = v; return nil }),
            SettingEntry(key: "ai_image_ratio", label: "AI 图片默认比例", options: nil,
                         get: { st.aiImageRatio }, set: { v in st.aiImageRatio = v; return nil }),
            SettingEntry(key: "ai_image_count", label: "AI 图片默认张数", options: nil,
                         get: { "\(st.aiImageCount)" },
                         set: { v in guard let i = Int(v), (1...9).contains(i) else { return "张数要在 1~9" }; st.aiImageCount = i; return nil }),
            SettingEntry(key: "canvas_snap", label: "画布拖卡片吸附", options: ["true", "false"],
                         get: { "\(st.canvasSnapEnabled)" },
                         set: { v in guard let b = bool(v) else { return "要 true / false" }; st.canvasSnapEnabled = b; return nil }),
            SettingEntry(key: "canvas_edges", label: "画布显示连接线", options: ["true", "false"],
                         get: { "\(st.canvasEdgesVisible)" },
                         set: { v in guard let b = bool(v) else { return "要 true / false" }; st.canvasEdgesVisible = b; return nil }),
        ]
    }

    static var settingsTools: [AgentToolSpec] {
        [
            AgentToolSpec(
                name: "app_settings",
                description: """
                看 / 改软件设置。先 action=get 看有哪些项、现在是什么值、能填什么；再 action=set 给 key 和 value。
                API Key、Agent 运行模式和步数上限不在这里，那些只能用户自己去设置里改。
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "action": ["type": "string", "enum": ["get", "set"]],
                        "key": ["type": "string"],
                        "value": ["type": "string"]
                    ] as [String: Any],
                    "required": ["action"]
                ],
                risk: .mutating)
        ]
    }

    @MainActor
    static func runSettingsTool(_ name: String, args: [String: Any], project p: ProjectState) -> AgentToolResult? {
        guard name == "app_settings" else { return nil }
        let entries = settingEntries(p)
        if (args["action"] as? String) != "set" {
            return .ok(entries.map { e in
                "- \(e.key)（\(e.label)）= \(e.get())" + (e.options.map { "，可选：\($0.joined(separator: " / "))" } ?? "")
            }.joined(separator: "\n"))
        }
        guard let key = args["key"] as? String, let e = entries.first(where: { $0.key == key }) else {
            return .fail("没有这个设置项，先 action=get 看看有哪些。")
        }
        let value: String
        if let v = args["value"] as? String { value = v.trimmingCharacters(in: .whitespaces) }
        else if let v = args["value"] { value = "\(v)" }
        else { return .fail("缺 value") }
        if let err = e.set(value) { return .fail("\(e.label)没改：\(err)") }
        return .ok("\(e.label)改成了 \(e.get())。")
    }
}
