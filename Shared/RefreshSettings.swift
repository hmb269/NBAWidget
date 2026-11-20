import Foundation
import Photos

// 小组件刷新间隔：在 App 设置里改，通过空相簿名传给小组件（「阿波设置·刷新·健康15·血糖60」）
struct RefreshSettings: Equatable {
    var health = 15     // 分钟
    var glucose = 60
    var theme = 0       // 小组件配色：见 WidgetThemes（0 跟随系统）
    var slots = HealthSlot.defaults   // 健康小组件右边 4 行显示什么

    static let healthOptions = [15, 30, 60]
    static let glucoseOptions = [30, 60, 120, 240, 480, 720]
    static let prefix = "阿波设置·刷新·"

    var albumTitle: String {
        Self.prefix + "健康\(health)·血糖\(glucose)" + (theme == 0 ? "" : "·外观\(theme)")
            + (slots == HealthSlot.defaults ? "" : "·行" + slots.map(\.rawValue).joined(separator: "-"))
    }

    init(health: Int = 15, glucose: Int = 60, theme: Int = 0) { self.health = health; self.glucose = glucose; self.theme = theme }

    init?(albumTitle t: String) {
        guard t.hasPrefix(Self.prefix) else { return nil }
        var r = RefreshSettings()
        for part in t.dropFirst(Self.prefix.count).split(separator: "·").map(String.init) {
            if part.hasPrefix("健康"), let n = Int(part.dropFirst(2)), Self.healthOptions.contains(n) { r.health = n }
            if part.hasPrefix("血糖"), let n = Int(part.dropFirst(2)), Self.glucoseOptions.contains(n) { r.glucose = n }
            if part.hasPrefix("行") {
                let s = part.dropFirst(1).split(separator: "-").compactMap { HealthSlot(rawValue: String($0)) }
                if s.count == 4 { r.slots = s }
            }
            if part.hasPrefix("外观"), let n = Int(part.dropFirst(2)), WidgetThemes.all.contains(where: { $0.id == n }) { r.theme = n }
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

/// 健康小组件可以选的项目
enum HealthSlot: String, CaseIterable, Identifiable {
    case weight = "wt", hrv = "hv", steps = "st", sun = "sn", vitals = "vt", temp = "tp",
         resting = "rh", spo2 = "o2", resp = "rr", kcal = "kc"

    var id: String { rawValue }
    static let defaults: [HealthSlot] = [.weight, .hrv, .steps, .vitals]

    var title: String {
        switch self {
        case .weight: return "体重"
        case .hrv: return "恢复HRV"
        case .steps: return "今日步数"
        case .sun: return "日出日落"
        case .vitals: return "生命体征"
        case .temp: return "体温"
        case .resting: return "静息心率"
        case .spo2: return "血氧"
        case .resp: return "呼吸频率"
        case .kcal: return "活动卡路里"
        }
    }

    /// 小组件上用的短名字（窄屏也放得下）
    var short: String {
        switch self {
        case .kcal: return "卡路里"
        case .resp: return "呼吸"
        case .steps: return "步数"
        default: return title
        }
    }

    var symbol: String {
        switch self {
        case .weight: return "figure"
        case .hrv: return "waveform.path.ecg"
        case .steps: return "figure.walk"
        case .sun: return "sun.horizon.fill"
        case .vitals: return "heart.text.square.fill"
        case .temp: return "thermometer.medium"
        case .resting: return "heart.fill"
        case .spo2: return "lungs.fill"
        case .resp: return "wind"
        case .kcal: return "flame.fill"
        }
    }
}
