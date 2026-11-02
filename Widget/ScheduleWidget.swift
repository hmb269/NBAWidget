import WidgetKit
import SwiftUI
import AppIntents

@main
struct NBAWidgetBundle: WidgetBundle {
    var body: some Widget {
        TodayWidget()
        TomorrowWidget()
    }
}

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NBAToday", provider: Provider(day: .today)) { entry in
            ScheduleWidgetView(entry: entry)
        }
        .configurationDisplayName("今日 NBA")
        .description("今天的 NBA 比赛（北京时间），点箭头翻页")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct TomorrowWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NBATomorrow", provider: Provider(day: .tomorrow)) { entry in
            ScheduleWidgetView(entry: entry)
        }
        .configurationDisplayName("明日 NBA")
        .description("明天的 NBA 比赛（北京时间），点箭头翻页")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
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
    let totalCount: Int
    let page: Int
    let totalPages: Int
    let stale: Bool
    let failed: Bool

    static func sample(_ day: DayOption = .today) -> ScheduleEntry {
        let now = Date()
        let g = [
            Game(id: "1", time: now, state: "post", detail: "Final", home: "魔术", away: "凯尔特人", homeScore: 97, awayScore: 108),
            Game(id: "2", time: now, state: "in", detail: "Q3 5:12", home: "步行者", away: "篮网", homeScore: 70, awayScore: 72),
            Game(id: "3", time: now, state: "pre", detail: "", home: "勇士", away: "快船", homeScore: 0, awayScore: 0),
            Game(id: "4", time: now, state: "pre", detail: "", home: "湖人", away: "猛龙", homeScore: 0, awayScore: 0)
        ]
        return ScheduleEntry(date: now, day: day, target: now, familyKey: "", games: g,
                             totalCount: g.count, page: 0, totalPages: 1, stale: false, failed: false)
    }
}

struct Provider: TimelineProvider {
    let day: DayOption

    func placeholder(in context: Context) -> ScheduleEntry { .sample(day) }

    func getSnapshot(in context: Context, completion: @escaping (ScheduleEntry) -> Void) {
        if context.isPreview {
            completion(.sample(day))
            return
        }
        Task { completion(await makeEntry(context)) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ScheduleEntry>) -> Void) {
        Task {
            let entry = await makeEntry(context)
            let now = Date()
            let live = entry.games.contains { $0.state == "in" }
            let soon = entry.games.contains { $0.state == "pre" && $0.time.timeIntervalSince(now) < 1800 }
            let minutes: Double = entry.failed ? 10 : (live || soon ? 5 : 30)
            completion(Timeline(entries: [entry], policy: .after(now.addingTimeInterval(minutes * 60))))
        }
    }

    private func makeEntry(_ context: Context) async -> ScheduleEntry {
        let day = self.day
        let target = NBAService.targetDate(offset: day.offset)
        let key = NBAService.dayKey(target)
        let layout = WidgetLayout.of(context.family)
        let familyKey = "\(context.family)"

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

        let totalPages = max(1, Int(ceil(Double(games.count) / Double(layout.pageSize))))
        let page = PageStore.current(day: day.rawValue, family: familyKey, dateKey: key, total: totalPages)
        let start = page * layout.pageSize
        let pageGames = start < games.count ? Array(games[start..<min(games.count, start + layout.pageSize)]) : []

        return ScheduleEntry(date: Date(), day: day, target: target, familyKey: familyKey,
                             games: pageGames, totalCount: games.count, page: page,
                             totalPages: totalPages, stale: stale, failed: failed)
    }
}

// MARK: - 界面

private let accent = Color(red: 0.88, green: 0.15, blue: 0.25)
private let liveRed = Color(red: 1.0, green: 0.27, blue: 0.23)

struct ScheduleWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: ScheduleEntry

    private var layout: WidgetLayout { WidgetLayout.of(family) }

    var body: some View {
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
        .containerBackground(Color(uiColor: .secondarySystemGroupedBackground), for: .widget)
    }

    private var header: some View {
        HStack(spacing: 2) {
            Text(entry.day == .today ? "今日 NBA" : "明日 NBA")
                .font(.system(size: family == .systemSmall ? 15 : 16, weight: .heavy))
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            if family != .systemSmall {
                Text(NBAService.dateLabel(entry.target, withWeekday: true) + (entry.stale ? " · 缓存" : ""))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 6)
            }

            Spacer(minLength: 0)

            if entry.totalPages > 1 {
                pageButton("chevron.left", delta: -1)
                Text("\(entry.page + 1)/\(entry.totalPages)")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                pageButton("chevron.right", delta: 1)
            } else if family == .systemSmall {
                Text(NBAService.dateLabel(entry.target, withWeekday: false))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func pageButton(_ symbol: String, delta: Int) -> some View {
        Button(intent: PageIntent(day: entry.day.rawValue, family: entry.familyKey, delta: delta)) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 24, height: 24)
                .background(Color.primary.opacity(0.08), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private var grid: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(0..<layout.cols, id: \.self) { c in
                VStack(spacing: 0) {
                    ForEach(0..<layout.rows, id: \.self) { r in
                        let i = c * layout.rows + r
                        if r > 0 { Spacer(minLength: 2) }
                        if i < entry.games.count {
                            GameRow(game: entry.games[i], fontSize: layout.fontSize)
                        } else {
                            Text(" ").font(.system(size: layout.fontSize))
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
    let fontSize: CGFloat

    var body: some View {
        HStack(spacing: 4) {
            Text(game.away)
                .foregroundStyle(awayColor)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(game.middleText)
                .font(.system(size: fontSize - 1, weight: .semibold).monospacedDigit())
                .foregroundStyle(middleColor)
                .frame(width: fontSize * 3.4)
            Text(game.home)
                .foregroundStyle(homeColor)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: fontSize, weight: .medium))
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }

    private var finished: Bool { game.state == "post" && !game.isPostponed && !game.isCanceled }

    private var middleColor: Color {
        if game.state == "in" { return liveRed }
        if finished { return .primary }
        return .secondary
    }

    // 已结束：输的一方变灰
    private var awayColor: Color { finished && game.homeScore > game.awayScore ? .secondary : .primary }
    private var homeColor: Color { finished && game.awayScore > game.homeScore ? .secondary : .primary }
}
