import Foundation
import CryptoKit

final class AIVideoService: ObservableObject {
    static let shared = AIVideoService()

    enum ProviderCategory: String, CaseIterable {
        case video = "视频生成"
        case image = "图片生成"
        case audio = "声音生成"
        case text = "文字生成"
    }

    enum Provider: String, CaseIterable, Identifiable {
        // 视频生成
        case kling = "kling"
        case seedance = "seedance"
        case seedance15 = "seedance15"
        case runway = "runway"
        case minimax = "minimax"
        case vidu = "vidu"
        // 图片生成
        case gptImage2 = "gpt-image-2"
        case flux = "flux"
        case sd3 = "sd3"
        case wanxiang = "wanxiang"
        // 声音生成
        case elevenlabs = "elevenlabs"
        case openaiTTS = "openai-tts"
        case fishAudio = "fish-audio"
        case suno = "suno"
        // 文字生成
        case claude = "claude"
        case gpt56 = "gpt-5.6"
        case deepseek_ai = "deepseek-ai"
        case qwen = "qwen"

        var id: String { rawValue }

        var category: ProviderCategory {
            switch self {
            case .kling, .seedance, .seedance15, .runway, .minimax, .vidu: return .video
            case .gptImage2, .flux, .sd3, .wanxiang: return .image
            case .elevenlabs, .openaiTTS, .fishAudio, .suno: return .audio
            case .claude, .gpt56, .deepseek_ai, .qwen: return .text
            }
        }

        var displayName: String {
            switch self {
            case .kling: return "可灵 (Kling)"
            case .seedance: return "Seedance 2.0"
            case .seedance15: return "Seedance 1.5 Pro"
            case .runway: return "Runway Gen-4"
            case .minimax: return "海螺 (MiniMax)"
            case .vidu: return "Vidu"
            case .gptImage2: return "GPT-Image-2"
            case .flux: return "Flux"
            case .sd3: return "Stable Diffusion 3"
            case .wanxiang: return "通义万相"
            case .elevenlabs: return "ElevenLabs"
            case .openaiTTS: return "OpenAI TTS"
            case .fishAudio: return "Fish Audio"
            case .suno: return "Suno"
            case .claude: return "Claude"
            case .gpt56: return "GPT-5.6"
            case .deepseek_ai: return "DeepSeek"
            case .qwen: return "通义千问"
            }
        }

        static func providers(for category: ProviderCategory) -> [Provider] {
            allCases.filter { $0.category == category }
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
            default: return false
            }
        }
        var accessKeyLabel: String {
            switch self {
            case .kling: return "Access Key"
            default: return "API Key"
            }
        }
        var secretKeyLabel: String { "Secret Key" }

        var supportsWebSearch: Bool {
            category == .text
        }

        var maxReferenceImages: Int {
            switch self {
            case .seedance, .seedance15: return 9
            case .kling, .runway, .minimax, .vidu: return 1
            case .gptImage2: return 4
            case .flux, .sd3, .wanxiang: return 1
            default: return 0
            }
        }

        var maxReferenceVideos: Int {
            switch self {
            case .seedance, .seedance15: return 3
            default: return 0
            }
        }

        var maxReferenceAudios: Int {
            switch self {
            case .seedance, .seedance15: return 3
            default: return 0
            }
        }

        var supportsFirstFrame: Bool {
            switch self {
            case .kling, .seedance, .seedance15, .runway, .minimax, .vidu: return true
            default: return false
            }
        }

        var supportsLastFrame: Bool {
            switch self {
            case .kling: return true
            default: return false
            }
        }
    }

    enum TaskStatus: Equatable {
        case idle
        case generating(progress: String)
        case downloading(progress: Double)
        case completed(url: URL)
        case completedImage(url: URL)
        case completedAudio(url: URL)
        case failed(error: String)
    }

    struct ChatMessage: Identifiable {
        let id: UUID
        let role: Role
        var content: String
        var videoURL: URL?
        var imageURL: URL?
        var audioURL: URL?
        var videoBookmark: Data?
        var imageBookmark: Data?
        var audioBookmark: Data?
        var status: TaskStatus
        let timestamp: Date

        enum Role { case user, assistant }

        init(id: UUID = UUID(), role: Role, content: String, videoURL: URL? = nil, imageURL: URL? = nil, audioURL: URL? = nil, status: TaskStatus = .idle) {
            self.id = id
            self.role = role
            self.content = content
            self.videoURL = videoURL
            self.imageURL = imageURL
            self.audioURL = audioURL
            self.status = status
            self.timestamp = Date()
        }

        func resolvedVideoURL() -> URL? {
            if let bm = videoBookmark, let url = Self.resolve(bm), FileManager.default.fileExists(atPath: url.path) { return url }
            if let url = videoURL, FileManager.default.fileExists(atPath: url.path) { return url }
            return nil
        }
        func resolvedImageURL() -> URL? {
            if let bm = imageBookmark, let url = Self.resolve(bm), FileManager.default.fileExists(atPath: url.path) { return url }
            if let url = imageURL, FileManager.default.fileExists(atPath: url.path) { return url }
            return nil
        }
        func resolvedAudioURL() -> URL? {
            if let bm = audioBookmark, let url = Self.resolve(bm), FileManager.default.fileExists(atPath: url.path) { return url }
            if let url = audioURL, FileManager.default.fileExists(atPath: url.path) { return url }
            return nil
        }
        private static func resolve(_ data: Data) -> URL? {
            var stale = false
            return try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
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
            var imagePath: String?
            var audioPath: String?
            var videoBookmark: Data?
            var imageBookmark: Data?
            var audioBookmark: Data?
        }
    }

    @Published var messages: [ChatMessage] = []
    @Published var selectedProvider: Provider = .kling
    @Published var isGenerating = false
    @Published var webSearchEnabled = false
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

    func sendPrompt(_ prompt: String, duration: String = "5", aspectRatio: String = "16:9", resolution: String = "720P", referenceImages: [URL] = [], referenceVideos: [URL] = [], referenceAudios: [URL] = [], firstFrame: URL? = nil, lastFrame: URL? = nil) {
        let userMsg = ChatMessage(role: .user, content: prompt)
        messages.append(userMsg)

        let category = selectedProvider.category
        let progressText: String
        switch category {
        case .video: progressText = "正在生成视频…"
        case .image: progressText = "正在生成图片…"
        case .audio: progressText = "正在生成音频…"
        case .text:  progressText = "正在生成回复…"
        }

        let assistantMsg = ChatMessage(role: .assistant, content: progressText, status: .generating(progress: "提交任务中"))
        let msgId = assistantMsg.id
        messages.append(assistantMsg)
        isGenerating = true

        saveCurrentConversation()
        let convId = currentConversationId!
        generatingConversationId = convId
        generatingMessageId = msgId

        let provider = selectedProvider
        let useSearch = webSearchEnabled && provider.supportsWebSearch
        generationTask = Task { @MainActor in
            do {
                switch category {
                case .video:
                    let url = try await generateVideo(provider: provider, prompt: prompt, duration: duration, aspectRatio: aspectRatio, resolution: resolution, referenceImages: referenceImages, referenceVideos: referenceVideos, referenceAudios: referenceAudios, firstFrame: firstFrame, lastFrame: lastFrame)
                    applyGenerationResult(convId: convId, msgId: msgId, content: "视频生成完成", mediaURL: url, status: .completed(url: url))
                case .image:
                    let url = try await generateImage(provider: provider, prompt: prompt)
                    applyGenerationResult(convId: convId, msgId: msgId, content: "图片生成完成", mediaURL: url, status: .completedImage(url: url))
                case .audio:
                    let url = try await generateAudio(provider: provider, prompt: prompt)
                    applyGenerationResult(convId: convId, msgId: msgId, content: "音频生成完成", mediaURL: url, status: .completedAudio(url: url))
                case .text:
                    let text = try await generateText(provider: provider, prompt: prompt, webSearch: useSearch)
                    applyGenerationResult(convId: convId, msgId: msgId, content: text, mediaURL: nil, status: .idle)
                }
            } catch is CancellationError {
                applyGenerationResult(convId: convId, msgId: msgId, content: "已取消", mediaURL: nil, status: .failed(error: "已取消生成"))
            } catch {
                applyGenerationResult(convId: convId, msgId: msgId, content: "生成失败: \(error.localizedDescription)", mediaURL: nil, status: .failed(error: error.localizedDescription))
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

    private func applyGenerationResult(convId: UUID, msgId: UUID, content: String, mediaURL: URL?, status: TaskStatus) {
        if currentConversationId == convId {
            if let idx = messages.firstIndex(where: { $0.id == msgId }) {
                messages[idx].content = content
                messages[idx].status = status
                switch status {
                case .completed(let url):
                    messages[idx].videoURL = url
                    messages[idx].videoBookmark = createBookmark(for: url)
                case .completedImage(let url):
                    messages[idx].imageURL = url
                    messages[idx].imageBookmark = createBookmark(for: url)
                case .completedAudio(let url):
                    messages[idx].audioURL = url
                    messages[idx].audioBookmark = createBookmark(for: url)
                default: break
                }
            }
            saveCurrentConversation()
        } else {
            if let histIdx = history.firstIndex(where: { $0.id == convId }) {
                var videoPath: String? = nil
                var imagePath: String? = nil
                var audioPath: String? = nil
                var videoBookmark: Data? = nil
                var imageBookmark: Data? = nil
                var audioBookmark: Data? = nil
                switch status {
                case .completed(let url):
                    videoPath = url.path; videoBookmark = createBookmark(for: url)
                case .completedImage(let url):
                    imagePath = url.path; imageBookmark = createBookmark(for: url)
                case .completedAudio(let url):
                    audioPath = url.path; audioBookmark = createBookmark(for: url)
                default: break
                }
                var entry = ConversationRecord.Entry(id: msgId, isUser: false, text: content, videoPath: videoPath)
                entry.imagePath = imagePath
                entry.audioPath = audioPath
                entry.videoBookmark = videoBookmark
                entry.imageBookmark = imageBookmark
                entry.audioBookmark = audioBookmark
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
                if let url = resolveMediaURL(path: entry.videoPath, bookmark: entry.videoBookmark) {
                    var msg = ChatMessage(role: .assistant, content: entry.text, videoURL: url, status: .completed(url: url))
                    msg.videoBookmark = entry.videoBookmark
                    return msg
                } else if let url = resolveMediaURL(path: entry.imagePath, bookmark: entry.imageBookmark) {
                    var msg = ChatMessage(role: .assistant, content: entry.text, imageURL: url, status: .completedImage(url: url))
                    msg.imageBookmark = entry.imageBookmark
                    return msg
                } else if let url = resolveMediaURL(path: entry.audioPath, bookmark: entry.audioBookmark) {
                    var msg = ChatMessage(role: .assistant, content: entry.text, audioURL: url, status: .completedAudio(url: url))
                    msg.audioBookmark = entry.audioBookmark
                    return msg
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
            var imagePath: String? = nil
            var audioPath: String? = nil
            var videoBookmark: Data? = nil
            var imageBookmark: Data? = nil
            var audioBookmark: Data? = nil
            switch msg.status {
            case .completed(let url):
                videoPath = url.path
                videoBookmark = createBookmark(for: url)
            case .completedImage(let url):
                imagePath = url.path
                imageBookmark = createBookmark(for: url)
            case .completedAudio(let url):
                audioPath = url.path
                audioBookmark = createBookmark(for: url)
            default: break
            }
            var entry = ConversationRecord.Entry(id: msg.id, isUser: msg.role == .user, text: msg.content, videoPath: videoPath)
            entry.imagePath = imagePath
            entry.audioPath = audioPath
            entry.videoBookmark = videoBookmark
            entry.imageBookmark = imageBookmark
            entry.audioBookmark = audioBookmark
            return entry
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

    private func generateVideo(provider: Provider, prompt: String, duration: String, aspectRatio: String, resolution: String, referenceImages: [URL], referenceVideos: [URL] = [], referenceAudios: [URL] = [], firstFrame: URL?, lastFrame: URL?) async throws -> URL {
        switch provider {
        case .kling:
            return try await generateWithKling(prompt: prompt, duration: duration, aspectRatio: aspectRatio, referenceImage: referenceImages.first ?? firstFrame, lastFrame: lastFrame)
        case .runway:
            return try await generateWithRunway(prompt: prompt, duration: duration, aspectRatio: aspectRatio, referenceImage: referenceImages.first ?? firstFrame)
        case .seedance:
            let ep = settings.seedanceEndpoint
            guard !ep.isEmpty else { throw AIError.missingAPIKey("请先在设置中填写 Seedance 2.0 的接入点 ID") }
            return try await generateWithSeedance(model: ep, prompt: prompt, duration: duration, aspectRatio: aspectRatio, referenceImages: referenceImages, referenceVideos: referenceVideos, referenceAudios: referenceAudios)
        case .seedance15:
            let ep = settings.seedance15Endpoint
            guard !ep.isEmpty else { throw AIError.missingAPIKey("请先在设置中填写 Seedance 1.5 Pro 的接入点 ID") }
            return try await generateWithSeedance(model: ep, prompt: prompt, duration: duration, aspectRatio: aspectRatio, referenceImages: referenceImages, referenceVideos: referenceVideos, referenceAudios: referenceAudios)
        case .minimax:
            return try await generateWithMiniMax(prompt: prompt, duration: duration, aspectRatio: aspectRatio, referenceImage: referenceImages.first ?? firstFrame)
        case .vidu:
            return try await generateWithVidu(prompt: prompt, duration: duration, aspectRatio: aspectRatio, referenceImage: referenceImages.first ?? firstFrame)
        default:
            throw AIError.missingAPIKey("\(provider.displayName) 尚未支持，敬请期待")
        }
    }

    // MARK: - Kling API

    private func generateWithKling(prompt: String, duration: String, aspectRatio: String, referenceImage: URL? = nil, lastFrame: URL? = nil) async throws -> URL {
        let accessKey = settings.aiAccessKey
        let secretKey = settings.aiSecretKey
        guard !accessKey.isEmpty, !secretKey.isEmpty else {
            throw AIError.missingAPIKey("请先在设置中填写可灵 Access Key 和 Secret Key")
        }

        let token = try generateKlingJWT(accessKey: accessKey, secretKey: secretKey)

        let hasImage = referenceImage != nil
        let taskId = try await createKlingTask(token: token, prompt: prompt, duration: duration, aspectRatio: aspectRatio, referenceImage: referenceImage, lastFrame: lastFrame)

        updateAssistantStatus(.generating(progress: "生成中，请等待…"))

        let videoURLString = try await pollKlingTask(token: token, taskId: taskId, endpoint: hasImage ? "image2video" : "text2video")

        updateAssistantStatus(.downloading(progress: 0))
        let localURL = try await downloadFile(from: videoURLString, filename: "kling_\(taskId).mp4")

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

    private func createKlingTask(token: String, prompt: String, duration: String, aspectRatio: String, referenceImage: URL? = nil, lastFrame: URL? = nil) async throws -> String {
        let hasImage = referenceImage != nil
        let endpoint = hasImage ? "https://api.klingai.com/v1/videos/image2video" : "https://api.klingai.com/v1/videos/text2video"
        let url = URL(string: endpoint)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "model_name": "kling-v2",
            "prompt": prompt,
            "duration": duration,
            "aspect_ratio": aspectRatio,
            "mode": "std"
        ]
        if let imgURL = referenceImage, let b64 = imageToBase64(imgURL) {
            body["image"] = b64
        }
        if let tailURL = lastFrame, let b64 = imageToBase64(tailURL) {
            body["tail_image"] = b64
        }
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

    private func pollKlingTask(token: String, taskId: String, endpoint: String = "text2video") async throws -> String {
        let url = URL(string: "https://api.klingai.com/v1/videos/\(endpoint)/\(taskId)")!
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

    private func generateWithRunway(prompt: String, duration: String, aspectRatio: String, referenceImage: URL? = nil) async throws -> URL {
        let apiKey = settings.aiAccessKey
        guard !apiKey.isEmpty else {
            throw AIError.missingAPIKey("请先在设置中填写 Runway API Key")
        }

        let taskId = try await createRunwayTask(apiKey: apiKey, prompt: prompt, duration: duration, aspectRatio: aspectRatio, referenceImage: referenceImage)

        updateAssistantStatus(.generating(progress: "生成中，请等待…"))

        let videoURLString = try await pollRunwayTask(apiKey: apiKey, taskId: taskId)

        updateAssistantStatus(.downloading(progress: 0))
        let localURL = try await downloadFile(from: videoURLString, filename: "runway_\(taskId).mp4")

        return localURL
    }

    private func createRunwayTask(apiKey: String, prompt: String, duration: String, aspectRatio: String, referenceImage: URL? = nil) async throws -> String {
        let hasImage = referenceImage != nil
        let endpoint = hasImage ? "https://api.dev.runwayml.com/v1/image_to_video" : "https://api.dev.runwayml.com/v1/text_to_video"
        let url = URL(string: endpoint)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2024-11-06", forHTTPHeaderField: "X-Runway-Version")

        let durationInt = Int(duration) ?? 5
        var body: [String: Any] = [
            "model": "gen4_turbo",
            "promptText": prompt,
            "duration": durationInt,
            "ratio": aspectRatio.replacingOccurrences(of: ":", with: "x")
        ]
        if let imgURL = referenceImage, let b64 = imageToBase64DataURI(imgURL) {
            body["promptImage"] = b64
        }
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

    private func generateWithSeedance(model: String, prompt: String, duration: String, aspectRatio: String, referenceImages: [URL] = [], referenceVideos: [URL] = [], referenceAudios: [URL] = []) async throws -> URL {
        let apiKey = settings.seedanceApiKey
        guard !apiKey.isEmpty else {
            throw AIError.missingAPIKey("请先在设置中填写 Seedance API Key")
        }

        let taskId = try await createSeedanceTask(apiKey: apiKey, model: model, prompt: prompt, duration: duration, aspectRatio: aspectRatio, referenceImages: referenceImages, referenceVideos: referenceVideos, referenceAudios: referenceAudios)

        updateAssistantStatus(.generating(progress: "生成中，请等待…"))

        let videoURLString = try await pollSeedanceTask(apiKey: apiKey, taskId: taskId)

        updateAssistantStatus(.downloading(progress: 0))
        let localURL = try await downloadFile(from: videoURLString, filename: "seedance_\(taskId).mp4")

        return localURL
    }

    private func createSeedanceTask(apiKey: String, model: String, prompt: String, duration: String, aspectRatio: String, referenceImages: [URL] = [], referenceVideos: [URL] = [], referenceAudios: [URL] = []) async throws -> String {
        let url = URL(string: "https://ark.cn-beijing.volces.com/api/v3/contents/generations/tasks")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var reqContent: [[String: Any]] = []
        for imgURL in referenceImages {
            if let b64 = imageToBase64DataURI(imgURL) {
                reqContent.append(["type": "image_url", "image_url": ["url": b64]])
            }
        }
        for vidURL in referenceVideos {
            if let b64 = fileToBase64DataURI(vidURL, mime: "video/mp4") {
                reqContent.append(["type": "video_url", "video_url": ["url": b64]])
            }
        }
        for audURL in referenceAudios {
            if let b64 = fileToBase64DataURI(audURL, mime: "audio/mpeg") {
                reqContent.append(["type": "input_audio", "input_audio": ["url": b64]])
            }
        }
        reqContent.append(["type": "text", "text": prompt])
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

    // MARK: - 图片生成

    private func generateImage(provider: Provider, prompt: String) async throws -> URL {
        let apiKey = settings.providerAPIKey(for: provider.rawValue)
        guard !apiKey.isEmpty else {
            throw AIError.missingAPIKey("请先在设置中填写 \(provider.displayName) 的 API Key")
        }
        switch provider {
        case .gptImage2:
            return try await generateWithGPTImage(apiKey: apiKey, prompt: prompt)
        case .flux:
            return try await generateWithFlux(apiKey: apiKey, prompt: prompt)
        case .sd3:
            return try await generateWithSD3(apiKey: apiKey, prompt: prompt)
        case .wanxiang:
            return try await generateWithWanxiang(apiKey: apiKey, prompt: prompt)
        default:
            throw AIError.missingAPIKey("\(provider.displayName) 不支持图片生成")
        }
    }

    // MARK: - GPT-Image-2

    private func generateWithGPTImage(apiKey: String, prompt: String) async throws -> URL {
        let url = URL(string: "https://api.openai.com/v1/images/generations")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["model": "gpt-image-1", "prompt": prompt, "n": 1, "size": "1024x1024"]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        await MainActor.run { updateAssistantStatus(.generating(progress: "生成图片中…")) }

        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any]
            throw AIError.apiError((msg?["message"] as? String) ?? "GPT-Image 请求失败")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let results = json?["data"] as? [[String: Any]],
              let b64 = results.first?["b64_json"] as? String,
              let imgData = Data(base64Encoded: b64) else {
            if let results = json?["data"] as? [[String: Any]],
               let urlStr = results.first?["url"] as? String {
                await MainActor.run { updateAssistantStatus(.downloading(progress: 0)) }
                return try await downloadFile(from: urlStr, filename: "gpt_image_\(UUID().uuidString.prefix(8)).png")
            }
            throw AIError.apiError("GPT-Image 返回数据格式错误")
        }

        let saveDir = AppSettings.shared.effectiveProjectDir.appendingPathComponent("AI生成")
        try FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
        let dest = saveDir.appendingPathComponent("gpt_image_\(UUID().uuidString.prefix(8)).png")
        try imgData.write(to: dest)
        return dest
    }

    // MARK: - Flux (BFL API)

    private func generateWithFlux(apiKey: String, prompt: String) async throws -> URL {
        let url = URL(string: "https://api.bfl.ml/v1/flux-pro-1.1")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Key \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["prompt": prompt, "width": 1024, "height": 1024]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw AIError.apiError("Flux 请求失败")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let taskId = json?["id"] as? String else {
            throw AIError.apiError("Flux 未返回任务 ID")
        }

        await MainActor.run { updateAssistantStatus(.generating(progress: "生成图片中…")) }

        let resultURL = URL(string: "https://api.bfl.ml/v1/get_result?id=\(taskId)")!
        for _ in 0..<120 {
            try await Task.sleep(nanoseconds: 3_000_000_000)
            var pollReq = URLRequest(url: resultURL)
            pollReq.setValue("Key \(apiKey)", forHTTPHeaderField: "Authorization")
            let (pData, _) = try await URLSession.shared.data(for: pollReq)
            let pJson = try JSONSerialization.jsonObject(with: pData) as? [String: Any]
            let status = pJson?["status"] as? String ?? ""
            if status == "Ready", let imgURL = (pJson?["result"] as? [String: Any])?["sample"] as? String {
                await MainActor.run { updateAssistantStatus(.downloading(progress: 0)) }
                return try await downloadFile(from: imgURL, filename: "flux_\(taskId.prefix(8)).png")
            } else if status == "Error" {
                throw AIError.apiError("Flux 生成失败")
            }
        }
        throw AIError.timeout
    }

    // MARK: - Stable Diffusion 3

    private func generateWithSD3(apiKey: String, prompt: String) async throws -> URL {
        let url = URL(string: "https://api.stability.ai/v2beta/stable-image/generate/sd3")!
        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var bodyData = Data()
        func addField(_ name: String, _ value: String) {
            bodyData.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        addField("prompt", prompt)
        addField("model", "sd3.5-large")
        addField("output_format", "png")
        bodyData.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = bodyData

        await MainActor.run { updateAssistantStatus(.generating(progress: "生成图片中…")) }

        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let errJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            throw AIError.apiError((errJson?["message"] as? String) ?? "SD3 请求失败 (\((resp as? HTTPURLResponse)?.statusCode ?? 0))")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let imgB64 = json?["image"] as? String, let imgData = Data(base64Encoded: imgB64) else {
            throw AIError.apiError("SD3 返回数据格式错误")
        }

        let saveDir = AppSettings.shared.effectiveProjectDir.appendingPathComponent("AI生成")
        try FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
        let dest = saveDir.appendingPathComponent("sd3_\(UUID().uuidString.prefix(8)).png")
        try imgData.write(to: dest)
        return dest
    }

    // MARK: - 通义万相

    private func generateWithWanxiang(apiKey: String, prompt: String) async throws -> URL {
        let url = URL(string: "https://dashscope.aliyuncs.com/api/v1/services/aigc/text2image/image-synthesis")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("enable", forHTTPHeaderField: "X-DashScope-Async")

        let body: [String: Any] = [
            "model": "wanx-v1",
            "input": ["prompt": prompt],
            "parameters": ["n": 1, "size": "1024*1024"]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw AIError.apiError("通义万相请求失败")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let output = json?["output"] as? [String: Any],
              let taskId = output["task_id"] as? String else {
            throw AIError.apiError("通义万相未返回任务 ID")
        }

        await MainActor.run { updateAssistantStatus(.generating(progress: "生成图片中…")) }

        let pollBase = URL(string: "https://dashscope.aliyuncs.com/api/v1/tasks/\(taskId)")!
        for _ in 0..<120 {
            try await Task.sleep(nanoseconds: 3_000_000_000)
            var pollReq = URLRequest(url: pollBase)
            pollReq.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            let (pData, _) = try await URLSession.shared.data(for: pollReq)
            let pJson = try JSONSerialization.jsonObject(with: pData) as? [String: Any]
            let pOutput = pJson?["output"] as? [String: Any]
            let status = pOutput?["task_status"] as? String ?? ""
            if status == "SUCCEEDED" {
                if let results = pOutput?["results"] as? [[String: Any]],
                   let imgURL = results.first?["url"] as? String {
                    await MainActor.run { updateAssistantStatus(.downloading(progress: 0)) }
                    return try await downloadFile(from: imgURL, filename: "wanxiang_\(taskId.prefix(8)).png")
                }
                throw AIError.apiError("通义万相返回无图片")
            } else if status == "FAILED" {
                throw AIError.apiError((pOutput?["message"] as? String) ?? "通义万相生成失败")
            }
        }
        throw AIError.timeout
    }

    // MARK: - 音频生成

    private func generateAudio(provider: Provider, prompt: String) async throws -> URL {
        let apiKey = settings.providerAPIKey(for: provider.rawValue)
        guard !apiKey.isEmpty else {
            throw AIError.missingAPIKey("请先在设置中填写 \(provider.displayName) 的 API Key")
        }
        switch provider {
        case .elevenlabs:
            return try await generateWithElevenLabs(apiKey: apiKey, prompt: prompt)
        case .openaiTTS:
            return try await generateWithOpenAITTS(apiKey: apiKey, prompt: prompt)
        case .fishAudio:
            return try await generateWithFishAudio(apiKey: apiKey, prompt: prompt)
        case .suno:
            return try await generateWithSuno(apiKey: apiKey, prompt: prompt)
        default:
            throw AIError.missingAPIKey("\(provider.displayName) 不支持音频生成")
        }
    }

    // MARK: - ElevenLabs TTS

    private func generateWithElevenLabs(apiKey: String, prompt: String) async throws -> URL {
        let voiceId = "21m00Tcm4TlvDq8ikWAM"
        let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "text": prompt,
            "model_id": "eleven_multilingual_v2",
            "voice_settings": ["stability": 0.5, "similarity_boost": 0.75]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        await MainActor.run { updateAssistantStatus(.generating(progress: "生成音频中…")) }

        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw AIError.apiError("ElevenLabs 请求失败 (\((resp as? HTTPURLResponse)?.statusCode ?? 0))")
        }

        let saveDir = AppSettings.shared.effectiveProjectDir.appendingPathComponent("AI生成")
        try FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
        let dest = saveDir.appendingPathComponent("elevenlabs_\(UUID().uuidString.prefix(8)).mp3")
        try data.write(to: dest)
        return dest
    }

    // MARK: - OpenAI TTS

    private func generateWithOpenAITTS(apiKey: String, prompt: String) async throws -> URL {
        let url = URL(string: "https://api.openai.com/v1/audio/speech")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["model": "tts-1-hd", "input": prompt, "voice": "alloy", "response_format": "mp3"]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        await MainActor.run { updateAssistantStatus(.generating(progress: "生成音频中…")) }

        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw AIError.apiError("OpenAI TTS 请求失败")
        }

        let saveDir = AppSettings.shared.effectiveProjectDir.appendingPathComponent("AI生成")
        try FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
        let dest = saveDir.appendingPathComponent("openai_tts_\(UUID().uuidString.prefix(8)).mp3")
        try data.write(to: dest)
        return dest
    }

    // MARK: - Fish Audio TTS

    private func generateWithFishAudio(apiKey: String, prompt: String) async throws -> URL {
        let url = URL(string: "https://api.fish.audio/v1/tts")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["text": prompt, "reference_id": "default", "format": "mp3"]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        await MainActor.run { updateAssistantStatus(.generating(progress: "生成音频中…")) }

        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw AIError.apiError("Fish Audio 请求失败")
        }

        let saveDir = AppSettings.shared.effectiveProjectDir.appendingPathComponent("AI生成")
        try FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
        let dest = saveDir.appendingPathComponent("fish_audio_\(UUID().uuidString.prefix(8)).mp3")
        try data.write(to: dest)
        return dest
    }

    // MARK: - Suno

    private func generateWithSuno(apiKey: String, prompt: String) async throws -> URL {
        let url = URL(string: "https://studio-api.suno.ai/api/external/generate/")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["topic": prompt, "tags": "pop"]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw AIError.apiError("Suno 请求失败")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let taskId = json?["id"] as? String else {
            if let clips = json?["clips"] as? [[String: Any]],
               let audioURL = clips.first?["audio_url"] as? String {
                await MainActor.run { updateAssistantStatus(.downloading(progress: 0)) }
                return try await downloadFile(from: audioURL, filename: "suno_\(UUID().uuidString.prefix(8)).mp3")
            }
            throw AIError.apiError("Suno 未返回任务信息")
        }

        await MainActor.run { updateAssistantStatus(.generating(progress: "生成音乐中…")) }

        let pollURL = URL(string: "https://studio-api.suno.ai/api/external/clips/?ids=\(taskId)")!
        for _ in 0..<120 {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            var pollReq = URLRequest(url: pollURL)
            pollReq.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            let (pData, _) = try await URLSession.shared.data(for: pollReq)
            if let clips = (try? JSONSerialization.jsonObject(with: pData)) as? [[String: Any]],
               let clip = clips.first,
               let status = clip["status"] as? String {
                if status == "complete", let audioURL = clip["audio_url"] as? String {
                    await MainActor.run { updateAssistantStatus(.downloading(progress: 0)) }
                    return try await downloadFile(from: audioURL, filename: "suno_\(taskId.prefix(8)).mp3")
                } else if status == "error" {
                    throw AIError.apiError("Suno 生成失败")
                }
            }
        }
        throw AIError.timeout
    }

    // MARK: - 文字生成

    private func generateText(provider: Provider, prompt: String, webSearch: Bool = false) async throws -> String {
        let apiKey = settings.providerAPIKey(for: provider.rawValue)
        guard !apiKey.isEmpty else {
            throw AIError.missingAPIKey("请先在设置中填写 \(provider.displayName) 的 API Key")
        }

        var finalPrompt = prompt
        let qwenNativeSearch = webSearch && provider == .qwen

        if webSearch && !qwenNativeSearch {
            await MainActor.run { updateAssistantStatus(.generating(progress: "正在搜索…")) }
            if let results = try? await webSearchQuery(prompt) {
                finalPrompt = "根据以下搜索结果回答用户问题。引用相关信息时注明来源。\n\n搜索结果：\n\(results)\n\n用户问题：\(prompt)"
            }
        }

        let (endpoint, model): (String, String)
        switch provider {
        case .claude:
            return try await generateWithClaude(apiKey: apiKey, prompt: finalPrompt)
        case .gpt56:
            endpoint = "https://api.openai.com/v1/chat/completions"
            model = "gpt-4o"
        case .deepseek_ai:
            endpoint = "https://api.deepseek.com/chat/completions"
            model = "deepseek-chat"
        case .qwen:
            endpoint = "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
            model = "qwen-max"
        default:
            throw AIError.missingAPIKey("\(provider.displayName) 不支持文字生成")
        }

        return try await chatCompletion(apiKey: apiKey, endpoint: endpoint, model: model, prompt: finalPrompt, webSearch: qwenNativeSearch)
    }

    private func generateWithClaude(apiKey: String, prompt: String) async throws -> String {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": "claude-sonnet-4-20250514",
            "max_tokens": 4096,
            "messages": [["role": "user", "content": prompt]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        await MainActor.run { updateAssistantStatus(.generating(progress: "生成回复中…")) }

        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let errJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let errMsg = (errJson?["error"] as? [String: Any])?["message"] as? String
            throw AIError.apiError(errMsg ?? "Claude 请求失败")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let content = json?["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String else {
            throw AIError.apiError("Claude 返回格式错误")
        }
        return text
    }

    private func chatCompletion(apiKey: String, endpoint: String, model: String, prompt: String, webSearch: Bool = false) async throws -> String {
        let url = URL(string: endpoint)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
            "max_tokens": 4096
        ]
        if webSearch {
            body["enable_search"] = true
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        await MainActor.run { updateAssistantStatus(.generating(progress: "生成回复中…")) }

        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let errJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let errMsg = (errJson?["error"] as? [String: Any])?["message"] as? String
            throw AIError.apiError(errMsg ?? "\(model) 请求失败")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let choices = json?["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let text = msg["content"] as? String else {
            throw AIError.apiError("\(model) 返回格式错误")
        }
        return text
    }

    // MARK: - 联网搜索

    private func webSearchQuery(_ query: String) async throws -> String {
        switch settings.searchEngine {
        case .bing:
            return try await bingSearch(query)
        case .google:
            return try await googleSearch(query)
        }
    }

    private func bingSearch(_ query: String) async throws -> String {
        let key = settings.bingSearchKey
        guard !key.isEmpty else {
            throw AIError.missingAPIKey("请先在设置中填写 Bing Search API Key")
        }

        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let url = URL(string: "https://api.bing.microsoft.com/v7.0/search?q=\(encoded)&count=5&mkt=zh-CN")!
        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")

        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw AIError.apiError("Bing 搜索请求失败")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let webPages = json?["webPages"] as? [String: Any],
              let results = webPages["value"] as? [[String: Any]] else {
            return ""
        }

        return results.prefix(5).enumerated().map { i, r in
            let title = r["name"] as? String ?? ""
            let snippet = r["snippet"] as? String ?? ""
            let url = r["url"] as? String ?? ""
            return "\(i+1). \(title)\n   \(snippet)\n   来源：\(url)"
        }.joined(separator: "\n\n")
    }

    private func googleSearch(_ query: String) async throws -> String {
        let key = settings.googleSearchKey
        let cx = settings.googleSearchCX
        guard !key.isEmpty, !cx.isEmpty else {
            throw AIError.missingAPIKey("请先在设置中填写 Google Search API Key 和 CX ID")
        }

        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let url = URL(string: "https://www.googleapis.com/customsearch/v1?key=\(key)&cx=\(cx)&q=\(encoded)&num=5")!

        let (data, resp) = try await URLSession.shared.data(for: URLRequest(url: url))
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw AIError.apiError("Google 搜索请求失败")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let items = json?["items"] as? [[String: Any]] else {
            return ""
        }

        return items.prefix(5).enumerated().map { i, r in
            let title = r["title"] as? String ?? ""
            let snippet = r["snippet"] as? String ?? ""
            let link = r["link"] as? String ?? ""
            return "\(i+1). \(title)\n   \(snippet)\n   来源：\(link)"
        }.joined(separator: "\n\n")
    }

    // MARK: - MiniMax 视频

    private func generateWithMiniMax(prompt: String, duration: String, aspectRatio: String, referenceImage: URL? = nil) async throws -> URL {
        let apiKey = settings.providerAPIKey(for: Provider.minimax.rawValue)
        guard !apiKey.isEmpty else {
            throw AIError.missingAPIKey("请先在设置中填写海螺的 API Key")
        }

        let url = URL(string: "https://api.minimax.chat/v1/video_generation")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = ["model": "video-01", "prompt": prompt]
        if let imgURL = referenceImage, let b64 = imageToBase64DataURI(imgURL) {
            body["first_frame_image"] = b64
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw AIError.apiError("MiniMax 请求失败")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let taskId = json?["task_id"] as? String else {
            throw AIError.apiError("MiniMax 未返回任务 ID")
        }

        await MainActor.run { updateAssistantStatus(.generating(progress: "生成视频中…")) }

        let pollURL = URL(string: "https://api.minimax.chat/v1/query/video_generation?task_id=\(taskId)")!
        for _ in 0..<120 {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            var pollReq = URLRequest(url: pollURL)
            pollReq.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            let (pData, _) = try await URLSession.shared.data(for: pollReq)
            let pJson = try JSONSerialization.jsonObject(with: pData) as? [String: Any]
            let status = pJson?["status"] as? String ?? ""
            if status == "Success" || status == "Finished" {
                if let fileId = pJson?["file_id"] as? String {
                    let dlURL = "https://api.minimax.chat/v1/files/retrieve?file_id=\(fileId)"
                    await MainActor.run { updateAssistantStatus(.downloading(progress: 0)) }
                    return try await downloadFileWithAuth(from: dlURL, apiKey: apiKey, filename: "minimax_\(taskId.prefix(8)).mp4")
                }
                throw AIError.apiError("MiniMax 完成但无文件")
            } else if status == "Failed" {
                throw AIError.apiError("MiniMax 生成失败")
            }
        }
        throw AIError.timeout
    }

    // MARK: - Vidu 视频

    private func generateWithVidu(prompt: String, duration: String, aspectRatio: String, referenceImage: URL? = nil) async throws -> URL {
        let apiKey = settings.providerAPIKey(for: Provider.vidu.rawValue)
        guard !apiKey.isEmpty else {
            throw AIError.missingAPIKey("请先在设置中填写 Vidu 的 API Key")
        }

        let url = URL(string: "https://api.vidu.com/v1/tasks")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var inputDict: [String: Any] = ["prompt": prompt]
        let taskType: String
        if let imgURL = referenceImage, let b64 = imageToBase64DataURI(imgURL) {
            taskType = "img2video"
            inputDict["image"] = ["url": b64]
        } else {
            taskType = "text2video"
        }
        let body: [String: Any] = [
            "type": taskType,
            "model": "vidu-2.0",
            "input": inputDict,
            "output_params": ["duration": Int(duration) ?? 4, "aspect_ratio": aspectRatio]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw AIError.apiError("Vidu 请求失败")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let taskId = json?["id"] as? String else {
            throw AIError.apiError("Vidu 未返回任务 ID")
        }

        await MainActor.run { updateAssistantStatus(.generating(progress: "生成视频中…")) }

        for _ in 0..<120 {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            let pollURL = URL(string: "https://api.vidu.com/v1/tasks/\(taskId)")!
            var pollReq = URLRequest(url: pollURL)
            pollReq.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            let (pData, _) = try await URLSession.shared.data(for: pollReq)
            let pJson = try JSONSerialization.jsonObject(with: pData) as? [String: Any]
            let status = pJson?["status"] as? String ?? ""
            if status == "success" {
                if let output = pJson?["output"] as? [String: Any],
                   let videoURL = output["video_url"] as? String {
                    await MainActor.run { updateAssistantStatus(.downloading(progress: 0)) }
                    return try await downloadFile(from: videoURL, filename: "vidu_\(taskId.prefix(8)).mp4")
                }
                throw AIError.apiError("Vidu 完成但无视频")
            } else if status == "failed" {
                throw AIError.apiError("Vidu 生成失败")
            }
        }
        throw AIError.timeout
    }

    // MARK: - 下载文件

    private func downloadFile(from urlString: String, filename: String) async throws -> URL {
        guard let url = URL(string: urlString) else {
            throw AIError.apiError("无效的下载 URL")
        }

        let (tempURL, response) = try await URLSession.shared.download(from: url)
        guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
            throw AIError.apiError("下载失败")
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

    private func downloadFileWithAuth(from urlString: String, apiKey: String, filename: String) async throws -> URL {
        guard let url = URL(string: urlString) else {
            throw AIError.apiError("无效的下载 URL")
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (tempURL, response) = try await URLSession.shared.download(for: request)
        guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
            throw AIError.apiError("下载失败")
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

    private func createBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private func resolveBookmark(_ data: Data) -> URL? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private func resolveMediaURL(path: String?, bookmark: Data?) -> URL? {
        if let bm = bookmark, let url = resolveBookmark(bm) {
            return url
        }
        if let p = path, FileManager.default.fileExists(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        return nil
    }

    private func imageToBase64(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return data.base64EncodedString()
    }

    private func imageToBase64DataURI(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let ext = url.pathExtension.lowercased()
        let mime: String
        switch ext {
        case "png": mime = "image/png"
        case "webp": mime = "image/webp"
        default: mime = "image/jpeg"
        }
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }

    private func fileToBase64DataURI(_ url: URL, mime: String) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return "data:\(mime);base64,\(data.base64EncodedString())"
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
