// FalUpscaleService.swift
// fal.ai 云端视频超分（FlashVSR / SeedVR2）。
//
// 跟本地引擎的根本区别：整段视频上传上去跑，不是逐帧推理，所以没有帧级进度，
// 只能报"上传 → 排队 → 处理 → 下载"这几个阶段。费用走用户自己的 fal.ai Key。
//
// 完整链路（都是 fal 官方客户端在用的那套）：
//   1. POST rest.fal.ai/storage/upload/initiate  → 拿 {file_url, upload_url}
//   2. PUT  upload_url  直传文件字节
//   3. POST queue.fal.run/{endpoint}             → 拿 request_id
//   4. GET  .../requests/{id}/status             → 轮询到 COMPLETED
//   5. GET  .../requests/{id}                    → 拿结果里的视频 URL，下载回本地
import Foundation

enum FalUpscaleService {

    enum FalError: Error, LocalizedError {
        case missingKey
        case uploadFailed(String)
        case submitFailed(String)
        case pollFailed(String)
        case downloadFailed(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .missingKey:           return "请先在设置里填写 fal.ai API Key"
            case .uploadFailed(let d):  return "上传失败：\(d)"
            case .submitFailed(let d):  return "提交失败：\(d)"
            case .pollFailed(let d):    return "处理失败：\(d)"
            case .downloadFailed(let d):return "下载结果失败：\(d)"
            case .cancelled:            return "已取消"
            }
        }
    }

    /// 云端处理的阶段。没有帧级进度可报，只能按阶段推进——每个阶段自带一个
    /// 0…1 的分量，调用方拿去合成总进度
    enum Stage {
        case uploading(Double)     // 上传中，带已传比例
        case queued(Int)           // 排队中，带队列位置（拿不到时给 0）
        case processing            // fal 那边在跑
        case downloading(Double)   // 下载结果中，带已下载比例

        /// 映射到 0…1 的总进度。上传占前 25%，排队+处理占中间 65%，下载占最后 10%。
        /// 处理阶段拿不到真实百分比，固定停在 90% 而不是假装在动——进度条骗人比
        /// 不动更难受（这条跟本地引擎那次"进来就 20%"的教训是一回事）
        var overallProgress: Double {
            switch self {
            case .uploading(let p):   return 0.25 * min(max(p, 0), 1)
            case .queued:             return 0.30
            case .processing:         return 0.90
            case .downloading(let p): return 0.90 + 0.10 * min(max(p, 0), 1)
            }
        }

        var label: String {
            switch self {
            case .uploading:          return "上传中"
            case .queued(let pos):    return pos > 0 ? "排队中（第 \(pos) 位）" : "排队中"
            case .processing:         return "云端处理中"
            case .downloading:        return "下载结果中"
            }
        }
    }

    private static let restHost  = "https://rest.fal.ai"
    private static let queueHost = "https://queue.fal.run"

    // MARK: - 取消

    /// 当前在跑的 fal 任务，取消时用。同 ClarityFrameIO.currentProcess 的模式：
    /// 除了本地断开，还要 PUT 一下 fal 的 cancel 接口，否则任务在云端继续跑、
    /// 用户照样被扣钱
    private static let lock = NSLock()
    private static var _cancelled = false
    private static var _activeCancelURL: URL?

    static func beginTask() {
        lock.lock(); defer { lock.unlock() }
        _cancelled = false
        _activeCancelURL = nil
    }

    static func cancelCurrentTask() {
        lock.lock()
        _cancelled = true
        let url = _activeCancelURL
        _activeCancelURL = nil
        lock.unlock()
        // 通知 fal 停掉，失败也不管——本地已经标记取消，不会再用它的结果
        guard let url, let key = currentKey() else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("Key \(key)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: req).resume()
    }

    static var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }

    private static func setCancelURL(_ url: URL?) {
        lock.lock(); defer { lock.unlock() }
        _activeCancelURL = url
    }

    private static func checkCancelled() throws {
        if isCancelled { throw FalError.cancelled }
    }

    /// 取消路径可能在任意线程，不能同步跳 MainActor 去读 AppSettings，用一份缓存
    private static var cachedKey: String = ""
    private static func currentKey() -> String? {
        lock.lock(); defer { lock.unlock() }
        return cachedKey.isEmpty ? nil : cachedKey
    }

    // MARK: - 主流程

    /// 把一个视频文件送去 fal 超分，结果下载到 outputURL。
    /// - Parameter endpoint: `ClarityEngine.falEndpoint`，形如 `fal-ai/flashvsr/upscale/video`
    /// - Parameter onStage: 阶段回调，调用方拿去更新进度卡片
    static func upscale(inputURL: URL, outputURL: URL, endpoint: String,
                        upscaleFactor: Int, apiKey: String,
                        onStage: @escaping (Stage) -> Void) async throws {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw FalError.missingKey }
        lock.lock(); cachedKey = key; lock.unlock()

        try checkCancelled()
        let fileURL = try await uploadFile(inputURL, key: key) { onStage(.uploading($0)) }

        try checkCancelled()
        let requestID = try await submit(endpoint: endpoint, videoURL: fileURL,
                                         upscaleFactor: upscaleFactor, key: key)
        setCancelURL(URL(string: "\(queueHost)/\(endpoint)/requests/\(requestID)/cancel"))

        try await waitUntilDone(endpoint: endpoint, requestID: requestID, key: key, onStage: onStage)

        try checkCancelled()
        let resultURL = try await fetchResultURL(endpoint: endpoint, requestID: requestID, key: key)
        try await download(resultURL, to: outputURL) { onStage(.downloading($0)) }
        setCancelURL(nil)
    }

    // MARK: - 1/2：上传

    /// 两步直传：先跟 fal 换一个一次性 upload_url，再 PUT 文件字节上去。
    /// 不走 multipart——剪辑里单个片段通常几十到几百 MB，单次 PUT 够用
    private static func uploadFile(_ url: URL, key: String,
                                   onProgress: @escaping (Double) -> Void) async throws -> String {
        let contentType = "video/mp4"
        var initReq = URLRequest(url: URL(string: "\(restHost)/storage/upload/initiate?storage_type=fal-cdn-v3")!)
        initReq.httpMethod = "POST"
        initReq.setValue("Key \(key)", forHTTPHeaderField: "Authorization")
        initReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        initReq.httpBody = try JSONSerialization.data(withJSONObject: [
            "content_type": contentType,
            "file_name": url.lastPathComponent
        ])

        let (initData, initResp) = try await URLSession.shared.data(for: initReq)
        try ensureOK(initResp, initData, wrap: FalError.uploadFailed)
        guard let obj = try? JSONSerialization.jsonObject(with: initData) as? [String: Any],
              let uploadURLString = obj["upload_url"] as? String,
              let fileURLString = obj["file_url"] as? String,
              let uploadURL = URL(string: uploadURLString) else {
            throw FalError.uploadFailed("返回里没有 upload_url")
        }

        try checkCancelled()
        var putReq = URLRequest(url: uploadURL)
        putReq.httpMethod = "PUT"
        putReq.setValue(contentType, forHTTPHeaderField: "Content-Type")
        // 用 upload(fromFile:) 而不是把整个文件读进内存——一个 4K 片段几百 MB，
        // 读进 Data 就是白白多占一份内存
        onProgress(0)
        let (putData, putResp) = try await URLSession.shared.upload(for: putReq, fromFile: url)
        try ensureOK(putResp, putData, wrap: FalError.uploadFailed)
        onProgress(1)
        return fileURLString
    }

    // MARK: - 3：提交

    private static func submit(endpoint: String, videoURL: String,
                               upscaleFactor: Int, key: String) async throws -> String {
        var body: [String: Any] = [
            "video_url": videoURL,
            "upscale_factor": upscaleFactor
        ]
        // FlashVSR 能自己把原音轨拷进输出；SeedVR2 没这个参数，音轨得在调用方
        // 用 ffmpeg 合回去（见 ProjectState 那边）
        if endpoint.contains("flashvsr") {
            body["preserve_audio"] = true
        }

        var req = URLRequest(url: URL(string: "\(queueHost)/\(endpoint)")!)
        req.httpMethod = "POST"
        req.setValue("Key \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        try ensureOK(resp, data, wrap: FalError.submitFailed)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["request_id"] as? String else {
            throw FalError.submitFailed("返回里没有 request_id")
        }
        return id
    }

    // MARK: - 4：轮询

    /// 轮询到 COMPLETED。间隔 3 秒——云端超分动辄几分钟，轮太密只是白费请求
    private static func waitUntilDone(endpoint: String, requestID: String, key: String,
                                      onStage: @escaping (Stage) -> Void) async throws {
        let url = URL(string: "\(queueHost)/\(endpoint)/requests/\(requestID)/status")!
        while true {
            try checkCancelled()
            var req = URLRequest(url: url)
            req.setValue("Key \(key)", forHTTPHeaderField: "Authorization")
            let (data, resp) = try await URLSession.shared.data(for: req)
            try ensureOK(resp, data, wrap: FalError.pollFailed)
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = obj["status"] as? String else {
                throw FalError.pollFailed("状态返回解析不了")
            }
            switch status {
            case "COMPLETED":   return
            case "IN_PROGRESS": onStage(.processing)
            case "IN_QUEUE":    onStage(.queued(obj["queue_position"] as? Int ?? 0))
            default:            throw FalError.pollFailed("未知状态 \(status)")
            }
            try await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    // MARK: - 5：取结果 + 下载

    private static func fetchResultURL(endpoint: String, requestID: String, key: String) async throws -> URL {
        var req = URLRequest(url: URL(string: "\(queueHost)/\(endpoint)/requests/\(requestID)")!)
        req.setValue("Key \(key)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try ensureOK(resp, data, wrap: FalError.pollFailed)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let video = obj["video"] as? [String: Any],
              let urlString = video["url"] as? String,
              let url = URL(string: urlString) else {
            throw FalError.pollFailed("结果里没有视频地址")
        }
        return url
    }

    private static func download(_ url: URL, to dest: URL,
                                 onProgress: @escaping (Double) -> Void) async throws {
        onProgress(0)
        let (tmp, resp) = try await URLSession.shared.download(from: url)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FalError.downloadFailed("HTTP \(http.statusCode)")
        }
        try? FileManager.default.removeItem(at: dest)
        do { try FileManager.default.moveItem(at: tmp, to: dest) }
        catch { throw FalError.downloadFailed(error.localizedDescription) }
        onProgress(1)
    }

    // MARK: - 工具

    /// 非 2xx 一律当失败，并把响应体带进错误信息——fal 的报错（余额不足、
    /// Key 无效、素材太大）都写在 body 里，吞掉的话用户只能看到一个状态码
    private static func ensureOK(_ resp: URLResponse, _ data: Data,
                                 wrap: (String) -> FalError) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        guard !(200..<300).contains(http.statusCode) else { return }
        var detail = "HTTP \(http.statusCode)"
        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            detail += "：" + text.prefix(300)
        }
        throw wrap(detail)
    }
}
