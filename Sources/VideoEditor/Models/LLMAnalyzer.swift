import Foundation

enum LLMAnalyzer {

    struct Highlight: Decodable {
        let start: Double
        let end: Double
        let reason: String
    }

    static func analyze(subtitles: [(start: Double, end: Double, text: String)],
                         provider: AppSettings.LLMProvider,
                         apiKey: String,
                         progress: @escaping (Double) -> Void) async throws -> [Highlight] {
        guard !apiKey.isEmpty else {
            throw NSError(domain: "LLM", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "请先在设置→视频分析中配置 API Key"])
        }
        guard !subtitles.isEmpty else {
            throw NSError(domain: "LLM", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "没有字幕数据，请先进行语音识别"])
        }

        let srtText = subtitles.map { s in
            let fmt = { (t: Double) -> String in
                let m = Int(t) / 60; let sec = t - Double(m * 60)
                return String(format: "%02d:%05.2f", m, sec)
            }
            return "[\(fmt(s.start)) --> \(fmt(s.end))] \(s.text)"
        }.joined(separator: "\n")

        let prompt = """
        你是一个专业的视频剪辑助手。以下是一段视频的字幕（含时间戳）。
        请分析内容，找出最精彩、最有价值的片段（高光时刻、关键信息、有趣对话等）。
        只保留真正精彩的部分，去除冗余、停顿、闲聊等无价值内容。

        要求：
        1. 返回精彩片段的时间段列表
        2. 每个片段的 start/end 必须是字幕中出现的实际时间（秒）
        3. 相邻精彩片段如果间隔很短（<3秒），合并为一个
        4. 只返回 JSON 数组，不要其他文字

        返回格式：
        [{"start": 秒数, "end": 秒数, "reason": "简短原因"}]

        字幕内容：
        \(srtText)
        """

        progress(0.1)

        let data: Data
        if provider == .claude {
            data = try await callClaude(apiKey: apiKey, prompt: prompt)
        } else {
            data = try await callOpenAICompatible(provider: provider, apiKey: apiKey, prompt: prompt)
        }

        progress(0.9)

        let text = String(data: data, encoding: .utf8) ?? ""
        let highlights = try parseResponse(text, provider: provider)

        guard !highlights.isEmpty else {
            throw NSError(domain: "LLM", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "大模型未返回有效的精彩片段"])
        }

        progress(1.0)
        return highlights
    }

    // MARK: - OpenAI-compatible API (OpenAI / DeepSeek / GLM)

    private static func callOpenAICompatible(provider: AppSettings.LLMProvider,
                                              apiKey: String,
                                              prompt: String) async throws -> Data {
        guard let url = URL(string: provider.baseURL) else {
            throw NSError(domain: "LLM", code: 4, userInfo: [NSLocalizedDescriptionKey: "无效的 API 地址"])
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 120

        let body: [String: Any] = [
            "model": provider.defaultModel,
            "messages": [
                ["role": "system", "content": "你是专业视频剪辑助手，只返回 JSON 数组。"],
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.3
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "未知错误"
            throw NSError(domain: "LLM", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "API 调用失败: \(String(msg.prefix(200)))"])
        }
        return data
    }

    // MARK: - Claude API

    private static func callClaude(apiKey: String, prompt: String) async throws -> Data {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw NSError(domain: "LLM", code: 4, userInfo: [NSLocalizedDescriptionKey: "无效的 API 地址"])
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.timeoutInterval = 120

        let body: [String: Any] = [
            "model": AppSettings.LLMProvider.claude.defaultModel,
            "max_tokens": 4096,
            "system": "你是专业视频剪辑助手，只返回 JSON 数组。",
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "未知错误"
            throw NSError(domain: "LLM", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "API 调用失败: \(String(msg.prefix(200)))"])
        }
        return data
    }

    // MARK: - Parse response

    private static func parseResponse(_ raw: String, provider: AppSettings.LLMProvider) throws -> [Highlight] {
        let content: String
        if provider == .claude {
            if let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
               let arr = json["content"] as? [[String: Any]],
               let first = arr.first, let text = first["text"] as? String {
                content = text
            } else {
                content = raw
            }
        } else {
            if let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let first = choices.first,
               let msg = first["message"] as? [String: Any],
               let text = msg["content"] as? String {
                content = text
            } else {
                content = raw
            }
        }

        guard let jsonStart = content.firstIndex(of: "["),
              let jsonEnd = content.lastIndex(of: "]") else {
            throw NSError(domain: "LLM", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "无法解析大模型返回的 JSON"])
        }

        let jsonStr = String(content[jsonStart...jsonEnd])
        let decoder = JSONDecoder()
        return try decoder.decode([Highlight].self, from: Data(jsonStr.utf8))
    }
}
