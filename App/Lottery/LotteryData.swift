import SwiftUI

// 彩票开奖数据：福彩来自中国福利彩票官网（cwl.gov.cn），体彩来自中国体育彩票官网（sporttery.cn）

enum LotteryGame: String, CaseIterable, Identifiable, Codable {
    case ssq, d3 = "3d", qlc, kl8      // 福彩
    case dlt, pl3, pl5, qxc            // 体彩
    var id: String { rawValue }

    var name: String {
        switch self {
        case .ssq: return "双色球"
        case .d3: return "福彩3D"
        case .qlc: return "七乐彩"
        case .kl8: return "快乐8"
        case .dlt: return "超级大乐透"
        case .pl3: return "排列3"
        case .pl5: return "排列5"
        case .qxc: return "七星彩"
        }
    }

    var isWelfare: Bool { [.ssq, .d3, .qlc, .kl8].contains(self) }
    static var welfare: [LotteryGame] { [.ssq, .d3, .qlc, .kl8] }
    static var sports: [LotteryGame] { [.dlt, .pl3, .pl5, .qxc] }

    /// 开奖时间（北京时间）：福彩 21:15（快乐8 21:30），体彩 21:25
    var drawTime: (hour: Int, minute: Int) {
        switch self {
        case .kl8: return (21, 30)
        case .ssq, .d3, .qlc: return (21, 15)
        default: return (21, 25)
        }
    }

    /// 开奖的星期（1 = 周日）
    var drawWeekdays: Set<Int> {
        switch self {
        case .ssq: return [3, 5, 1]
        case .qlc: return [2, 4, 6]
        case .dlt: return [2, 4, 7]
        case .qxc: return [3, 6, 1]
        default: return [1, 2, 3, 4, 5, 6, 7]
        }
    }

    var timeText: String { String(format: "%02d:%02d", drawTime.hour, drawTime.minute) }

    var schedule: String {
        switch self {
        case .ssq: return "每周二、四、日 " + timeText
        case .qlc: return "每周一、三、五 " + timeText
        case .dlt: return "每周一、三、六 " + timeText
        case .qxc: return "每周二、五、日 " + timeText
        default: return "每天 " + timeText
        }
    }

    /// 某天的开奖时刻
    func drawDate(on day: Date) -> Date {
        let cal = Calendar.current
        return cal.date(bySettingHour: drawTime.hour, minute: drawTime.minute, second: 0, of: day) ?? day
    }

    func isDrawDay(_ day: Date) -> Bool { drawWeekdays.contains(Calendar.current.component(.weekday, from: day)) }

    /// 下一次开奖（今天还没到点就是今天）
    func nextDraw(after now: Date = Date()) -> Date {
        let cal = Calendar.current
        for i in 0..<8 {
            let day = cal.date(byAdding: .day, value: i, to: now)!
            let t = drawDate(on: day)
            if isDrawDay(day) && t > now { return t }
        }
        return now
    }

    /// 体彩接口的游戏编号
    var sportteryNo: String? {
        switch self {
        case .dlt: return "85"
        case .pl3: return "35"
        case .pl5: return "350133"
        case .qxc: return "04"
        default: return nil
        }
    }

    /// 后区（蓝球）个数，用于把体彩的开奖号码拆开
    var backCount: Int {
        switch self {
        case .dlt: return 2
        case .qxc: return 1
        default: return 0
        }
    }

    var hasPool: Bool { ![.d3, .pl3].contains(self) }

    /// 支持拍照自动对奖的
    var checkable: Bool { [.ssq, .dlt, .kl8, .qxc].contains(self) }
    static var checkableGames: [LotteryGame] { [.ssq, .dlt, .kl8, .qxc] }
    var shortName: String { self == .dlt ? "大乐透" : name }

    var frontColor: Color {
        switch self {
        case .dlt, .pl3, .pl5, .qxc: return Color(red: 0.25, green: 0.55, blue: 1.0)
        default: return Color(red: 0.95, green: 0.25, blue: 0.30)
        }
    }
    var backColor: Color {
        switch self {
        case .dlt, .qxc: return Color(red: 1.0, green: 0.70, blue: 0.20)
        default: return Color(red: 0.25, green: 0.50, blue: 1.0)
        }
    }
}

struct LotteryPrize: Codable, Hashable {
    var name: String
    var count: String      // 注数
    var amount: String     // 单注奖金（元）
}

struct LotteryDraw: Codable, Identifiable, Hashable {
    var issue: String
    var date: String
    var front: [String]
    var back: [String]
    var pool: Double?      // 奖池（元）
    var sales: Double?
    var prizes: [LotteryPrize]
    var winners: String? = nil   // 一等奖中奖地（福彩公告里有）
    var id: String { issue }

    /// 开奖日期（yyyy-MM-dd 部分）是不是今天
    var isToday: Bool {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return date.hasPrefix(f.string(from: Date()))
    }

    func prize(_ name: String) -> LotteryPrize? {
        prizes.first { $0.name == name } ?? prizes.first { $0.name.hasPrefix(name) && !$0.name.contains("追加") }
    }
}

enum LotteryFormat {
    static func money(_ v: Double?) -> String {
        guard let v else { return "—" }
        if v >= 1e8 { return String(format: "%.2f 亿", v / 1e8) }
        if v >= 1e4 { return String(format: "%.0f 万", v / 1e4) }
        return String(format: "%.0f 元", v)
    }

    static func yuan(_ s: String) -> String {
        guard let v = Double(s.replacingOccurrences(of: ",", with: "")) else { return s.isEmpty ? "—" : s }
        if v >= 1e4 { return String(format: "%.0f", v).groupedThousands + " 元" }
        return String(format: "%.0f 元", v)
    }

    static func number(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String { return Double(s.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)) }
        if let n = any as? NSNumber { return n.doubleValue }
        return nil
    }

    static func string(_ any: Any?) -> String {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return ""
    }
}

extension String {
    var groupedThousands: String {
        guard let v = Int(self) else { return self }
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: v)) ?? self
    }
}

enum LotteryAPI {
    struct APIError: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }

    private static let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    static func history(_ g: LotteryGame, count: Int = 30) async throws -> [LotteryDraw] {
        let list = g.isWelfare ? try await welfare(g, count: count) : try await sports(g, count: count)
        cache(list, for: g)
        return list
    }

    // MARK: 福彩

    private static func welfare(_ g: LotteryGame, count: Int) async throws -> [LotteryDraw] {
        var comp = URLComponents(string: "https://www.cwl.gov.cn/cwl_admin/front/cwlkj/search/kjxx/findDrawNotice")!
        comp.queryItems = [
            URLQueryItem(name: "name", value: g.rawValue),
            URLQueryItem(name: "pageNo", value: "1"),
            URLQueryItem(name: "pageSize", value: "\(count)"),
            URLQueryItem(name: "systemType", value: "PC"),
        ]
        var req = URLRequest(url: comp.url!, timeoutInterval: 15)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("https://www.cwl.gov.cn/", forHTTPHeaderField: "Referer")
        req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let result = obj["result"] as? [[String: Any]] else {
            throw APIError(text: "福彩官网没有返回数据（可能被网站拦截了，稍后再试）")
        }
        return result.map { r in
            let grades = (r["prizegrades"] as? [[String: Any]]) ?? []
            let prizes: [LotteryPrize] = grades.compactMap { p in
                let type = Int(LotteryFormat.string(p["type"])) ?? 0
                let name = welfarePrizeName(g, type: type)
                let cnt = LotteryFormat.string(p["typenum"])
                let money = LotteryFormat.string(p["typemoney"])
                if cnt.isEmpty && money.isEmpty { return nil }
                return LotteryPrize(name: name, count: cnt, amount: money)
            }
            let date = LotteryFormat.string(r["date"])
            return LotteryDraw(
                issue: LotteryFormat.string(r["code"]),
                date: date,
                front: LotteryFormat.string(r["red"]).split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) },
                back: LotteryFormat.string(r["blue"]).split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                pool: LotteryFormat.number(r["poolmoney"]),
                sales: LotteryFormat.number(r["sales"]),
                prizes: prizes,
                winners: cleanWinners(LotteryFormat.string(r["content"]))
            )
        }
    }

    /// 「北京1注,河北2注,共3注。」→「北京 1 注、河北 2 注」
    private static func cleanWinners(_ s: String) -> String? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if let r = t.range(of: "共") { t = String(t[..<r.lowerBound]) }
        t = t.replacingOccurrences(of: "，", with: ",").replacingOccurrences(of: "。", with: "")
        let parts = t.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return parts.isEmpty ? s : parts.joined(separator: "、")
    }

    private static func welfarePrizeName(_ g: LotteryGame, type: Int) -> String {
        let cn = ["", "一", "二", "三", "四", "五", "六", "七", "八", "九", "十"]
        switch g {
        case .d3:
            return [1: "直选", 2: "组三", 3: "组六"][type] ?? "奖级\(type)"
        case .ssq:
            if type == 7 { return "福运奖" }
            return type >= 1 && type <= 6 ? "\(cn[type])等奖" : "奖级\(type)"
        case .qlc:
            return type >= 1 && type <= 7 ? "\(cn[type])等奖" : "奖级\(type)"
        default:
            return type >= 1 && type < cn.count ? "\(cn[type])等奖" : "奖级\(type)"
        }
    }

    // MARK: 体彩

    private static func sports(_ g: LotteryGame, count: Int) async throws -> [LotteryDraw] {
        var comp = URLComponents(string: "https://webapi.sporttery.cn/gateway/lottery/getHistoryPageListV1.qry")!
        comp.queryItems = [
            URLQueryItem(name: "gameNo", value: g.sportteryNo),
            URLQueryItem(name: "provinceId", value: "0"),
            URLQueryItem(name: "pageSize", value: "\(count)"),
            URLQueryItem(name: "isVerify", value: "1"),
            URLQueryItem(name: "pageNo", value: "1"),
        ]
        var req = URLRequest(url: comp.url!, timeoutInterval: 15)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("https://static.sporttery.cn/", forHTTPHeaderField: "Referer")
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let value = obj["value"] as? [String: Any],
              let list = value["list"] as? [[String: Any]] else {
            throw APIError(text: "体彩官网没有返回数据（可能被网站拦截了，稍后再试）")
        }
        return list.map { r in
            let nums = LotteryFormat.string(r["lotteryDrawResult"]).split(separator: " ").map(String.init)
            let bc = min(g.backCount, nums.count)
            let levels = (r["prizeLevelList"] as? [[String: Any]]) ?? []
            let prizes = levels.map { p in
                LotteryPrize(name: LotteryFormat.string(p["prizeLevel"]),
                             count: LotteryFormat.string(p["stakeCount"]),
                             amount: LotteryFormat.string(p["stakeAmount"]))
            }
            return LotteryDraw(
                issue: LotteryFormat.string(r["lotteryDrawNum"]),
                date: LotteryFormat.string(r["lotteryDrawTime"]),
                front: Array(nums.dropLast(bc)),
                back: Array(nums.suffix(bc)),
                pool: LotteryFormat.number(r["poolBalanceAfterdraw"]),
                sales: LotteryFormat.number(r["totalSaleAmount"]),
                prizes: prizes
            )
        }
    }

    // MARK: 缓存（没网时也能看上次的）

    static func cached(_ g: LotteryGame) -> [LotteryDraw] {
        guard let data = UserDefaults.standard.data(forKey: "lottery_" + g.rawValue),
              let list = try? JSONDecoder().decode([LotteryDraw].self, from: data) else { return [] }
        return list
    }

    private static func cache(_ list: [LotteryDraw], for g: LotteryGame) {
        guard !list.isEmpty, let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: "lottery_" + g.rawValue)
    }

    /// 期号统一成 7 位数字比较（大乐透 26126 → 2026126）
    static func issueNumber(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let v = Int(t) else { return nil }
        return t.count == 5 ? 2_000_000 + v : v
    }

    /// 多期：从 from 到 to（含），或者从 from 起连续 periods 期。返回已开奖的期和还没开奖的期数
    static func draws(_ g: LotteryGame, from: String, to: String?, periods: Int?) async throws -> (draws: [LotteryDraw], pending: Int) {
        guard let a = issueNumber(from) else { return ([], 0) }
        let b = to.flatMap(issueNumber)
        var list = cached(g)
        let nums = list.compactMap { issueNumber($0.issue) }
        let latest = nums.max() ?? 0, oldest = nums.min() ?? Int.max
        if list.isEmpty || (b ?? a) > latest || a < oldest || periods != nil {
            list = try await history(g, count: 100)
        }
        let sorted = list.sorted { (issueNumber($0.issue) ?? 0) < (issueNumber($1.issue) ?? 0) }
        let newest = sorted.last.flatMap { issueNumber($0.issue) } ?? 0
        if let n = periods, n > 1 {
            let picked = Array(sorted.filter { (issueNumber($0.issue) ?? 0) >= a }.prefix(n))
            return (picked, max(0, n - picked.count))
        }
        let end = b ?? a
        let lo = min(a, end), hi = max(a, end)
        let picked = sorted.filter { let v = issueNumber($0.issue) ?? 0; return v >= lo && v <= hi }
        // 同一年内还没开的期数
        let pending = hi > newest ? hi - max(lo, newest + 1) + 1 : 0
        return (picked, max(0, pending))
    }

    /// 找某一期：先找缓存，没有就多拉一些
    static func draw(_ g: LotteryGame, issue: String) async throws -> LotteryDraw? {
        let match = { (d: LotteryDraw) in d.issue == issue || d.issue.hasSuffix(issue) || issue.hasSuffix(d.issue) }
        if let d = cached(g).first(where: match) { return d }
        let list = try await history(g, count: 100)
        return list.first(where: match)
    }
}
