// DownloadProgress.swift
// 带进度的文件下载。app 更新和模型下载共用。
//
// 这里有两个坑，都是实测撞出来的，别再走回头路：
//
// 1. **不能用 URLSession.bytes(for:) 逐字节读**。AsyncBytes 是一个字节一个字节
//    吐的，每个字节还要 Data.append 一次——65MB 的包就是 6800 万次循环，
//    388MB 的模型更甚，慢到看着像卡死。
//
// 2. **进度回调必须挂 session 级 delegate，不能用 async download 的 task 级
//    delegate 参数**。实测 `session.download(for:delegate:)` 那个 delegate
//    收不到 didWriteData：URLSession.shared 和自建 session 都是 **0 次回调**，
//    表现就是进度条一直 0%、下完直接跳 100%。换成
//    `URLSession(configuration:delegate:delegateQueue:)` 之后同一个文件收到 41 次。
import Foundation

enum DownloadProgress {

    /// 下载到临时文件并返回它的位置。调用方负责把它搬到最终位置。
    /// onProgress 在后台线程回调，0…1。
    static func download(_ request: URLRequest,
                         onProgress: @escaping (Double) -> Void) async throws -> (URL, URLResponse) {
        let delegate = ProgressDelegate(onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        return try await withCheckedThrowingContinuation { cont in
            delegate.completion = { cont.resume(with: $0) }
            session.downloadTask(with: request).resume()
        }
    }

    private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate {
        private let onProgress: (Double) -> Void
        var completion: ((Result<(URL, URLResponse), Error>) -> Void)?
        /// 保证只 resume 一次：出错和完成两条回调都可能到，continuation 重复
        /// resume 会直接崩
        private var finished = false

        init(onProgress: @escaping (Double) -> Void) {
            self.onProgress = onProgress
            super.init()
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            // 必须**在这个回调里**把文件搬走：函数一返回系统就删掉那个临时文件
            let dst = FileManager.default.temporaryDirectory
                .appendingPathComponent("dl-\(UUID().uuidString)")
            do {
                try FileManager.default.moveItem(at: location, to: dst)
                guard !finished else { return }
                finished = true
                completion?(.success((dst, downloadTask.response ?? URLResponse())))
            } catch {
                guard !finished else { return }
                finished = true
                completion?(.failure(error))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didCompleteWithError error: Error?) {
            guard let error, !finished else { return }
            finished = true
            completion?(.failure(error))
        }
    }
}
