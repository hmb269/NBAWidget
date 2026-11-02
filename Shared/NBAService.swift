import Foundation

struct Game: Codable, Identifiable, Hashable {
    let id: String
    let time: Date
    let state: String      // pre / in / post
    let detail: String
    let home: String
    let away: String
    let homeScore: Int
    let awayScore: Int
    let homeCode: String   // 统一后的球队代码，例如 GSW
    let awayCode: String

    func involves(_ favorites: Set<String>) -> Bool {
        favorites.contains(homeCode) || favorites.contains(awayCode)
    }

    var isPostponed: Bool { detail.localizedCaseInsensitiveContains("postpon") }
    var isCanceled: Bool { detail.localizedCaseInsensitiveContains("cancel") }

    /// 中间那一栏：开赛时间 / 比分 / 推迟
    var middleText: String {
        if state == "pre" { return NBAService.timeString(time) }
        if isPostponed { return "推迟" }
        if isCanceled { return "取消" }
        return "\(awayScore)-\(homeScore)"
    }

    /// 进行中的节次，例如 Q3 5:12
    var liveText: String {
        detail
            .replacingOccurrences(of: "Halftime", with: "中场")
            .replacingOccurrences(of: "End of ", with: "")
    }
}

enum NBAService {
    static let teams: [String: String] = [
        "ATL": "老鹰", "BOS": "凯尔特人", "BKN": "篮网", "CHA": "黄蜂", "CHI": "公牛",
        "CLE": "骑士", "DAL": "独行侠", "DEN": "掘金", "DET": "活塞", "GS": "勇士", "GSW": "勇士",
        "HOU": "火箭", "IND": "步行者", "LAC": "快船", "LAL": "湖人", "MEM": "灰熊",
        "MIA": "热火", "MIL": "雄鹿", "MIN": "森林狼", "NO": "鹈鹕", "NOP": "鹈鹕",
        "NY": "尼克斯", "NYK": "尼克斯", "OKC": "雷霆", "ORL": "魔术", "PHI": "76人",
        "PHX": "太阳", "POR": "开拓者", "SAC": "国王", "SA": "马刺", "SAS": "马刺",
        "TOR": "猛龙", "UTAH": "爵士", "UTA": "爵士", "WSH": "奇才", "WAS": "奇才"
    ]

    /// ESPN 有时用短代码，统一成一种
    static func canonical(_ abbr: String) -> String {
        let map = ["GS": "GSW", "NO": "NOP", "NY": "NYK", "SA": "SAS", "UTAH": "UTA", "WSH": "WAS"]
        return map[abbr] ?? abbr
    }

    /// App 里选球队用（东部 / 西部）
    static let east = ["ATL", "BOS", "BKN", "CHA", "CHI", "CLE", "DET", "IND", "MIA", "MIL", "NYK", "ORL", "PHI", "TOR", "WAS"]
    static let west = ["DAL", "DEN", "GSW", "HOU", "LAC", "LAL", "MEM", "MIN", "NOP", "OKC", "PHX", "POR", "SAC", "SAS", "UTA"]

    static let beijing = TimeZone(identifier: "Asia/Shanghai") ?? TimeZone(secondsFromGMT: 8 * 3600)!

    /// 小组件刷新时间有限，整个请求最多等 10 秒
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8
        c.timeoutIntervalForResource = 10
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = beijing
        f.dateFormat = "yyyyMMdd"
        return f.string(from: date)
    }

    static func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = beijing
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    static func dateLabel(_ date: Date, withWeekday: Bool) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = beijing
        let c = cal.dateComponents([.month, .day, .weekday], from: date)
        let base = "\(c.month ?? 0)/\(c.day ?? 0)"
        guard withWeekday, let w = c.weekday else { return base }
        let names = ["日", "一", "二", "三", "四", "五", "六"]
        return base + " 周" + names[(w - 1) % 7]
    }

    /// offset: 0 = 今天, 1 = 明天（北京时间；中国没有夏令时，直接加 86400 秒）
    static func targetDate(offset: Int, now: Date = Date()) -> Date {
        now.addingTimeInterval(Double(offset) * 86400)
    }

    static func fetch(offset: Int) async throws -> [Game] {
        let target = targetDate(offset: offset)
        let targetKey = dayKey(target)
        // 北京时间某天的比赛，基本都在美国日期的前一天
        let usDates = [usKey(target.addingTimeInterval(-86400)), usKey(target)]
        async let a = fetchDay(usDates[0])
        async let b = fetchDay(usDates[1])
        let all = try await a + b
        var seen = Set<String>()
        var out: [Game] = []
        for g in all where !seen.contains(g.id) && dayKey(g.time) == targetKey {
            seen.insert(g.id)
            out.append(g)
        }
        return out.sorted { $0.time < $1.time }
    }

    private static func usKey(_ date: Date) -> String {
        // ESPN 的 dates 参数是美国日期；用同一个北京日期字符串即可（前一天 + 当天都会查）
        dayKey(date)
    }

    private static func fetchDay(_ key: String) async throws -> [Game] {
        let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/basketball/nba/scoreboard?dates=\(key)")!
        let (data, _) = try await session.data(from: url)
        let resp = try JSONDecoder().decode(ESPNResponse.self, from: data)
        return (resp.events ?? []).compactMap { e in
            guard let time = parseDate(e.date),
                  let comp = e.competitions.first,
                  let home = comp.competitors.first(where: { $0.homeAway == "home" }),
                  let away = comp.competitors.first(where: { $0.homeAway == "away" })
            else { return nil }
            return Game(
                id: e.id,
                time: time,
                state: e.status.type.state,
                detail: e.status.type.shortDetail ?? "",
                home: teamName(home.team),
                away: teamName(away.team),
                homeScore: Int(home.score ?? "") ?? 0,
                awayScore: Int(away.score ?? "") ?? 0,
                homeCode: canonical(home.team.abbreviation),
                awayCode: canonical(away.team.abbreviation)
            )
        }
    }

    private static func teamName(_ t: ESPNTeam) -> String {
        teams[t.abbreviation] ?? t.shortDisplayName ?? t.abbreviation
    }

    private static func parseDate(_ s: String) -> Date? {
        for fmt in ["yyyy-MM-dd'T'HH:mmX", "yyyy-MM-dd'T'HH:mm:ssX", "yyyy-MM-dd'T'HH:mm:ss.SSSX"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        return nil
    }
}

// MARK: - 缓存（各自进程内的 UserDefaults，App 和小组件互不依赖，签名后不需要 App Group）

enum GameCache {
    private static let d = UserDefaults.standard

    static func save(_ games: [Game], key: String) {
        if let data = try? JSONEncoder().encode(games) {
            d.set(data, forKey: "games_\(key)")
            d.set(Date(), forKey: "games_time_\(key)")
        }
    }

    static func load(key: String) -> (games: [Game], savedAt: Date)? {
        guard let data = d.data(forKey: "games_\(key)"),
              let games = try? JSONDecoder().decode([Game].self, from: data),
              let t = d.object(forKey: "games_time_\(key)") as? Date
        else { return nil }
        return (games, t)
    }
}

// MARK: - ESPN JSON

private struct ESPNResponse: Decodable { let events: [ESPNEvent]? }
private struct ESPNEvent: Decodable {
    let id: String
    let date: String
    let status: ESPNStatus
    let competitions: [ESPNCompetition]
}
private struct ESPNStatus: Decodable { let type: ESPNStatusType }
private struct ESPNStatusType: Decodable { let state: String; let shortDetail: String? }
private struct ESPNCompetition: Decodable { let competitors: [ESPNCompetitor] }
private struct ESPNCompetitor: Decodable { let homeAway: String; let score: String?; let team: ESPNTeam }
private struct ESPNTeam: Decodable { let abbreviation: String; let shortDisplayName: String? }
