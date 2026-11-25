import SwiftUI
import UIKit
import Charts

/// 趋势对比：步数、HRV、体重、血糖、睡眠评分放在一个页面，同一条时间轴，点一天所有图一起标出来
enum CompareMetric: String, CaseIterable, Identifiable {
    case sleep = "睡眠评分"
    case hrv = "HRV"
    case steps = "步数"
    case weight = "体重"
    case glucose = "血糖"
    case activeEnergy = "活动卡路里"
    case exercise = "锻炼"
    case restingHR = "静息心率"
    case bmi = "BMI"
    var id: String { rawValue }

    var unit: String {
        switch self {
        case .sleep: return "分"
        case .hrv: return "毫秒"
        case .steps: return "步"
        case .weight: return "公斤"
        case .glucose: return "mmol/L"
        case .activeEnergy: return "千卡"
        case .exercise: return "分钟"
        case .restingHR: return "次/分"
        case .bmi: return ""
        }
    }

    var color: Color {
        switch self {
        case .sleep: return AppColor.sleep
        case .hrv: return Color(red: 1.0, green: 0.45, blue: 0.55)
        case .steps: return Color(red: 1.0, green: 0.68, blue: 0.25)
        case .weight: return Color(red: 0.80, green: 0.55, blue: 1.0)
        case .glucose: return Color(red: 0.35, green: 0.90, blue: 0.65)
        case .activeEnergy: return Color(red: 0.98, green: 0.20, blue: 0.40)
        case .exercise: return Color(red: 0.62, green: 1.0, blue: 0.0)
        case .restingHR: return Color(red: 1.0, green: 0.55, blue: 0.45)
        case .bmi: return Color(red: 0.45, green: 0.90, blue: 0.80)
        }
    }

    var icon: String {
        switch self {
        case .sleep: return "bed.double.fill"
        case .hrv: return "waveform.path.ecg"
        case .steps: return "figure.walk"
        case .weight: return "scalemass.fill"
        case .glucose: return "drop.fill"
        case .activeEnergy: return "flame.fill"
        case .exercise: return "figure.run"
        case .restingHR: return "heart.fill"
        case .bmi: return "person.fill"
        }
    }

    func format(_ v: Double) -> String {
        switch self {
        case .sleep, .hrv, .activeEnergy, .exercise, .restingHR: return String(Int(v.rounded()))
        case .bmi: return String(format: "%.1f", v)
        case .steps: return Int(v.rounded()).formatted()
        case .weight: return String(format: "%.1f", v)
        case .glucose: return String(format: "%.1f", v)
        }
    }
}

/// 睡眠评分：仿照苹果手表的睡眠评分（watchOS 26）三项结构，满分 100：
/// 时长 50 + 入睡时间 30（和你平时几点睡比，越规律越高）+ 睡眠中断 20（夜里清醒越少越高）
/// 苹果每项的具体扣分没有公开，这里的曲线是按你的手表分数校准的近似
enum SleepScore {
    /// 入睡时刻换成「从中午 12 点起的分钟数」，过了零点的不会被当成更早
    static func bedMinutes(_ d: Date?) -> Double? {
        guard let d else { return nil }
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        var m = Double((c.hour ?? 0) * 60 + (c.minute ?? 0))
        if m < 12 * 60 { m += 24 * 60 }
        return m
    }

    /// 一晚的原始特征：睡了几小时、入睡比平时偏了几分钟、入睡后醒来几次、清醒几分钟
    struct Features {
        var hours: Double
        var bedDev: Double?
        var wakes: Double?
        var awakeMin: Double
    }

    static func features(_ s: HealthService.SleepData, usualBed: Double?) -> Features? {
        let h = s.asleep / 3600
        guard h > 0.5 else { return nil }
        var dev: Double?
        if let m = bedMinutes(s.bedtime) {
            let ref = usualBed ?? (23 * 60 + 30)
            dev = usualBed == nil ? max(0, m - ref) : abs(m - ref)
        }
        let awake = (s.awakeAllInside ?? s.awakeInside ?? s.awake) / 60
        return Features(hours: h, bedDev: dev, wakes: (s.wakeCountAll ?? s.wakeCount).map(Double.init), awakeMin: awake)
    }

    /// 每项的扣分规则（可以用你填的苹果分项校准）
    /// 默认值按你填的 21 天苹果分项拟合（每项平均差：时长 0.4、就寝 0.5、中断 0.9 分）
    struct Model {
        var fullHours = 9.15     // 时长：差 x 小时到 fullHours，扣 perHour·x^2.5 分
        var perHour = 0.975
        var durPow = 2.5
        var bedTol = 25.0        // 入睡偏差几分钟内满分
        var bedSlope = 0.156     // 超出后每分钟扣几分
        var interBase = 23.6     // 中断 = interBase − perWake·醒来次数 − perAwakeMin·清醒分钟（0～20）
        var perWake = 0.88
        var perAwakeMin = 0.133
    }

    static func parts(_ f: Features, _ m: Model) -> [Double] {
        let h = f.hours
        var dur = h >= m.fullHours ? 50 : max(0, 50 - pow(m.fullHours - h, m.durPow) * m.perHour)
        if h > 9.5 { dur = max(45, dur - (h - 9.5) * 3) }
        let bed: Double = f.bedDev.map { $0 <= m.bedTol ? 30 : max(0, 30 - ($0 - m.bedTol) * m.bedSlope) } ?? 24
        let inter: Double
        if let w = f.wakes {
            inter = min(20, max(0, m.interBase - w * m.perWake - f.awakeMin * m.perAwakeMin))
        } else {
            inter = f.awakeMin <= 10 ? 20 : max(0, 20 - (f.awakeMin - 10) / 80 * 20)
        }
        return [dur, bed, inter]
    }

    /// 旧接口：三项分数（时长 0~50、入睡时间 0~30、中断 0~20），按默认规则
    static func parts(_ s: HealthService.SleepData, usualBed: Double? = nil) -> [Double]? {
        features(s, usualBed: usualBed).map { parts($0, Model()) }
    }

    // MARK: 用苹果的分项（时长 / 就寝 / 中断）逐项校准

    private static let partsKey = "appleSleepParts"
    /// 你填的苹果分项：「2026-11-24」→ [48, 30, 14]
    static var appleParts: [String: [Int]] {
        var m = (UserDefaults.standard.dictionary(forKey: partsKey) as? [String: [Int]]) ?? [:]
        if m["2026-11-24"] == nil { m["2026-11-24"] = [48, 30, 14] }   // 你发来的截图
        return m
    }
    static func setAppleParts(_ v: [Int]?, on day: Date) {
        var m = (UserDefaults.standard.dictionary(forKey: partsKey) as? [String: [Int]]) ?? [:]
        m[dayFmt.string(from: day)] = v
        UserDefaults.standard.set(m, forKey: partsKey)
    }
    static func appleParts(on day: Date) -> [Int]? { appleParts[dayFmt.string(from: day)] }

    private static func solve3(_ A0: [[Double]], _ b0: [Double]) -> [Double]? {
        var A = A0, b = b0
        for c in 0..<3 {
            guard let p = (c..<3).max(by: { abs(A[$0][c]) < abs(A[$1][c]) }), abs(A[p][c]) > 1e-9 else { return nil }
            A.swapAt(c, p); b.swapAt(c, p)
            for r in 0..<3 where r != c {
                let f = A[r][c] / A[c][c]
                for j in c..<3 { A[r][j] -= f * A[c][j] }
                b[r] -= f * b[c]
            }
        }
        return (0..<3).map { b[$0] / A[$0][$0] }
    }

    /// 按分项数据拟合每项的扣分规则（数据少时尽量贴近默认值）
    static func fitModel(_ data: [(Features, [Int])]) -> Model {
        var m = Model()
        guard !data.isEmpty else { return m }
        // 时长：50 − c·(H−小时)^2.5，在 8～9.6 小时里找 H，再算 c（往默认值拉一点）
        let durPts = data.map { ($0.0.hours, Double($0.1[0])) }
        if durPts.count >= 3 && durPts.contains(where: { $0.1 < 50 }) {
            var best = (err: Double.infinity, full: m.fullHours, k: m.perHour)
            var full = 8.0
            while full <= 9.6001 {
                var num = 0.0, den = 0.0
                for (h, y) in durPts where h < full {
                    let x = pow(full - h, m.durPow)
                    num += x * (50 - y); den += x * x
                }
                let k = den > 0 ? (num + 0.5 * m.perHour) / (den + 0.5) : m.perHour
                var err = 0.0
                for (h, y) in durPts { let p = h >= full ? 50 : 50 - pow(full - h, m.durPow) * k; err += (p - y) * (p - y) }
                err += abs(full - 9.15) * 0.5
                if err < best.err { best = (err, full, k) }
                full += 0.05
            }
            m.fullHours = best.full
            m.perHour = max(0, best.k)
        }
        // 就寝：有不满分的才调斜率
        let bedPts = data.compactMap { d -> (Double, Double)? in d.0.bedDev.map { ($0, Double(d.1[1])) } }.filter { $0.0 > m.bedTol }
        if bedPts.count >= 2 {
            let num = bedPts.map { ($0.0 - m.bedTol) * (30 - $0.1) }.reduce(0, +) + 100 * m.bedSlope
            let den = bedPts.map { ($0.0 - m.bedTol) * ($0.0 - m.bedTol) }.reduce(0, +) + 100
            m.bedSlope = max(0.02, num / den)
        }
        // 中断：y = c0 − a·醒来次数 − b·清醒分钟，最小二乘（3 个参数），往默认值拉
        let ip = data.compactMap { d -> (Double, Double, Double)? in
            guard let w = d.0.wakes else { return nil }
            return (w, d.0.awakeMin, Double(d.1[2]))
        }
        if ip.count >= 5 {
            let prior = [m.interBase, -m.perWake, -m.perAwakeMin]
            let lam = [1.0, 20.0, 400.0]
            var A = [[Double]](repeating: [0, 0, 0], count: 3)
            var bb = [0.0, 0, 0]
            for i in 0..<3 { A[i][i] = lam[i]; bb[i] = lam[i] * prior[i] }
            for (w, mins, y) in ip {
                let r = [1, w, mins]
                for i in 0..<3 { bb[i] += r[i] * y; for j in 0..<3 { A[i][j] += r[i] * r[j] } }
            }
            if let c = solve3(A, bb) {
                m.interBase = c[0]; m.perWake = max(0, -c[1]); m.perAwakeMin = max(0, -c[2])
            }
        }
        return m
    }

    static func score(_ s: HealthService.SleepData, usualBed: Double? = nil) -> Double? {
        parts(s, usualBed: usualBed).map { $0.reduce(0, +).rounded() }
    }

    // MARK: 用苹果手表的分数校准

    private static let appleKey = "appleSleepScores"
    private static let dayFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()

    /// 你填的苹果睡眠评分：「2026-11-14」→ 78
    static var appleScores: [String: Int] {
        var m = (UserDefaults.standard.dictionary(forKey: appleKey) as? [String: Int]) ?? [:]
        // 你最早发来的几天
        let seed = ["2026-11-07": 69, "2026-11-08": 83, "2026-11-09": 90, "2026-11-10": 77,
                    "2026-11-11": 89, "2026-11-12": 95, "2026-11-13": 86, "2026-11-14": 78]
        for (k, v) in seed where m[k] == nil { m[k] = v }
        return m
    }
    static func setApple(_ v: Int?, on day: Date) {
        var m = appleScores
        m[dayFmt.string(from: day)] = v
        UserDefaults.standard.set(m, forKey: appleKey)
    }
    static func apple(on day: Date) -> Int? {
        let k = dayFmt.string(from: day)
        return appleScores[k] ?? appleParts[k].map { $0.reduce(0, +) }
    }

    /// 最小二乘拟合：苹果分 ≈ a + b·时长分 + c·入睡分 + d·中断分（加一点点约束防止乱跳）
    static func fit(_ xs: [[Double]], _ ys: [Double]) -> [Double]? {
        guard xs.count >= 5 else { return nil }
        let k = 4
        var A = [[Double]](repeating: [Double](repeating: 0, count: k), count: k)
        var b = [Double](repeating: 0, count: k)
        for (x, y) in zip(xs, ys) {
            let row = [1] + x
            for i in 0..<k {
                b[i] += row[i] * y
                for j in 0..<k { A[i][j] += row[i] * row[j] }
            }
        }
        // 往「原样相加」(0,1,1,1) 拉一点，数据少时不会算出离谱的系数
        let prior = [0.0, 1, 1, 1], lambda = 2.0
        for i in 1..<k { A[i][i] += lambda; b[i] += lambda * prior[i] }
        // 高斯消元
        for c in 0..<k {
            guard let p = (c..<k).max(by: { abs(A[$0][c]) < abs(A[$1][c]) }), abs(A[p][c]) > 1e-9 else { return nil }
            A.swapAt(c, p); b.swapAt(c, p)
            for r in 0..<k where r != c {
                let f = A[r][c] / A[c][c]
                for j in c..<k { A[r][j] -= f * A[c][j] }
                b[r] -= f * b[c]
            }
        }
        return (0..<k).map { b[$0] / A[$0][$0] }
    }

    /// 校准情况（给页面显示）：用了几天、平均差几分
    @MainActor static var calibrationNote = ""

    /// 一串按日期排好的夜晚：每晚用前 13 晚的中位入睡时刻算「就寝」；
    /// 有你填的苹果分项就逐项校准规则；只有总分的，再按总分整体校准
    static func scores(_ nights: [(Date, HealthService.SleepData)]) -> ([DayValue], String) {
        let d = detailed(nights)
        return (d.0, d.1)
    }

    nonisolated(unsafe) static var lastInfo: [Date: String] = [:]

    static func detailed(_ nights: [(Date, HealthService.SleepData)]) -> ([DayValue], String, [Date: [Double]]) {
        var feats: [(Date, Features)] = []
        for (i, n) in nights.enumerated() {
            let prev = nights[max(0, i - 13)..<i].compactMap { bedMinutes($0.1.bedtime) }.sorted()
            let usual: Double? = prev.count >= 3 ? prev[prev.count / 2] : nil
            if let f = features(n.1, usualBed: usual) { feats.append((n.0, f)) }
        }
        let partData = feats.compactMap { f in appleParts(on: f.0).map { (f.1, $0) } }
        let model = fitModel(partData)
        let raw: [(Date, [Double])] = feats.map { ($0.0, parts($0.1, model)) }
        var byDay: [Date: [Double]] = [:]
        for r in raw { byDay[r.0] = r.1 }
        var info: [Date: String] = [:]
        for (d, f) in feats {
            let p = parts(f, model)
            var t = String(format: "阿波：时长 %.0f · 就寝 %.0f · 中断 %.0f", p[0], p[1], p[2])
            t += String(format: "\n睡 %d:%02d", Int(f.hours), Int((f.hours - Double(Int(f.hours))) * 60))
            if let dv = f.bedDev { t += String(format: " · 入睡偏 %.0f 分", dv) }
            if let w = f.wakes { t += String(format: " · 醒 %.0f 次（含短暂）", w) }
            t += String(format: " · 清醒 %.0f 分", f.awakeMin)
            info[d] = t
        }
        lastInfo = info
        // 有分项数据时按分项规则直接相加（和苹果一样）；没有时用总分整体校准
        let useParts = !partData.isEmpty
        let pairs = raw.compactMap { r in apple(on: r.0).map { (r.1, Double($0)) } }
        let w = useParts ? nil : fit(pairs.map(\.0), pairs.map(\.1))
        func val(_ p: [Double]) -> Double {
            guard let w else { return p.reduce(0, +) }
            return w[0] + w[1] * p[0] + w[2] * p[1] + w[3] * p[2]
        }
        let out = raw.map { DayValue(date: $0.0, value: min(100, max(0, val($0.1))).rounded()) }
        var note = "还没用苹果分校准（填几天苹果的分项最准）"
        if !pairs.isEmpty && (useParts || w != nil) {
            let err = pairs.map { abs(min(100, max(0, val($0.0))).rounded() - $0.1) }
            note = String(format: "已按 %d 天苹果分%@校准，平均差 %.1f 分", pairs.count, useParts ? "（含 \(partData.count) 天分项）" : "",
                          err.reduce(0, +) / Double(err.count))
        }
        return (out, note, byDay)
    }
}

extension CompareMetric {
    /// 精简版没有血糖
    static var available: [CompareMetric] {
#if LITE
        return allCases.filter { $0 != .glucose }
#else
        return Array(allCases)
#endif
    }
}

struct HealthCompareView: View {
    @State private var days = 30
    @State private var shown: Set<CompareMetric> = HealthCompareView.savedShown
    @State private var order: [CompareMetric] = HealthCompareView.savedOrder
    @State private var arranging = false        // 调整顺序
    @State private var calibrating = false      // 填苹果睡眠评分
    @State private var onScreen = false
    @State private var overlay = false           // 叠在一张图上
    @State private var data: [CompareMetric: [DayValue]] = [:]
    @State private var loading = false
    @State private var selected: Date?

    /// 读 90 天，屏幕上一次看 days 天，左右拖动看别的天
    static let loadDays = 90
    @State private var scrollX: Date = Calendar.current.date(byAdding: .day, value: -29, to: Calendar.current.startOfDay(for: Date()))!
    /// 屏幕上能看到几天（双指缩放会改它）
    @State private var zoomDays: Double = 30
    @State private var pinchFrom: Double?
    private var visible: TimeInterval { zoomDays * 86400 }
    /// 日期刻度：放得越大刻得越密，放到 10 天以内一天一个
    private var xStride: Int {
        if zoomDays <= 10 { return 1 }
        if zoomDays <= 20 { return 2 }
        if zoomDays <= 45 { return 7 }
        return 14
    }
    private func pinchChanged(_ scale: CGFloat) {
        if pinchFrom == nil { pinchFrom = zoomDays }
        let center = scrollX.addingTimeInterval(visible / 2)
        let nd = min(max(pinchFrom! / Double(max(scale, 0.05)), 5), Double(Self.loadDays))
        zoomDays = nd
        let t = center.addingTimeInterval(-nd * 86400 / 2)
        scrollX = min(max(t, start), end.addingTimeInterval(-nd * 86400))
    }
    private func pinchEnded() { pinchFrom = nil }
    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { v in pinchChanged(v.magnification) }
            .onEnded { _ in pinchEnded() }
    }
    private var winStart: Date { scrollX }
    private var winEnd: Date { scrollX.addingTimeInterval(visible) }
    @State private var dragFrom: Date?

    /// 在图上左右拖：所有图一起平移（自己算，不用系统的图表滚动，免得和页面手势抢）
    private func panChanged(_ dx: CGFloat) {
        if dragFrom == nil { dragFrom = scrollX }
        let w = max(200, UIScreen.main.bounds.width - 90)
        let t = dragFrom!.addingTimeInterval(-Double(dx / w) * visible)
        scrollX = min(max(t, start), end.addingTimeInterval(-visible))
    }
    private func panEnded() { dragFrom = nil }
    private var start: Date {
        Calendar.current.date(byAdding: .day, value: -(Self.loadDays - 1), to: Calendar.current.startOfDay(for: Date()))!
    }
    private var end: Date { Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))! }
    private var metrics: [CompareMetric] { order.filter { shown.contains($0) } }

    // 顺序和显示哪几项记在本机
    static var savedOrder: [CompareMetric] {
        let saved = (UserDefaults.standard.stringArray(forKey: "compareOrder") ?? []).compactMap(CompareMetric.init(rawValue:))
        return saved + CompareMetric.available.filter { !saved.contains($0) }
    }
    static var savedShown: Set<CompareMetric> {
        guard let hidden = UserDefaults.standard.stringArray(forKey: "compareHidden") else { return Set(CompareMetric.available) }
        return Set(CompareMetric.available.filter { !hidden.contains($0.rawValue) })
    }
    private func persist() {
        UserDefaults.standard.set(order.map(\.rawValue), forKey: "compareOrder")
        UserDefaults.standard.set(CompareMetric.available.filter { !shown.contains($0) }.map(\.rawValue), forKey: "compareHidden")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Picker("", selection: $overlay) {
                        Text("分开看").tag(false)
                        Text("叠在一起").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 200)
                    Spacer()
                    Picker("范围", selection: $days) {
                        Text("7天").tag(7)
                        Text("30天").tag(30)
                        Text("90天").tag(90)
                    }
                    .pickerStyle(.menu).tint(.secondary)
                }
                if abs(zoomDays - Double(days)) > 0.5 {
                    Button {
                        withAnimation { zoomDays = Double(days); scrollX = Calendar.current.date(byAdding: .day, value: -(days - 1), to: Calendar.current.startOfDay(for: Date()))! }
                    } label: {
                        Label("已缩放到 \(Int(zoomDays.rounded())) 天 · 点这里还原", systemImage: "arrow.uturn.backward")
                            .font(.caption)
                    }
                    .tint(.secondary)
                }

                // 选哪几项
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(order) { m in
                            let on = shown.contains(m)
                            Button {
                                withAnimation { if on { shown.remove(m) } else { shown.insert(m) } }
                            } label: {
                                Label(m.rawValue, systemImage: m.icon)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(on ? Color.white : m.color)
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(Capsule().fill(on ? m.color.opacity(0.75) : Color.white.opacity(0.07)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }


                // 关系分析入口
                NavigationLink { HealthRelationView() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color(red: 1, green: 0.8, blue: 0.4))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("关系分析").font(.subheadline.weight(.bold))
                            Text("算一算哪几项之间真的有关系").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .glassCard(18)
                }
                .buttonStyle(.plain)

                if loading && data.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(40)
                } else if overlay {
                    overlayChart
                } else {
                    ForEach(metrics) { m in chartCard(m) }
                }

                Text("点图上任意一天，所有图都会标出那一天，上面显示当天各项数值。「叠在一起」把每项按自己的最低到最高缩放到同一高度，只看涨跌趋势。BMI 绿色区域是健康范围 18.5～23.9（中国成人标准）；静息心率正常 60～100。血糖用你自己的餐后 2 小时记录，一天测了几次就取平均。睡眠评分仿照苹果手表的评分（满分 100）：时长 50（8 小时以上满分）、入睡时间 30（和平时几点睡差 30 分钟以内满分）、睡眠中断 20（夜里清醒 10 分钟以内满分）。苹果的具体算法没公开；在睡眠评分图上点「校准」填几天手表上的苹果分，会自动调整权重，越填越准。左右拖动图表可以看更早的日子。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(16)
            .padding(.bottom, 100)
        }
        .background(AppBackground())
        .navigationTitle("趋势对比")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task { await load() }
        // 图表要左右拖，这个页面里关掉主页面的左右翻页
        .background(DisableTabPaging(active: onScreen).frame(width: 0, height: 0))
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        .onChange(of: days) { _, d in
            zoomDays = Double(d)
            scrollX = Calendar.current.date(byAdding: .day, value: -(d - 1), to: Calendar.current.startOfDay(for: Date()))!
        }
        .onChange(of: shown) { _, _ in persist() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { arranging = true } label: { Image(systemName: "arrow.up.arrow.down") }
            }
        }
        .sheet(isPresented: $arranging) { arrangeSheet }
        .sheet(isPresented: $calibrating, onDismiss: {
            Task { await HealthCompareView.clearMemo(); await load() }
        }) {
            SleepCalibrationSheet(mine: data[.sleep] ?? [])
        }
    }

    // MARK: 调整顺序（按住右边的三条线拖动）

    private var arrangeSheet: some View {
        NavigationStack {
            List {
                Section(footer: Text("按住右边的 ≡ 上下拖动调整顺序，开关决定显示哪几项。")) {
                    ForEach(order) { m in
                        Toggle(isOn: Binding(get: { shown.contains(m) },
                                             set: { on in if on { shown.insert(m) } else { shown.remove(m) } })) {
                            Label(m.rawValue, systemImage: m.icon).foregroundStyle(m.color)
                        }
                    }
                    .onMove { from, to in
                        order.move(fromOffsets: from, toOffset: to)
                        persist()
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("调整顺序")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { arranging = false } }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: 选中那天的数值

    private var selectedPanel: some View {
        let day = selected ?? Calendar.current.startOfDay(for: Date())
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "M月d日 EEE"
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(selected == nil ? "今天" : f.string(from: day)).font(.headline)
                Spacer()
                if selected != nil {
                    Button("回到今天") { withAnimation { selected = nil } }.font(.caption)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 10) {
                ForEach(metrics) { m in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.rawValue).font(.caption2).foregroundStyle(m.color)
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text(value(m, on: day).map(m.format) ?? "—")
                                .font(.system(size: 19, weight: .bold, design: .rounded).monospacedDigit())
                            if m == .bmi, let v = value(m, on: day) {
                                Text(BMI.category(v).0).font(.system(size: 10, weight: .bold)).foregroundStyle(BMI.category(v).1)
                            } else {
                                Text(m.unit).font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(16)
        .glassCard(22)
    }

    private func value(_ m: CompareMetric, on day: Date) -> Double? {
        data[m]?.first { Calendar.current.isDate($0.date, inSameDayAs: day) }?.value
    }

    // MARK: 分开看

    private func chartCard(_ m: CompareMetric) -> some View {
        let from = start
        let pts = (data[m] ?? []).filter { $0.date >= from }    // 范围外的点不画，免得伸出图表
        let vals = pts.map(\.value)
        var lo = vals.min() ?? 0, hi = vals.max() ?? 1
        if m == .bmi { lo = min(lo, 18); hi = max(hi, 24.4) }   // 健康范围要看得到
        let pad = max((hi - lo) * 0.15, m == .steps ? 500 : m == .weight ? 0.3 : 0.5)
        let win = pts.filter { $0.date >= winStart.addingTimeInterval(-2 * 86400) && $0.date <= winEnd.addingTimeInterval(86400) }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(m == .glucose ? "血糖（餐后2h）" : m.rawValue, systemImage: m.icon).font(.subheadline.weight(.semibold)).foregroundStyle(m.color)
                if m == .sleep {
                    Button("校准") { calibrating = true }.font(.caption.weight(.semibold))
                }
                Spacer()
                if !vals.isEmpty {
                    Text("平均 " + m.format(vals.reduce(0, +) / Double(vals.count)) + " " + m.unit)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if pts.isEmpty {
                Text("这段时间没有数据").font(.caption).foregroundStyle(.secondary).frame(height: 90)
            } else {
                Chart {
                    ForEach(win) { p in
                        LineMark(x: .value("日期", p.date, unit: .day), y: .value(m.rawValue, p.value))
                            .interpolationMethod(.monotone)   // 不会冲出最高/最低点
                            .foregroundStyle(m.color)
                            .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
                        PointMark(x: .value("日期", p.date, unit: .day), y: .value(m.rawValue, p.value))
                            .foregroundStyle(m.color)
                            .symbolSize(zoomDays > 30 ? 10 : 22)
                    }
                    if m == .bmi {
                        RectangleMark(yStart: .value("下限", 18.5), yEnd: .value("上限", 23.9))
                            .foregroundStyle(Color.green.opacity(0.12))
                    }
                    if m == .glucose {
                        RuleMark(y: .value("参考", 7.8))
                            .foregroundStyle(Color.red.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                    if let s = selected {
                        RuleMark(x: .value("选中", s, unit: .day)).foregroundStyle(.white.opacity(0.35))
                        // 选中那天：在这条曲线上标出数值
                        if let p = pts.first(where: { Calendar.current.isDate($0.date, inSameDayAs: s) }) {
                            PointMark(x: .value("日期", p.date, unit: .day), y: .value(m.rawValue, p.value))
                                .foregroundStyle(.white)
                                .symbolSize(70)
                                .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                                    Text(m.format(p.value))
                                        .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Capsule().fill(m.color.opacity(0.85)))
                                }
                        }
                    }
                }
                .chartXScale(domain: winStart...winEnd)
                .chartPlotStyle { $0.clipped() }
                .chartYScale(domain: (lo - pad)...(hi + pad))
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: xStride)) { v in
                        AxisGridLine().foregroundStyle(.white.opacity(0.05))
                        AxisValueLabel(format: .dateTime.month(.defaultDigits).day(), centered: false)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                        AxisGridLine().foregroundStyle(.white.opacity(0.06))
                        AxisValueLabel {
                            if let d = v.as(Double.self) { Text(m == .steps ? String(format: "%.0fk", d / 1000) : m.format(d)).font(.caption2) }
                        }
                    }
                }
                .frame(height: 110)
                .tapToSelect($selected, dates: win.map(\.date), byDay: true)
                .horizontalPan(changed: panChanged, ended: panEnded)
                .simultaneousGesture(pinch)
            }
        }
        .padding(14)
        .glassCard(20)
    }

    // MARK: 叠在一起（各自缩放到 0~100）

    private struct NormPoint: Identifiable {
        let metric: CompareMetric
        let date: Date
        let v: Double
        let raw: Double
        var id: String { metric.rawValue + "\(date.timeIntervalSince1970)" }
    }

    private var overlayChart: some View {
        var pts: [NormPoint] = []
        for m in metrics {
            let list = (data[m] ?? []).filter { $0.date >= start }
            let vals = list.map(\.value)
            guard let lo = vals.min(), let hi = vals.max() else { continue }
            for p in list {
                pts.append(NormPoint(metric: m, date: p.date, v: hi > lo ? (p.value - lo) / (hi - lo) * 100 : 50, raw: p.value))
            }
        }
        let shownPts = pts.filter { $0.date >= winStart.addingTimeInterval(-2 * 86400) && $0.date <= winEnd.addingTimeInterval(86400) }
        let dates = Array(Set(shownPts.map(\.date))).sorted()
        return VStack(alignment: .leading, spacing: 8) {
            Chart {
                ForEach(shownPts) { p in
                    LineMark(x: .value("日期", p.date, unit: .day), y: .value("相对", p.v),
                             series: .value("项目", p.metric.rawValue))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(p.metric.color)
                        .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
                }
                if let s = selected {
                    RuleMark(x: .value("选中", s, unit: .day)).foregroundStyle(.white.opacity(0.35))
                    // 每条线在选中那天标出实际数值
                    ForEach(pts.filter { Calendar.current.isDate($0.date, inSameDayAs: s) }) { p in
                        PointMark(x: .value("日期", p.date, unit: .day), y: .value("相对", p.v))
                            .foregroundStyle(p.metric.color)
                            .symbolSize(60)
                            .annotation(position: .trailing, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                                Text(p.metric.format(p.raw))
                                    .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Capsule().fill(p.metric.color.opacity(0.85)))
                            }
                    }
                }
            }
            .chartXScale(domain: winStart...winEnd)
            .chartPlotStyle { $0.clipped() }
            .chartYScale(domain: -5...105)
            .chartYAxis {
                AxisMarks(position: .trailing, values: [0, 50, 100]) { v in
                    AxisGridLine().foregroundStyle(.white.opacity(0.06))
                    AxisValueLabel {
                        if let d = v.as(Double.self) { Text(d == 0 ? "低" : d == 100 ? "高" : "").font(.caption2) }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: xStride)) { _ in
                    AxisValueLabel(format: .dateTime.month(.defaultDigits).day(), centered: false)
                }
            }
            .frame(height: 260)
            .tapToSelect($selected, dates: dates, byDay: true)
            .horizontalPan(changed: panChanged, ended: panEnded)
                .simultaneousGesture(pinch)

            // 图例
            HStack(spacing: 12) {
                ForEach(metrics) { m in
                    HStack(spacing: 4) {
                        Capsule().fill(m.color).frame(width: 14, height: 4)
                        Text(m.rawValue).font(.caption2)
                    }
                }
            }
        }
        .padding(14)
        .glassCard(20)
    }

    // MARK: 读取

    private func load() async {
        loading = true
        defer { loading = false }
        selected = nil
        let out = await Self.loadData(days: Self.loadDays)
        withAnimation { data = out }
    }

    /// 读最近 n 天每天的各项数据（趋势对比和关系分析共用）
    /// 10 分钟内重复打开不再重新读（读 90 晚睡眠要查很多次健康数据）
    @MainActor private static var memo: [Int: (Date, [CompareMetric: [DayValue]])] = [:]

    static func clearMemo() async { await MainActor.run { memo = [:] } }

    static func loadData(days n: Int) async -> [CompareMetric: [DayValue]] {
        if let m = await MainActor.run(body: { memo[n] }), Date().timeIntervalSince(m.0) < 600 { return m.1 }
        let out = await fetchData(days: n)
        await MainActor.run { memo[n] = (Date(), out) }
        return out
    }

    private static func fetchData(days n: Int) async -> [CompareMetric: [DayValue]] {
        let cal = Calendar.current
        let from = cal.date(byAdding: .day, value: -(n - 1), to: cal.startOfDay(for: Date()))!
        async let steps = (try? HealthService.daily(.steps, days: n)) ?? []
        async let hrv = (try? HealthService.daily(.hrv, days: n)) ?? []
        async let weight = (try? HealthService.weightHistory(days: n)) ?? []
        async let kcal = (try? HealthService.daily(.activeEnergy, days: n)) ?? []
        async let exercise = (try? HealthService.daily(.exercise, days: n)) ?? []
        async let resting = (try? HealthService.daily(.restingHR, days: n)) ?? []
        async let height = BMI.height()

        var out: [CompareMetric: [DayValue]] = [:]
        out[.steps] = await steps
        out[.hrv] = await hrv
        // 体重：一天多次取当天最后一次
        var w: [Date: Double] = [:]
        for p in await weight.sorted(by: { $0.date < $1.date }) { w[cal.startOfDay(for: p.date)] = p.kg }
        out[.weight] = w.map { DayValue(date: $0.key, value: $0.value) }.sorted { $0.date < $1.date }
        if let cm = await height { out[.bmi] = out[.weight]?.map { DayValue(date: $0.date, value: BMI.value(kg: $0.value, cm: cm)) } }
        out[.activeEnergy] = await kcal
        out[.exercise] = await exercise
        out[.restingHR] = await resting
        // 多读 14 晚，用来算「平时几点睡」
        let all = await HealthService.nightlySleep(days: n + 14)
        let (sl, note) = SleepScore.scores(all)
        out[.sleep] = sl.filter { $0.date >= from }
        await MainActor.run { SleepScore.calibrationNote = note }
        // 血糖：自己的餐后 2 小时记录，同一天多次取平均
        let owners = GlucosePeople.owners
        let tags = GlucoseTags.all
        var g: [Date: [Double]] = [:]
        for r in GlucoseLocal.load() where r.date >= from && (owners[r.id] ?? GlucosePeople.me) == GlucosePeople.me
            && GlucoseKind.of(tags[r.id] ?? GlucoseTags.auto(r)) == .after2 {
            g[cal.startOfDay(for: r.date), default: []].append(r.mmol)
        }
        out[.glucose] = g.map { DayValue(date: $0.key, value: $0.value.reduce(0, +) / Double($0.value.count)) }.sorted { $0.date < $1.date }
        return out
    }
}


/// 填苹果手表的睡眠评分，用来校准
struct SleepCalibrationSheet: View {
    let mine: [DayValue]
    @Environment(\.dismiss) private var dismiss
    @State private var texts: [Date: [String]] = [:]   // [总分, 时长, 就寝, 中断]

    private var days: [Date] {
        let cal = Calendar.current
        return (0..<21).map { cal.date(byAdding: .day, value: -$0, to: cal.startOfDay(for: Date()))! }
    }

    var body: some View {
        NavigationStack {
            List {
                Section(footer: Text("打开「健康」App →「睡眠评分」，把苹果的总分填进来；最好连「时长 / 就寝 / 中断」三项一起填，填了分项会逐项校准，比只填总分准得多。" + (SleepScore.calibrationNote.isEmpty ? "" : "\n现在：" + SleepScore.calibrationNote))) {
                    ForEach(days, id: \.self) { d in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(label(d)).font(.subheadline.weight(.semibold))
                                Spacer()
                                if let m = mine.first(where: { Calendar.current.isDate($0.date, inSameDayAs: d) }) {
                                    Text("阿波算 \(Int(m.value))").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            if let i = SleepScore.lastInfo.first(where: { Calendar.current.isDate($0.key, inSameDayAs: d) })?.value {
                                Text(i).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                            }
                            HStack(spacing: 8) {
                                field(d, 0, "总分")
                                field(d, 1, "时长/50")
                                field(d, 2, "就寝/30")
                                field(d, 3, "中断/20")
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .navigationTitle("睡眠评分校准")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save(); dismiss() }
                }
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
            .onAppear {
                for d in days {
                    var t = ["", "", "", ""]
                    if let p = SleepScore.appleParts(on: d), p.count == 3 {
                        t = [String(p.reduce(0, +)), String(p[0]), String(p[1]), String(p[2])]
                    } else if let v = SleepScore.apple(on: d) {
                        t[0] = String(v)
                    }
                    texts[d] = t
                }
            }
        }
    }

    private func field(_ d: Date, _ i: Int, _ hint: String) -> some View {
        TextField(hint, text: Binding(get: { (texts[d] ?? ["", "", "", ""])[i] }, set: { v in
            var t = texts[d] ?? ["", "", "", ""]
            t[i] = v
            texts[d] = t
        }))
        .keyboardType(.numberPad)
        .multilineTextAlignment(.center)
        .font(.subheadline.monospacedDigit())
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
    }

    private func save() {
        for d in days {
            let t = (texts[d] ?? ["", "", "", ""]).map { Int($0.trimmingCharacters(in: .whitespaces)) }
            let maxes = [50, 30, 20]
            let partsOK = (1...3).allSatisfy { i in t[i].map { (0...maxes[i - 1]).contains($0) } ?? false }
            if partsOK {
                let p = [t[1]!, t[2]!, t[3]!]
                SleepScore.setAppleParts(p, on: d)
                SleepScore.setApple(p.reduce(0, +), on: d)
            } else {
                SleepScore.setAppleParts(nil, on: d)
                SleepScore.setApple(t[0].flatMap { (0...100).contains($0) ? $0 : nil }, on: d)
            }
        }
    }

    private func label(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "M月d日 EEE"
        return f.string(from: d)
    }
}


// MARK: 只认横向拖动的手势（竖着拖直接让给页面滚动）

@available(iOS 18.0, *)
struct HorizontalPan: UIGestureRecognizerRepresentable {
    var enabled: Bool = true
    var changed: (CGFloat) -> Void
    var ended: () -> Void

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let p = g as? UIPanGestureRecognizer else { return true }
            let v = p.velocity(in: p.view)
            let t = p.translation(in: p.view)
            let dx: CGFloat = abs(v.x) + abs(t.x) * 10
            let dy: CGFloat = abs(v.y) + abs(t.y) * 10
            return dx > dy * 1.2
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let g = UIPanGestureRecognizer()
        g.maximumNumberOfTouches = 1
        g.delegate = context.coordinator
        g.isEnabled = enabled
        return g
    }

    func updateUIGestureRecognizer(_ g: UIPanGestureRecognizer, context: Context) {
        g.isEnabled = enabled
    }

    func handleUIGestureRecognizerAction(_ g: UIPanGestureRecognizer, context: Context) {
        switch g.state {
        case .began, .changed: changed(g.translation(in: g.view).x)
        default: ended()
        }
    }
}

extension View {
    @ViewBuilder
    func horizontalPan(enabled: Bool = true, changed: @escaping (CGFloat) -> Void, ended: @escaping () -> Void) -> some View {
        if #available(iOS 18.0, *) {
            self.gesture(HorizontalPan(enabled: enabled, changed: changed, ended: ended))
        } else {
            self.simultaneousGesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { v in
                        if abs(v.translation.width) > abs(v.translation.height) { changed(v.translation.width) }
                    }
                    .onEnded { _ in ended() },
                including: enabled ? .all : .subviews
            )
        }
    }
}
