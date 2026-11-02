import AppIntents
import WidgetKit

enum DayOption: String {
    case today
    case tomorrow

    var offset: Int { self == .tomorrow ? 1 : 0 }
}

/// 小组件上的翻页按钮
struct PageIntent: AppIntent {
    static var title: LocalizedStringResource = "翻页"
    static var isDiscoverable: Bool = false

    @Parameter(title: "日期") var day: String
    @Parameter(title: "尺寸") var family: String
    @Parameter(title: "方向") var delta: Int

    init() {}

    init(day: String, family: String, delta: Int) {
        self.day = day
        self.family = family
        self.delta = delta
    }

    func perform() async throws -> some IntentResult {
        if delta == 0 {
            GameCache.expireAll() // 只有一页：点一下重新拉数据
        } else {
            PageStore.shift(day: day, family: family, delta: delta)
        }
        return .result()
    }
}

/// 每个「日期 + 尺寸」记住自己在第几页，换天自动回到第 1 页
enum PageStore {
    private static let d = UserDefaults.standard
    private static func key(_ day: String, _ family: String) -> String { "page_\(day)_\(family)" }

    static func current(day: String, family: String, dateKey: String, total: Int) -> Int {
        let k = key(day, family)
        if d.string(forKey: k + "_date") != dateKey {
            d.set(0, forKey: k)
            d.set(dateKey, forKey: k + "_date")
        }
        d.set(total, forKey: k + "_total")
        return min(max(0, d.integer(forKey: k)), max(0, total - 1))
    }

    static func shift(day: String, family: String, delta: Int) {
        let k = key(day, family)
        let total = max(1, d.integer(forKey: k + "_total"))
        let p = d.integer(forKey: k) + delta
        d.set(((p % total) + total) % total, forKey: k) // 循环翻页
    }
}

/// 小组件自己记住的喜欢的球队（不需要和 App 共享）
enum WidgetFavorites {
    private static let d = UserDefaults.standard
    private static let key = "widgetFavorites"

    static var all: Set<String> { Set(d.stringArray(forKey: key) ?? []) }

    static func toggle(_ code: String) {
        var f = all
        if f.contains(code) { f.remove(code) } else { f.insert(code) }
        d.set(f.sorted(), forKey: key)
    }

    /// 收藏模式：开了 2 分钟没关就自动退出
    private static func editKey(_ day: String, _ family: String) -> String { "edit_\(day)_\(family)" }

    static func isEditing(day: String, family: String) -> Bool {
        guard let t = d.object(forKey: editKey(day, family)) as? Date else { return false }
        return Date().timeIntervalSince(t) < 120
    }

    static func toggleEditing(day: String, family: String) {
        if isEditing(day: day, family: family) {
            d.removeObject(forKey: editKey(day, family))
        } else {
            d.set(Date(), forKey: editKey(day, family))
        }
    }
}

/// 右上角 ☆ / ✓：进入或退出收藏模式
struct ToggleEditIntent: AppIntent {
    static var title: LocalizedStringResource = "收藏模式"
    static var isDiscoverable: Bool = false

    @Parameter(title: "日期") var day: String
    @Parameter(title: "尺寸") var family: String

    init() {}
    init(day: String, family: String) {
        self.day = day
        self.family = family
    }

    func perform() async throws -> some IntentResult {
        WidgetFavorites.toggleEditing(day: day, family: family)
        return .result()
    }
}

/// 收藏模式下点球队名
struct ToggleFavoriteIntent: AppIntent {
    static var title: LocalizedStringResource = "收藏球队"
    static var isDiscoverable: Bool = false

    @Parameter(title: "球队") var code: String

    init() {}
    init(code: String) { self.code = code }

    func perform() async throws -> some IntentResult {
        WidgetFavorites.toggle(code)
        return .result()
    }
}
