import SwiftUI
import AVFoundation

/// 全局素材库（v5.1.0）
///
/// 素材从「每个项目一份」改成「全 app 一份」。`ProjectState.mediaAssets` 现在只是
/// 转发到这里，所有窗口共用同一个数组。
///
/// **为什么 id 必须稳定**：时间轴片段靠 `assetID` 找素材。老的全局备份（UserDefaults
/// 里那串 bookmark）恢复时是现造 `MediaAsset`，每次启动 id 都不一样 —— 所以以前打开
/// 项目必须以 .bcj 里那份为准，全局备份只在新建项目时凑合用。这里把 id 一起存盘，
/// 重启后不变，全局库才能当唯一数据源。
final class MediaLibrary: ObservableObject {

    static let shared = MediaLibrary()

    /// 全局素材列表。多窗口共享同一份
    @Published var assets: [MediaAsset] = [] {
        didSet { scheduleSave() }
    }

    /// 保持 security scope 的 URL，app 活着期间不释放
    private var accessedURLs: [URL] = []
    private var saveWorkItem: DispatchWorkItem?

    private init() {
        // 测试环境不碰真实素材库文件：这是全局单例，测试里增删会直接写回
        // 用户的 media_library.json，把人家的素材库毁了
        guard !DiagLog.isUnitTesting else { return }
        load()
    }

    // MARK: - 持久化

    /// 存盘用的一条记录。比 `MediaAsset` 多一个 bookmark —— 沙盒下光有路径读不了文件
    private struct StoredAsset: Codable {
        var id: UUID
        var path: String
        var name: String
        var type: AssetType
        var duration: Double
        var importDate: Date?
        var fileSize: Int64?
        var bookmark: Data?
    }

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BlackCat")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("media_library.json")
    }

    /// 老格式：UserDefaults 里一串裸 bookmark，没有 id 也没有元数据
    private static let legacyKey = "savedMediaBookmarks"

    /// 写盘节流。批量导入时 `assets` 会连着变很多次，没必要每次都落盘
    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.save() }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    func save() {
        guard !DiagLog.isUnitTesting else { return }
        let stored: [StoredAsset] = assets.map { a in
            StoredAsset(id: a.id,
                        path: a.url.path,
                        name: a.name,
                        type: a.type,
                        duration: a.duration,
                        importDate: a.importDate,
                        fileSize: a.fileSize,
                        bookmark: try? a.url.bookmarkData(options: .withSecurityScope,
                                                          includingResourceValuesForKeys: nil,
                                                          relativeTo: nil))
        }
        guard let data = try? JSONEncoder().encode(stored) else {
            DiagLog.log("[素材库] 编码失败，未保存")
            return
        }
        do {
            try data.write(to: fileURL)
        } catch {
            DiagLog.log("[素材库] 写盘失败：\(error.localizedDescription)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode([StoredAsset].self, from: data) else {
            migrateFromLegacyDefaults()
            return
        }

        var restored: [MediaAsset] = []
        for s in stored {
            var url = URL(fileURLWithPath: s.path)
            if let bm = s.bookmark {
                var isStale = false
                if let resolved = try? URL(resolvingBookmarkData: bm,
                                           options: .withSecurityScope,
                                           relativeTo: nil,
                                           bookmarkDataIsStale: &isStale) {
                    url = resolved
                    if resolved.startAccessingSecurityScopedResource() {
                        accessedURLs.append(resolved)
                    } else {
                        DiagLog.log("[素材库] security-scoped 访问被拒 \(resolved.lastPathComponent)")
                    }
                }
            }
            // 文件不在了也保留条目 —— 让用户看得见「丢失」并能重新链接，
            // 直接丢掉的话时间轴片段会莫名其妙找不到源
            restored.append(MediaAsset(id: s.id, url: url, name: s.name, type: s.type,
                                       duration: s.duration, importDate: s.importDate,
                                       fileSize: s.fileSize))
        }
        assets = restored
        saveWorkItem?.cancel()   // load 触发的 didSet 不必回写
    }

    /// 从老的 UserDefaults bookmark 数组迁移一次。老数据没有 id，只能新生成 —— 反正
    /// 它以前每次启动就在变，项目里的引用本来就不靠它
    private func migrateFromLegacyDefaults() {
        guard let dataArray = UserDefaults.standard.array(forKey: Self.legacyKey) as? [Data],
              !dataArray.isEmpty else { return }

        var migrated: [MediaAsset] = []
        for bm in dataArray {
            var isStale = false
            guard let url = try? URL(resolvingBookmarkData: bm,
                                     options: .withSecurityScope,
                                     relativeTo: nil,
                                     bookmarkDataIsStale: &isStale) else { continue }
            guard url.startAccessingSecurityScopedResource() else { continue }
            accessedURLs.append(url)
            let ext = url.pathExtension.lowercased()
            guard let type = ProjectState.assetType(for: ext) else { continue }
            guard !migrated.contains(where: { $0.url == url }) else { continue }
            migrated.append(MediaAsset(url: url, name: url.lastPathComponent, type: type))
        }
        guard !migrated.isEmpty else { return }
        assets = migrated
        save()
        UserDefaults.standard.removeObject(forKey: Self.legacyKey)
        DiagLog.log("[素材库] 从旧 UserDefaults 迁移了 \(migrated.count) 条")
    }

    // MARK: - 合并（打开项目时用）

    /// 把项目文件里带的素材并进全局库，返回 **旧 id → 全局 id** 的映射。
    ///
    /// 同一个文件在全局库里已经有一条时，不新增也不改全局那条的 id —— 改了会让**别的**
    /// 项目的片段引用失效。改的是这次打开的项目：调用方拿映射把片段的 `assetID` 换过去。
    @discardableResult
    func merge(_ incoming: [MediaAsset]) -> [UUID: UUID] {
        var remap: [UUID: UUID] = [:]
        var added: [MediaAsset] = []

        for asset in incoming {
            if let existing = assets.first(where: { $0.url == asset.url }) {
                if existing.id != asset.id { remap[asset.id] = existing.id }
            } else if let pending = added.first(where: { $0.url == asset.url }) {
                if pending.id != asset.id { remap[asset.id] = pending.id }
            } else {
                added.append(asset)
                if asset.url.startAccessingSecurityScopedResource() {
                    accessedURLs.append(asset.url)
                }
            }
        }

        if !added.isEmpty { assets.append(contentsOf: added) }
        return remap
    }

    // MARK: - 增删

    func add(_ asset: MediaAsset) {
        guard !assets.contains(where: { $0.url == asset.url }) else { return }
        assets.append(asset)
    }

    func remove(id: UUID) {
        assets.removeAll { $0.id == id }
    }

    func removeAll() {
        assets.removeAll()
    }

    /// 仅供单元测试：把全局库清干净，避免用例之间互相串。
    /// 生产代码别调 —— 清空素材库走 `removeAll()` 那条带确认的路径
    func resetForTesting() {
        assert(DiagLog.isUnitTesting, "resetForTesting 只能在测试里用")
        saveWorkItem?.cancel()
        assets.removeAll()
        accessedURLs.removeAll()
    }
}
