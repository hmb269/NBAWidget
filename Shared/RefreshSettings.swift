import Foundation
import Photos

// 小组件刷新间隔：在 App 设置里改，通过空相簿名传给小组件（「阿波设置·刷新·健康15·血糖60」）
struct RefreshSettings: Equatable {
    var health = 15     // 分钟
    var glucose = 60

    static let healthOptions = [15, 30, 60]
    static let glucoseOptions = [30, 60, 120]
    static let prefix = "阿波设置·刷新·"

    var albumTitle: String { Self.prefix + "健康\(health)·血糖\(glucose)" }

    init(health: Int = 15, glucose: Int = 60) { self.health = health; self.glucose = glucose }

    init?(albumTitle t: String) {
        guard t.hasPrefix(Self.prefix) else { return nil }
        var r = RefreshSettings()
        for part in t.dropFirst(Self.prefix.count).split(separator: "·").map(String.init) {
            if part.hasPrefix("健康"), let n = Int(part.dropFirst(2)), Self.healthOptions.contains(n) { r.health = n }
            if part.hasPrefix("血糖"), let n = Int(part.dropFirst(2)), Self.glucoseOptions.contains(n) { r.glucose = n }
        }
        self = r
    }

    private static let key = "refreshSettingsTitle"
    static var current: RefreshSettings {
        UserDefaults.standard.string(forKey: key).flatMap(RefreshSettings.init(albumTitle:)) ?? RefreshSettings()
    }
    static var savedTitle: String? { UserDefaults.standard.string(forKey: "refreshSettingsSaved") }

    private static func album() -> PHAssetCollection? {
        let st = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard st == .authorized || st == .limited else { return nil }
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "title BEGINSWITH %@", prefix)
        return PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: opts).firstObject
    }

    /// 小组件里调用
    static func refreshFromAlbum() {
        if let t = album()?.localizedTitle, RefreshSettings(albumTitle: t) != nil {
            UserDefaults.standard.set(t, forKey: key)
        }
    }

    /// App 里调用
    static func save(_ s: RefreshSettings) async throws {
        UserDefaults.standard.set(s.albumTitle, forKey: key)
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw NSError(domain: "阿波", code: 1, userInfo: [NSLocalizedDescriptionKey: "没有相册权限，小组件读不到设置"])
        }
        let title = s.albumTitle
        if let col = album() {
            if col.localizedTitle != title {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCollectionChangeRequest(for: col)?.title = title
                }
            }
        } else {
            try await PHPhotoLibrary.shared().performChanges {
                _ = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            }
        }
        UserDefaults.standard.set(title, forKey: "refreshSettingsSaved")
    }
}
