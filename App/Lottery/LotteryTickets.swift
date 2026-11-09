import SwiftUI

// 我的彩票：拍照对奖过的票自动存下来（多期票只扫一次），每次打开自动把已开奖的期对一遍

struct MyTicket: Codable, Identifiable, Hashable {
    struct Bet: Codable, Hashable {
        var front: [Int]
        var back: [Int]
        var multiple: Int
        var pick: Int?
        var added: Bool
    }

    var id: String               // 玩法|起始期|结束期|倍数|追加|号码 —— 同一张票只存一条
    var game: LotteryGame
    var issueFrom: String
    var issueTo: String          // 空 = 单期
    var multiple: Int
    var added: Bool
    var bets: [Bet]
    var photo: Data?
    var savedAt = Date()          // 扫票时间
    var ticketNo: String = ""     // 票号
    var amount: Double?           // 投注金额（票面）

    /// 投注金额：票面没认出就按注数算
    var cost: Double {
        if let amount { return amount }
        let n = lotteryBets.reduce(0) { sum, b in
            switch game {
            case .ssq: return sum + PrizeCalc.comb(b.front.count, 6) * PrizeCalc.comb(b.back.count, 1) * max(1, b.multiple)
            case .dlt: return sum + PrizeCalc.comb(b.front.count, 5) * PrizeCalc.comb(b.back.count, 2) * max(1, b.multiple)
            case .kl8: return sum + PrizeCalc.comb(b.front.count, b.pick ?? b.front.count) * max(1, b.multiple)
            default: return sum + max(1, b.multiple)
            }
        }
        return Double(n * (game == .dlt && added ? 3 : 2) * multiple * periods)
    }

    var periods: Int {
        guard !issueTo.isEmpty, let a = LotteryAPI.issueNumber(issueFrom), let b = LotteryAPI.issueNumber(issueTo), b >= a else { return 1 }
        return b - a + 1
    }
    var lotteryBets: [LotteryBet] { bets.map { LotteryBet(front: $0.front, back: $0.back, multiple: $0.multiple, pick: $0.pick, added: $0.added) } }
    var scan: TicketScan {
        TicketScan(game: game, issue: issueFrom, issueTo: issueTo, bets: lotteryBets, added: added, multiple: multiple)
    }

    static func key(game: LotteryGame, from: String, to: String, multiple: Int, added: Bool, bets: [LotteryBet]) -> String {
        let b = bets.map { $0.front.map(String.init).joined(separator: ",") + "+" + $0.back.map(String.init).joined(separator: ",") + "x\($0.multiple)" }
            .sorted().joined(separator: ";")
        return [game.rawValue, from, to == from ? "" : to, "\(multiple)", added ? "A" : "", b].joined(separator: "|")
    }
}

extension Notification.Name {
    static let lotteryTicketsChanged = Notification.Name("lotteryTicketsChanged")
}

enum LotteryTickets {
    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("lottery_tickets.json")
    }
    private static var memo: [MyTicket]?

    static func load() -> [MyTicket] {
        if let memo { return memo }
        guard let d = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([MyTicket].self, from: d) else { memo = []; return [] }
        memo = list
        return list
    }

    static func save(_ list: [MyTicket]) {
        memo = list
        if let d = try? JSONEncoder().encode(list) { try? d.write(to: url, options: .atomic) }
        AutoBackup.schedule()
        NotificationCenter.default.post(name: .lotteryTicketsChanged, object: nil)
    }

    /// 存一张票，返回它的 id。
    /// - replacing：同一张照片之前存过的那条（改了期号、号码就更新它，不会多出一张）
    /// - 有票号的按票号认，同一张票扫几次都只有一条
    @discardableResult
    static func upsert(_ s: TicketScan, photo: UIImage?, replacing: String? = nil) -> String? {
        guard !s.bets.isEmpty, !s.issue.isEmpty else { return replacing }
        let to = s.issueTo == s.issue ? "" : s.issueTo
        let no = s.ticketNo.replacingOccurrences(of: " ", with: "")
        var list = load()
        let thumb = photo.flatMap(small)
        let i = list.firstIndex { $0.id == replacing }
            ?? (no.isEmpty ? nil : list.firstIndex { $0.ticketNo.replacingOccurrences(of: " ", with: "") == no && $0.game == s.game })
            ?? list.firstIndex { $0.id == MyTicket.key(game: s.game, from: s.issue, to: to, multiple: s.multiple, added: s.added, bets: s.bets) }
        let bets = s.bets.map { MyTicket.Bet(front: $0.front, back: $0.back, multiple: max(1, $0.multiple), pick: $0.pick, added: $0.added) }
        let id: String
        if let i {
            id = list[i].id
            list[i].game = s.game
            list[i].issueFrom = s.issue
            list[i].issueTo = to
            list[i].multiple = max(1, s.multiple)
            list[i].added = s.added
            list[i].bets = bets
            if let thumb { list[i].photo = thumb }
            if !no.isEmpty { list[i].ticketNo = no }
            if let a = s.amount { list[i].amount = a }
        } else {
            id = UUID().uuidString
            list.append(MyTicket(id: id, game: s.game, issueFrom: s.issue, issueTo: to, multiple: max(1, s.multiple), added: s.added,
                                 bets: bets, photo: thumb, ticketNo: no, amount: s.amount))
        }
        save(list)
        return id
    }

    static func delete(_ id: String) { save(load().filter { $0.id != id }) }

    private static func small(_ img: UIImage) -> Data? {
        let maxSide: CGFloat = 900
        let scale = min(1, maxSide / max(img.size.width, img.size.height))
        let size = CGSize(width: img.size.width * scale, height: img.size.height * scale)
        return UIGraphicsImageRenderer(size: size).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }.jpegData(compressionQuality: 0.7)
    }

    // 备份
    static func exportData() -> Data? { try? JSONEncoder().encode(load()) }
    static func importData(_ data: Data) -> Int {
        guard let incoming = try? JSONDecoder().decode([MyTicket].self, from: data) else { return 0 }
        var list = load(), added = 0
        for t in incoming where !list.contains(where: { $0.id == t.id }) { list.append(t); added += 1 }
        if added > 0 { save(list) }
        return added
    }

    /// 一张票的对奖情况
    struct Status {
        var opened = 0          // 已开奖几期
        var pending = 0         // 还没开几期
        var wonPeriods = 0
        var money = 0.0
        var floating = false
        var error: String?
    }

    /// 把已开奖的期对一遍；中了的顺便记到「中奖」栏
    static func check(_ t: MyTicket) async -> Status {
        var st = Status()
        do {
            let r = try await LotteryAPI.draws(t.game, from: t.issueFrom, to: t.issueTo.isEmpty ? nil : t.issueTo, periods: nil)
            st.opened = r.draws.count
            st.pending = max(0, t.periods - r.draws.count)
            let photo = t.photo.flatMap(UIImage.init(data:))
            for d in r.draws {
                let res = t.lotteryBets.map { b -> BetResult in
                    var b = b
                    if t.game == .dlt && t.added { b.added = true }
                    return PrizeCalc.check(b, draw: d, game: t.game, multiple: t.multiple * max(1, b.multiple))
                }
                let hits = res.flatMap(\.hits)
                if !hits.isEmpty {
                    st.wonPeriods += 1
                    st.money += hits.compactMap(\.total).reduce(0, +)
                    if hits.contains(where: { $0.each == nil }) { st.floating = true }
                    LotteryWins.record(game: t.game, draw: d, results: res, factor: t.multiple, photo: photo)
                }
            }
        } catch {
            st.error = error.localizedDescription
        }
        return st
    }
}

// MARK: - 「我的彩票」栏

struct LotteryTicketsPane: View {
    let onOpen: (MyTicket) -> Void
    @State private var tickets: [MyTicket] = LotteryTickets.load()
    @State private var status: [String: LotteryTickets.Status] = [:]
    @State private var filter = 0      // 0 全部 1 待开奖 2 已中奖

    private func pending(_ t: MyTicket) -> Bool { (status[t.id]?.pending ?? 1) > 0 }
    private func won(_ t: MyTicket) -> Bool { (status[t.id]?.wonPeriods ?? 0) > 0 }

    private var shown: [MyTicket] {
        tickets.filter { filter == 0 || (filter == 1 && pending($0)) || (filter == 2 && won($0)) }
            .sorted { $0.savedAt > $1.savedAt }
    }

    var body: some View {
        VStack(spacing: 12) {
            Picker("", selection: $filter) {
                Text("全部").tag(0)
                Text("待开奖").tag(1)
                Text("已中奖").tag(2)
            }
            .pickerStyle(.segmented)

            if shown.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "ticket").font(.system(size: 34)).foregroundStyle(.secondary)
                    Text(tickets.isEmpty ? "还没有彩票" : filter == 1 ? "没有待开奖的票" : "还没有中奖的票").font(.headline)
                    if tickets.isEmpty {
                        Text("拍照对奖过的票会自动存到这里。多期票只要扫一次，以后每开一期打开这里就自动对奖。")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(24)
                .glassCard(22)
            } else {
                ForEach(shown) { t in
                    Button { onOpen(t) } label: { card(t) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                LotteryTickets.delete(t.id)
                            } label: { Label("删除这张票", systemImage: "trash") }
                        }
                }
                Text("没有更多了 · 长按一张票可以删除").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .lotteryTicketsChanged)) { _ in
            tickets = LotteryTickets.load()
            Task { await refresh() }
        }
    }

    private func refresh() async {
        for t in tickets {
            let s = await LotteryTickets.check(t)
            withAnimation { status[t.id] = s }
        }
    }

    private func card(_ t: MyTicket) -> some View {
        let s = status[t.id]
        let red = Color(red: 1, green: 0.4, blue: 0.35)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return VStack(alignment: .leading, spacing: 0) {
            Text("票号：" + (t.ticketNo.isEmpty ? "未识别" : t.ticketNo.replacingOccurrences(of: "-", with: "")))
                .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.7)
                .padding(.bottom, 10)
            Divider().overlay(Color.white.opacity(0.08))
            HStack(alignment: .center, spacing: 14) {
                badge(t)
                VStack(alignment: .leading, spacing: 6) {
                    Text(t.game.name + " " + (t.periods > 1 ? "\(t.issueFrom)~\(t.issueTo)期" : "\(t.issueFrom)期"))
                        .font(.headline).lineLimit(1).minimumScaleFactor(0.8)
                    HStack(spacing: 0) {
                        Text("投注")
                        Text(String(format: "%.0f", t.cost)).foregroundStyle(red)
                        Text("元" + (t.periods > 1 ? " · \(t.periods)期" : ""))
                    }
                    .font(.subheadline)
                    Text("扫票时间：" + f.string(from: t.savedAt)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 4) {
                    resultText(t, s, red: red)
                    if let s, t.periods > 1 {
                        Text("已开 \(s.opened)/\(t.periods)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 12)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(18)
    }

    @ViewBuilder
    private func resultText(_ t: MyTicket, _ s: LotteryTickets.Status?, red: Color) -> some View {
        if let s {
            if s.error != nil && s.opened == 0 {
                Text("对奖失败").font(.subheadline).foregroundStyle(.orange)
            } else if s.wonPeriods > 0 {
                Text("中奖" + String(format: "%.0f", s.money) + "元" + (s.floating ? "+" : ""))
                    .font(.title3.weight(.semibold)).foregroundStyle(red)
            } else if s.opened == 0 {
                Text("待开奖").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            } else if s.pending > 0 {
                Text("待开奖").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            } else {
                Text("未中奖").font(.subheadline).foregroundStyle(.secondary)
            }
        } else {
            ProgressView()
        }
    }

    /// 左边：票的照片；没有就用玩法色块
    @ViewBuilder
    private func badge(_ t: MyTicket) -> some View {
        if let d = t.photo, let img = UIImage(data: d) {
            Image(uiImage: img).resizable().scaledToFill()
                .frame(width: 56, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            Text(t.game.shortName)
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .frame(width: 56, height: 56)
                .background(Circle().fill(t.game.frontColor.gradient))
        }
    }
}
