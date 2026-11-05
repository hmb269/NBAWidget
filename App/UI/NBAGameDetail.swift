import SwiftUI

// 比赛详情：比分、每节得分、两队数据、球员数据（ESPN summary 接口）

struct BoxPlayer: Identifiable, Hashable {
    var id: String
    var name: String          // 中文名（有的话）或英文简写
    var fullName: String
    var position: String
    var starter: Bool
    var dnp: String?          // 没上场的原因
    var stats: [String: String]   // MIN / PTS / REB / AST / FG / 3PT / FT / STL / BLK / TO / +/- / PF
    func n(_ k: String) -> Int { Int(stats[k] ?? "") ?? 0 }
}

struct BoxTeam: Hashable {
    var code: String
    var name: String
    var score: String
    var quarters: [String]
    var players: [BoxPlayer]
    var totals: [String: String]
}

struct GameSummary {
    var state: String
    var detail: String
    var away: BoxTeam
    var home: BoxTeam
}

enum NBAGameAPI {
    static func summary(_ id: String) async throws -> GameSummary {
        let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/basketball/nba/summary?event=\(id)")!
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw NSError(domain: "阿波", code: 1, userInfo: [NSLocalizedDescriptionKey: "数据格式不对"])
        }
        let header = root["header"] as? [String: Any]
        let comp = (header?["competitions"] as? [[String: Any]])?.first ?? [:]
        let status = ((comp["status"] as? [String: Any])?["type"] as? [String: Any]) ?? [:]
        let competitors = (comp["competitors"] as? [[String: Any]]) ?? []

        // 球员数据按球队代码分组
        var boxByCode: [String: ([BoxPlayer], [String: String])] = [:]
        let box = root["boxscore"] as? [String: Any]
        for t in (box?["players"] as? [[String: Any]]) ?? [] {
            let code = NBAService.canonical(((t["team"] as? [String: Any])?["abbreviation"] as? String) ?? "")
            guard let st = (t["statistics"] as? [[String: Any]])?.first else { continue }
            let labels = ((st["labels"] as? [String]) ?? (st["names"] as? [String]) ?? []).map { $0.uppercased() }
            func row(_ arr: [String]) -> [String: String] {
                var m: [String: String] = [:]
                for (i, l) in labels.enumerated() where i < arr.count { m[l] = arr[i] }
                return m
            }
            let players: [BoxPlayer] = ((st["athletes"] as? [[String: Any]]) ?? []).compactMap { a in
                guard let ath = a["athlete"] as? [String: Any] else { return nil }
                let full = ath["displayName"] as? String ?? ""
                let short = ath["shortName"] as? String ?? full
                let stats = (a["stats"] as? [String]) ?? []
                let dnp = (a["didNotPlay"] as? Bool) == true || stats.isEmpty
                return BoxPlayer(
                    id: ath["id"] as? String ?? full,
                    name: NBAPlayers.chinese[full] ?? short,
                    fullName: full,
                    position: (ath["position"] as? [String: Any])?["abbreviation"] as? String ?? "",
                    starter: a["starter"] as? Bool ?? false,
                    dnp: dnp ? ((a["reason"] as? String).map(NBAPlayers.reason) ?? "未上场") : nil,
                    stats: row(stats))
            }
            boxByCode[code] = (players, row((st["totals"] as? [String]) ?? []))
        }

        func team(_ side: String) -> BoxTeam {
            let c = competitors.first { ($0["homeAway"] as? String) == side } ?? [:]
            let t = c["team"] as? [String: Any] ?? [:]
            let raw = t["abbreviation"] as? String ?? ""
            let code = NBAService.canonical(raw)
            let q = ((c["linescores"] as? [[String: Any]]) ?? []).map {
                ($0["displayValue"] as? String) ?? LotteryFormat.string($0["value"])
            }
            let b = boxByCode[code] ?? ([], [:])
            return BoxTeam(code: code, name: NBAService.teams[raw] ?? NBAService.teams[code] ?? raw,
                           score: LotteryFormat.string(c["score"]), quarters: q, players: b.0, totals: b.1)
        }

        return GameSummary(state: status["state"] as? String ?? "",
                           detail: status["shortDetail"] as? String ?? "",
                           away: team("away"), home: team("home"))
    }
}

/// 常见球星的中文名（ESPN 只有英文）
enum NBAPlayers {
    static let chinese: [String: String] = [
        "LeBron James": "詹姆斯", "Luka Doncic": "东契奇", "Austin Reaves": "里夫斯", "Rui Hachimura": "八村塁",
        "Deandre Ayton": "艾顿", "Marcus Smart": "斯玛特", "Jaxson Hayes": "海耶斯", "Dalton Knecht": "克内克特",
        "Joel Embiid": "恩比德", "Tyrese Maxey": "马克西", "Paul George": "乔治", "VJ Edgecombe": "埃奇库姆",
        "Kelly Oubre Jr.": "乌布雷", "Andre Drummond": "德拉蒙德", "Quentin Grimes": "格莱姆斯",
        "Stephen Curry": "库里", "Jimmy Butler III": "巴特勒", "Jimmy Butler": "巴特勒", "Draymond Green": "格林",
        "Kevin Durant": "杜兰特", "Devin Booker": "布克", "Nikola Jokic": "约基奇", "Jamal Murray": "穆雷",
        "Giannis Antetokounmpo": "字母哥", "Damian Lillard": "利拉德", "Jayson Tatum": "塔图姆", "Jaylen Brown": "杰伦·布朗",
        "Shai Gilgeous-Alexander": "亚历山大", "Chet Holmgren": "霍姆格伦", "Jalen Williams": "杰伦·威廉姆斯",
        "Anthony Edwards": "爱德华兹", "Rudy Gobert": "戈贝尔", "Julius Randle": "兰德尔",
        "Victor Wembanyama": "文班亚马", "De'Aaron Fox": "福克斯", "Anthony Davis": "浓眉", "Kyrie Irving": "欧文",
        "Klay Thompson": "汤普森", "Jalen Brunson": "布伦森", "Karl-Anthony Towns": "唐斯", "OG Anunoby": "阿奴诺比",
        "Mikal Bridges": "布里奇斯", "Donovan Mitchell": "米切尔", "Darius Garland": "加兰", "Evan Mobley": "莫布利",
        "Jarrett Allen": "阿伦", "Tyrese Haliburton": "哈利伯顿", "Pascal Siakam": "西亚卡姆", "Trae Young": "特雷·杨",
        "Jalen Johnson": "杰伦·约翰逊", "Ja Morant": "莫兰特", "Jaren Jackson Jr.": "小贾伦·杰克逊",
        "Zion Williamson": "锡安", "Paolo Banchero": "班凯罗", "Franz Wagner": "弗朗茨·瓦格纳",
        "Bam Adebayo": "阿德巴约", "Tyler Herro": "希罗", "Kawhi Leonard": "伦纳德", "James Harden": "哈登",
        "Ivica Zubac": "祖巴茨", "Domantas Sabonis": "萨博尼斯", "Zach LaVine": "拉文", "DeMar DeRozan": "德罗赞",
        "Lauri Markkanen": "马尔卡宁", "Alperen Sengun": "申京", "Amen Thompson": "阿门·汤普森", "Fred VanVleet": "范弗里特",
        "Cade Cunningham": "康宁汉姆", "Scottie Barnes": "巴恩斯", "LaMelo Ball": "拉梅洛·鲍尔", "Brandon Miller": "布兰登·米勒",
        "Cooper Flagg": "弗拉格", "Derrick White": "怀特", "Jrue Holiday": "霍勒迪", "Kristaps Porzingis": "波尔津吉斯",
        "Cam Thomas": "卡姆·托马斯", "Michael Porter Jr.": "小波特", "Aaron Gordon": "戈登", "Deni Avdija": "阿夫迪亚",
        "Scoot Henderson": "亨德森", "Josh Giddey": "吉迪", "Coby White": "科比·怀特", "Desmond Bane": "贝恩",
        "Jamal Shead": "希德", "Bradley Beal": "比尔", "Chris Paul": "保罗", "Russell Westbrook": "威少",
        "Dyson Daniels": "戴森·丹尼尔斯", "Kristaps Porziņģis": "波尔津吉斯", "Myles Turner": "特纳",
    ]

    static func reason(_ s: String) -> String {
        let l = s.lowercased()
        if l.contains("coach") { return "教练决定" }
        if l.contains("injur") || l.contains("knee") || l.contains("ankle") || l.contains("hamstring") || l.contains("back") { return "伤病" }
        if l.contains("illness") { return "生病" }
        if l.contains("rest") { return "轮休" }
        if l.contains("personal") { return "个人原因" }
        if l.contains("suspen") { return "禁赛" }
        if l.contains("g league") || l.contains("assign") { return "下放发展联盟" }
        return "未上场"
    }
}

// MARK: - 页面

struct NBAGameDetailView: View {
    let game: Game
    @State private var s: GameSummary?
    @State private var error: String?
    @State private var side = 0          // 0 客队 1 主队
    @State private var sortKey = "PTS"
    private let red = Color(red: 1.0, green: 0.30, blue: 0.35)

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                scoreCard
                if let s {
                    if !s.away.quarters.isEmpty { quarterCard(s) }
                    if !s.away.players.isEmpty || !s.home.players.isEmpty {
                        leadersCard(s)
                        boxCard(s)
                    } else {
                        Text(s.state == "pre" ? "比赛还没开始，开赛后这里会显示球员数据" : "暂时还没有球员数据")
                            .font(.footnote).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(20).glassCard(20)
                    }
                } else if let error {
                    Text(error).font(.footnote).foregroundStyle(.orange).padding().glassCard(16)
                } else {
                    ProgressView().padding(30)
                }
                Text("数据来自 ESPN，比赛进行中每 30 秒自动刷新").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(16)
        }
        .background(AppBackground())
        .navigationTitle("\(game.away) vs \(game.home)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .refreshable { await load() }
        .task {
            await load()
            // 比赛进行中自动刷新
            while !Task.isCancelled, (s?.state ?? game.state) == "in" {
                try? await Task.sleep(for: .seconds(30))
                await load()
            }
        }
    }

    private func load() async {
        do { s = try await NBAGameAPI.summary(game.id); error = nil }
        catch { if s == nil { self.error = "加载失败：\(error.localizedDescription)" } }
    }

    // MARK: 比分

    private var scoreCard: some View {
        let state = s?.state ?? game.state
        let awayScore = s?.away.score ?? "\(game.awayScore)"
        let homeScore = s?.home.score ?? "\(game.homeScore)"
        let aw = Int(awayScore) ?? 0, hm = Int(homeScore) ?? 0
        return HStack {
            teamBlock(game.away, game.awayCode, "客队")
            Spacer()
            VStack(spacing: 4) {
                if state == "pre" {
                    Text(NBAService.timeString(game.time)).font(.system(size: 34, weight: .bold, design: .rounded))
                    Text("北京时间开赛").font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 10) {
                        Text(awayScore).foregroundStyle(state == "post" && aw < hm ? Color.secondary : Color.primary)
                        Text("-").foregroundStyle(.secondary)
                        Text(homeScore).foregroundStyle(state == "post" && hm < aw ? Color.secondary : Color.primary)
                    }
                    .font(.system(size: 38, weight: .heavy, design: .rounded).monospacedDigit())
                    Text(state == "post" ? "已结束" : (s?.detail ?? game.liveText)
                            .replacingOccurrences(of: "Halftime", with: "中场")
                            .replacingOccurrences(of: "End of ", with: ""))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(state == "in" ? red : .secondary)
                }
            }
            Spacer()
            teamBlock(game.home, game.homeCode, "主队")
        }
        .padding(18)
        .glassCard(24)
    }

    private func teamBlock(_ name: String, _ code: String, _ tag: String) -> some View {
        VStack(spacing: 4) {
            Text(name).font(.title3.weight(.bold)).foregroundStyle(myTeams.contains(code) ? red : .primary)
            Text(tag).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(width: 80)
    }

    // MARK: 每节

    private func quarterCard(_ s: GameSummary) -> some View {
        let n = max(s.away.quarters.count, s.home.quarters.count)
        let heads = (0..<n).map { $0 < 4 ? "\($0 + 1)" : "OT\($0 - 3)" }
        return VStack(spacing: 8) {
            row("", heads + ["总"], bold: false, dim: true)
            Divider().overlay(Color.white.opacity(0.08))
            row(s.away.name, s.away.quarters + [s.away.score], bold: true, dim: false)
            row(s.home.name, s.home.quarters + [s.home.score], bold: true, dim: false)
        }
        .padding(16)
        .glassCard(20)
    }

    private func row(_ title: String, _ cells: [String], bold: Bool, dim: Bool) -> some View {
        HStack(spacing: 0) {
            Text(title).font(.subheadline.weight(.semibold)).frame(width: 70, alignment: .leading)
            ForEach(Array(cells.enumerated()), id: \.offset) { i, c in
                Text(c)
                    .font(.system(size: 14, weight: i == cells.count - 1 && bold ? .heavy : .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(dim ? Color.secondary : (i == cells.count - 1 ? Color.orange : Color.primary))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: 两队最佳

    private func leadersCard(_ s: GameSummary) -> some View {
        VStack(spacing: 10) {
            ForEach(Array([("得分", "PTS"), ("篮板", "REB"), ("助攻", "AST")].enumerated()), id: \.offset) { _, item in
                let (title, key) = item
                let a = s.away.players.max { $0.n(key) < $1.n(key) }
                let h = s.home.players.max { $0.n(key) < $1.n(key) }
                HStack {
                    leader(a, key, alignment: .leading)
                    Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 40)
                    leader(h, key, alignment: .trailing)
                }
            }
        }
        .padding(16)
        .glassCard(20)
    }

    private func leader(_ p: BoxPlayer?, _ key: String, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(p.map { "\($0.n(key))" } ?? "-").font(.system(size: 22, weight: .heavy, design: .rounded).monospacedDigit())
            Text(p?.name ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
    }

    // MARK: 球员数据

    private let cols: [(String, String, CGFloat)] = [
        ("MIN", "时间", 34), ("PTS", "得分", 34), ("REB", "篮板", 34), ("AST", "助攻", 34),
        ("FG", "投篮", 46), ("3PT", "三分", 42), ("FT", "罚球", 42),
        ("STL", "抢断", 34), ("BLK", "盖帽", 34), ("TO", "失误", 34), ("PF", "犯规", 34), ("+/-", "+/-", 38),
    ]

    private func boxCard(_ s: GameSummary) -> some View {
        let team = side == 0 ? s.away : s.home
        let players = team.players.filter { $0.dnp == nil }
            .sorted { a, b in
                if sortKey == "starter" { return a.starter && !b.starter }
                return a.n(sortKey) > b.n(sortKey)
            }
        let dnp = team.players.filter { $0.dnp != nil }
        return VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $side) {
                Text(s.away.name).tag(0)
                Text(s.home.name).tag(1)
            }
            .pickerStyle(.segmented)

            Text("点表头可以按那一项排序，左右滑动看更多数据").font(.caption2).foregroundStyle(.tertiary)

            HStack(alignment: .top, spacing: 0) {
                // 名字固定在左边
                VStack(alignment: .leading, spacing: 0) {
                    Button { sortKey = "starter" } label: {
                        Text("球员").font(.caption2.weight(.semibold)).foregroundStyle(sortKey == "starter" ? Color.orange : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .frame(height: 26, alignment: .leading)
                    ForEach(players) { p in
                        HStack(spacing: 4) {
                            Text(p.name).font(.subheadline.weight(p.starter ? .semibold : .regular)).lineLimit(1)
                            if p.starter { Text(p.position).font(.system(size: 9)).foregroundStyle(.secondary) }
                        }
                        .frame(height: 30, alignment: .leading)
                    }
                    Text("全队").font(.subheadline.weight(.bold)).frame(height: 30, alignment: .leading)
                }
                .frame(width: 96, alignment: .leading)

                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 4) {
                            ForEach(Array(cols.enumerated()), id: \.offset) { _, c in
                                Button { sortKey = c.0 } label: {
                                    Text(c.1).font(.caption2.weight(.semibold))
                                        .foregroundStyle(sortKey == c.0 ? Color.orange : Color.secondary)
                                        .frame(width: c.2)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .frame(height: 26)
                        ForEach(players) { p in
                            HStack(spacing: 4) {
                                ForEach(Array(cols.enumerated()), id: \.offset) { _, c in
                                    Text(p.stats[c.0] ?? "-")
                                        .font(.system(size: 13, weight: c.0 == "PTS" ? .bold : .regular, design: .rounded).monospacedDigit())
                                        .foregroundStyle(c.0 == "PTS" ? Color.orange : Color.primary)
                                        .frame(width: c.2)
                                }
                            }
                            .frame(height: 30)
                        }
                        HStack(spacing: 4) {
                            ForEach(Array(cols.enumerated()), id: \.offset) { _, c in
                                Text(team.totals[c.0] ?? "")
                                    .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                                    .frame(width: c.2)
                            }
                        }
                        .frame(height: 30)
                    }
                }
            }

            if !dnp.isEmpty {
                Text("未上场：" + dnp.map { "\($0.name)（\($0.dnp ?? "")）" }.joined(separator: "、"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .glassCard(20)
        .onAppear {
            // 有我关注的球队，默认先看那一队
            if myTeams.contains(s.home.code) && !myTeams.contains(s.away.code) { side = 1 }
        }
    }
}
