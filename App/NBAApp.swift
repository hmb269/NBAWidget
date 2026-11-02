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

struct ContentView: View {
    @State private var day = 0
    @State private var games: [Game] = []
    @State private var loading = false
    @State private var errorText: String?

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
                        ForEach(games) { g in
                            AppGameRow(game: g)
                        }
                    }
                }

                Section(header: Text("小组件")) {
                    Text("长按桌面空白处 → 编辑 → 添加小组件 → 搜索「NBA赛程」，左右滑动可以选「今日 NBA」或「明日 NBA」，小、中、大三种尺寸都有。\n标题右边的左右箭头可以直接翻页。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("NBA 赛程")
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

struct AppGameRow: View {
    let game: Game

    var body: some View {
        HStack {
            Text(game.away)
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
            Text(game.home)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.body.weight(.medium))
        .padding(.vertical, 4)
    }

    private var statusText: String {
        switch game.state {
        case "pre": return "客 @ 主"
        case "in": return game.liveText
        default: return game.isPostponed ? "" : "已结束"
        }
    }
}
