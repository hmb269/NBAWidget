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
    @State private var favorites: Set<String> = FavoriteStore.load()
    @State private var showTeams = false

    private var sortedGames: [Game] {
        games.filter { $0.involves(favorites) } + games.filter { !$0.involves(favorites) }
    }

    var body: some View {
        NavigationStack {
            List {
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
                                .listRowBackground(g.involves(favorites) ? accent.opacity(0.12) : nil)
                        }
                    }
                }

                Section(header: Text("小组件")) {
                    Text("长按桌面空白处 → 编辑 → 添加小组件 → 搜索「NBA赛程」，左右滑动可以选「今日 NBA」或「明日 NBA」。\n点一下小组件：多页时翻页，只有一页时刷新。\n点右上角 ☆ 选喜欢的球队，他们的比赛会排在最上面并高亮。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("NBA 赛程")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showTeams = true
                    } label: {
                        Label("我的球队", systemImage: favorites.isEmpty ? "star" : "star.fill")
                    }
                }
            }
            .sheet(isPresented: $showTeams) {
                TeamPicker(favorites: $favorites)
            }
            .onChange(of: favorites) { _, newValue in
                FavoriteStore.save(newValue)
                WidgetCenter.shared.reloadAllTimelines()
            }
            .refreshable { await load() }
            .task(id: day) { await load() }
        }
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
