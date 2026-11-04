import SwiftUI

/// 「收藏」栏：每种玩法一张卡，选一下期号就自动对好所有收藏的号码
struct LotteryFavoritesPane: View {
    let data: [LotteryGame: [LotteryDraw]]
    let onAdd: (LotteryGame) -> Void

    @State private var favs: [LotteryGame: [LotteryBet]] = [:]

    var body: some View {
        VStack(spacing: 14) {
            let games = LotteryGame.checkableGames.filter { !(favs[$0] ?? []).isEmpty }
            if games.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "star").font(.system(size: 34)).foregroundStyle(.yellow)
                    Text("还没有收藏号码").font(.headline)
                    Text("点下面的玩法开始选号，在「我的号码」里点 ☆ 就能收藏。以后在这里选一下期号，就自动对好奖。")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(22)
                .glassCard(22)
            }
            ForEach(games) { g in
                FavoriteGameCard(game: g, draws: data[g] ?? [], bets: favs[g] ?? []) { game, bet in
                    favs[game]?.removeAll { $0.id == bet.id }
                    LotteryFavorites.save(favs[game] ?? [], for: game)
                }
            }

            // 添加收藏
            VStack(alignment: .leading, spacing: 10) {
                Text("添加收藏").font(.subheadline.weight(.semibold))
                HStack(spacing: 8) {
                    ForEach(LotteryGame.checkableGames) { g in
                        Button { onAdd(g) } label: {
                            Text(g.shortName).font(.caption.weight(.semibold)).frame(maxWidth: .infinity)
                        }
                        .glassButton()
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(22)
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .lotteryFavsChanged)) { _ in reload() }
    }

    private func reload() {
        favs = Dictionary(uniqueKeysWithValues: LotteryGame.checkableGames.map { ($0, LotteryFavorites.load($0)) })
    }
}

private struct FavoriteGameCard: View {
    let game: LotteryGame
    let draws: [LotteryDraw]
    let bets: [LotteryBet]
    let onDelete: (LotteryGame, LotteryBet) -> Void

    @State private var issue = ""
    @State private var more: [LotteryDraw] = []

    private var list: [LotteryDraw] {
        let all = more.isEmpty ? draws : more
        return all.sorted { (LotteryAPI.issueNumber($0.issue) ?? 0) > (LotteryAPI.issueNumber($1.issue) ?? 0) }
    }
    private var draw: LotteryDraw? { list.first { $0.issue == issue } ?? list.first }

    var body: some View {
        let results = draw.map { d in bets.map { PrizeCalc.check($0, draw: d, game: game) } } ?? []
        let money = results.flatMap(\.hits).compactMap(\.total).reduce(0, +)
        let won = results.filter { !$0.hits.isEmpty }.count
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(game.name).font(.headline)
                Spacer()
                if !list.isEmpty {
                    // 选期号（默认最近一期）
                    Picker("期号", selection: Binding(get: { draw?.issue ?? "" }, set: { issue = $0 })) {
                        ForEach(list) { d in Text("第\(d.issue)期").tag(d.issue) }
                    }
                    .pickerStyle(.menu)
                    .tint(.secondary)
                }
            }
            if let d = draw {
                HStack {
                    LotteryBalls(game: game, front: d.front, back: d.back, size: game == .kl8 ? 22 : 26)
                    Spacer(minLength: 0)
                }
                Text(d.date + " " + game.timeText + " 开奖").font(.caption2).foregroundStyle(.tertiary)

                // 汇总
                HStack {
                    Image(systemName: won > 0 ? "party.popper.fill" : "face.dashed")
                        .foregroundStyle(won > 0 ? Color.orange : Color.secondary)
                    Text(won > 0 ? "\(bets.count) 注里中了 \(won) 注" : "\(bets.count) 注都没中")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if money > 0 {
                        Text(LotteryFormat.yuan(String(format: "%.0f", money)))
                            .font(.subheadline.weight(.bold).monospacedDigit()).foregroundStyle(.orange)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.05)))

                ForEach(results) { r in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            ScrollView(.horizontal, showsIndicators: false) {
                                LotteryBalls(game: game, front: r.bet.frontStrings(game), back: r.bet.backStrings(game),
                                             size: 24, hitFront: r.frontHitIdx, hitBack: r.backHitIdx)
                            }
                            Menu {
                                Button("取消收藏", systemImage: "star.slash", role: .destructive) { onDelete(game, r.bet) }
                            } label: {
                                Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
                            }
                        }
                        Text(resultText(r)).font(.caption.weight(r.hits.isEmpty ? .regular : .semibold))
                            .foregroundStyle(r.hits.isEmpty ? Color.secondary : Color.orange)
                    }
                    .padding(.vertical, 2)
                }
            } else {
                Text("还没有开奖数据，下拉刷新一下").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(22)
        .task {
            // 收藏页可以选更早的期号：拉最近 100 期
            if draws.count < 100, let l = try? await LotteryAPI.history(game, count: 100) { more = l }
        }
    }

    private func resultText(_ r: BetResult) -> String {
        let hit: String
        switch game {
        case .kl8: hit = "中 \(r.frontHits) 个"
        case .qxc: hit = "对上 \(r.frontHits) 位" + (r.backHits > 0 ? " + 后区" : "")
        default: hit = "中 \(r.frontHits)+\(r.backHits)"
        }
        if r.hits.isEmpty { return hit + " · 未中奖" }
        let prize = r.hits.map { h in
            "\(h.name)" + (h.count > 1 ? "×\(h.count)" : "") + " " +
            (h.total.map { LotteryFormat.yuan(String(format: $0 < 100 && $0 != $0.rounded() ? "%.1f" : "%.0f", $0)) } ?? "浮动奖金")
        }.joined(separator: "、")
        return hit + " · " + prize
    }
}
