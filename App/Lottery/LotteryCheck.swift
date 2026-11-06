import UIKit
import Vision
import CoreImage

// 拍照对奖：识别彩票上的文字 → 找出玩法、期号、号码 → 和开奖号码对比算奖级
// 支持：双色球、大乐透（单式/复式）、快乐8（选一~选十）、七星彩（单式）

struct LotteryBet: Identifiable, Hashable {
    var id = UUID()
    var front: [Int]
    var back: [Int]
    var multiple = 1      // 这注的倍数（收藏时一起存）
    var pick: Int? = nil  // 快乐8 复式：选几（号码个数比它多就是复式）
    var added = false     // 大乐透追加投注

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
        s = s.replacingOccurrences(of: "[\\[\\(（【「『]?\\s*\\d+\\s*倍\\s*[\\]\\)）】」』]?", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "[xX×]\\s*\\d+\\s*$", with: " ", options: .regularExpression)
        switch game {
        case .kl8:
            let nums = Array(Set(numbers(s))).sorted()
            guard nums.allSatisfy({ (1...80).contains($0) }) else { return nil }
            if let k = kl8Pick {
                // 选几就要几个号码；多了是复式（最多 20 个）
                guard nums.count >= k, nums.count <= 20 else { return nil }
                return LotteryBet(front: nums, back: [], pick: nums.count > k ? k : nil)
            }
            guard (1...10).contains(nums.count) else { return nil }
            if strict && nums.count < 2 { return nil }
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
    private static func parseQXC(_ s0: String) -> LotteryBet? {
        // 单独一个「1」常被认成 l、I、|
        let s = s0.replacingOccurrences(of: "(?<=\\s)[lI|!丨](?=\\s|$)", with: "1", options: .regularExpression)
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
    var drawDate = ""        // 票上印的开奖日期「2026-10-29」，用来校正认错的期号
    var gameFound = false    // 票上认出了玩法名
    var amountOK = false     // 号码算出来的金额和票面金额对得上
    var engine = ""          // 用的哪种识别
}

enum TicketReader {
    /// 彩票上常见的词，告诉识别器优先往这些词上认
    static let lotteryWords = ["快乐8", "双色球", "大乐透", "七星彩", "超级大乐透", "中国福利彩票", "中国体育彩票",
                               "选一", "选二", "选三", "选四", "选五", "选六", "选七", "选八", "选九", "选十",
                               "单式", "复式", "胆拖", "追加", "倍", "期", "开奖日期", "金额", "销售时间", "投注站"]

    /// 系统文字识别（老接口）：一行一行返回
    static func lines(in cg: CGImage, orientation: CGImagePropertyOrientation, correction: Bool) async -> [String] {
        await withCheckedContinuation { cont in
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
            // 不纠正：数字不会被乱改；纠正 + 彩票词表：汉字认得更准
            req.usesLanguageCorrection = correction
            if correction { req.customWords = lotteryWords }
            let handler = VNImageRequestHandler(cgImage: cg, orientation: orientation)
            do { try handler.perform([req]) } catch { cont.resume(returning: []) }
        }
    }

    /// iOS 26 新的文档识别（专门认票据、文档）
    static func documentLines(in cg: CGImage) async -> [String] {
        guard #available(iOS 26.0, *) else { return [] }
        var req = RecognizeDocumentsRequest()
        req.textRecognitionOptions.recognitionLanguages = [Locale.Language(identifier: "zh-Hans"), Locale.Language(identifier: "en-US")]
        req.textRecognitionOptions.useLanguageCorrection = true
        req.textRecognitionOptions.customWords = lotteryWords
        guard let obs = try? await req.perform(on: cg), let doc = obs.first?.document else { return [] }
        return doc.text.transcript.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// 把照片摆正、放大、去色、加强对比，热敏纸上的淡字更清楚
    static func enhanced(_ image: UIImage) -> CGImage? {
        guard let cg = image.cgImage else { return nil }
        var ci = CIImage(cgImage: cg).oriented(image.cgOrientation)
        let longSide = max(ci.extent.width, ci.extent.height)
        if longSide < 2600 {
            let s = 2600 / longSide
            ci = ci.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1])
        }
        ci = ci.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0, kCIInputContrastKey: 1.45, kCIInputBrightnessKey: 0.03])
            .applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.6])
        return CIContext().createCGImage(ci, from: ci.extent)
    }

    /// 拍照对奖：同时跑三种识别（原图 / 增强图+词表纠正 / 新的文档识别），挑号码和金额最对得上的结果
    static func scan(_ image: UIImage) async -> TicketScan {
        guard let cg = image.cgImage else { return TicketScan() }
        let ori = image.cgOrientation
        let better = enhanced(image)
        async let a = lines(in: cg, orientation: ori, correction: false)
        async let b: [String] = better == nil ? [] : lines(in: better!, orientation: .up, correction: true)
        async let c: [String] = better == nil ? [] : documentLines(in: better!)
        async let d: [String] = better == nil ? [] : lines(in: better!, orientation: .up, correction: false)
        let results: [(String, [String])] = [("系统识别", await a), ("增强+词表", await b), ("文档识别", await c), ("增强图", await d)]

        // 玩法：任何一种识别认出了玩法名就用它
        let union = results.flatMap(\.1).joined(separator: "\n")
        let game = detectGame(union)

        var best: TicketScan?
        var bestScore = -1
        for (name, ls) in results where !ls.isEmpty {
            var t = scan(lines: ls, game: game)
            t.engine = name
            // 期号、开奖日期这些某种识别没认出来，就从别的识别里补
            if t.issue.isEmpty || t.drawDate.isEmpty {
                for (_, other) in results where !other.isEmpty {
                    let o = scan(lines: other, game: game)
                    if t.issue.isEmpty { t.issue = o.issue; if t.issueTo.isEmpty { t.issueTo = o.issueTo } }
                    if t.drawDate.isEmpty { t.drawDate = o.drawDate }
                }
            }
            let score = (t.bets.isEmpty ? 0 : 10) + (t.amountOK ? 8 : 0) + (t.gameFound ? 3 : 0)
                + (t.issue.isEmpty ? 0 : 2) + (t.drawDate.isEmpty ? 0 : 1) + min(t.bets.count, 5)
            if score > bestScore { best = t; bestScore = score }
        }
        var out = best ?? scan(lines: results[0].1, game: game)
        // 七星彩漏了后区那一位：单独补认
        if out.game == .qxc, out.bets.isEmpty, let better, let back = await qxcBackDigit(in: better) {
            var ls = out.rawText.components(separatedBy: "\n")
            if let i = ls.firstIndex(where: { l in l.filter(\.isNumber).count == 6 && l.filter({ !$0.isWhitespace }).count == 6 }) {
                ls[i] += " + \(back)"
                var t = scan(lines: ls, game: .qxc)
                t.engine = out.engine + "+补认后区"
                if t.issue.isEmpty { t.issue = out.issue; t.issueTo = out.issueTo }
                if t.drawDate.isEmpty { t.drawDate = out.drawDate }
                if !t.bets.isEmpty { out = t }
            }
        }
        return out
    }

    /// 七星彩后区那一位数字离前面很远，常常单独漏掉：
    /// 找到前区 6 位数字那一行，把它右边那一块裁出来放大，再单独认一次
    static func qxcBackDigit(in cg: CGImage) async -> Int? {
        let obs: [VNRecognizedTextObservation] = await withCheckedContinuation { cont in
            let req = VNRecognizeTextRequest { r, _ in cont.resume(returning: (r.results as? [VNRecognizedTextObservation]) ?? []) }
            req.recognitionLevel = .accurate
            req.recognitionLanguages = ["zh-Hans", "en-US"]
            req.usesLanguageCorrection = false
            do { try VNImageRequestHandler(cgImage: cg, orientation: .up).perform([req]) } catch { cont.resume(returning: []) }
        }
        // 同一行的拼起来；前区那一行：去掉空格正好 6 个数字
        var rows: [(y: CGFloat, items: [VNRecognizedTextObservation])] = []
        for o in obs.sorted(by: { $0.boundingBox.midY > $1.boundingBox.midY }) {
            if let i = rows.firstIndex(where: { abs($0.y - o.boundingBox.midY) < o.boundingBox.height * 0.5 }) {
                rows[i].items.append(o)
            } else { rows.append((o.boundingBox.midY, [o])) }
        }
        guard let row = rows.first(where: { r in
            let t = r.items.compactMap { $0.topCandidates(1).first?.string }.joined().filter { !$0.isWhitespace }
            return t.count == 6 && t.allSatisfy(\.isNumber)
        }) else { return nil }
        let b = row.items.map(\.boundingBox).reduce(row.items[0].boundingBox) { $0.union($1) }   // 0~1，左下角为原点
        let W = CGFloat(cg.width), H = CGFloat(cg.height)
        let x0 = (b.maxX + b.width * 0.02) * W
        let y0 = (1 - b.maxY - b.height * 0.6) * H
        let rect = CGRect(x: x0, y: y0, width: min(W - x0, b.width * W * 0.6), height: b.height * 2.2 * H).intersection(CGRect(x: 0, y: 0, width: W, height: H))
        guard rect.width > 4, rect.height > 4, let crop = cg.cropping(to: rect) else { return nil }
        // 放大 3 倍，四周留白
        let scale: CGFloat = 3, pad: CGFloat = 40
        let size = CGSize(width: rect.width * scale + pad * 2, height: rect.height * scale + pad * 2)
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
        let big = UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            UIImage(cgImage: crop).draw(in: CGRect(x: pad, y: pad, width: rect.width * scale, height: rect.height * scale))
        }
        guard let bigCG = big.cgImage else { return nil }
        for level in [VNRequestTextRecognitionLevel.accurate, .fast] {
            let text: String = await withCheckedContinuation { cont in
                let req = VNRecognizeTextRequest { r, _ in
                    let o = (r.results as? [VNRecognizedTextObservation]) ?? []
                    cont.resume(returning: o.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " "))
                }
                req.recognitionLevel = level
                req.recognitionLanguages = ["en-US"]
                req.usesLanguageCorrection = false
                req.minimumTextHeight = 0
                do { try VNImageRequestHandler(cgImage: bigCG, orientation: .up).perform([req]) } catch { cont.resume(returning: "") }
            }
            let t = text.replacingOccurrences(of: "[lI|!丨]", with: "1", options: .regularExpression)
            if let m = t.range(of: "\\d{1,2}", options: .regularExpression), let v = Int(t[m]), (0...14).contains(v) { return v }
        }
        return nil
    }

    /// 从文字里认玩法
    static func detectGame(_ all: String) -> LotteryGame? {
        if all.contains("大乐透") || all.contains("超级") { return .dlt }
        // 快乐8：识别常把「快」认成「央」「块」，所以只认「乐8」也算
        if all.contains("快乐8") || all.contains("快乐") || all.contains("KL8")
            || all.range(of: "乐\\s*[8８]", options: .regularExpression) != nil { return .kl8 }
        if all.contains("七星") || all.contains("7星") || all.lowercased().contains("seven star") { return .qxc }
        if all.contains("双色球") { return .ssq }
        return nil
    }

    static func scan(lines ls: [String], game: LotteryGame?) -> TicketScan {
        var t = TicketScan()
        let all = ls.joined(separator: "\n")
        t.rawText = all
        if let game { t.game = game; t.gameFound = true }
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
        // 开奖日期：「开奖日期:2026/10/29」「2026年09月28日开奖」
        for p in ["开奖日期\\s*[:：]?\\s*(\\d{4})\\s*[/\\-.年]\\s*(\\d{1,2})\\s*[/\\-.月]\\s*(\\d{1,2})",
                  "(\\d{4})\\s*年\\s*(\\d{1,2})\\s*月\\s*(\\d{1,2})\\s*日\\s*开奖"] {
            if let m = try! NSRegularExpression(pattern: p).firstMatch(in: all, range: NSRange(all.startIndex..., in: all)),
               let y = Range(m.range(at: 1), in: all), let mo = Range(m.range(at: 2), in: all), let d = Range(m.range(at: 3), in: all),
               let mm = Int(all[mo]), let dd = Int(all[d]) {
                t.drawDate = String(all[y]) + String(format: "-%02d-%02d", mm, dd)
                break
            }
        }

        // 快乐8 复式的号码常常一行写不下：「01+07+…+30+」接着下一行「42+64+77」，先把它们拼成一行
        var rows = ls
        if t.game == .kl8 {
            var merged: [String] = []
            for l in ls {
                let trimmed = l.trimmingCharacters(in: .whitespaces)
                if let last = merged.last, last.trimmingCharacters(in: .whitespaces).hasSuffix("+") || trimmed.hasPrefix("+") {
                    merged[merged.count - 1] = last + " " + trimmed
                } else {
                    merged.append(trimmed)
                }
            }
            rows = merged
        }
        t.bets = rows.compactMap { LotteryBet.parse($0, game: t.game, kl8Pick: pick, strict: true, single: single) }

        // 快乐8：用票面金额核对「选几」。识别常把「选十」认成「选一」，
        // 例如 11 个号码：选十复式 = C(11,10) = 11 注 = 22 元，选一也是 11 注，金额一样，
        // 但选一不会这样打复式，所以金额对得上更大的选法时以大的为准
        if t.game == .kl8, let amount = amount(all), !t.bets.isEmpty {
            let periods: Int = {
                guard let a = LotteryAPI.issueNumber(t.issue), let b = LotteryAPI.issueNumber(t.issueTo), b >= a else { return 1 }
                return b - a + 1
            }()
            let counts = t.bets.map(\.front.count)
            let fits = (1...10).filter { k in
                let n = counts.reduce(0) { $0 + PrizeCalc.comb($1, k) }
                guard n > 0 else { return false }
                let cost = Double(n * 2 * t.multiple)
                return abs(cost - amount) < 0.01 || abs(cost * Double(periods) - amount) < 0.01
            }
            var k = pick
            if let p = pick, p == 1, let big = fits.filter({ $0 > 1 }).max() { k = big }
            else if let p = pick, fits.contains(p) { k = p }
            else if fits.count == 1 { k = fits[0] }
            else if pick == nil, let big = fits.max() { k = big }
            if let k, k != pick {
                pick = k
                t.bets = rows.compactMap { LotteryBet.parse($0, game: t.game, kl8Pick: k, strict: true, single: single) }
            }
        }
        // 号码算出来的金额和票面金额对不对得上（用来挑最好的识别结果）
        if let amount = amount(all), !t.bets.isEmpty {
            let n = t.bets.reduce(0) { sum, b in
                switch t.game {
                case .ssq: return sum + PrizeCalc.comb(b.front.count, 6) * PrizeCalc.comb(b.back.count, 1)
                case .dlt: return sum + PrizeCalc.comb(b.front.count, 5) * PrizeCalc.comb(b.back.count, 2)
                case .kl8: return sum + PrizeCalc.comb(b.front.count, b.pick ?? b.front.count)
                default: return sum + 1
                }
            }
            let each = t.game == .dlt && t.added ? 3.0 : 2.0
            let periods: Double = {
                guard let a = LotteryAPI.issueNumber(t.issue), let b = LotteryAPI.issueNumber(t.issueTo), b >= a else { return 1 }
                return Double(b - a + 1)
            }()
            let cost = Double(n) * each * Double(t.multiple)
            t.amountOK = abs(cost - amount) < 0.01 || abs(cost * periods - amount) < 0.01
        }
        return t
    }

    /// 票面金额「金额：22.00元」
    private static func amount(_ all: String) -> Double? {
        guard let m = try! NSRegularExpression(pattern: "金\\s*额\\s*[:：]?\\s*(\\d+(?:\\.\\d+)?)\\s*元").firstMatch(in: all, range: NSRange(all.startIndex..., in: all)),
              let r = Range(m.range(at: 1), in: all) else { return nil }
        return Double(all[r])
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
        var hits = order.compactMap { name -> PrizeHit? in
            guard let c = counts[name] else { return nil }
            return PrizeHit(name: name, count: c * multiple, each: amount(name, draw: draw, fixed: fixed))
        }
        // 大乐透追加：一、二等奖另得追加奖金（公告里有就用公告的，没有按基本奖金的 80%）
        if game == .dlt && bet.added {
            for name in ["一等奖", "二等奖"] {
                guard let h = hits.first(where: { $0.name == name }) else { continue }
                let p = draw.prizes.first { $0.name.contains(name) && $0.name.contains("追加") }
                let each = p.flatMap { Double($0.amount.replacingOccurrences(of: ",", with: "")) } ?? h.each.map { $0 * 0.8 }
                hits.append(PrizeHit(name: name + "（追加）", count: h.count, each: each))
            }
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
        let M = bet.front.count, h = idx.count
        let N = min(bet.pick ?? M, 10)
        // 复式：从 M 个号码里任选 N 个组成一注，中 k 个的注数 = C(h,k) × C(M-h, N-k)
        var hits: [PrizeHit] = []
        for k in stride(from: N, through: 0, by: -1) {
            let n = comb(h, k) * comb(M - h, N - k)
            guard n > 0 else { continue }
            if N == 10 && k == 10 {
                hits.append(PrizeHit(name: "选十中十", count: n * multiple, each: nil))
            } else if let v = kl8Table[N]?[k] {
                hits.append(PrizeHit(name: "选\(cnNum[N])中\(k == 0 ? "零" : cnNum[k])", count: n * multiple, each: v))
            }
        }
        return BetResult(bet: bet, frontHitIdx: idx, backHitIdx: [], frontHits: h, backHits: 0, hits: hits, combos: comb(M, N))
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
