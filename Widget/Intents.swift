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
