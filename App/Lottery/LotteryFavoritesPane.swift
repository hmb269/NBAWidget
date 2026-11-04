import SwiftUI

/// 「收藏」栏：显示收藏的号码，每注后面「对奖」→ 选期号（可多期）就对好
struct LotteryFavoritesPane: View {
    let onAdd: (LotteryGame) -> Void
    let onCheck: (LotteryGame, [LotteryBet]) -> Void

    @State private var favs: [LotteryGame: [LotteryBet]] = [:]

    var body: some View {
        VStack(spacing: 14) {
            let games = LotteryGame.checkableGames.filter { !(favs[$0] ?? []).isEmpty }
            if games.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "star").font(.system(size: 34)).foregroundStyle(.yellow)
                    Text("还没有收藏号码").font(.headline)
                    Text("点下面的玩法开始选号，在「我的号码」里点 ☆ 就能收藏。以后在这里点「对奖」，选一下期号就对好奖。")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(22)
                .glassCard(22)
            }
            ForEach(games) { g in
                FavoriteGameCard(game: g, bets: favs[g] ?? [], onCheck: { onCheck(g, $0) }, onDelete: { bet in
                    favs[g]?.removeAll { $0.id == bet.id }
                    LotteryFavorites.save(favs[g] ?? [], for: g)
                }, onMultiple: { bet, m in
                    if let i = favs[g]?.firstIndex(where: { $0.id == bet.id }) { favs[g]?[i].multiple = m }
                    LotteryFavorites.save(favs[g] ?? [], for: g)
                }, onToggleAdded: { bet in
                    if let i = favs[g]?.firstIndex(where: { $0.id == bet.id }) { favs[g]?[i].added.toggle() }
                    LotteryFavorites.save(favs[g] ?? [], for: g)
                })
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
    let bets: [LotteryBet]
    let onCheck: ([LotteryBet]) -> Void
    let onDelete: (LotteryBet) -> Void
    let onMultiple: (LotteryBet, Int) -> Void
    let onToggleAdded: (LotteryBet) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(game.name).font(.headline)
                Text("\(bets.count) 注").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if bets.count > 1 {
                    Button { onCheck(bets) } label: {
                        Label("全部对奖", systemImage: "checkmark.seal").font(.caption.weight(.semibold))
                    }
                    .glassButton()
                }
            }
            ForEach(Array(bets.enumerated()), id: \.element.id) { i, b in
                if i > 0 { RowDivider() }
                // 第一行：号码（占满整行，不会被按钮挤）；第二行：追加、倍数、选几复式 + 对奖
                VStack(alignment: .leading, spacing: 8) {
                    LotteryBalls(game: game, front: b.frontStrings(game), back: b.backStrings(game),
                                 size: game == .kl8 && b.front.count > 8 ? 24 : 28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 8) {
                        if let p = b.pick {
                            tag("选\(["", "一", "二", "三", "四", "五", "六", "七", "八", "九", "十"][min(p, 10)])复式", color: .secondary)
                        }
                        if b.added { tag("追加", color: .orange) }
                        // 倍数：点开选
                        Menu {
                            Picker("倍数", selection: Binding(get: { b.multiple }, set: { onMultiple(b, $0) })) {
                                ForEach([1, 2, 3, 4, 5, 6, 8, 10, 15, 20, 30, 50, 99], id: \.self) { Text("\($0) 倍").tag($0) }
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Text("\(b.multiple) 倍").monospacedDigit()
                                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold))
                            }
                            .font(.caption.weight(.bold))
                            .foregroundStyle(b.multiple > 1 ? Color.orange : Color.secondary)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                        }
                        Spacer(minLength: 0)
                        Menu {
                            if game == .dlt {
                                Button(b.added ? "改成不追加" : "改成追加投注", systemImage: "plus.circle") { onToggleAdded(b) }
                            }
                            Button("取消收藏", systemImage: "star.slash", role: .destructive) { onDelete(b) }
                        } label: {
                            Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(.secondary)
                        }
                        Button { onCheck([b]) } label: {
                            Label("对奖", systemImage: "checkmark.seal").font(.subheadline.weight(.semibold))
                        }
                        .glassButton()
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(22)
    }

    private func tag(_ t: String, color: Color) -> some View {
        Text(t)
            .font(.caption.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().stroke(color.opacity(0.6), lineWidth: 1))
    }
}
