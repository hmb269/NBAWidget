import SwiftUI
import Charts
import HealthKit

// 关系分析：把每天的数据对齐，算两两之间是不是「一起变」（排名相关），
// 有的看当天，有的看「隔一天」（比如今天走得多 → 明天的 HRV）

/// 参与分析的一项（在趋势对比的基础上，血糖拆成空腹和餐后 2 小时）
enum RelMetric: String, CaseIterable, Identifiable {
    case steps = "步数", exercise = "锻炼", kcal = "活动卡路里", sleep = "睡眠评分", hrv = "HRV",
         resting = "静息心率", weight = "体重", fasting = "空腹血糖", after2 = "餐后2h血糖", postSteps = "饭后步数"
    var id: String { rawValue }
    var unit: String {
        switch self {
        case .steps, .postSteps: return "步"
        case .exercise: return "分钟"
        case .kcal: return "千卡"
        case .sleep: return "分"
        case .hrv: return "毫秒"
        case .resting: return "次/分"
        case .weight: return "公斤"
        case .fasting, .after2: return "mmol/L"
        }
    }
    var color: Color {
        switch self {
        case .steps: return CompareMetric.steps.color
        case .exercise: return CompareMetric.exercise.color
        case .kcal: return CompareMetric.activeEnergy.color
        case .sleep: return CompareMetric.sleep.color
        case .hrv: return CompareMetric.hrv.color
        case .resting: return CompareMetric.restingHR.color
        case .weight: return CompareMetric.weight.color
        case .fasting, .after2: return CompareMetric.glucose.color
        case .postSteps: return Color(red: 1.0, green: 0.85, blue: 0.35)
        }
    }
    func format(_ v: Double) -> String {
        switch self {
        case .steps, .postSteps: return Int(v.rounded()).formatted()
        case .weight, .fasting, .after2: return String(format: "%.1f", v)
        default: return String(Int(v.rounded()))
        }
    }
    /// 矩阵里用的短名字
    var short: String {
        switch self {
        case .steps: return "步数"
        case .exercise: return "锻炼"
        case .kcal: return "卡路里"
        case .sleep: return "睡眠"
        case .hrv: return "HRV"
        case .resting: return "静息心率"
        case .weight: return "体重"
        case .fasting: return "空腹糖"
        case .after2: return "餐后糖"
        case .postSteps: return "饭后走"
        }
    }
}

/// 一对关系的计算结果
struct RelResult: Identifiable {
    let x: RelMetric
    let y: RelMetric
    let lag: Int                 // 0 = 当天，1 = 第二天
    let n: Int                   // 有效天数
    let r: Double                // 排名相关系数
    let p: Double                // 纯属巧合的概率（近似）
    let hiX: Double, hiY: Double // x 最高三分之一的天：x 平均、y 平均
    let loX: Double, loY: Double // x 最低三分之一的天
    let points: [(Double, Double)]
    var id: String { x.rawValue + y.rawValue + "\(lag)" }

    var strength: (String, Color) {
        let a = abs(r)
        if n < 10 { return ("天数太少", .secondary) }
        if p > 0.1 { return ("可能是巧合", .secondary) }
        if a >= 0.5 { return ("关系明显", r > 0 ? Color(red: 1, green: 0.45, blue: 0.4) : Color(red: 0.4, green: 0.65, blue: 1)) }
        if a >= 0.3 { return ("有一定关系", r > 0 ? Color(red: 1, green: 0.65, blue: 0.4) : Color(red: 0.5, green: 0.75, blue: 1)) }
        return ("基本看不出", .secondary)
    }
    var meaningful: Bool { n >= 10 && p <= 0.1 && abs(r) >= 0.3 }

    var title: String { x.rawValue + " → " + (lag == 1 ? "第二天" : "当天") + y.rawValue }

    /// 一句大白话
    var sentence: String {
        guard n >= 10 else { return "只有 \(n) 天同时有这两项数据，至少要 10 天才分析。" }
        let more: String = hiY >= loY ? "高" : "低"
        let diff: String = y.format(abs(hiY - loY))
        let when: String = lag == 1 ? "第二天" : "当天"
        return "\(x.rawValue)多的那些天（平均 \(x.format(hiX)) \(x.unit)），\(when)\(y.rawValue)平均 \(y.format(hiY))；"
            + "\(x.rawValue)少的那些天（平均 \(x.format(loX))），\(when)\(y.rawValue)平均 \(y.format(loY))，"
            + "\(more) \(diff) \(y.unit)。"
    }
}

enum Relation {
    /// 想看的几对（原因 → 结果，隔几天）
    static let pairs: [(RelMetric, RelMetric, Int)] = [
        (.steps, .hrv, 1), (.exercise, .hrv, 1), (.kcal, .resting, 1),
        (.steps, .sleep, 1), (.exercise, .sleep, 1),
        (.sleep, .hrv, 0), (.sleep, .fasting, 0), (.sleep, .after2, 0), (.hrv, .fasting, 0),
        (.steps, .after2, 0), (.exercise, .after2, 0), (.kcal, .after2, 0),
        (.hrv, .resting, 0), (.sleep, .steps, 0), (.after2, .hrv, 1), (.postSteps, .after2, 0),
    ]

    static func compute(_ data: [RelMetric: [Date: Double]], x: RelMetric, y: RelMetric, lag: Int) -> RelResult {
        let cal = Calendar.current
        var pts: [(Double, Double)] = []
        for (d, xv) in data[x] ?? [:] {
            let target = cal.date(byAdding: .day, value: lag, to: d)!
            if let yv = data[y]?[target] { pts.append((xv, yv)) }
        }
        let n = pts.count
        let r = n >= 3 ? spearman(pts) : 0
        let p = n >= 4 ? pValue(r, n) : 1
        let sorted = pts.sorted { $0.0 < $1.0 }
        let k = max(1, n / 3)
        let lo = Array(sorted.prefix(k)), hi = Array(sorted.suffix(k))
        func avg(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.reduce(0, +) / Double(a.count) }
        return RelResult(x: x, y: y, lag: lag, n: n, r: r, p: p,
                         hiX: avg(hi.map(\.0)), hiY: avg(hi.map(\.1)), loX: avg(lo.map(\.0)), loY: avg(lo.map(\.1)),
                         points: pts)
    }

    /// 排名相关：先换成名次（相同的取平均名次），再算皮尔逊相关
    static func spearman(_ pts: [(Double, Double)]) -> Double {
        func ranks(_ v: [Double]) -> [Double] {
            let idx = v.indices.sorted { v[$0] < v[$1] }
            var out = [Double](repeating: 0, count: v.count)
            var i = 0
            while i < idx.count {
                var j = i
                while j + 1 < idx.count && v[idx[j + 1]] == v[idx[i]] { j += 1 }
                let r = Double(i + j) / 2 + 1
                for t in i...j { out[idx[t]] = r }
                i = j + 1
            }
            return out
        }
        let a = ranks(pts.map(\.0)), b = ranks(pts.map(\.1))
        let ma = a.reduce(0, +) / Double(a.count), mb = b.reduce(0, +) / Double(b.count)
        var num = 0.0, da = 0.0, db = 0.0
        for i in a.indices {
            num += (a[i] - ma) * (b[i] - mb)
            da += (a[i] - ma) * (a[i] - ma)
            db += (b[i] - mb) * (b[i] - mb)
        }
        guard da > 0, db > 0 else { return 0 }
        return num / sqrt(da * db)
    }

    /// 近似的「纯属巧合」概率（t 检验，用正态近似）
    static func pValue(_ r: Double, _ n: Int) -> Double {
        let rr = min(0.9999, abs(r))
        let t = rr * sqrt(Double(n - 2) / (1 - rr * rr))
        return erfc(t / sqrt(2))
    }
}

struct HealthRelationView: View {
    @State private var days = 60
    @State private var loading = false
    @State private var results: [RelResult] = []
    @State private var matrix: [String: RelResult] = [:]
    @State private var dayCount = 0
    @State private var open: String?
    @State private var cell: RelResult?
    @State private var data: [RelMetric: [Date: Double]] = [:]
    @State private var dose: DoseKind = .steps

    private var top: [RelResult] {
        Array(results.filter(\.meaningful).sorted { abs($0.r) > abs($1.r) }.prefix(3))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("用最近 \(days) 天的数据").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Picker("范围", selection: $days) {
                        Text("30天").tag(30)
                        Text("60天").tag(60)
                        Text("90天").tag(90)
                    }
                    .pickerStyle(.menu).tint(.secondary)
                }

                if loading {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("正在读取健康数据、计算…").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(40)
                } else {
                    topCard
                    doseCard
                    Text("每一对的详细结果").font(.headline).padding(.top, 4)
                    ForEach(results.sorted { abs($0.r) * ($0.n >= 10 ? 1 : 0) > abs($1.r) * ($1.n >= 10 ? 1 : 0) }) { r in
                        pairCard(r)
                    }
                    matrixCard
                    explain
                }
            }
            .padding(16)
            .padding(.bottom, 100)
        }
        .background(AppBackground())
        .navigationTitle("关系分析")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task(id: days) { await run() }
        .sheet(item: Binding(get: { cell }, set: { cell = $0 })) { r in
            NavigationStack {
                ScrollView { pairCard(r, expanded: true).padding(16) }
                    .navigationTitle(r.x.short + " 和 " + r.y.short)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭") { cell = nil } } }
            }
            .presentationDetents([.medium, .large])
        }
    }

    // MARK: 最明显的几对

    private var topCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("关系最明显的", systemImage: "sparkles").font(.headline)
                .foregroundStyle(Color(red: 1, green: 0.8, blue: 0.4))
            if top.isEmpty {
                Text(dayCount < 14 ? "现在只有 \(dayCount) 天的数据，还看不出可靠的关系。坚持戴手表、记血糖，一两个月后再来看会准很多。"
                                   : "这段时间里各项之间都没有明显的关系（或者可能是巧合）。数据再多一些可能会看出来。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(Array(top.enumerated()), id: \.element.id) { i, r in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("\(i + 1). " + r.title).font(.subheadline.weight(.bold))
                        Spacer()
                        badge(r)
                    }
                    Text(r.sentence).font(.caption).foregroundStyle(.secondary)
                }
                if i < top.count - 1 { Divider().overlay(Color.white.opacity(0.08)) }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(22)
    }

    private func badge(_ r: RelResult) -> some View {
        let s = r.strength
        return Text(s.0 + (r.n >= 10 ? String(format: " %.2f", r.r) : ""))
            .font(.caption2.weight(.bold).monospacedDigit())
            .foregroundStyle(s.1 == .secondary ? Color.secondary : .white)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(s.1 == .secondary ? Color.white.opacity(0.08) : s.1.opacity(0.8)))
    }

    // MARK: 一对的卡片（点开看散点图）

    private func pairCard(_ r: RelResult, expanded: Bool = false) -> some View {
        let isOpen = expanded || open == r.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(r.title).font(.subheadline.weight(.semibold))
                Spacer()
                badge(r)
            }
            Text(r.sentence).font(.caption).foregroundStyle(.secondary)
            if isOpen && r.n >= 3 {
                Chart {
                    ForEach(Array(r.points.enumerated()), id: \.offset) { _, p in
                        PointMark(x: .value(r.x.rawValue, p.0), y: .value(r.y.rawValue, p.1))
                            .foregroundStyle(r.y.color.opacity(0.8))
                            .symbolSize(40)
                    }
                }
                .chartXAxisLabel(r.x.rawValue + (r.lag == 1 ? "（当天）" : ""))
                .chartYAxisLabel(r.y.rawValue + (r.lag == 1 ? "（第二天）" : ""))
                .chartXScale(domain: .automatic(includesZero: false))
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 200)
                Text("每个点是一天。点从左下往右上排 = 同向；从左上往右下排 = 反向；散成一团 = 没关系。共 \(r.n) 天。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(18)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !expanded else { return }
            withAnimation(.snappy) { open = open == r.id ? nil : r.id }
        }
    }

    // MARK: 关系表（当天的两两关系）

    private var matrixCard: some View {
        let ms = RelMetric.allCases
        return VStack(alignment: .leading, spacing: 8) {
            Text("关系表（同一天）").font(.headline)
            Text("格子越红：一个高另一个也高；越蓝：一个高另一个反而低；灰 = 看不出或天数太少。点格子看详情。")
                .font(.caption2).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 3) {
                        Text("").frame(width: 58)
                        ForEach(ms) { m in
                            Text(m.short).font(.system(size: 9, weight: .semibold)).foregroundStyle(m.color)
                                .frame(width: 38).lineLimit(1).minimumScaleFactor(0.6)
                        }
                    }
                    ForEach(ms) { a in
                        HStack(spacing: 3) {
                            Text(a.short).font(.system(size: 10, weight: .semibold)).foregroundStyle(a.color)
                                .frame(width: 58, alignment: .leading).lineLimit(1).minimumScaleFactor(0.6)
                            ForEach(ms) { b in
                                matrixCell(a, b)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .glassCard(22)
    }

    @ViewBuilder
    private func matrixCell(_ a: RelMetric, _ b: RelMetric) -> some View {
        if a == b {
            RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.04)).frame(width: 38, height: 30)
        } else if let r = matrix[a.rawValue + "|" + b.rawValue] {
            let ok = r.n >= 10 && r.p <= 0.1
            let c: Color = r.r > 0 ? Color(red: 1, green: 0.35, blue: 0.35) : Color(red: 0.3, green: 0.55, blue: 1)
            Button { cell = r } label: {
                Text(r.n >= 10 ? String(format: "%.1f", r.r) : "·")
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white.opacity(ok ? 1 : 0.4))
                    .frame(width: 38, height: 30)
                    .background(RoundedRectangle(cornerRadius: 5).fill(ok ? c.opacity(0.2 + abs(r.r) * 0.7) : Color.white.opacity(0.06)))
            }
            .buttonStyle(.plain)
        } else {
            RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.04)).frame(width: 38, height: 30)
        }
    }

    /// 一段时间内的步数
    static func steps(from: Date, to: Date) async -> Double? {
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: [])
        return await withCheckedContinuation { cont in
            let q = HKStatisticsQuery(quantityType: HKQuantityType(.stepCount), quantitySamplePredicate: predicate,
                                      options: .cumulativeSum) { _, st, _ in
                cont.resume(returning: st?.sumQuantity()?.doubleValue(for: .count()))
            }
            HealthService.store.execute(q)
        }
    }

    // MARK: 最佳区间：按活动量分档，看每档的各项结果

    enum DoseKind: String, CaseIterable, Identifiable {
        case steps = "每天步数", exercise = "锻炼分钟", kcal = "活动卡路里", postSteps = "饭后走动"
        var id: String { rawValue }
        var metric: RelMetric {
            switch self {
            case .steps: return .steps
            case .exercise: return .exercise
            case .kcal: return .kcal
            case .postSteps: return .postSteps
            }
        }
        /// 分档边界
        var edges: [Double] {
            switch self {
            case .steps: return [3000, 5000, 7000, 9000]
            case .exercise: return [10, 20, 40, 60]
            case .kcal: return [100, 200, 300, 450]
            case .postSteps: return [300, 800, 1500, 2500]
            }
        }
        func label(_ i: Int) -> String {
            let e = edges
            let u = metric == .exercise ? "分钟" : metric == .kcal ? "千卡" : "步"
            func f(_ v: Double) -> String { v >= 1000 && metric != .kcal ? String(format: "%g千", v / 1000) : String(Int(v)) }
            if i == 0 { return "\(f(e[0]))\(u)以下" }
            if i == e.count { return "\(f(e[e.count - 1]))\(u)以上" }
            return "\(f(e[i - 1]))～\(f(e[i]))"
        }
    }

    /// 结果项：(名字, 指标, 隔几天, 越大越好？)
    private var outcomes: [(String, RelMetric, Int, Bool)] {
        // 偏瘦（BMI < 18.5）时体重往上走算好
        var list: [(String, RelMetric, Int, Bool)] = [
            ("次日HRV", .hrv, 1, true), ("次日睡眠", .sleep, 1, true), ("次日静息心率", .resting, 1, false),
            ("餐后血糖", .after2, 0, false),
        ]
        if dose == .postSteps { list = [("餐后血糖", .after2, 0, false)] }
        return list
    }

    private struct DoseRow {
        let label: String
        let days: Int
        let means: [Double?]
        var score: Double?
    }

    private func doseRows() -> [DoseRow] {
        let cal = Calendar.current
        let x = data[dose.metric] ?? [:]
        let edges = dose.edges
        var rows: [DoseRow] = []
        let outs = outcomes
        // 每个结果项的整体平均、标准差（算综合分用）
        var stats: [(Double, Double)] = []
        for o in outs {
            let vals = Array((data[o.1] ?? [:]).values)
            let m = vals.isEmpty ? 0 : vals.reduce(0, +) / Double(vals.count)
            let v = vals.isEmpty ? 0 : vals.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(vals.count)
            stats.append((m, max(sqrt(v), 0.0001)))
        }
        for i in 0...edges.count {
            let lo = i == 0 ? -Double.infinity : edges[i - 1]
            let hi = i == edges.count ? Double.infinity : edges[i]
            let days = x.filter { $0.value >= lo && $0.value < hi }.map(\.key)
            var means: [Double?] = []
            var zs: [Double] = []
            for (k, o) in outs.enumerated() {
                let ys = days.compactMap { d in data[o.1]?[cal.date(byAdding: .day, value: o.2, to: d)!] }
                if ys.count >= 3 {
                    let m = ys.reduce(0, +) / Double(ys.count)
                    means.append(m)
                    let z = (m - stats[k].0) / stats[k].1
                    zs.append(o.3 ? z : -z)
                } else {
                    means.append(nil)
                }
            }
            rows.append(DoseRow(label: dose.label(i), days: days.count, means: means,
                                score: days.count >= 5 && !zs.isEmpty ? zs.reduce(0, +) / Double(zs.count) : nil))
        }
        return rows
    }

    private var doseCard: some View {
        let rows = doseRows()
        let outs = outcomes
        let best = rows.enumerated().filter { $0.element.score != nil }.max { ($0.element.score ?? 0) < ($1.element.score ?? 0) }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("最佳区间", systemImage: "target").font(.headline).foregroundStyle(Color(red: 0.5, green: 0.95, blue: 0.6))
                Spacer()
                Picker("", selection: $dose) {
                    ForEach(DoseKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu).tint(.secondary)
            }
            Text(doseConclusion(rows, best: best?.offset))
                .font(.subheadline.weight(.semibold))
            // 表格：每档一行
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(dose.rawValue).frame(width: 92, alignment: .leading)
                        Text("天数").frame(width: 34)
                        ForEach(Array(outs.enumerated()), id: \.offset) { _, o in
                            Text(o.0).frame(width: 66)
                        }
                    }
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                        HStack(spacing: 6) {
                            HStack(spacing: 2) {
                                if i == best?.offset { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.yellow) }
                                Text(r.label)
                            }
                            .frame(width: 92, alignment: .leading)
                            Text("\(r.days)").frame(width: 34).foregroundStyle(r.days >= 5 ? Color.primary : Color.secondary)
                            ForEach(Array(outs.enumerated()), id: \.offset) { k, o in
                                doseCell(rows, i, k, o)
                            }
                        }
                        .font(.system(size: 12, weight: i == best?.offset ? .bold : .regular).monospacedDigit())
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(i == best?.offset ? Color.green.opacity(0.12) : Color.clear))
                    }
                }
            }
            Text("每列里最好的那格标绿色（HRV、睡眠越高越好；静息心率、餐后血糖越低越好）。少于 5 天的档不参与评比，少于 3 天的格子不显示。⭐ 是综合最好的一档。")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(22)
    }

    @ViewBuilder
    private func doseCell(_ rows: [DoseRow], _ i: Int, _ k: Int, _ o: (String, RelMetric, Int, Bool)) -> some View {
        let vals: [(Int, Double)] = rows.enumerated().compactMap { j, r in r.days >= 5 ? r.means[k].map { (j, $0) } : nil }
        let bestJ = o.3 ? vals.max { $0.1 < $1.1 }?.0 : vals.min { $0.1 < $1.1 }?.0
        let isBest = bestJ == i && vals.count >= 2
        Text(rows[i].means[k].map { o.1.format($0) } ?? "—")
            .frame(width: 66)
            .foregroundStyle(isBest ? Color(red: 0.4, green: 0.95, blue: 0.5) : (rows[i].days >= 5 ? Color.primary : Color.secondary))
    }

    private func doseConclusion(_ rows: [DoseRow], best: Int?) -> String {
        let usable = rows.filter { $0.days >= 5 }.count
        guard let b = best, usable >= 2 else {
            return "还看不出来：至少要有两档各 5 天以上的数据。可以有意识地每周换一个目标（比如这周每天 5000 步、下周 7000 步）来攒数据。"
        }
        let r = rows[b]
        return "目前看，你在「\(r.label)」这一档各项结果综合最好（\(r.days) 天）。数据还会变，先当参考。"
    }

    private var explain: some View {
        Text("怎么算的：每天一行对齐各项数据，算「排名相关」（-1 到 1，只看高低顺序，不怕个别极端值）。绝对值 0.5 以上算关系明显，0.3～0.5 有一定关系；同时算纯属巧合的概率，超过 10% 的标「可能是巧合」；少于 10 天不下结论。「→ 第二天」表示用当天的数去比第二天的数。相关不等于因果，只是帮你发现线索。全部在手机上计算，数据不会上传。")
            .font(.caption2).foregroundStyle(.tertiary)
    }

    // MARK: 读取 + 计算

    private func run() async {
        loading = true
        defer { loading = false }
        let raw = await HealthCompareView.loadData(days: days)
        let cal = Calendar.current
        func byDay(_ list: [DayValue]?) -> [Date: Double] {
            var m: [Date: Double] = [:]
            for v in list ?? [] { m[cal.startOfDay(for: v.date)] = v.value }
            return m
        }
        var data: [RelMetric: [Date: Double]] = [
            .steps: byDay(raw[.steps]), .exercise: byDay(raw[.exercise]), .kcal: byDay(raw[.activeEnergy]),
            .sleep: byDay(raw[.sleep]), .hrv: byDay(raw[.hrv]), .resting: byDay(raw[.restingHR]), .weight: byDay(raw[.weight]),
        ]
        // 血糖：自己的，空腹和餐后 2 小时分开，同一天多次取平均
        let from = cal.date(byAdding: .day, value: -(days - 1), to: cal.startOfDay(for: Date()))!
        let owners = GlucosePeople.owners
        let tags = GlucoseTags.all
        var fast: [Date: [Double]] = [:], post: [Date: [Double]] = [:]
        for r in GlucoseLocal.load() where r.date >= from && (owners[r.id] ?? GlucosePeople.me) == GlucosePeople.me {
            let k = GlucoseKind.of(tags[r.id] ?? GlucoseTags.auto(r))
            let d = cal.startOfDay(for: r.date)
            if k == .fasting { fast[d, default: []].append(r.mmol) }
            if k == .after2 { post[d, default: []].append(r.mmol) }
        }
        data[.fasting] = fast.mapValues { $0.reduce(0, +) / Double($0.count) }
        data[.after2] = post.mapValues { $0.reduce(0, +) / Double($0.count) }
        // 饭后走动：每条餐后 2 小时记录，往前 2 小时内走了多少步（同一天多条取平均）
        var walk: [Date: [Double]] = [:]
        for r in GlucoseLocal.load() where r.date >= from && (owners[r.id] ?? GlucosePeople.me) == GlucosePeople.me
            && GlucoseKind.of(tags[r.id] ?? GlucoseTags.auto(r)) == .after2 {
            if let n = await Self.steps(from: r.date.addingTimeInterval(-2 * 3600), to: r.date) {
                walk[cal.startOfDay(for: r.date), default: []].append(n)
            }
        }
        data[.postSteps] = walk.mapValues { $0.reduce(0, +) / Double($0.count) }
        self.data = data
        dayCount = Set(data.values.flatMap(\.keys)).count

        let snapshot = data
        let (res, mat) = await Task.detached(priority: .userInitiated) { () -> ([RelResult], [String: RelResult]) in
            let res = Relation.pairs.map { Relation.compute(snapshot, x: $0.0, y: $0.1, lag: $0.2) }
            var mat: [String: RelResult] = [:]
            for a in RelMetric.allCases {
                for b in RelMetric.allCases where a != b {
                    mat[a.rawValue + "|" + b.rawValue] = Relation.compute(snapshot, x: a, y: b, lag: 0)
                }
            }
            return (res, mat)
        }.value
        results = res
        matrix = mat
    }
}
