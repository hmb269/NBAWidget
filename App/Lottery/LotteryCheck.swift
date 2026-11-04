import UIKit
import Vision

// 拍照对奖：识别彩票上的文字 → 找出玩法、期号、号码 → 和开奖号码对比算奖级（支持单式和复式）

struct LotteryBet: Identifiable, Hashable {
    var id = UUID()
    var front: [Int]
    var back: [Int]

    var text: String {
        front.map { String(format: "%02d", $0) }.joined(separator: " ") + " + " +
        back.map { String(format: "%02d", $0) }.joined(separator: " ")
    }

    /// 从一行文字解析：「01 05 12 18 22 30 + 07」，没有分隔符时按玩法取最后几个当后区
    static func parse(_ line: String, game: LotteryGame) -> LotteryBet? {
        let seps = ["+", "＋", "|", "｜", "-", "—", "－", ":", "：", "蓝", "后", "/"]
        var s = line
        for (a, b) in [("①", " "), ("②", " "), ("③", " "), ("④", " "), ("⑤", " "), ("O", "0"), ("o", "0")] {
            s = s.replacingOccurrences(of: a, with: b)
        }
        var frontPart = s, backPart = ""
        if let sep = seps.first(where: { s.contains($0) }), let r = s.range(of: sep, options: .backwards) {
            frontPart = String(s[..<r.lowerBound]); backPart = String(s[r.upperBound...])
        }
        let f = numbers(frontPart), b = numbers(backPart)
        let (fn, bn) = game == .dlt ? (5, 2) : (6, 1)
        let (fmax, bmax) = game == .dlt ? (35, 12) : (33, 16)
        var front = f, back = b
        if back.isEmpty {
            guard f.count >= fn + bn else { return nil }
            front = Array(f.dropLast(bn)); back = Array(f.suffix(bn))
        }
        front = Array(Set(front)).sorted(); back = Array(Set(back)).sorted()
        guard front.count >= fn, back.count >= bn, front.count <= 20, back.count <= 16,
              front.allSatisfy({ (1...fmax).contains($0) }), back.allSatisfy({ (1...bmax).contains($0) }) else { return nil }
        return LotteryBet(front: front, back: back)
    }

    /// 只取两位数（01、33），避开年份、时间、流水号
    private static func numbers(_ s: String) -> [Int] {
        let re = try! NSRegularExpression(pattern: "(?<!\\d)\\d{2}(?!\\d)")
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap {
            Range($0.range, in: s).flatMap { Int(s[$0]) }
        }
    }
}

struct TicketScan {
    var game: LotteryGame = .ssq
    var issue = ""
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
                // 从上到下、从左到右
                let sorted = obs.sorted {
                    abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.01 ? $0.boundingBox.midY > $1.boundingBox.midY
                                                                         : $0.boundingBox.minX < $1.boundingBox.minX
                }
                cont.resume(returning: sorted.compactMap { $0.topCandidates(1).first?.string })
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
        else if all.contains("双色球") { t.game = .ssq }
        t.added = t.game == .dlt && all.contains("追加")

        // 期号：「第2026128期」或「2026128期」
        for p in ["第\\s*(\\d{5,7})\\s*期", "(\\d{5,7})\\s*期"] {
            let re = try! NSRegularExpression(pattern: p)
            if let m = re.firstMatch(in: all, range: NSRange(all.startIndex..., in: all)),
               let r = Range(m.range(at: 1), in: all) { t.issue = String(all[r]); break }
        }
        // 倍数：「3倍」
        if let m = try! NSRegularExpression(pattern: "(\\d{1,2})\\s*倍").firstMatch(in: all, range: NSRange(all.startIndex..., in: all)),
           let r = Range(m.range(at: 1), in: all), let n = Int(all[r]), n > 0 { t.multiple = n }

        t.bets = ls.compactMap { LotteryBet.parse($0, game: t.game) }
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
    let each: Double?     // 单注奖金
    var total: Double? { each.map { $0 * Double(count) } }
}

struct BetResult: Identifiable {
    let id = UUID()
    let bet: LotteryBet
    let frontHit: Set<Int>
    let backHit: Set<Int>
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
        let df = Set(draw.front.compactMap { Int($0) }), db = Set(draw.back.compactMap { Int($0) })
        let fh = Set(bet.front).intersection(df), bh = Set(bet.back).intersection(db)
        let F = bet.front.count, B = bet.back.count, hf = fh.count, hb = bh.count
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
        let hits = order.compactMap { name -> PrizeHit? in
            guard let c = counts[name] else { return nil }
            return PrizeHit(name: name, count: c * multiple, each: amount(name, game: game, draw: draw))
        }
        return BetResult(bet: bet, frontHit: fh, backHit: bh, hits: hits, combos: comb(F, fn) * comb(B, bn))
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

    private static func amount(_ name: String, game: LotteryGame, draw: LotteryDraw) -> Double? {
        if let p = draw.prize(name), let v = Double(p.amount.replacingOccurrences(of: ",", with: "")), v > 0 { return v }
        let fixed: [String: Double] = game == .ssq
            ? ["三等奖": 3000, "四等奖": 200, "五等奖": 10, "六等奖": 5, "福运奖": 5]
            : ["三等奖": 5000, "四等奖": 300, "五等奖": 150, "六等奖": 15, "七等奖": 5]
        return fixed[name]
    }
}
