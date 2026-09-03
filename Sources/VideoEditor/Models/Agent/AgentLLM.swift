// AgentLLM.swift
//
// 带工具调用的模型客户端。复用设置→AI 设置里配好的那套文字模型。
//
// 两种协议的 tool use 长得完全不一样：OpenAI 兼容的把工具塞进 `tools[].function`、
// 回复在 `tool_calls`；Claude 的是 `tools[].input_schema`、回复在 `content[].tool_use`。
// 上层不该关心这个差别，所以这里统一成 AgentTurn 吐出去。

import Foundation

/// 一轮对话里模型的产出
struct AgentTurn {
    var text: String = ""
    var toolCalls: [AgentToolCall] = []
    /// 这一次请求烧掉的 token（进+出）。拿不到就是 0
    var tokens: Int = 0
    /// 模型说它讲完了（没有再要调工具）
    var isFinal: Bool { toolCalls.isEmpty }
}

struct AgentToolCall: Identifiable {
    let id: String
    let name: String
    let arguments: [String: Any]
}

/// 对话历史里的一条。工具结果也算一条，得原样回给模型
enum AgentMessage {
    case user(String, images: [Data] = [])
    case assistant(text: String, calls: [AgentToolCall])
    case toolResult(callID: String, name: String, text: String, imageData: Data?)
}

enum AgentLLM {

    /// 聊天框上选中的那家。它不是 Agent 模型（比如用户切到了图片生成）时，
    /// 退回设置里配的那个
    static func currentProvider() -> AppSettings.LLMProvider {
        let picked = AIVideoService.shared.selectedProvider
        if picked.category == .text,
           let m = AppSettings.LLMProvider.allCases.first(where: { $0.sharedProviderKey == picked.rawValue }) {
            return m
        }
        return AppSettings.shared.llmProvider
    }

    /// 当前这家的接口地址。**中转站就是靠它生效的** ——
    /// 之前 Claude 那条分支把地址写死成官方的，用户填了中转地址也没用上，
    /// 拿中转站的 Key 去打官方接口，只会得到 401
    static func currentBaseURL() -> String {
        let p = currentProvider()
        let path = p == .claude ? "/v1/messages" : "/v1/chat/completions"
        let custom = AIVideoService.normalizedEndpoint(
            AppSettings.shared.providerBaseURL(for: p.sharedProviderKey), defaultPath: path)
        return custom.isEmpty ? p.baseURL : custom
    }

    /// 填了自定义接口地址就是走中转。服务端工具（Claude 的 web_search）
    /// 多数中转站不透传，AIVideoService 那边实测会报
    /// 「tools[0].web_search can not be null」，所以这种情况下别加
    static func viaRelay() -> Bool {
        !AppSettings.shared.providerBaseURL(for: currentProvider().sharedProviderKey)
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 自带联网的几家。跟 AIVideoService 里那份保持一致：
    /// DeepSeek 的原生搜索只在 Anthropic 端点上且未文档化，
    /// Kimi 的 $web_search 要自己写工具调用循环，都不算
    static let nativeSearchProviders: Set<AppSettings.LLMProvider> = [.qwen, .glm, .grok, .claude]

    /// 这一家现在能不能用原生联网。用不了就该挂外挂 web_search 工具
    static func canUseNativeSearch() -> Bool {
        nativeSearchProviders.contains(currentProvider()) && !viaRelay()
    }

    /// 当前该用哪个模型名。显示名换算和「没选过用哪个」都在 resolvedModel 里
    static func currentModel() -> String {
        let p = currentProvider()
        return p.resolvedModel(saved: AppSettings.shared.providerModel(for: p.sharedProviderKey))
    }

    /// 发一轮。返回模型的文本和它要调的工具
    static func send(messages: [AgentMessage],
                     tools: [AgentToolSpec],
                     systemPrompt: String,
                     webSearch: Bool = false) async throws -> AgentTurn {
        // **认聊天框上选的那家**，不是设置里的 llmProvider。
        // 两套配置共用同一份 Key 和模型名，但「当前选哪家」是各记各的 ——
        // 用户在聊天框选了 Claude，Agent 却按设置里的智谱去发请求，
        // 报出来的是「glm-4-flash 不存在」，跟他看到的模型对不上号
        let provider = currentProvider()
        let key = AppSettings.shared.providerAPIKey(for: provider.sharedProviderKey)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw NSError(domain: "Agent", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "「\(provider.rawValue)」还没填 API Key。到设置 → AI 设置里给它配一个，或者在上面的下拉里换一家已经配好的。"])
        }
        return provider == .claude
            ? try await sendClaude(messages, tools, systemPrompt, key, webSearch && canUseNativeSearch())
            : try await sendOpenAI(messages, tools, systemPrompt, key,
                                   webSearch && canUseNativeSearch())
    }

    // MARK: - OpenAI 兼容

    private static func sendOpenAI(_ messages: [AgentMessage], _ tools: [AgentToolSpec],
                                   _ system: String, _ key: String,
                                   _ webSearch: Bool) async throws -> AgentTurn {
        var msgs: [[String: Any]] = [["role": "system", "content": system]]
        for m in messages {
            switch m {
            case .user(let t, let imgs):
                if imgs.isEmpty {
                    msgs.append(["role": "user", "content": t])
                } else {
                    var parts: [[String: Any]] = [["type": "text", "text": t]]
                    for img in imgs {
                        parts.append(["type": "image_url",
                                      "image_url": ["url": "data:image/jpeg;base64,\(img.base64EncodedString())"]])
                    }
                    msgs.append(["role": "user", "content": parts])
                }
            case .assistant(let t, let calls):
                var m: [String: Any] = ["role": "assistant", "content": t]
                if !calls.isEmpty {
                    m["tool_calls"] = calls.map { c in
                        ["id": c.id, "type": "function",
                         "function": ["name": c.name,
                                      "arguments": jsonString(c.arguments)]]
                    }
                }
                msgs.append(m)
            case .toolResult(let id, _, let text, let img):
                // 这套协议的工具结果只能是纯文本，图片单独再补一条 user 消息
                msgs.append(["role": "tool", "tool_call_id": id, "content": text])
                if let img {
                    msgs.append(["role": "user", "content": [
                        ["type": "text", "text": "（上一步截到的画面）"],
                        ["type": "image_url",
                         "image_url": ["url": "data:image/jpeg;base64,\(img.base64EncodedString())"]]
                    ]])
                }
            }
        }

        var body: [String: Any] = [
            "model": currentModel(),
            "messages": msgs,
            "temperature": 0.3
        ]
        var toolList: [[String: Any]] = tools.map { t in
            ["type": "function",
             "function": ["name": t.name, "description": t.description, "parameters": t.parameters]]
        }
        // 原生联网。三家的声明方式各不相同，都是 AIVideoService 那边实测过的写法：
        // 智谱要带一个 web_search 配置对象，xAI 只要个 type，千问走 body 上的开关
        if webSearch {
            switch currentProvider() {
            case .glm:
                toolList.append(["type": "web_search",
                                 "web_search": ["enable": "True", "search_result": "True", "count": "5"]])
            case .grok:
                toolList.append(["type": "web_search"])
            case .qwen:
                body["enable_search"] = true
                // 不加 forced_search，模型多半会「自己判断」然后不搜
                body["search_options"] = ["forced_search": true, "enable_source": true]
                // 千问 max 系列要在思考模式下才支持联网，光给 enable_search 不生效
                body["enable_thinking"] = true
            default: break
            }
        }
        if !toolList.isEmpty { body["tools"] = toolList }

        let data = try await post(currentBaseURL(), key: key,
                                  headers: ["Authorization": "Bearer \(key)"], body: body)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (root["choices"] as? [[String: Any]])?.first,
              let msg = choice["message"] as? [String: Any] else {
            throw NSError(domain: "Agent", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "模型返回的格式看不懂：\(String(String(data: data, encoding: .utf8)?.prefix(200) ?? ""))"])
        }
        var turn = AgentTurn(text: msg["content"] as? String ?? "")
        // 用量：OpenAI 兼容这边统一在 usage 里。部分中转站不回，拿不到就算 0
        if let u = root["usage"] as? [String: Any] {
            turn.tokens = (u["total_tokens"] as? Int)
                ?? ((u["prompt_tokens"] as? Int ?? 0) + (u["completion_tokens"] as? Int ?? 0))
        }
        for c in (msg["tool_calls"] as? [[String: Any]]) ?? [] {
            guard let id = c["id"] as? String,
                  let f = c["function"] as? [String: Any],
                  let name = f["name"] as? String else { continue }
            turn.toolCalls.append(AgentToolCall(
                id: id, name: name,
                arguments: parseArgs(f["arguments"] as? String ?? "{}")))
        }
        return turn
    }

    // MARK: - Claude

    private static func sendClaude(_ messages: [AgentMessage], _ tools: [AgentToolSpec],
                                   _ system: String, _ key: String,
                                   _ webSearch: Bool) async throws -> AgentTurn {
        var msgs: [[String: Any]] = []
        for m in messages {
            switch m {
            case .user(let t, let imgs):
                var content: [[String: Any]] = [["type": "text", "text": t]]
                // 图片放在文字前面：Anthropic 建议先给图再提问，模型答得更准
                for img in imgs.reversed() {
                    content.insert(["type": "image",
                                    "source": ["type": "base64", "media_type": "image/jpeg",
                                               "data": img.base64EncodedString()]], at: 0)
                }
                msgs.append(["role": "user", "content": content])
            case .assistant(let t, let calls):
                var content: [[String: Any]] = []
                if !t.isEmpty { content.append(["type": "text", "text": t]) }
                for c in calls {
                    content.append(["type": "tool_use", "id": c.id,
                                    "name": c.name, "input": c.arguments])
                }
                if !content.isEmpty { msgs.append(["role": "assistant", "content": content]) }
            case .toolResult(let id, _, let text, let img):
                var inner: [[String: Any]] = [["type": "text", "text": text]]
                if let img {
                    inner.append(["type": "image",
                                  "source": ["type": "base64", "media_type": "image/jpeg",
                                             "data": img.base64EncodedString()]])
                }
                msgs.append(["role": "user", "content": [[
                    "type": "tool_result", "tool_use_id": id, "content": inner
                ]]])
            }
        }

        var body: [String: Any] = [
            "model": currentModel(),
            "max_tokens": 4096,
            "system": system,
            "messages": msgs
        ]
        var toolList: [[String: Any]] = tools.map { t in
            ["name": t.name, "description": t.description, "input_schema": t.parameters]
        }
        // 联网是**服务端工具**：Anthropic 那边自己搜完把结果接回答案里，
        // 不会走到我们这边的执行循环，所以下面解析时不用管它
        if webSearch {
            toolList.append(["type": "web_search_20260209", "name": "web_search"])
        }
        if !toolList.isEmpty { body["tools"] = toolList }

        let data = try await post(currentBaseURL(), key: key,
                                  headers: ["x-api-key": key,
                                            "anthropic-version": "2023-06-01"], body: body)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = root["content"] as? [[String: Any]] else {
            throw NSError(domain: "Agent", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "模型返回的格式看不懂：\(String(String(data: data, encoding: .utf8)?.prefix(200) ?? ""))"])
        }
        var turn = AgentTurn()
        // Claude 这边进出分开报，加起来才是这一轮的总量
        if let u = root["usage"] as? [String: Any] {
            turn.tokens = (u["input_tokens"] as? Int ?? 0) + (u["output_tokens"] as? Int ?? 0)
        }
        for block in content {
            switch block["type"] as? String {
            case "text": turn.text += (block["text"] as? String ?? "")
            case "tool_use":
                guard let id = block["id"] as? String, let name = block["name"] as? String
                else { continue }
                turn.toolCalls.append(AgentToolCall(
                    id: id, name: name, arguments: block["input"] as? [String: Any] ?? [:]))
            default: break
            }
        }
        return turn
    }

    // MARK: - 小工具

    private static var providerName: String { currentProvider().rawValue }

    private static func post(_ urlString: String, key: String,
                             headers: [String: String], body: [String: Any]) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw NSError(domain: "Agent", code: 3, userInfo: [NSLocalizedDescriptionKey: "API 地址无效"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.timeoutInterval = 180
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            // 常见的几种先翻成人话，剩下的再把原文附上 ——
            // 直接甩一串英文 JSON 出来，用户根本不知道该去改哪
            let hint: String
            switch code {
            case 401, 403:
                hint = "「\(providerName)」的 API Key 无效或没有权限。到设置 → AI 设置里检查这一家的 Key。"
            case 404:
                hint = "「\(providerName)」那边找不到模型「\(currentModel())」。可能是模型名写错了，或者你的账号没开通它。"
            case 429:
                hint = "「\(providerName)」限流了，等一会儿再试。"
            case 400:
                hint = "请求被「\(providerName)」拒绝了。多半是这个模型不支持工具调用 —— Agent 必须用支持 tool use 的模型。"
            default:
                hint = "「\(providerName)」返回了 \(code)。"
            }
            throw NSError(domain: "Agent", code: 4, userInfo: [NSLocalizedDescriptionKey:
                hint + "\n\n接口原文：" + String(raw.prefix(300))])
        }
        return data
    }

    private static func jsonString(_ obj: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(obj),
              let d = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }

    /// OpenAI 那套把参数塞在字符串里，得再解一层
    private static func parseArgs(_ s: String) -> [String: Any] {
        guard let d = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return obj
    }
}
