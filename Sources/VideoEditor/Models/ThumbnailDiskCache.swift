// ThumbnailDiskCache.swift
//
// 时间轴视频缩略图的硬盘缓存。
//
// 缩略图原来只在内存里，每次打开项目都要把每个视频重新解码抽 200 张。
// 老项目素材一多，几个视频排着队抽，后面的要等十几二十秒才有画面
// （AVFoundation 一旦超时还会整轮切到更慢的 ffmpeg）。抽过一次就落盘，
// 下次打开直接读，不再解码。
//
// 缓存认的是**文件本身**：路径 + 大小 + 修改时间。文件被替换、重新导出过，
// 这三样有一样变了就自然失效，不用手动清。

import AppKit
import CryptoKit
import Foundation

enum ThumbnailDiskCache {

    /// 总量上限。每个视频 200 张小图约 1MB，这个量够几百个视频
    private static let maxBytes: Int64 = 400 * 1024 * 1024

    private static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("黑猫剪辑/thumb-cache", isDirectory: true)
    }

    private struct Stored: Codable {
        var times: [Double]
        var images: [Data]
    }

    private static let lock = NSLock()

    /// 路径 + 大小 + 修改时间 → 文件名。读不到属性（文件不在）就不缓存
    private static func key(for url: URL) -> String? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = a[.size] as? NSNumber,
              let mtime = a[.modificationDate] as? Date else { return nil }
        let raw = "\(url.standardizedFileURL.path)|\(size.int64Value)|\(mtime.timeIntervalSince1970)"
        let hash = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
        return String(hash.prefix(32))
    }

    /// 读缓存。没有、坏了、文件变了都返回 nil
    static func load(for url: URL) -> [ThumbnailFrame]? {
        guard let k = key(for: url) else { return nil }
        let file = dir.appendingPathComponent(k + ".plist")
        // 锁只罩读文件这一下（防跟写入、清理撞上）。原来连解码 200 张图也罩在里面，
        // 打开项目时几十个视频的缓存只能一个一个排队解，时间轴缩略图半天出不来
        lock.lock()
        let raw = try? Data(contentsOf: file)
        lock.unlock()
        guard let data = raw,
              let s = try? PropertyListDecoder().decode(Stored.self, from: data),
              s.times.count == s.images.count, !s.times.isEmpty else { return nil }
        var frames: [ThumbnailFrame] = []
        frames.reserveCapacity(s.times.count)
        for (t, d) in zip(s.times, s.images) {
            guard let img = NSImage(data: d) else { return nil }
            frames.append(ThumbnailFrame(time: t, image: img))
        }
        // 碰一下修改时间，清理时按「最近用过」保留
        lock.lock()
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        lock.unlock()
        return frames
    }

    /// 写缓存。在后台线程调
    static func save(_ frames: [ThumbnailFrame], for url: URL) {
        guard !frames.isEmpty, let k = key(for: url) else { return }
        var times: [Double] = []
        var images: [Data] = []
        for f in frames {
            guard let tiff = f.image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.75])
            else { continue }
            times.append(f.time)
            images.append(jpg)
        }
        guard !times.isEmpty else { return }
        let enc = PropertyListEncoder()
        enc.outputFormat = .binary
        guard let data = try? enc.encode(Stored(times: times, images: images)) else { return }
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appendingPathComponent(k + ".plist"), options: .atomic)
        prune()
    }

    // MARK: - 音频波形
    //
    // 波形也落盘，同一个目录、同一套「文件没变才算数」的认法，清理时跟缩略图一起算总量。
    // 原来每次打开都要把每个音频整段解码一遍，启动那阵子几十个视频正在抽缩略图，
    // 系统音频解码排不上队，长一点的音乐每个都要干等 8 秒超时再换 ffmpeg 重来。
    // 格式：8 字节时长（Double）+ 峰值数组（Float32），一首三分钟的歌约 16KB

    static func loadWaveform(for url: URL) -> WaveformData? {
        guard let k = key(for: url) else { return nil }
        let file = dir.appendingPathComponent(k + ".wave")
        lock.lock()
        let raw = try? Data(contentsOf: file)
        if raw != nil {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        }
        lock.unlock()
        let head = MemoryLayout<Double>.size
        guard let data = raw, data.count > head,
              (data.count - head) % MemoryLayout<Float>.size == 0 else { return nil }
        let dur = data.prefix(head).withUnsafeBytes { $0.loadUnaligned(as: Double.self) }
        let samples: [Float] = data.dropFirst(head).withUnsafeBytes { buf in
            (0..<(buf.count / MemoryLayout<Float>.size)).map {
                buf.loadUnaligned(fromByteOffset: $0 * MemoryLayout<Float>.size, as: Float.self)
            }
        }
        guard dur > 0, !samples.isEmpty else { return nil }
        return WaveformData(totalDuration: dur, samples: samples)
    }

    static func saveWaveform(_ w: WaveformData, for url: URL) {
        guard w.totalDuration > 0, !w.samples.isEmpty, let k = key(for: url) else { return }
        var data = Data()
        withUnsafeBytes(of: w.totalDuration) { data.append(contentsOf: $0) }
        w.samples.withUnsafeBytes { data.append(contentsOf: $0) }
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appendingPathComponent(k + ".wave"), options: .atomic)
        prune()
    }

    /// 超过上限就从最久没用过的开始删
    private static func prune() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys:
                [.fileSizeKey, .contentModificationDateKey]) else { return }
        var entries: [(url: URL, size: Int64, date: Date)] = items.compactMap { u in
            guard let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (u, Int64(v.fileSize ?? 0), v.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > maxBytes else { return }
        entries.sort { $0.date < $1.date }
        for e in entries where total > maxBytes {
            try? fm.removeItem(at: e.url)
            total -= e.size
        }
    }
}
