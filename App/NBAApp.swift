import SwiftUI
import WidgetKit

@main
struct NBAApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

private let accent = Color(red: 0.88, green: 0.15, blue: 0.25)

struct ContentView: View {
    @State private var day = 0
    @State private var games: [Game] = []
    @State private var loading = false
    @State private var errorText: String?
    @State private var health = HealthSnapshot()
    @State private var healthMessage: String?
    private let favorites = myTeams

    private var sortedGames: [Game] {
        games.filter { $0.involves(favorites) } + games.filter { !$0.involves(favorites) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section(header: Text("健康")) {
                    HealthRow(icon: "bed.double.fill", title: "睡眠时间", value: health.sleep.map { HealthFormat.duration($0.asleep) })
                    HealthRow(icon: "figure", title: "体重", value: health.weight.map { w in
                        var t = HealthFormat.kg(w.kg) + " 公斤"
                        if let p = w.previousKg {
                            let d = w.kg - p
                            t += abs(d) < 0.005 ? "  持平" : (d > 0 ? "  ↑" : "  ↓") + String(format: "%.2f", abs(d))
                        }
                        return t
                    })
                    HealthRow(icon: "waveform.path.ecg", title: "恢复心率变异性", value: health.hrv.map { "\(Int($0.ms.rounded())) 毫秒" })
                    HealthRow(icon: "figure.walk", title: "今日步数", value: health.steps.map { $0.formatted() })
                    HealthRow(icon: "sun.horizon.fill", title: "日出 / 日落", value: SunTimes.times().map { HealthFormat.time($0.sunrise) + " / " + HealthFormat.time($0.sunset) })
                    if let note = healthMessage {
                        Text(note).font(.footnote).foregroundStyle(.orange)
                    }
                    Button("授权 / 重新读取健康数据") {
                        Task { await authorizeAndLoad() }
                    }
                }

                Section {
                    Picker("日期", selection: $day) {
                        Text("今天").tag(0)
                        Text("明天").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                Section(header: Text(NBAService.dateLabel(NBAService.targetDate(offset: day), withWeekday: true) + "（北京时间）")) {
                    if loading && games.isEmpty {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    } else if let errorText {
                        Text(errorText).foregroundStyle(.secondary)
                    } else if games.isEmpty {
                        Text(day == 0 ? "今天没有比赛" : "明天没有比赛").foregroundStyle(.secondary)
                    } else {
                        ForEach(sortedGames) { g in
                            AppGameRow(game: g, favorites: favorites)
                        }
                    }
                }

                Section(header: Text("小组件")) {
                    Text("长按桌面空白处 → 编辑 → 添加小组件 → 搜索「阿波」，左右滑动可以选「今日 NBA」「明日 NBA」，以及大号的「健康」（睡眠、体重、心率变异性、步数、日出日落）。\n点一下小组件：多页时翻页，只有一页时刷新。\n湖人、76人的比赛排在最上面，队名显示为红色。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("阿波")
            .refreshable { await load(); await loadSteps() }
            .task(id: day) { await load() }
            .task { await authorizeAndLoad() }
        }
    }

    private func authorizeAndLoad() async {
        healthMessage = await HealthService.requestAccess()
        await loadSteps()
    }

    private func loadSteps() async {
        var h = HealthSnapshot()
        var errors: [String] = []
        do { h.sleep = try await HealthService.lastNightSleep() } catch { errors.append("睡眠：" + HealthService.describe(error)) }
        do { h.weight = try await HealthService.latestWeight() } catch { errors.append("体重：" + HealthService.describe(error)) }
        do { h.hrv = try await HealthService.recentHRV(sleep: h.sleep, prevSleep: try? await HealthService.lastNightSleep(nightsAgo: 1)) } catch { errors.append("HRV：" + HealthService.describe(error)) }
        do { h.steps = try await HealthService.todaySteps() } catch { errors.append("步数：" + HealthService.describe(error)) }
        health = h
        if healthMessage == nil, !errors.isEmpty { healthMessage = errors.joined(separator: "\n") }
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let result = try await NBAService.fetch(offset: day)
            games = result
            errorText = nil
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            errorText = "加载失败：\(error.localizedDescription)"
        }
    }
}

struct TeamPicker: View {
    @Binding var favorites: Set<String>
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var refreshTick = 0

    var body: some View {
        NavigationStack {
            List {
                Section {
                    let _ = refreshTick // 从桌面切回来时重新检查同步状态
                    let status = FavoriteStore.syncStatus(for: favorites)
                    Label(status.text, systemImage: status.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(status.ok ? Color.green : Color.orange)
                }
                teamSection("东部", NBAService.east)
                teamSection("西部", NBAService.west)
            }
            .navigationTitle("我的球队")
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { refreshTick += 1 }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !favorites.isEmpty {
                        Button("清空") { favorites = [] }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }.bold()
                }
            }
        }
    }

    private func teamSection(_ title: String, _ codes: [String]) -> some View {
        let sorted = codes.sorted { (NBAService.teams[$0] ?? $0).localizedCompare(NBAService.teams[$1] ?? $1) == .orderedAscending }
        return Section(header: Text(title)) {
            ForEach(sorted, id: \.self) { code in
                Button {
                    if favorites.contains(code) { favorites.remove(code) } else { favorites.insert(code) }
                } label: {
                    HStack {
                        Text(NBAService.teams[code] ?? code)
                            .foregroundStyle(.primary)
                        Text(code)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: favorites.contains(code) ? "star.fill" : "star")
                            .foregroundStyle(favorites.contains(code) ? accent : Color.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct AppGameRow: View {
    let game: Game
    let favorites: Set<String>

    var body: some View {
        HStack {
            team(game.away, game.awayCode)
                .frame(maxWidth: .infinity, alignment: .trailing)
            VStack(spacing: 2) {
                Text(game.middleText)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(game.state == "in" ? .red : .primary)
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 90)
            team(game.home, game.homeCode)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }

    private func team(_ name: String, _ code: String) -> some View {
        let fav = favorites.contains(code)
        return Text(name)
            .font(.body.weight(fav ? .heavy : .medium))
            .foregroundStyle(fav ? accent : .primary)
    }

    private var statusText: String {
        switch game.state {
        case "pre": return "客 @ 主"
        case "in": return game.liveText
        default: return game.isPostponed ? "" : "已结束"
        }
    }
}

struct HealthSnapshot {
    var sleep: HealthService.SleepData?
    var weight: HealthService.WeightData?
    var hrv: HealthService.HRVData?
    var steps: Int?
}

struct HealthRow: View {
    let icon: String
    let title: String
    let value: String?

    var body: some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            Text(value ?? "暂无数据")
                .font(.body.weight(.semibold).monospacedDigit())
                .foregroundStyle(value == nil ? .secondary : .primary)
        }
    }
}
