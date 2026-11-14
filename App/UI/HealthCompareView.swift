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

    /// - usualBed：平时的入睡时刻（前 14 晚的中位数，bedMinutes 的单位）
    static func score(_ s: HealthService.SleepData, usualBed: Double? = nil) -> Double? {
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
        return (dur + bed + inter).rounded()
    }

    /// 一串按日期排好的夜晚，每晚用前 14 晚的中位入睡时刻来评分
    static func scores(_ nights: [(Date, HealthService.SleepData)]) -> [DayValue] {
        var out: [DayValue] = []
        for (i, n) in nights.enumerated() {
            let prev = nights[max(0, i - 14)..<i].compactMap { bedMinutes($0.1.bedtime) }.sorted()
            let usual: Double? = prev.count >= 3 ? prev[prev.count / 2] : nil
            if let v = score(n.1, usualBed: usual) { out.append(DayValue(date: n.0, value: v)) }
        }
        return out
    }
}

struct HealthCompareView: View {
    @State private var days = 30
    @State private var shown: Set<CompareMetric> = HealthCompareView.savedShown
    @State private var order: [CompareMetric] = HealthCompareView.savedOrder
    @State private var arranging = false        // 调整顺序
    @State private var overlay = false           // 叠在一张图上
    @State private var data: [CompareMetric: [DayValue]] = [:]
    @State private var loading = false
    @State private var selected: Date?

    private var start: Date {
        Calendar.current.date(byAdding: .day, value: -(days - 1), to: Calendar.current.startOfDay(for: Date()))!
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

                Text("点图上任意一天，所有图都会标出那一天，上面显示当天各项数值。「叠在一起」把每项按自己的最低到最高缩放到同一高度，只看涨跌趋势。BMI 绿色区域是健康范围 18.5～23.9（中国成人标准）；静息心率正常 60～100。血糖用你自己的餐后 2 小时记录，一天测了几次就取平均。睡眠评分仿照苹果手表的评分（满分 100）：时长 50（8 小时以上满分）、入睡时间 30（和平时几点睡差 30 分钟以内满分）、睡眠中断 20（夜里清醒 10 分钟以内满分）。苹果的具体算法没公开，和手表上的分可能差几分。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(16)
            .padding(.bottom, 100)
        }
        .background(AppBackground())
        .navigationTitle("趋势对比")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task(id: days) { await load() }
        .onChange(of: shown) { _, _ in persist() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { arranging = true } label: { Image(systemName: "arrow.up.arrow.down") }
            }
        }
        .sheet(isPresented: $arranging) { arrangeSheet }
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
        let out = await Self.loadData(days: days)
        withAnimation { data = out }
    }

    /// 读最近 n 天每天的各项数据（趋势对比和关系分析共用）
    /// 10 分钟内重复打开不再重新读（读 90 晚睡眠要查很多次健康数据）
    @MainActor private static var memo: [Int: (Date, [CompareMetric: [DayValue]])] = [:]

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
        out[.sleep] = SleepScore.scores(all).filter { $0.date >= from }
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
