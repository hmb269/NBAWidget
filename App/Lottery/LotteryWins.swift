import SwiftUI

// 中奖记录：扫码 / 手输 / 收藏对奖时，只要中了就自动存一条，集中显示奖金和兑奖期限

struct LotteryWin: Codable, Identifiable, Hashable {
    struct Hit: Codable, Hashable {
        var name: String
        var count: Int
        var each: Double?      // nil = 浮动奖
    }

    var id: String             // 玩法|期号|号码|倍数|追加 —— 同一注同一期只存一条
    var game: LotteryGame
    var issue: String
    var drawDate: String       // 「2026-10-24」
    var drawFront: [String]
    var drawBack: [String]
    var front: [Int]
    var back: [Int]
    var multiple: Int
    var added: Bool
    var pick: Int?
    var hits: [Hit]
    var claimed = false
    var savedAt = Date()
    var photo: Data?           // 彩票照片小图（拍照对奖时才有）

    var money: Double { hits.compactMap { h in h.each.map { $0 * Double(h.count) } }.reduce(0, +) }
    var floating: Bool { hits.contains { $0.each == nil } }

    var deadline: Date? {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: String(drawDate.prefix(10))) else { return nil }
        return Calendar.current.date(byAdding: .day, value: 60, to: d)
    }
    var daysLeft: Int? {
        guard let end = deadline else { return nil }
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: end).day
    }
    var expired: Bool { (daysLeft ?? 0) < 0 }

    var bet: LotteryBet { LotteryBet(front: front, back: back, multiple: multiple, pick: pick, added: added) }
}

extension Notification.Name {
    static let lotteryWinsChanged = Notification.Name("lotteryWinsChanged")
}

enum LotteryWins {
    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("lottery_wins.json")
    }

    private static var memo: [LotteryWin]?

    static func load() -> [LotteryWin] {
        if let memo { return memo }
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([LotteryWin].self, from: data) else { memo = []; return [] }
        memo = list
        return list
    }

    static func save(_ list: [LotteryWin]) {
        memo = list
        if let data = try? JSONEncoder().encode(list) { try? data.write(to: url, options: .atomic) }
        AutoBackup.schedule()
        NotificationCenter.default.post(name: .lotteryWinsChanged, object: nil)
    }

    /// 对奖结果里中奖的注都存起来（已有的更新奖金，保留「已兑奖」状态和照片）
    /// - factor：整张票的倍数（每注自己的倍数之外再乘的）
    static func record(game: LotteryGame, draw: LotteryDraw, results: [BetResult], factor: Int, photo: UIImage?) {
        let won = results.filter { !$0.hits.isEmpty }
        guard !won.isEmpty else { return }
        var list = load()
        let thumb = photo.flatMap { small($0) }
        for r in won {
            let b = r.bet
            let mult = max(1, b.multiple) * max(1, factor)
            let id = [game.rawValue, draw.issue, b.front.map(String.init).joined(separator: ","),
                      b.back.map(String.init).joined(separator: ","), "\(mult)", b.added ? "A" : ""].joined(separator: "|")
            var w = LotteryWin(id: id, game: game, issue: draw.issue, drawDate: String(draw.date.prefix(10)),
                               drawFront: draw.front, drawBack: draw.back, front: b.front, back: b.back,
                               multiple: mult, added: b.added, pick: b.pick,
                               hits: r.hits.map { LotteryWin.Hit(name: $0.name, count: $0.count, each: $0.each) },
                               photo: thumb)
            if let i = list.firstIndex(where: { $0.id == id }) {
                w.claimed = list[i].claimed
                w.savedAt = list[i].savedAt
                w.photo = thumb ?? list[i].photo
                list[i] = w
            } else {
                list.append(w)
            }
        }
        save(list)
    }

    private static func small(_ img: UIImage) -> Data? {
        let maxSide: CGFloat = 480
        let scale = min(1, maxSide / max(img.size.width, img.size.height))
        let size = CGSize(width: img.size.width * scale, height: img.size.height * scale)
        let r = UIGraphicsImageRenderer(size: size)
        return r.image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }.jpegData(compressionQuality: 0.7)
    }

    // 备份
    static func exportData() -> Data? { try? JSONEncoder().encode(load()) }

    static func importData(_ data: Data) -> Int {
        guard let incoming = try? JSONDecoder().decode([LotteryWin].self, from: data) else { return 0 }
        var list = load(), added = 0
        for w in incoming where !list.contains(where: { $0.id == w.id }) { list.append(w); added += 1 }
        if added > 0 { save(list) }
        return added
    }
}

// MARK: - 「中奖」栏

struct LotteryWinsPane: View {
    @State private var wins: [LotteryWin] = LotteryWins.load()
    @State private var showClaimed = true
    @State private var photo: LotteryWin?

    /// 待兑奖的按截止日期排前面；已兑奖、已过期的放后面
    private var sorted: [LotteryWin] {
        wins.sorted { a, b in
            let ra = a.claimed ? 2 : (a.expired ? 1 : 0), rb = b.claimed ? 2 : (b.expired ? 1 : 0)
            if ra != rb { return ra < rb }
            return (a.deadline ?? .distantFuture) < (b.deadline ?? .distantFuture)
        }
    }

    var body: some View {
        let pending = wins.filter { !$0.claimed && !$0.expired }
        let pendingMoney = pending.map(\.money).reduce(0, +)
        VStack(spacing: 14) {
            // 汇总
            VStack(spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("待兑奖").font(.caption).foregroundStyle(.secondary)
                        Text(pending.isEmpty ? "没有" : "\(pending.count) 注")
                            .font(.title2.weight(.bold))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("合计奖金").font(.caption).foregroundStyle(.secondary)
                        Text(LotteryFormat.yuan(String(format: "%.0f", pendingMoney)) + (pending.contains(where: \.floating) ? "+" : ""))
                            .font(.title2.weight(.bold).monospacedDigit())
                            .foregroundStyle(.orange)
                    }
                }
                if let first = pending.min(by: { ($0.deadline ?? .distantFuture) < ($1.deadline ?? .distantFuture) }),
                   let left = first.daysLeft {
                    Label("最近一张 \(first.game.shortName) 第\(first.issue)期，还剩 \(left) 天截止兑奖",
                          systemImage: "calendar.badge.clock")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(left <= 7 ? Color.red : Color.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
            .glassCard(22)

            if wins.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "trophy").font(.system(size: 34)).foregroundStyle(.yellow)
                    Text("还没有中奖记录").font(.headline)
                    Text("拍照对奖、手输对奖或收藏对奖时，中了奖会自动记到这里，提醒你兑奖期限。")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(22)
                .glassCard(22)
            }

            ForEach(sorted) { w in
                winCard(w)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .lotteryWinsChanged)) { _ in wins = LotteryWins.load() }
        .onAppear { wins = LotteryWins.load() }
        .sheet(item: $photo) { w in
            if let d = w.photo, let img = UIImage(data: d) {
                Image(uiImage: img).resizable().scaledToFit().padding()
                    .presentationDetents([.large])
                    .presentationBackground(.ultraThinMaterial)
            }
        }
    }

    private func winCard(_ w: LotteryWin) -> some View {
        let dim = w.claimed || w.expired
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(w.game.shortName).font(.headline)
                Text("第\(w.issue)期").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Text(w.money > 0 ? LotteryFormat.yuan(String(format: "%.0f", w.money)) + (w.floating ? "+" : "") : "浮动奖")
                    .font(.title3.weight(.bold).monospacedDigit())
                    .foregroundStyle(dim ? Color.secondary : Color.orange)
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("开奖号码 · " + w.drawDate).font(.caption2).foregroundStyle(.tertiary)
                    LotteryBalls(game: w.game, front: w.drawFront, back: w.drawBack, size: w.game == .kl8 ? 20 : 24)
                    Text("我的号码").font(.caption2).foregroundStyle(.tertiary)
                    let r = PrizeCalc.check(w.bet, draw: LotteryDraw(issue: w.issue, date: w.drawDate, front: w.drawFront,
                                                                     back: w.drawBack, pool: nil, sales: nil, prizes: []),
                                            game: w.game, multiple: 1)
                    LotteryBalls(game: w.game, front: w.bet.frontStrings(w.game), back: w.bet.backStrings(w.game),
                                 size: w.game == .kl8 ? 20 : 24, hitFront: r.frontHitIdx, hitBack: r.backHitIdx)
                }
                Spacer(minLength: 0)
                if let d = w.photo, let img = UIImage(data: d) {
                    Button { photo = w } label: {
                        Image(uiImage: img).resizable().scaledToFill()
                            .frame(width: 56, height: 74)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(w.hits.map { "\($0.name) × \($0.count)" + ($0.each.map { " " + LotteryFormat.yuan(String(format: $0 < 100 && $0 != $0.rounded() ? "%.1f" : "%.0f", $0)) } ?? " 浮动") }
                .joined(separator: "、") + (w.multiple > 1 ? "（\(w.multiple) 倍）" : "") + (w.added ? "（追加）" : ""))
                .font(.caption.weight(.semibold))
                .foregroundStyle(dim ? Color.secondary : Color.orange)

            HStack {
                if w.claimed {
                    Label("已兑奖", systemImage: "checkmark.seal.fill").font(.caption.weight(.semibold)).foregroundStyle(.green)
                } else if let left = w.daysLeft, let end = w.deadline {
                    let f = { () -> String in let x = DateFormatter(); x.locale = Locale(identifier: "zh_CN"); x.dateFormat = "M月d日"; return x.string(from: end) }()
                    Label(left < 0 ? "已过兑奖期（\(f)截止）" : "兑奖截止 \(f)，还剩 \(left) 天", systemImage: "calendar.badge.clock")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(left < 0 ? Color.secondary : (left <= 7 ? Color.red : Color.green))
                }
                Spacer()
                Menu {
                    Button(w.claimed ? "标记为未兑奖" : "标记为已兑奖", systemImage: "checkmark.seal") { toggleClaimed(w) }
                    Button("删除这条记录", systemImage: "trash", role: .destructive) { delete(w) }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(.secondary)
                }
                if !w.claimed && !w.expired {
                    Button { toggleClaimed(w) } label: {
                        Label("已兑", systemImage: "checkmark").font(.caption.weight(.semibold))
                    }
                    .glassButton()
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(22)
        .opacity(dim ? 0.6 : 1)
    }

    private func toggleClaimed(_ w: LotteryWin) {
        guard let i = wins.firstIndex(where: { $0.id == w.id }) else { return }
        withAnimation { wins[i].claimed.toggle() }
        LotteryWins.save(wins)
    }

    private func delete(_ w: LotteryWin) {
        withAnimation { wins.removeAll { $0.id == w.id } }
        LotteryWins.save(wins)
    }
}
