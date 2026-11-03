import WidgetKit
import SwiftUI
import AppIntents

@main
struct NBAWidgetBundle: WidgetBundle {
    var body: some Widget {
        TodayWidget()
        TomorrowWidget()
        HealthWidget()
    }
}

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NBAToday", provider: Provider(day: .today)) { entry in
            ScheduleWidgetView(entry: entry)
        }
        .configurationDisplayName("今日 NBA")
        .description("今天的 NBA 比赛（北京时间）。点一下翻页，喜欢的球队在 App 里设置")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled() // 自己画底色和边距，避免系统把底色提亮
    }
}

struct TomorrowWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NBATomorrow", provider: Provider(day: .tomorrow)) { entry in
            ScheduleWidgetView(entry: entry)
        }
        .configurationDisplayName("明日 NBA")
        .description("明天的 NBA 比赛（北京时间）。点一下翻页，喜欢的球队在 App 里设置")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled() // 自己画底色和边距，避免系统把底色提亮
    }
}

// MARK: - 布局

struct WidgetLayout {
    let cols: Int
    let rows: Int
    let fontSize: CGFloat
    var pageSize: Int { cols * rows }

    static func of(_ family: WidgetFamily) -> WidgetLayout {
        switch family {
        case .systemMedium: return WidgetLayout(cols: 2, rows: 4, fontSize: 14)
        case .systemLarge: return WidgetLayout(cols: 2, rows: 8, fontSize: 15)
        default: return WidgetLayout(cols: 1, rows: 5, fontSize: 15)
        }
    }
}

// MARK: - 数据

struct ScheduleEntry: TimelineEntry {
    let date: Date
    let day: DayOption
    let target: Date
    let familyKey: String
    let games: [Game]        // 当前页
    let favorites: Set<String>
    let totalCount: Int
    let page: Int
    let totalPages: Int
    let stale: Bool
    let failed: Bool
    var editing: Bool = false

    static func sample(_ day: DayOption = .today) -> ScheduleEntry {
        let now = Date()
        let g = [
            Game(id: "1", time: now, state: "in", detail: "Q3 5:12", home: "勇士", away: "湖人",
                 homeScore: 70, awayScore: 72, homeCode: "GSW", awayCode: "LAL"),
            Game(id: "2", time: now, state: "post", detail: "Final", home: "魔术", away: "凯尔特人",
                 homeScore: 97, awayScore: 108, homeCode: "ORL", awayCode: "BOS"),
            Game(id: "3", time: now, state: "pre", detail: "", home: "步行者", away: "篮网",
                 homeScore: 0, awayScore: 0, homeCode: "IND", awayCode: "BKN"),
            Game(id: "4", time: now, state: "pre", detail: "", home: "猛龙", away: "快船",
                 homeScore: 0, awayScore: 0, homeCode: "TOR", awayCode: "LAC")
        ]
        return ScheduleEntry(date: now, day: day, target: now, familyKey: "", games: g, favorites: ["LAL"],
                             totalCount: g.count, page: 0, totalPages: 1, stale: false, failed: false)
    }
}

struct Provider: TimelineProvider {
    let day: DayOption

    func placeholder(in context: Context) -> ScheduleEntry { .sample(day) }

    /// 上一次时间线的结果（按 今天/明天 + 尺寸 分开存），快照时直接用，不再联网
    private static var lastEntries: [String: ScheduleEntry] = [:]
    private func cacheKey(_ context: Context) -> String { "\(day.rawValue)-\(context.family)" }

    func getSnapshot(in context: Context, completion: @escaping (ScheduleEntry) -> Void) {
        if context.isPreview {
            completion(.sample(day))
            return
        }
        if let last = Provider.lastEntries[cacheKey(context)] { completion(last); return }
        Task { completion(await makeEntry(context)) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ScheduleEntry>) -> Void) {
        Task {
            let entry = await makeEntry(context)
            Provider.lastEntries[cacheKey(context)] = entry
            let now = Date()
            let live = entry.games.contains { $0.state == "in" }
            let soon = entry.games.contains { $0.state == "pre" && $0.time.timeIntervalSince(now) < 1800 }
            var minutes: Double = entry.failed ? 10 : (live || soon ? 5 : 30)
            if entry.editing { minutes = 2.1 } // 收藏模式到时自动退出
            completion(Timeline(entries: [entry], policy: .after(now.addingTimeInterval(minutes * 60))))
        }
    }

    private func makeEntry(_ context: Context) async -> ScheduleEntry {
        let target = NBAService.targetDate(offset: day.offset)
        let key = NBAService.dayKey(target)
        let layout = WidgetLayout.of(context.family)
        let familyKey = "\(context.family)"
        let favorites = myTeams
        let editing = false

        var games: [Game] = []
        var stale = false
        var failed = false

        let cached = GameCache.load(key: key)
        // 刚翻页时直接用 1.5 分钟内的缓存，翻页不用等网络
        if let c = cached, Date().timeIntervalSince(c.savedAt) < 90 {
            games = c.games
        } else {
            do {
                games = try await NBAService.fetch(offset: day.offset)
                GameCache.save(games, key: key)
            } catch {
                if let c = cached {
                    games = c.games
                    stale = true
                } else {
                    failed = true
                }
            }
        }

        // 喜欢的球队的比赛排在最前面，其余按开赛时间（收藏模式下不重排，免得点着点着位置变了）
        if !editing {
            let fav = games.filter { $0.involves(favorites) }
            let rest = games.filter { !$0.involves(favorites) }
            games = fav + rest
        }

        let totalPages = max(1, Int(ceil(Double(games.count) / Double(layout.pageSize))))
        let page = PageStore.current(day: day.rawValue, family: familyKey, dateKey: key, total: totalPages)
        let start = page * layout.pageSize
        let pageGames = start < games.count ? Array(games[start..<min(games.count, start + layout.pageSize)]) : []

        return ScheduleEntry(date: Date(), day: day, target: target, familyKey: familyKey,
                             games: pageGames, favorites: favorites, totalCount: games.count, page: page,
                             totalPages: totalPages, stale: stale, failed: failed, editing: editing)
    }
}

// MARK: - 界面

/// 和系统自带小组件一样的底色：深色模式接近纯黑，浅色模式白色
let widgetBackground = Color(uiColor: UIColor { trait in
    trait.userInterfaceStyle == .dark
        ? UIColor(red: 28 / 255, green: 28 / 255, blue: 28 / 255, alpha: 1)
        : UIColor.white
})
let nbaAccent = Color(red: 0.88, green: 0.15, blue: 0.25)
private let liveRed = Color(red: 1.0, green: 0.27, blue: 0.23)

struct ScheduleWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: ScheduleEntry

    private var layout: WidgetLayout { WidgetLayout.of(family) }

    var body: some View {
        // 整个小组件就是一个按钮，不会打开 App：
        // 多页时点一下翻到下一页（最后一页再点回到第一页）；只有一页时点一下刷新数据
        Button(intent: PageIntent(day: entry.day.rawValue, family: entry.familyKey,
                                  delta: entry.totalPages > 1 ? 1 : 0)) {
            content
                .padding(.horizontal, family == .systemSmall ? 14 : 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(widgetBackground)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .containerBackground(widgetBackground, for: .widget)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if entry.failed {
                message("加载失败，稍后自动重试")
            } else if entry.totalCount == 0 {
                message(entry.day == .today ? "今天没有比赛" : "明天没有比赛")
            } else {
                grid
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(entry.day == .today ? "今日 NBA" : "明日 NBA")
                .font(.system(size: family == .systemSmall ? 15 : 16, weight: .heavy))
                .foregroundStyle(nbaAccent)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            if entry.editing {
                Text("点球队名收藏")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(nbaAccent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else if family != .systemSmall {
                Text(NBAService.dateLabel(entry.target, withWeekday: true) + (entry.stale ? " · 缓存" : ""))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if entry.totalPages > 1 {
                pageDots
            } else if family == .systemSmall && !entry.editing {
                Text(NBAService.dateLabel(entry.target, withWeekday: false))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

        }
    }

    /// 页码：● ○ ○
    private var pageDots: some View {
        HStack(spacing: 4) {
            ForEach(0..<entry.totalPages, id: \.self) { i in
                Circle()
                    .fill(i == entry.page ? Color.primary : Color.secondary.opacity(0.35))
                    .frame(width: 6, height: 6)
            }
        }
    }

    private var grid: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(0..<layout.cols, id: \.self) { c in
                VStack(spacing: 0) {
                    ForEach(0..<layout.rows, id: \.self) { r in
                        let i = c * layout.rows + r
                        if r > 0 { Spacer(minLength: 1) }
                        if i < entry.games.count {
                            GameRow(game: entry.games[i], favorites: entry.favorites, fontSize: layout.fontSize, editing: entry.editing)
                        } else {
                            Text(" ").font(.system(size: layout.fontSize)).padding(.vertical, 2)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct GameRow: View {
    let game: Game
    let favorites: Set<String>
    let fontSize: CGFloat
    var editing: Bool = false

    private var isFav: Bool { game.involves(favorites) }

    var body: some View {
        HStack(spacing: 4) {
            teamCell(game.away, code: game.awayCode, dim: awayDim, alignment: .trailing)
            Text(game.middleText)
                .font(.system(size: fontSize - 1, weight: .semibold).monospacedDigit())
                .foregroundStyle(middleColor)
                .frame(width: fontSize * 3.4)
            teamCell(game.home, code: game.homeCode, dim: homeDim, alignment: .leading)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .padding(.vertical, 2)
        .padding(.horizontal, 2)
    }

    /// 收藏模式下球队名是按钮，点一下收藏 / 取消
    @ViewBuilder
    private func teamCell(_ name: String, code: String, dim: Bool, alignment: Alignment) -> some View {
        let label = teamText(name, code: code, dim: dim)
            .frame(maxWidth: .infinity, alignment: alignment)
            .contentShape(Rectangle())
        if editing {
            Button(intent: ToggleFavoriteIntent(code: code)) {
                label
                    .padding(.vertical, 1)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        } else {
            label
        }
    }

    private func teamText(_ name: String, code: String, dim: Bool) -> some View {
        let fav = favorites.contains(code)
        return Text(name)
            .font(.system(size: fontSize, weight: fav ? .heavy : .medium))
            .foregroundStyle(fav ? nbaAccent : (dim ? Color.secondary : Color.primary))
    }

    private var finished: Bool { game.state == "post" && !game.isPostponed && !game.isCanceled }

    private var middleColor: Color {
        if game.state == "in" { return liveRed }
        if finished { return .primary }
        return .secondary
    }

    // 已结束：输的一方变灰
    private var awayDim: Bool { finished && game.homeScore > game.awayScore }
    private var homeDim: Bool { finished && game.awayScore > game.homeScore }
}
