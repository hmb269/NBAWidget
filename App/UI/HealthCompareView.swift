import SwiftUI
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

    /// 三项分数（时长 0~50、入睡时间 0~30、中断 0~20）
    static func parts(_ s: HealthService.SleepData, usualBed: Double? = nil) -> [Double]? {
        let h = s.asleep / 3600
        guard h > 0.5 else { return nil }
        // 时长：8～9.5 小时满分；4 小时以下 0；超过 9.5 小时最多扣到 45
        let dur: Double = h >= 8 ? (h <= 9.5 ? 50 : max(45, 50 - (h - 9.5) * 3)) : max(0, (h - 4) / 4 * 50)
        // 入睡时间：和平时差 30 分钟以内满分，差 3 小时以上 0；没有平时的数据就按 23:30 前算满分
        var bed: Double = 24
        if let m = bedMinutes(s.bedtime) {
            let ref = usualBed ?? (23 * 60 + 30)
            let dev = usualBed == nil ? max(0, m - ref) : abs(m - ref)
            bed = dev <= 30 ? 30 : max(0, 30 - (dev - 30) / 150 * 30)
        }
        // 中断：夜里清醒 10 分钟以内满分，90 分钟以上 0
        let awakeMin = s.awake / 60
        let inter: Double = awakeMin <= 10 ? 20 : max(0, 20 - (awakeMin - 10) / 80 * 20)
        return [dur, bed, inter]
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
    static func apple(on day: Date) -> Int? { appleScores[dayFmt.string(from: day)] }

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

    /// 一串按日期排好的夜晚，每晚用前 14 晚的中位入睡时刻来评分；
    /// 有 5 天以上你填的苹果分时，按它们校准三项的权重
    static func scores(_ nights: [(Date, HealthService.SleepData)]) -> ([DayValue], String) {
        var raw: [(Date, [Double])] = []
        for (i, n) in nights.enumerated() {
            let prev = nights[max(0, i - 14)..<i].compactMap { bedMinutes($0.1.bedtime) }.sorted()
            let usual: Double? = prev.count >= 3 ? prev[prev.count / 2] : nil
            if let p = parts(n.1, usualBed: usual) { raw.append((n.0, p)) }
        }
        let pairs = raw.compactMap { r in apple(on: r.0).map { (r.1, Double($0)) } }
        let w = fit(pairs.map(\.0), pairs.map(\.1))
        func val(_ p: [Double]) -> Double {
            guard let w else { return p.reduce(0, +) }
            return w[0] + w[1] * p[0] + w[2] * p[1] + w[3] * p[2]
        }
        let out = raw.map { DayValue(date: $0.0, value: min(100, max(0, val($0.1))).rounded()) }
        var note = "还没用苹果分校准（至少要 5 天）"
        if w != nil {
            let err = pairs.map { abs(min(100, max(0, val($0.0))).rounded() - $0.1) }
            note = String(format: "已按 %d 天苹果分校准，平均差 %.1f 分", pairs.count, err.reduce(0, +) / Double(err.count))
        }
        return (out, note)
    }
}

struct HealthCompareView: View {
    @State private var days = 30
    @State private var shown: Set<CompareMetric> = HealthCompareView.savedShown
    @State private var order: [CompareMetric] = HealthCompareView.savedOrder
    @State private var arranging = false        // 调整顺序
    @State private var calibrating = false      // 填苹果睡眠评分
    @State private var overlay = false           // 叠在一张图上
    @State private var data: [CompareMetric: [DayValue]] = [:]
    @State private var loading = false
    @State private var selected: Date?

    /// 读 90 天，屏幕上一次看 days 天，左右拖动看别的天
    static let loadDays = 90
    @State private var scrollX: Date = Calendar.current.date(byAdding: .day, value: -29, to: Calendar.current.startOfDay(for: Date()))!
    private var visible: TimeInterval { Double(days) * 86400 }
    private var start: Date {
        Calendar.current.date(byAdding: .day, value: -(Self.loadDays - 1), to: Calendar.current.startOfDay(for: Date()))!
    }
    private var end: Date { Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))! }
    private var metrics: [CompareMetric] { order.filter { shown.contains($0) } }

    // 顺序和显示哪几项记在本机
    static var savedOrder: [CompareMetric] {
        let saved = (UserDefaults.standard.stringArray(forKey: "compareOrder") ?? []).compactMap(CompareMetric.init(rawValue:))
        return saved + CompareMetric.allCases.filter { !saved.contains($0) }
    }
    static var savedShown: Set<CompareMetric> {
        guard let hidden = UserDefaults.standard.stringArray(forKey: "compareHidden") else { return Set(CompareMetric.allCases) }
        return Set(CompareMetric.allCases.filter { !hidden.contains($0.rawValue) })
    }
    private func persist() {
        UserDefaults.standard.set(order.map(\.rawValue), forKey: "compareOrder")
        UserDefaults.standard.set(CompareMetric.allCases.filter { !shown.contains($0) }.map(\.rawValue), forKey: "compareHidden")
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
        .onChange(of: days) { _, d in
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
                    ForEach(pts) { p in
                        LineMark(x: .value("日期", p.date, unit: .day), y: .value(m.rawValue, p.value))
                            .interpolationMethod(.monotone)   // 不会冲出最高/最低点
                            .foregroundStyle(m.color)
                            .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
                        PointMark(x: .value("日期", p.date, unit: .day), y: .value(m.rawValue, p.value))
                            .foregroundStyle(m.color)
                            .symbolSize(days > 30 ? 10 : 22)
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
                .chartXScale(domain: start...end)
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: visible)
                .chartScrollPosition(x: $scrollX)
                .chartYScale(domain: (lo - pad)...(hi + pad))
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { v in
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
                .tapToSelect($selected, dates: pts.map(\.date), byDay: true)
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
        let dates = Array(Set(pts.map(\.date))).sorted()
        return VStack(alignment: .leading, spacing: 8) {
            Chart {
                ForEach(pts) { p in
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
            .chartXScale(domain: start...end)
            .chartScrollableAxes(.horizontal)
            .chartXVisibleDomain(length: visible)
            .chartScrollPosition(x: $scrollX)
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
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisValueLabel(format: .dateTime.month(.defaultDigits).day(), centered: false)
                }
            }
            .frame(height: 260)
            .tapToSelect($selected, dates: dates, byDay: true)

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
    @State private var texts: [Date: String] = [:]

    private var days: [Date] {
        let cal = Calendar.current
        return (0..<21).map { cal.date(byAdding: .day, value: -$0, to: cal.startOfDay(for: Date()))! }
    }

    var body: some View {
        NavigationStack {
            List {
                Section(footer: Text("打开手表或「健康」App 的睡眠，看每天的「睡眠评分」填进来。填了 5 天以上就会按它们自动调整算法。" + (SleepScore.calibrationNote.isEmpty ? "" : "\n现在：" + SleepScore.calibrationNote))) {
                    ForEach(days, id: \.self) { d in
                        HStack {
                            Text(label(d))
                            Spacer()
                            if let m = mine.first(where: { Calendar.current.isDate($0.date, inSameDayAs: d) }) {
                                Text("阿波 \(Int(m.value))").font(.caption).foregroundStyle(.secondary)
                            }
                            TextField("苹果分", text: Binding(get: { texts[d] ?? "" }, set: { texts[d] = $0 }))
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 70)
                        }
                    }
                }
            }
            .navigationTitle("睡眠评分校准")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        for d in days {
                            let t = (texts[d] ?? "").trimmingCharacters(in: .whitespaces)
                            SleepScore.setApple(Int(t).flatMap { (0...100).contains($0) ? $0 : nil }, on: d)
                        }
                        dismiss()
                    }
                }
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
            .onAppear {
                for d in days { if let v = SleepScore.apple(on: d) { texts[d] = String(v) } }
            }
        }
    }

    private func label(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "M月d日 EEE"
        return f.string(from: d)
    }
}
