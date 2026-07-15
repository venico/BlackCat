import Foundation
import CryptoKit

final class AIVideoService: ObservableObject {
    static let shared = AIVideoService()

    enum Provider: String, CaseIterable, Identifiable {
        case kling = "kling"
        case runway = "runway"
        case seedance = "seedance"
        case seedance15 = "seedance15"

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .kling: return "可灵 (Kling)"
            case .runway: return "Runway Gen-4"
            case .seedance: return "Seedance 2.0"
            case .seedance15: return "Seedance 1.5 Pro"
            }
        }
        var needsAccessKey: Bool {
            switch self {
            case .seedance, .seedance15: return false
            default: return true
            }
        }
        var needsSecretKey: Bool {
            switch self {
            case .kling: return true
            case .runway, .seedance, .seedance15: return false
            }
        }
        var accessKeyLabel: String {
            switch self {
            case .kling: return "Access Key"
            case .runway: return "API Key"
            case .seedance, .seedance15: return "API Key"
            }
        }
        var secretKeyLabel: String { "Secret Key" }
    }

    enum TaskStatus: Equatable {
        case idle
        case generating(progress: String)
        case downloading(progress: Double)
        case completed(url: URL)
        case failed(error: String)
    }

    struct ChatMessage: Identifiable {
        let id: UUID
        let role: Role
        var content: String
        var videoURL: URL?
        var status: TaskStatus
        let timestamp: Date

        enum Role { case user, assistant }

        init(id: UUID = UUID(), role: Role, content: String, videoURL: URL? = nil, status: TaskStatus = .idle) {
            self.id = id
            self.role = role
            self.content = content
            self.videoURL = videoURL
            self.status = status
            self.timestamp = Date()
        }
    }

    struct ConversationRecord: Identifiable, Codable {
        let id: UUID
        var title: String
        let createdAt: Date
        var entries: [Entry]

        struct Entry: Identifiable, Codable {
            let id: UUID
            let isUser: Bool
            let text: String
            let videoPath: String?
        }
    }

    @Published var messages: [ChatMessage] = []
    @Published var selectedProvider: Provider = .kling
    @Published var isGenerating = false
    @Published var history: [ConversationRecord] = []
    @Published var currentConversationId: UUID? = nil

    private let settings = AppSettings.shared
    private var generatingConversationId: UUID?
    private var generatingMessageId: UUID?
    private var generationTask: Task<Void, Never>?

    private init() {
        if let p = Provider(rawValue: settings.aiProvider) {
            selectedProvider = p
        }
        loadHistory()
    }

    func sendPrompt(_ prompt: String, duration: String = "5", aspectRatio: String = "16:9") {
        let userMsg = ChatMessage(role: .user, content: prompt)
        messages.append(userMsg)

        let assistantMsg = ChatMessage(role: .assistant, content: "正在生成视频…", status: .generating(progress: "提交任务中"))
        let msgId = assistantMsg.id
        messages.append(assistantMsg)
        isGenerating = true

        saveCurrentConversation()
        let convId = currentConversationId!
        generatingConversationId = convId
        generatingMessageId = msgId

        let provider = selectedProvider
        generationTask = Task { @MainActor in
            do {
                let videoURL = try await generateVideo(provider: provider, prompt: prompt, duration: duration, aspectRatio: aspectRatio)
                applyGenerationResult(convId: convId, msgId: msgId, content: "视频生成完成", videoURL: videoURL, status: .completed(url: videoURL))
            } catch is CancellationError {
                applyGenerationResult(convId: convId, msgId: msgId, content: "已取消", videoURL: nil, status: .failed(error: "已取消生成"))
            } catch {
                applyGenerationResult(convId: convId, msgId: msgId, content: "生成失败: \(error.localizedDescription)", videoURL: nil, status: .failed(error: error.localizedDescription))
            }
            isGenerating = false
            generatingConversationId = nil
            generatingMessageId = nil
            generationTask = nil
        }
    }

    func cancelGeneration() {
        generationTask?.cancel()
        generationTask = nil
    }

    private func applyGenerationResult(convId: UUID, msgId: UUID, content: String, videoURL: URL?, status: TaskStatus) {
        if currentConversationId == convId {
            if let idx = messages.firstIndex(where: { $0.id == msgId }) {
                messages[idx].content = content
                messages[idx].videoURL = videoURL
                messages[idx].status = status
            }
            saveCurrentConversation()
        } else {
            if let histIdx = history.firstIndex(where: { $0.id == convId }) {
                var videoPath: String? = nil
                if case .completed(let url) = status { videoPath = url.path }
                let entry = ConversationRecord.Entry(id: msgId, isUser: false, text: content, videoPath: videoPath)
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

    func newConversation() {
        saveCurrentConversation()
        messages.removeAll()
        currentConversationId = nil
    }

    func loadConversation(_ id: UUID) {
        saveCurrentConversation()
        guard let conv = history.first(where: { $0.id == id }) else { return }
        currentConversationId = conv.id
        messages = conv.entries.map { entry in
            if entry.isUser {
                return ChatMessage(role: .user, content: entry.text)
            } else {
                if let path = entry.videoPath, FileManager.default.fileExists(atPath: path) {
                    let url = URL(fileURLWithPath: path)
                    return ChatMessage(role: .assistant, content: entry.text, videoURL: url, status: .completed(url: url))
                } else {
                    return ChatMessage(role: .assistant, content: entry.text)
                }
            }
        }
        if generatingConversationId == id, let msgId = generatingMessageId,
           !messages.contains(where: { $0.id == msgId }) {
            messages.append(ChatMessage(id: msgId, role: .assistant, content: "正在生成视频…", status: .generating(progress: "生成中，请等待…")))
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
            if case .completed(let url) = msg.status {
                videoPath = url.path
            }
            return ConversationRecord.Entry(id: msg.id, isUser: msg.role == .user, text: msg.content, videoPath: videoPath)
        }
        let title = String((validMessages.first(where: { $0.role == .user })?.content ?? "对话").prefix(30))

        if let cid = currentConversationId, let idx = history.firstIndex(where: { $0.id == cid }) {
            history[idx].entries = entries
            history[idx].title = title
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
        if let data = try? JSONEncoder().encode(history) {
            try? data.write(to: historyFileURL)
        }
    }

    private func loadHistory() {
        guard let data = try? Data(contentsOf: historyFileURL),
              let h = try? JSONDecoder().decode([ConversationRecord].self, from: data) else { return }
        history = h
    }

    // MARK: - API 调用

    private func generateVideo(provider: Provider, prompt: String, duration: String, aspectRatio: String) async throws -> URL {
        switch provider {
        case .kling:
            return try await generateWithKling(prompt: prompt, duration: duration, aspectRatio: aspectRatio)
        case .runway:
            return try await generateWithRunway(prompt: prompt, duration: duration, aspectRatio: aspectRatio)
        case .seedance:
            let ep = settings.seedanceEndpoint
            guard !ep.isEmpty else { throw AIError.missingAPIKey("请先在设置中填写 Seedance 2.0 的接入点 ID") }
            return try await generateWithSeedance(model: ep, prompt: prompt, duration: duration, aspectRatio: aspectRatio)
        case .seedance15:
            let ep = settings.seedance15Endpoint
            guard !ep.isEmpty else { throw AIError.missingAPIKey("请先在设置中填写 Seedance 1.5 Pro 的接入点 ID") }
            return try await generateWithSeedance(model: ep, prompt: prompt, duration: duration, aspectRatio: aspectRatio)
        }
    }

    // MARK: - Kling API

    private func generateWithKling(prompt: String, duration: String, aspectRatio: String) async throws -> URL {
        let accessKey = settings.aiAccessKey
        let secretKey = settings.aiSecretKey
        guard !accessKey.isEmpty, !secretKey.isEmpty else {
            throw AIError.missingAPIKey("请先在设置中填写可灵 Access Key 和 Secret Key")
        }

        let token = try generateKlingJWT(accessKey: accessKey, secretKey: secretKey)

        let taskId = try await createKlingTask(token: token, prompt: prompt, duration: duration, aspectRatio: aspectRatio)

        updateAssistantStatus(.generating(progress: "生成中，请等待…"))

        let videoURLString = try await pollKlingTask(token: token, taskId: taskId)

        updateAssistantStatus(.downloading(progress: 0))
        let localURL = try await downloadVideo(from: videoURLString, filename: "kling_\(taskId).mp4")

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

    private func createKlingTask(token: String, prompt: String, duration: String, aspectRatio: String) async throws -> String {
        let url = URL(string: "https://api.klingai.com/v1/videos/text2video")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model_name": "kling-v2",
            "prompt": prompt,
            "duration": duration,
            "aspect_ratio": aspectRatio,
            "mode": "std"
        ]
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

    private func pollKlingTask(token: String, taskId: String) async throws -> String {
        let url = URL(string: "https://api.klingai.com/v1/videos/text2video/\(taskId)")!
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
                updateAssistantStatus(.generating(progress: "生成中（\(status)）…"))
            }
        }
        throw AIError.timeout
    }

    // MARK: - Runway API

    private func generateWithRunway(prompt: String, duration: String, aspectRatio: String) async throws -> URL {
        let apiKey = settings.aiAccessKey
        guard !apiKey.isEmpty else {
            throw AIError.missingAPIKey("请先在设置中填写 Runway API Key")
        }

        let taskId = try await createRunwayTask(apiKey: apiKey, prompt: prompt, duration: duration, aspectRatio: aspectRatio)

        updateAssistantStatus(.generating(progress: "生成中，请等待…"))

        let videoURLString = try await pollRunwayTask(apiKey: apiKey, taskId: taskId)

        updateAssistantStatus(.downloading(progress: 0))
        let localURL = try await downloadVideo(from: videoURLString, filename: "runway_\(taskId).mp4")

        return localURL
    }

    private func createRunwayTask(apiKey: String, prompt: String, duration: String, aspectRatio: String) async throws -> String {
        let url = URL(string: "https://api.dev.runwayml.com/v1/text_to_video")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2024-11-06", forHTTPHeaderField: "X-Runway-Version")

        let durationInt = Int(duration) ?? 5
        let body: [String: Any] = [
            "model": "gen4_turbo",
            "promptText": prompt,
            "duration": durationInt,
            "ratio": aspectRatio.replacingOccurrences(of: ":", with: "x")
        ]
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

    private func generateWithSeedance(model: String, prompt: String, duration: String, aspectRatio: String) async throws -> URL {
        let apiKey = settings.seedanceApiKey
        guard !apiKey.isEmpty else {
            throw AIError.missingAPIKey("请先在设置中填写 Seedance API Key")
        }

        let taskId = try await createSeedanceTask(apiKey: apiKey, model: model, prompt: prompt, duration: duration, aspectRatio: aspectRatio)

        updateAssistantStatus(.generating(progress: "生成中，请等待…"))

        let videoURLString = try await pollSeedanceTask(apiKey: apiKey, taskId: taskId)

        updateAssistantStatus(.downloading(progress: 0))
        let localURL = try await downloadVideo(from: videoURLString, filename: "seedance_\(taskId).mp4")

        return localURL
    }

    private func createSeedanceTask(apiKey: String, model: String, prompt: String, duration: String, aspectRatio: String) async throws -> String {
        let url = URL(string: "https://ark.cn-beijing.volces.com/api/v3/contents/generations/tasks")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var reqContent: [[String: Any]] = [
            ["type": "text", "text": prompt]
        ]
        let durationSec: Int
        switch duration {
        case "10": durationSec = 10
        default: durationSec = 5
        }
        let body: [String: Any] = [
            "model": model,
            "content": reqContent,
            "parameters": [
                "aspect_ratio": aspectRatio,
                "duration": durationSec,
                "quality": "high"
            ]
        ]
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
                updateAssistantStatus(.generating(progress: "生成中（\(status)）…"))
            }
        }
        throw AIError.timeout
    }

    // MARK: - 下载视频

    private func downloadVideo(from urlString: String, filename: String) async throws -> URL {
        guard let url = URL(string: urlString) else {
            throw AIError.apiError("无效的视频 URL")
        }

        let (tempURL, response) = try await URLSession.shared.download(from: url)
        guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
            throw AIError.apiError("下载视频失败")
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

    private func updateAssistantStatus(_ status: TaskStatus) {
        guard generatingConversationId == nil || currentConversationId == generatingConversationId else { return }
        if let idx = messages.lastIndex(where: { $0.role == .assistant && $0.status != .idle }) {
            messages[idx].status = status
        }
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
