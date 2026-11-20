import Foundation

/// 月经周期 / 体温的简单推算（小组件用，App 里的「备孕」页用 FertilityStore，算法一致）
enum CycleMath {
    static let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }()

    static func day(_ d: Date) -> Date { cal.startOfDay(for: d) }
    static func add(_ d: Date, _ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: day(d))! }
    static func between(_ a: Date, _ b: Date) -> Int { cal.dateComponents([.day], from: day(a), to: day(b)).day ?? 0 }

    /// 出血的日子 → 每次月经第一天（前 10 天内没出血才算新的一次）
    static func starts(_ bleed: [Date]) -> [Date] {
        let ds = Array(Set(bleed.map(day))).sorted()
        var out: [Date] = []
        var prev: Date?
        for d in ds {
            if prev == nil || between(prev!, d) > 10 { out.append(d) }
            prev = d
        }
        return out
    }

    static func avgCycle(_ s: [Date], fallback: Int = 28) -> Int {
        guard s.count >= 2 else { return fallback }
        let l = (1..<s.count).map { between(s[$0 - 1], s[$0]) }.filter { (18...50).contains($0) }.suffix(6)
        guard !l.isEmpty else { return fallback }
        return Int((Double(l.reduce(0, +)) / Double(l.count)).rounded())
    }

    /// 「3 高于 6」：连续 3 天都高于前 6 天最高值，第 3 天至少高 rise
    static func shift(_ p: [(Date, Double)], rise: Double = 0.2) -> (date: Date, cover: Double)? {
        guard p.count >= 9 else { return nil }
        for i in 6..<(p.count - 2) {
            let m = p[(i - 6)..<i].map(\.1).max() ?? 0
            if p[i].1 > m && p[i + 1].1 > m && p[i + 2].1 >= m + rise { return (p[i].0, m + 0.05) }
        }
        return nil
    }

    struct Status {
        var cycleDay: Int
        var nextStart: Date
        var lateDays: Int
        var ovulation: Date
        var ovulationSource: String
        var fertileFrom: Date
        var fertileTo: Date
        var phase: String       // 经期 / 易孕期 / 排卵日 / 非易孕期 / 推迟
    }

    static func status(bleed: [Date], bbt: [(Date, Double)], periodLen: Int = 5, today: Date = Date()) -> Status? {
        let s = starts(bleed).filter { $0 <= day(today) }
        guard let last = s.last else { return nil }
        let cyc = avgCycle(s)
        let next = add(last, cyc)
        let cd = between(last, today) + 1
        var ov = add(next, -14)
        var src = "预测"
        let cur = bbt.filter { $0.0 >= last }
        if let sh = shift(cur) { ov = add(sh.date, -1); src = "体温确认" }
        let late = max(0, between(next, today))
        let diff = between(ov, today)
        let bleedToday = bleed.contains { cal.isDate($0, inSameDayAs: today) }
        let phase: String
        let recentBleed = bleed.contains { b in
            let x = day(b)
            return x >= last && between(x, today) <= 1
        }
        if bleedToday || (cd <= periodLen && recentBleed) { phase = "经期" }
        else if late > 0 { phase = "推迟 \(late) 天" }
        else if diff == 0 { phase = "排卵日" }
        else if (-5...1).contains(diff) { phase = "易孕期" }
        else { phase = "非易孕期" }
        return Status(cycleDay: cd, nextStart: next, lateDays: late, ovulation: ov, ovulationSource: src,
                      fertileFrom: add(ov, -5), fertileTo: add(ov, 1), phase: phase)
    }

    /// 腕温：和中位数比的偏差
    static func deviation(_ temps: [(Date, Double)]) -> [(Date, Double)] {
        let v = temps.map(\.1).sorted()
        guard v.count >= 5 else { return [] }
        let base = v[v.count / 2]
        return temps.map { ($0.0, $0.1 - base) }
    }

    static func md(_ d: Date) -> String {
        let c = cal.dateComponents([.month, .day], from: d)
        return "\(c.month ?? 0)/\(c.day ?? 0)"
    }
}
