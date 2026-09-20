import Foundation

enum LLMAnalyzer {

    struct Highlight: Decodable {
        let start: Double
        let end: Double
        let reason: String
    }

    /// - Parameter send: 把 prompt 发给模型、拿回文本。由调用方注入 ——
    ///   现在统一走「AI 设置」里配好的那家文字模型（Key / 接口地址 / 子模型 / 推理强度
    ///   全从设置取），跟字幕校对同一条链路，不再自己拼 Claude / OpenAI 请求
    static func analyze(subtitles: [(start: Double, end: Double, text: String)],
                         send: (String) async throws -> String,
                         progress: @escaping (Double) -> Void) async throws -> [Highlight] {
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

        let raw = try await send(prompt)

        progress(0.9)

        let highlights: [Highlight] = parseFixes(raw)

        guard !highlights.isEmpty else {
            throw NSError(domain: "LLM", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "大模型未返回有效的精彩片段"])
        }

        progress(1.0)
        return highlights
    }

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

        // 25 而不是 40：思考型模型一批太多要想很久，中途容易被掐断
        let batchSize = 25
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

    /// AI 翻译字幕。跟校对走同一套协议（模型只回「哪几条合成一条、文字是什么」，
    /// **时间戳一概不交给模型**），区别只在提示词：这边要求翻译 + 顺带断句润色。
    ///
    /// 比翻译引擎强在能看上下文：术语前后一致、代词有着落、语气连贯，
    /// 而引擎是一句一句孤立翻的
    static func translateSubtitles(
        _ segs: [(start: Double, end: Double, text: String)],
        to lang: String,
        send: @escaping (String) async throws -> String,
        progress: @escaping (Double) -> Void
    ) async -> (segs: [(start: Double, end: Double, text: String)], changed: Int, error: String?) {
        guard !segs.isEmpty else { return (segs, 0, nil) }

        // 25 而不是 40：思考型模型一批太多要想很久，中途容易被掐断
        let batchSize = 25
        var result: [(start: Double, end: Double, text: String)] = []
        var done = 0
        var batchStart = 0
        var changed = 0
        var firstError: String?

        while batchStart < segs.count {
            if Task.isCancelled { return (result + Array(segs[batchStart...]), changed, firstError) }
            let batchEnd = min(batchStart + batchSize, segs.count)
            let batch = Array(segs[batchStart..<batchEnd])
            var out = batch
            do {
                out = try await translateBatch(batch, to: lang, send: send)
            } catch {
                if firstError == nil { firstError = error.localizedDescription }
                DiagLog.log("[AI 翻译] 批次失败: \(error.localizedDescription)")
            }
            if out.count != batch.count { changed += abs(out.count - batch.count) }
            for (a, b) in zip(batch, out) where a.text != b.text { changed += 1 }
            result += out
            done += batch.count
            progress(Double(done) / Double(segs.count))
            batchStart = batchEnd
        }
        DiagLog.log("[AI 翻译] 完成：\(segs.count) 条 → \(result.count) 条，改动 \(changed) 处"
                    + (firstError.map { "，有失败：\($0)" } ?? ""))
        return (result, changed, firstError)
    }

    private static func translateBatch(
        _ batch: [(start: Double, end: Double, text: String)],
        to lang: String,
        send: (String) async throws -> String
    ) async throws -> [(start: Double, end: Double, text: String)] {
        let listing = batch.enumerated()
            .map { "\($0.offset + 1)|\($0.element.text)" }
            .joined(separator: "\n")

        let prompt = """
        下面是视频字幕，来自语音识别，每行格式为 `序号|文本`。
        请把它们翻译成\(lang)，并做到：

        1. 结合上下文翻译：术语、人名、代词前后保持一致，别一句一个译法。
        2. 译文要像中文字幕该有的样子：口语、简短、读得顺，不要翻译腔。
        3. 合并被切碎的同一句话。只合并**相邻**的行。

        要求：
        - 不要新增原文没有的信息，不要解释或扩写。
        - 不要拆分任何一行。
        - 每一行都必须出现在结果里，且只出现一次，序号连续覆盖 1 到 \(batch.count)。

        **直接输出 JSON 数组**，不要写思考过程、不要解释、不要 markdown 代码块，格式：
        [{"from":1,"to":1,"text":"译文"},{"from":2,"to":3,"text":"合并后的译文"}]

        字幕：
        \(listing)
        """

        let raw = try await send(prompt)

        struct Fix: Decodable { let from: Int; let to: Int; let text: String }
        let fixes: [Fix] = parseFixes(raw)
        guard !fixes.isEmpty else {
            DiagLog.log("[AI 翻译] 模型回复解析不出 JSON，原样保留。回复开头：\(raw.prefix(120))")
            return batch
        }
        return assemble(batch, fixes.map { ($0.from, $0.to, $0.text) })
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

        **直接输出 JSON 数组**，不要写思考过程、不要解释、不要 markdown 代码块，格式：
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

        return assemble(batch, fixes.map { ($0.from, $0.to, $0.text) })
    }

    /// 把模型给的「哪几条合成一条、文字是什么」装回字幕。
    /// **时间戳由代码取首尾**，模型碰不到。
    /// 越界、倒序、跳号、没盖全 —— 任一出现就整批退回原文：
    /// 宁可不改，也不能把字幕搞乱或搞丢
    private static func assemble(_ batch: [(start: Double, end: Double, text: String)],
                                 _ fixes: [(from: Int, to: Int, text: String)])
    -> [(start: Double, end: Double, text: String)] {
        var out: [(start: Double, end: Double, text: String)] = []
        var covered = 0
        for f in fixes.sorted(by: { $0.from < $1.from }) {
            let lo = f.from - 1, hi = f.to - 1
            guard lo >= 0, hi < batch.count, lo <= hi, lo == covered else { return batch }
            let text = f.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return batch }
            out.append((batch[lo].start, batch[hi].end, text))
            covered = hi + 1
        }
        guard covered == batch.count else { return batch }
        return out
    }

    /// 从模型回复里取出 JSON 数组。
    ///
    /// 模型爱把 JSON 包在 ```json 代码块里，或者前后加一段说明。**思考型模型更麻烦**
    /// —— DeepSeek 实测会把整段思考写进正文（「我们需要回答用户。需要把字幕翻译成…」），
    /// 里头还带方括号，按「第一个 `[` 到最后一个 `]`」截就会截出一坨解不开的东西，
    /// 结果整批原样退回（现象是「翻译完还是英文」）。
    /// 所以改成从**后往前**逐对括号试解码，取第一个能解开的 —— 答案通常在思考之后
    private static func parseFixes<T: Decodable>(_ raw: String) -> [T] {
        let chars = Array(raw)
        let opens = chars.indices.filter { chars[$0] == "[" }.suffix(12)
        let closes = chars.indices.filter { chars[$0] == "]" }.suffix(12)
        for o in opens.reversed() {
            for c in closes.reversed() where c > o {
                let sub = String(chars[o...c])
                if let v = try? JSONDecoder().decode([T].self, from: Data(sub.utf8)), !v.isEmpty {
                    return v
                }
            }
        }
        return []
    }
}
