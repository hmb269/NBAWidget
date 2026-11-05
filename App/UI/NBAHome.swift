import SwiftUI
import WidgetKit

// NBA 首页：一张卡片，卡片里左右滑动切换「今天 / 明天」（卡片外左右滑动还是切换 App 页面）

struct NBAView: View {
    @State private var today: [Game] = []
    @State private var tomorrow: [Game] = []
    @State private var loading = false
    @State private var errorText: String?
    @State private var day = 0
    private let favorites = myTeams

    var body: some View {
        PageScroll(title: "NBA", subtitle: "北京时间 · 点比赛看球员数据") {
            if let errorText {
                Text(errorText).font(.footnote).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12).glassCard(16)
            }

            VStack(spacing: 0) {
                // 标题：今天 / 明天，点也能切换
                HStack(spacing: 16) {
                    dayTab("今天", 0)
                    dayTab("明天", 1)
                    Spacer()
                    HStack(spacing: 5) {
                        Circle().fill(day == 0 ? Color.white : Color.white.opacity(0.25)).frame(width: 6, height: 6)
                        Circle().fill(day == 1 ? Color.white : Color.white.opacity(0.25)).frame(width: 6, height: 6)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 8)

                // 卡片里面的左右滑动
                TabView(selection: $day.animation()) {
                    dayList(today).tag(0)
                    dayList(tomorrow).tag(1)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: listHeight)
            }
            .glassCard(24)
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private let rowHeight: CGFloat = 62

    private var listHeight: CGFloat {
        let n = max(max(today.count, tomorrow.count), 1)
        return CGFloat(n) * rowHeight + 16
    }

    private func dayTab(_ title: String, _ i: Int) -> some View {
        Button {
            withAnimation { day = i }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(.system(size: day == i ? 22 : 17, weight: .bold))
                    .foregroundStyle(day == i ? Color.primary : Color.secondary)
                Text(NBAService.dateLabel(NBAService.targetDate(offset: i), withWeekday: true))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func sorted(_ g: [Game]) -> [Game] {
        g.filter { $0.involves(favorites) } + g.filter { !$0.involves(favorites) }
    }

    @ViewBuilder
    private func dayList(_ games: [Game]) -> some View {
        VStack(spacing: 0) {
            if loading && games.isEmpty {
                ProgressView().padding(.vertical, 20)
            } else if games.isEmpty {
                Text("没有比赛").font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 20)
            } else {
                ForEach(Array(sorted(games).enumerated()), id: \.element.id) { i, g in
                    if i > 0 { Divider().overlay(Color.white.opacity(0.06)).padding(.horizontal, 18) }
                    NavigationLink {
                        NBAGameDetailView(game: g)
                    } label: {
                        GameRow(game: g, favorites: favorites)
                            .frame(height: rowHeight - 1)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            async let a = NBAService.fetch(offset: 0)
            async let b = NBAService.fetch(offset: 1)
            today = try await a
            tomorrow = try await b
            errorText = nil
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            errorText = "加载失败：\(error.localizedDescription)"
        }
    }
}

/// 一场比赛一行：客队 · 比分/时间 · 主队（大字号）
struct GameRow: View {
    let game: Game
    let favorites: Set<String>
    private let red = Color(red: 1.0, green: 0.30, blue: 0.35)

    var body: some View {
        HStack(spacing: 6) {
            team(game.away, game.awayCode, won: game.state == "post" && game.awayScore > game.homeScore)
                .frame(maxWidth: .infinity, alignment: .trailing)
            VStack(spacing: 1) {
                Text(game.middleText)
                    .font(.system(size: 20, weight: .heavy, design: .rounded).monospacedDigit())
                    .foregroundStyle(game.state == "in" ? red : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if game.state == "in" {
                    Text(game.liveText)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(red)
                        .lineLimit(1)
                } else if game.state == "post" {
                    Text("已结束").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            .frame(width: 112)
            team(game.home, game.homeCode, won: game.state == "post" && game.homeScore > game.awayScore)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
    }

    private func team(_ name: String, _ code: String, won: Bool) -> some View {
        let fav = favorites.contains(code)
        return Text(name)
            .font(.system(size: 17, weight: fav ? .heavy : (won ? .bold : .medium)))
            .foregroundStyle(fav ? red : (game.state == "post" && !won ? Color.secondary : Color.primary))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}
