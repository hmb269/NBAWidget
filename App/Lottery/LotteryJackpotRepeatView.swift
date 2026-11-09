import SwiftUI

/// 头奖号码回看：历史上开出过一等奖的号码，在别的期里又中过几个号码
struct LotteryJackpotRepeatView: View {
    @State private var game: LotteryGame = .ssq
    @State private var range = 0              // 0 = 全部
    @State private var minHits = 5
    @State private var needBack = false       // 后区（蓝球）也要中
    @State private var onlyWon = true         // 只看当期真的有人中了一等奖的
    @State private var loading = false
    @State private var progress = 0
    @State private var results: [Match]?
    @State private var scanned = 0
    @State private var error: String?

    struct Hit: Identifiable {
        var id: String { draw.issue }
        let draw: LotteryDraw
        let frontIdx: Set<Int>     // 这一期开奖号码里，和头奖号码一样的位置
        let backIdx: Set<Int>
    }
    struct Match: Identifiable {
        var id: String { jackpot.issue }
        let jackpot: LotteryDraw
        let hits: [Hit]
    }

    private static let games: [LotteryGame] = [.ssq, .dlt, .qxc]
    private var hitRange: ClosedRange<Int> {
        switch game {
        case .dlt: return 3...5
        default: return 3...6
        }
    }
    private var frontName: String { game == .ssq ? "红球" : game == .dlt ? "前区" : "前 6 位（按位置）" }
    private var backName: String { game == .ssq ? "蓝球" : "后区" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("从历史开奖里找出开过一等奖的号码，看它们在别的期里有没有又中过好几个号码。")
                    .font(.footnote).foregroundStyle(.secondary)

                CardSection {
                    Picker("玩法", selection: $game) {
                        ForEach(Self.games) { Text($0.shortName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.vertical, 10)
                    RowDivider()
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("在别的期中了几个")
                            Text(frontName + "至少中这么多").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(minHits) 个").font(.title3.weight(.bold).monospacedDigit())
                        Stepper("", value: $minHits, in: hitRange).labelsHidden()
                    }
                    .padding(.vertical, 6)
                    RowDivider()
                    Toggle(backName + "也要中", isOn: $needBack).padding(.vertical, 6)
                    RowDivider()
                    Toggle(isOn: $onlyWon) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("只看真有人中了一等奖的期")
                            Text("有的期一等奖没人中").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                    RowDivider()
                    HStack {
                        Text("查多少期")
                        Spacer()
                        Picker("", selection: $range) {
                            Text("近 500 期").tag(500)
                            Text("近 1000 期").tag(1000)
                            Text("全部").tag(0)
                        }
                        .pickerStyle(.menu).tint(.secondary)
                    }
                    .padding(.vertical, 6)
                }

                Button {
                    Task { await run() }
                } label: {
                    HStack {
                        if loading { ProgressView() }
                        Text(loading ? (progress > 0 ? "已取 \(progress) 期开奖…" : "查询中…") : "开始查").font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .glassButton()
                .disabled(loading)

                if let error {
                    Text(error).font(.footnote).foregroundStyle(.orange)
                }

                if let results {
                    summary(results)
                    ForEach(results.prefix(200)) { m in matchCard(m) }
                    if results.count > 200 {
                        Text("只列出最近的 200 组").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
            .padding(.bottom, 100)
        }
        .background(AppBackground())
        .navigationTitle("头奖号码回看")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .onChange(of: game) { _, _ in
            results = nil
            minHits = min(max(minHits, hitRange.lowerBound), hitRange.upperBound)
        }
    }

    private func summary(_ r: [Match]) -> some View {
        let total = r.reduce(0) { $0 + $1.hits.count }
        return VStack(alignment: .leading, spacing: 6) {
            Text("查了 \(scanned) 期").font(.headline)
            Text(summaryText(r.count, total))
                .font(.subheadline.weight(.semibold))
            Text("每期开奖号码都是独立随机的，这里只是看看历史巧合，不代表以后会不会再开。")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(22)
    }

    private func firstText(_ p: LotteryPrize) -> String {
        let each: String = p.amount.isEmpty ? "" : "，每注 " + LotteryFormat.yuan(p.amount)
        return "当期一等奖 \(p.count) 注\(each)"
    }

    private func hitTitle(_ h: Hit) -> String {
        let day: String = String(h.draw.date.prefix(10))
        let b: String = h.backIdx.isEmpty ? "" : " + " + backName
        return "第\(h.draw.issue)期（\(day)）中了 \(h.frontIdx.count) 个\(b)"
    }

    private func summaryText(_ n: Int, _ total: Int) -> String {
        if n == 0 { return "没有找到符合条件的号码" }
        let more: String = minHits < hitRange.upperBound ? "及以上" : ""
        let withBack: String = needBack ? "（含" + backName + "）" : ""
        return "有 \(n) 期的一等奖号码，在别的期里一共 \(total) 次中了 \(minHits) 个\(more)\(withBack)"
    }

    private func matchCard(_ m: Match) -> some View {
        let first = m.jackpot.prizes.first { $0.name.contains("一等") }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("第\(m.jackpot.issue)期 一等奖号码").font(.subheadline.weight(.bold))
                Spacer()
                Text(String(m.jackpot.date.prefix(10))).font(.caption).foregroundStyle(.secondary)
            }
            LotteryBalls(game: game, front: m.jackpot.front, back: m.jackpot.back, size: 26)
            if let first, !first.count.isEmpty {
                Text(firstText(first))
                    .font(.caption).foregroundStyle(Color(red: 1, green: 0.75, blue: 0.3))
            }
            Divider().overlay(Color.white.opacity(0.08))
            ForEach(m.hits) { h in
                VStack(alignment: .leading, spacing: 4) {
                    Text(hitTitle(h))
                        .font(.caption.weight(.semibold))
                    LotteryBalls(game: game, front: h.draw.front, back: h.draw.back, size: 22,
                                 hitFront: h.frontIdx, hitBack: h.backIdx)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(18)
    }

    private func run() async {
        error = nil
        results = nil
        loading = true
        progress = 0
        defer { loading = false }
        do {
            let g = game
            let list = try await LotteryAPI.longHistory(g, limit: range) { n in
                Task { @MainActor in progress = n }
            }
            let need = minHits, back = needBack, won = onlyWon
            let found = await Task.detached(priority: .userInitiated) {
                Self.compute(list, game: g, minHits: need, needBack: back, onlyWon: won)
            }.value
            scanned = list.count
            withAnimation { results = found }
        } catch {
            self.error = "获取历史开奖失败：\(error.localizedDescription)"
        }
    }

    /// 两两比较（用位运算，几千期也很快）
    nonisolated static func compute(_ list: [LotteryDraw], game: LotteryGame, minHits: Int, needBack: Bool, onlyWon: Bool) -> [Match] {
        struct D { let draw: LotteryDraw; let f: [Int]; let b: [Int]; let fm: UInt64; let bm: UInt64; let won: Bool }
        let ds: [D] = list.map { d in
            let f = d.front.compactMap { Int($0) }, b = d.back.compactMap { Int($0) }
            let fm = f.reduce(UInt64(0)) { $0 | (UInt64(1) << UInt64(max(0, min(63, $1)))) }
            let bm = b.reduce(UInt64(0)) { $0 | (UInt64(1) << UInt64(max(0, min(63, $1)))) }
            let p = d.prizes.first { $0.name.contains("一等") }
            let cnt = Int(p?.count.filter(\.isNumber) ?? "") ?? 0
            return D(draw: d, f: f, b: b, fm: fm, bm: bm, won: cnt > 0)
        }
        var out: [Match] = []
        for j in ds where !onlyWon || j.won {
            guard !j.f.isEmpty else { continue }
            var hits: [Hit] = []
            for e in ds where e.draw.issue != j.draw.issue {
                var fIdx = Set<Int>(), bIdx = Set<Int>()
                if game == .qxc {
                    // 七星彩按位置比
                    for i in 0..<min(6, min(j.f.count, e.f.count)) where j.f[i] == e.f[i] { fIdx.insert(i) }
                    if fIdx.count < minHits { continue }
                    if let x = e.b.first, let y = j.b.first, x == y { bIdx.insert(0) }
                } else {
                    let common = j.fm & e.fm
                    if common.nonzeroBitCount < minHits { continue }
                    fIdx = Set(e.f.indices.filter { common & (UInt64(1) << UInt64(e.f[$0])) != 0 })
                    let cb = j.bm & e.bm
                    bIdx = Set(e.b.indices.filter { cb & (UInt64(1) << UInt64(e.b[$0])) != 0 })
                }
                if needBack && bIdx.isEmpty { continue }
                hits.append(Hit(draw: e.draw, frontIdx: fIdx, backIdx: bIdx))
            }
            if !hits.isEmpty {
                hits.sort { $0.frontIdx.count != $1.frontIdx.count ? $0.frontIdx.count > $1.frontIdx.count
                            : (LotteryAPI.issueNumber($0.draw.issue) ?? 0) > (LotteryAPI.issueNumber($1.draw.issue) ?? 0) }
                out.append(Match(jackpot: j.draw, hits: hits))
            }
        }
        return out.sorted {
            let a = $0.hits.map(\.frontIdx.count).max() ?? 0, b = $1.hits.map(\.frontIdx.count).max() ?? 0
            if a != b { return a > b }
            return (LotteryAPI.issueNumber($0.jackpot.issue) ?? 0) > (LotteryAPI.issueNumber($1.jackpot.issue) ?? 0)
        }
    }
}
