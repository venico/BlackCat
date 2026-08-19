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

    // MARK: - 字幕校对

    /// 让大模型校对语音识别出来的字幕：修错别字、把被切碎的句子合并。
    ///
    /// **时间戳一概不交给模型**。它听不到音频，给不出比 VAD 更准的时间——
    /// 所以协议设计成「模型只回答哪几条该并成一条、文字改成什么」，
    /// 合并后的起止由代码取首尾（首条的 start、末条的 end），这个不会失真。
    /// 同理不允许拆分：拆点只能靠猜。
    ///
    /// 分批送（每批 40 条），单批失败就原样保留那一批，不影响其余。
    /// - Returns: 校对后的字幕；全程失败时返回原始输入
    /// - Parameter send: 把 prompt 发给模型、拿回文本。由调用方注入，
    ///   这样校对不绑死在某一套供应商配置上（现在走「AI 生成」里配好的文字模型）
    /// - Returns: (校对后的字幕, 改动了多少条, 出错信息)。
    ///   一条都没改动时调用方该提示用户，而不是静悄悄地показ"完成"
    static func proofreadSubtitles(
        _ segs: [(start: Double, end: Double, text: String)],
        send: @escaping (String) async throws -> String,
        progress: @escaping (Double) -> Void
    ) async -> (segs: [(start: Double, end: Double, text: String)], changed: Int, error: String?) {
        guard !segs.isEmpty else { return (segs, 0, nil) }

        let batchSize = 40
        var result: [(start: Double, end: Double, text: String)] = []
        var done = 0
        var batchStart = 0
        var changed = 0
        var firstError: String?

        while batchStart < segs.count {
            if Task.isCancelled { return (result + Array(segs[batchStart...]), changed, firstError) }
            let batchEnd = min(batchStart + batchSize, segs.count)
            let batch = Array(segs[batchStart..<batchEnd])
            var fixed = batch
            do {
                fixed = try await proofreadBatch(batch, send: send)
            } catch {
                if firstError == nil { firstError = error.localizedDescription }
                DiagLog.log("[字幕校对] 批次失败: \(error.localizedDescription)")
            }
            // 条数变了，或任一条文字变了，都算改动
            if fixed.count != batch.count {
                changed += abs(fixed.count - batch.count)
            }
            for (a, b) in zip(batch, fixed) where a.text != b.text { changed += 1 }
            result += fixed
            done += batch.count
            progress(Double(done) / Double(segs.count))
            batchStart = batchEnd
        }
        DiagLog.log("[字幕校对] 完成：\(segs.count) 条 → \(result.count) 条，改动 \(changed) 处"
                    + (firstError.map { "，有失败：\($0)" } ?? ""))
        return (result, changed, firstError)
    }

    private static func proofreadBatch(
        _ batch: [(start: Double, end: Double, text: String)],
        send: (String) async throws -> String
    ) async throws -> [(start: Double, end: Double, text: String)] {
        let listing = batch.enumerated()
            .map { "\($0.offset + 1)|\($0.element.text)" }
            .joined(separator: "\n")

        let prompt = """
        下面是视频字幕，来自语音识别（可能还经过机器翻译），每行格式为 `序号|文本`。
        请做三件事：

        1. 修正识别错误和错别字：同音字、听错的词、明显不对的专有名词。
        2. 润色：改掉机器翻译腔和读不通的地方。常见毛病——多余或错位的量词单位
           （例如「从 0 提高到 50%分钟」，末尾那个「分钟」是错的，应删掉）、
           成分残缺、语序生硬。改完要像人写的、能直接当字幕看。
        3. 合并被切碎的同一句话。只合并**相邻**的行。

        要求：
        - 保持原意和原语言，不要新增原文没有的信息，不要做解释或扩写。
        - 不要拆分任何一行。
        - 每一行都必须出现在结果里，且只出现一次，序号连续覆盖 1 到 \(batch.count)。

        只返回 JSON 数组，不要任何解释文字，格式：
        [{"from":1,"to":1,"text":"修正后的文本"},{"from":2,"to":3,"text":"合并后的文本"}]

        字幕：
        \(listing)
        """

        let raw = try await send(prompt)

        struct Fix: Decodable { let from: Int; let to: Int; let text: String }
        let fixes: [Fix] = parseFixes(raw)
        guard !fixes.isEmpty else {
            DiagLog.log("[字幕校对] 模型回复解析不出 JSON，原样保留。回复开头：\(raw.prefix(120))")
            return batch
        }

        var out: [(start: Double, end: Double, text: String)] = []
        var covered = 0
        for f in fixes.sorted(by: { $0.from < $1.from }) {
            let lo = f.from - 1, hi = f.to - 1
            // 越界、倒序、跳号一律当这批不可信，整批退回原文——
            // 宁可不校对，也不能把字幕搞乱或搞丢
            guard lo >= 0, hi < batch.count, lo <= hi, lo == covered else { return batch }
            let text = f.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return batch }
            out.append((batch[lo].start, batch[hi].end, text))
            covered = hi + 1
        }
        guard covered == batch.count else { return batch }   // 没盖全 → 退回原文
        return out
    }

    /// 从模型回复里取出 JSON 数组。模型爱把 JSON 包在 ```json 代码块里，
    /// 或者前后加一段说明，所以取第一个 `[` 到最后一个 `]`
    private static func parseFixes<T: Decodable>(_ raw: String) -> [T] {
        guard let s = raw.firstIndex(of: "["), let e = raw.lastIndex(of: "]"), s < e else { return [] }
        return (try? JSONDecoder().decode([T].self, from: Data(String(raw[s...e]).utf8))) ?? []
    }

    private static func callOpenAICompatible(provider: AppSettings.LLMProvider,
                                              apiKey: String,
                                              prompt: String) async throws -> Data {
        guard let url = URL(string: AppSettings.shared.effectiveLLMBaseURL) else {
            throw NSError(domain: "LLM", code: 4, userInfo: [NSLocalizedDescriptionKey: "无效的 API 地址"])
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 120

        let body: [String: Any] = [
            "model": AppSettings.shared.effectiveLLMModel,
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
            "model": AppSettings.shared.effectiveLLMModel,
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
