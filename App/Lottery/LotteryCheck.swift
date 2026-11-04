import UIKit
import Vision

// 拍照对奖：识别彩票上的文字 → 找出玩法、期号、号码 → 和开奖号码对比算奖级
// 支持：双色球、大乐透（单式/复式）、快乐8（选一~选十）、七星彩（单式）

struct LotteryBet: Identifiable, Hashable {
    var id = UUID()
    var front: [Int]
    var back: [Int]
    var multiple = 1      // 这注的倍数（收藏时一起存）

    func text(_ g: LotteryGame) -> String {
        switch g {
        case .kl8: return front.map { String(format: "%02d", $0) }.joined(separator: " ")
        case .qxc: return front.map(String.init).joined(separator: " ") + " + " + back.map(String.init).joined(separator: " ")
        default:
            return front.map { String(format: "%02d", $0) }.joined(separator: " ") + " + " +
                back.map { String(format: "%02d", $0) }.joined(separator: " ")
        }
    }

    /// 号码显示用的字符串
    func frontStrings(_ g: LotteryGame) -> [String] { g == .qxc ? front.map(String.init) : front.map { String(format: "%02d", $0) } }
    func backStrings(_ g: LotteryGame) -> [String] { g == .qxc ? back.map(String.init) : back.map { String(format: "%02d", $0) } }

    private static let junk = ["年", "月", "日", ":", "：", "期", "元", "站", "机", "销售", "合计", "开奖", "时间", "地址", "验票", "流水", "编号"]

    private static func clean(_ line: String) -> String {
        var s = line
        for (a, b) in [("①", " "), ("②", " "), ("③", " "), ("④", " "), ("⑤", " "), ("O", "0"), ("o", "0"), ("l", "1"), ("I", "1")] {
            s = s.replacingOccurrences(of: a, with: b)
        }
        return s
    }

    private static func split(_ s: String) -> (String, String) {
        let seps = ["+", "＋", "|", "｜", "-", "—", "－", "蓝", "后", "/"]
        if let sep = seps.first(where: { s.contains($0) }), let r = s.range(of: sep, options: .backwards) {
            return (String(s[..<r.lowerBound]), String(s[r.upperBound...]))
        }
        return (s, "")
    }

    /// 从一行文字解析出一注
    /// - kl8Pick：快乐8 的「选几」（认出来了就只接受这么多个号码的行）
    /// - single：票上写着「单式」，每注号码个数是固定的（多出来的是注序号或识别错）
    static func parse(_ line: String, game: LotteryGame, kl8Pick: Int? = nil, strict: Bool = false, single: Bool = false) -> LotteryBet? {
        var s = clean(line)
        if strict, junk.contains(where: { s.contains($0) }) { return nil }
        // 去掉倍数「[10倍]」「(5倍)」「x3」，免得 10 被当成号码
        s = s.replacingOccurrences(of: "[\\[\\(（【]?\\s*\\d+\\s*倍\\s*[\\]\\)）】]?", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "[xX×]\\s*\\d+\\s*$", with: " ", options: .regularExpression)
        switch game {
        case .kl8:
            let nums = Array(Set(numbers(s))).sorted()
            guard (1...10).contains(nums.count), nums.allSatisfy({ (1...80).contains($0) }) else { return nil }
            if let k = kl8Pick, nums.count != k { return nil }
            if strict && kl8Pick == nil && nums.count < 2 { return nil }
            return LotteryBet(front: nums, back: [])
        case .qxc:
            return parseQXC(s)
        default:
            let (fp, bp) = split(s)
            let f = numbers(fp), b = numbers(bp)
            let (fn, bn) = game == .dlt ? (5, 2) : (6, 1)
            let (fmax, bmax) = game == .dlt ? (35, 12) : (33, 16)
            var front = f, back = b
            if back.isEmpty {
                guard f.count >= fn + bn else { return nil }
                front = Array(f.dropLast(bn)); back = Array(f.suffix(bn))
            }
            if single {
                // 单式：前面多出来的是注序号（①被认成 1、11），后面多出来的丢掉
                if front.count > fn { front = Array(front.suffix(fn)) }
                if back.count > bn { back = Array(back.prefix(bn)) }
            }
            front = Array(Set(front)).sorted(); back = Array(Set(back)).sorted()
            guard front.count >= fn, back.count >= bn, front.count <= 20, back.count <= 16,
                  front.allSatisfy({ (1...fmax).contains($0) }), back.allSatisfy({ (1...bmax).contains($0) }) else { return nil }
            return LotteryBet(front: front, back: back)
        }
    }

    /// 七星彩：前区 6 位（每位 0~9，顺序有意义），后区 1 个（0~14）
    private static func parseQXC(_ s: String) -> LotteryBet? {
        let (fp, bp) = split(s)
        let tokens = { (t: String) -> [String] in
            let re = try! NSRegularExpression(pattern: "\\d+")
            return re.matches(in: t, range: NSRange(t.startIndex..., in: t)).compactMap { Range($0.range, in: t).map { String(t[$0]) } }
        }
        var front: [Int] = [], back: [Int] = []
        if !bp.isEmpty {
            front = tokens(fp).joined().compactMap { $0.wholeNumberValue }
            back = tokens(bp).compactMap { Int($0) }
        } else {
            let ts = tokens(fp)
            guard ts.count >= 2, let last = ts.last, let b = Int(last) else { return nil }
            front = ts.dropLast().joined().compactMap { $0.wholeNumberValue }
            back = [b]
        }
        guard front.count == 6, back.count == 1, (0...14).contains(back[0]) else { return nil }
        return LotteryBet(front: front, back: back)
    }

    /// 取两位数的号码（01、33）。识别时常把相邻号码粘在一起（「1424」→ 14、24），偶数位的数字串按两位拆开；
    /// 单个数字（注序号「1」、倍数）忽略
    static func numbers(_ s: String) -> [Int] {
        let re = try! NSRegularExpression(pattern: "\\d+")
        var out: [Int] = []
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let r = Range(m.range, in: s) else { continue }
            var t = Array(s[r])
            // 奇数位：多半是前面的注序号「①」被认成「1」粘在号码上（「103」→ 03），去掉第一位
            if t.count >= 3 && t.count % 2 == 1 { t.removeFirst() }
            guard t.count >= 2, t.count % 2 == 0, t.count <= 20 else { continue }
            for i in stride(from: 0, to: t.count, by: 2) {
                if let v = Int(String(t[i...i + 1])) { out.append(v) }
            }
        }
        return out
    }
}

struct TicketScan {
    var game: LotteryGame = .ssq
    var issue = ""           // 起始期号
    var issueTo = ""         // 结束期号（多期票；空 = 只有一期）
    var bets: [LotteryBet] = []
    var added = false        // 大乐透追加
    var multiple = 1         // 倍数
    var rawText = ""
}

enum TicketReader {
    /// 用系统的文字识别（中文 + 数字），一行一行返回
    static func lines(in image: UIImage) async -> [String] {
        guard let cg = image.cgImage else { return [] }
        return await withCheckedContinuation { cont in
            let req = VNRecognizeTextRequest { r, _ in
                let obs = (r.results as? [VNRecognizedTextObservation]) ?? []
                // 同一行的合并起来，从上到下
                let sorted = obs.sorted { $0.boundingBox.midY > $1.boundingBox.midY }
                var rows: [(y: CGFloat, items: [VNRecognizedTextObservation])] = []
                for o in sorted {
                    if let i = rows.firstIndex(where: { abs($0.y - o.boundingBox.midY) < o.boundingBox.height * 0.5 }) {
                        rows[i].items.append(o)
                    } else {
                        rows.append((o.boundingBox.midY, [o]))
                    }
                }
                let lines = rows.map { row in
                    row.items.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                        .compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                }
                cont.resume(returning: lines)
            }
            req.recognitionLevel = .accurate
            req.recognitionLanguages = ["zh-Hans", "en-US"]
            req.usesLanguageCorrection = false
            let handler = VNImageRequestHandler(cgImage: cg, orientation: image.cgOrientation)
            do { try handler.perform([req]) } catch { cont.resume(returning: []) }
        }
    }

    static func scan(_ image: UIImage) async -> TicketScan {
        let ls = await lines(in: image)
        var t = TicketScan()
        let all = ls.joined(separator: "\n")
        t.rawText = all
        if all.contains("大乐透") || all.contains("超级") { t.game = .dlt }
        else if all.contains("快乐8") || all.contains("快乐") || all.contains("KL8") { t.game = .kl8 }
        else if all.contains("七星彩") || all.contains("七星") { t.game = .qxc }
        else if all.contains("双色球") { t.game = .ssq }
        t.added = t.game == .dlt && all.contains("追加")

        // 期号：「第2026128期」或「2026128期」
        for p in ["第\\s*(\\d{5,7})\\s*期", "(\\d{5,7})\\s*期"] {
            let re = try! NSRegularExpression(pattern: p)
            if let m = re.firstMatch(in: all, range: NSRange(all.startIndex..., in: all)),
               let r = Range(m.range(at: 1), in: all) { t.issue = String(all[r]); break }
        }
        // 多期票：「第2026120期至第2026124期」「2026120-2026124期」（后面必须带「期」，避免把票号 110450-298261 当成期号）；
        // 或者「连续5期」「追加投注20期5倍」这种只写期数的
        let range = NSRange(all.startIndex..., in: all)
        if let m = try! NSRegularExpression(pattern: "(?<!\\d)(\\d{5}|\\d{7})\\s*期?\\s*[-—~～至到]\\s*第?\\s*(\\d{5}|\\d{7})\\s*期").firstMatch(in: all, range: range),
           let r1 = Range(m.range(at: 1), in: all), let r2 = Range(m.range(at: 2), in: all),
           let a = LotteryAPI.issueNumber(String(all[r1])), let b = LotteryAPI.issueNumber(String(all[r2])), b > a, b - a < 200 {
            t.issue = String(all[r1]); t.issueTo = String(all[r2])
        } else if let m = try! NSRegularExpression(pattern: "(?<!\\d)(\\d{1,3})\\s*期(?!号)").firstMatch(in: all, range: range),
                  let r = Range(m.range(at: 1), in: all), let n = Int(all[r]), n > 1,
                  let start = LotteryAPI.issueNumber(t.issue) {
            // 只知道起始期和期数：按同一年连续推算结束期
            let end = start + n - 1
            t.issueTo = t.issue.count == 5 ? String(end - 2_000_000) : String(end)
        }

        // 倍数：「3倍」
        if let m = try! NSRegularExpression(pattern: "(\\d{1,2})\\s*倍").firstMatch(in: all, range: NSRange(all.startIndex..., in: all)),
           let r = Range(m.range(at: 1), in: all), let n = Int(all[r]), n > 0 { t.multiple = n }

        // 快乐8：「选十」「选5」
        var pick: Int?
        if t.game == .kl8 {
            let cn = ["一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9, "十": 10]
            if let m = try! NSRegularExpression(pattern: "选\\s*([一二三四五六七八九十]|10|[1-9])").firstMatch(in: all, range: NSRange(all.startIndex..., in: all)),
               let r = Range(m.range(at: 1), in: all) {
                let v = String(all[r]); pick = cn[v] ?? Int(v)
            }
        }
        let single = all.contains("单式")
        t.bets = ls.compactMap { LotteryBet.parse($0, game: t.game, kl8Pick: pick, strict: true, single: single) }
        return t
    }
}

extension UIImage {
    var cgOrientation: CGImagePropertyOrientation {
        switch imageOrientation {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}

// MARK: - 算奖

struct PrizeHit: Identifiable {
    var id: String { name }
    let name: String
    let count: Int        // 注数（已乘倍数）
    let each: Double?     // 单注奖金；nil = 浮动奖
    var total: Double? { each.map { $0 * Double(count) } }
}

struct BetResult: Identifiable {
    let id = UUID()
    let bet: LotteryBet
    let frontHitIdx: Set<Int>     // 中了的号码在这注里的位置
    let backHitIdx: Set<Int>
    let frontHits: Int
    let backHits: Int
    let hits: [PrizeHit]
    let combos: Int
}

enum PrizeCalc {
    static func comb(_ n: Int, _ k: Int) -> Int {
        guard k >= 0, n >= k else { return 0 }
        if k == 0 || k == n { return 1 }
        var r = 1
        for i in 0..<min(k, n - k) { r = r * (n - i) / (i + 1) }
        return r
    }

    static func check(_ bet: LotteryBet, draw: LotteryDraw, game: LotteryGame, multiple: Int = 1) -> BetResult {
        switch game {
        case .kl8: return checkKL8(bet, draw: draw, multiple: multiple)
        case .qxc: return checkQXC(bet, draw: draw, multiple: multiple)
        default: return checkSSQDLT(bet, draw: draw, game: game, multiple: multiple)
        }
    }

    // MARK: 双色球 / 大乐透（支持复式）

    private static func checkSSQDLT(_ bet: LotteryBet, draw: LotteryDraw, game: LotteryGame, multiple: Int) -> BetResult {
        let df = Set(draw.front.compactMap { Int($0) }), db = Set(draw.back.compactMap { Int($0) })
        let fIdx = Set(bet.front.indices.filter { df.contains(bet.front[$0]) })
        let bIdx = Set(bet.back.indices.filter { db.contains(bet.back[$0]) })
        let F = bet.front.count, B = bet.back.count, hf = fIdx.count, hb = bIdx.count
        let (fn, bn) = game == .dlt ? (5, 2) : (6, 1)

        var counts: [String: Int] = [:]
        for k in 0...fn {
            for j in 0...bn {
                let n = comb(hf, k) * comb(F - hf, fn - k) * comb(hb, j) * comb(B - hb, bn - j)
                guard n > 0, let tier = tier(game, k, j, draw: draw) else { continue }
                counts[tier, default: 0] += n
            }
        }
        let order = ["一等奖", "二等奖", "三等奖", "四等奖", "五等奖", "六等奖", "七等奖", "福运奖"]
        let fixed: [String: Double] = game == .ssq
            ? ["三等奖": 3000, "四等奖": 200, "五等奖": 10, "六等奖": 5, "福运奖": 5]
            : ["三等奖": 5000, "四等奖": 300, "五等奖": 150, "六等奖": 15, "七等奖": 5]
        let hits = order.compactMap { name -> PrizeHit? in
            guard let c = counts[name] else { return nil }
            return PrizeHit(name: name, count: c * multiple, each: amount(name, draw: draw, fixed: fixed))
        }
        return BetResult(bet: bet, frontHitIdx: fIdx, backHitIdx: bIdx, frontHits: hf, backHits: hb,
                         hits: hits, combos: comb(F, fn) * comb(B, bn))
    }

    /// 双色球、大乐透（2026 年 2 月起新规则）的奖级
    private static func tier(_ g: LotteryGame, _ k: Int, _ j: Int, draw: LotteryDraw) -> String? {
        if g == .ssq {
            switch (k, j) {
            case (6, 1): return "一等奖"
            case (6, 0): return "二等奖"
            case (5, 1): return "三等奖"
            case (5, 0), (4, 1): return "四等奖"
            case (4, 0), (3, 1): return "五等奖"
            case (2, 1), (1, 1), (0, 1): return "六等奖"
            case (3, 0):
                // 福运奖：奖池达到 15 亿时才设，看这期开奖公告里有没有
                if let p = draw.prize("福运奖"), (Int(p.count.replacingOccurrences(of: ",", with: "")) ?? 0) > 0 { return "福运奖" }
                return nil
            default: return nil
            }
        }
        switch (k, j) {
        case (5, 2): return "一等奖"
        case (5, 1): return "二等奖"
        case (5, 0), (4, 2): return "三等奖"
        case (4, 1): return "四等奖"
        case (4, 0), (3, 2): return "五等奖"
        case (3, 1), (2, 2): return "六等奖"
        case (3, 0), (2, 1), (1, 2), (0, 2): return "七等奖"
        default: return nil
        }
    }

    // MARK: 快乐8（选一 ~ 选十，开 20 个号码）

    /// [选几: [中几: 奖金]]，选十中十是浮动奖（最高 500 万）
    private static let kl8Table: [Int: [Int: Double]] = [
        10: [9: 8000, 8: 800, 7: 80, 6: 5, 5: 3, 0: 2],
        9: [9: 300000, 8: 2000, 7: 200, 6: 20, 5: 5, 4: 3, 0: 2],
        8: [8: 50000, 7: 800, 6: 88, 5: 10, 4: 3, 0: 2],
        7: [7: 10000, 6: 288, 5: 28, 4: 4, 0: 2],
        6: [6: 3000, 5: 30, 4: 10, 3: 3],
        5: [5: 1000, 4: 21, 3: 3],
        4: [4: 100, 3: 5, 2: 3],
        3: [3: 53, 2: 3],
        2: [2: 19],
        1: [1: 4.6],
    ]
    private static let cnNum = ["", "一", "二", "三", "四", "五", "六", "七", "八", "九", "十"]

    private static func checkKL8(_ bet: LotteryBet, draw: LotteryDraw, multiple: Int) -> BetResult {
        let drawn = Set(draw.front.compactMap { Int($0) })
        let idx = Set(bet.front.indices.filter { drawn.contains(bet.front[$0]) })
        let n = bet.front.count, k = idx.count
        var hits: [PrizeHit] = []
        if n == 10 && k == 10 {
            hits = [PrizeHit(name: "选十中十", count: multiple, each: nil)]
        } else if let v = kl8Table[n]?[k] {
            hits = [PrizeHit(name: "选\(cnNum[n])中\(k == 0 ? "零" : cnNum[k])", count: multiple, each: v)]
        }
        return BetResult(bet: bet, frontHitIdx: idx, backHitIdx: [], frontHits: k, backHits: 0, hits: hits, combos: 1)
    }

    // MARK: 七星彩（前区 6 位对位比较 + 后区 1 位）

    private static func checkQXC(_ bet: LotteryBet, draw: LotteryDraw, multiple: Int) -> BetResult {
        let df = draw.front.compactMap { Int($0) }, db = draw.back.compactMap { Int($0) }
        let idx = Set(bet.front.indices.filter { $0 < df.count && bet.front[$0] == df[$0] })
        let backHit = !bet.back.isEmpty && !db.isEmpty && bet.back[0] == db[0]
        let k = idx.count
        let name: String?
        switch (k, backHit) {
        case (6, true): name = "一等奖"
        case (6, false): name = "二等奖"
        case (5, true): name = "三等奖"
        case (5, false), (4, true): name = "四等奖"
        case (4, false), (3, true): name = "五等奖"
        case (3, false), (2, true), (1, true), (0, true): name = "六等奖"
        default: name = nil
        }
        let fixed: [String: Double] = ["三等奖": 3000, "四等奖": 500, "五等奖": 30, "六等奖": 5]
        let hits = name.map { [PrizeHit(name: $0, count: multiple, each: amount($0, draw: draw, fixed: fixed))] } ?? []
        return BetResult(bet: bet, frontHitIdx: idx, backHitIdx: backHit ? [0] : [], frontHits: k, backHits: backHit ? 1 : 0,
                         hits: hits, combos: 1)
    }

    private static func amount(_ name: String, draw: LotteryDraw, fixed: [String: Double]) -> Double? {
        if let p = draw.prize(name), let v = Double(p.amount.replacingOccurrences(of: ",", with: "")), v > 0 { return v }
        return fixed[name]
    }
}
