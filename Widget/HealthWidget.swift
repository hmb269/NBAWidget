import WidgetKit
import SwiftUI
import Charts
import AppIntents

// 健康小组件，小 / 中 / 大三种尺寸，样式照系统「睡眠评分」，每项一种颜色：
// 小号：五行，图标 + 数值
// 中号：左边睡眠圆环，右边体重 / 恢复心率变异性 / 步数 / 日出日落
// 大号：三层卡片——睡眠、体重趋势、三个小格
// 图标可以在 App 里换成自己的照片

// MARK: - 颜色（参考健康 App 各分类的颜色）

struct Theme {
    let top: Color
    let bottom: Color
    var gradient: LinearGradient { LinearGradient(colors: [top, bottom], startPoint: .topLeading, endPoint: .bottomTrailing) }
    var text: Color { top }

    static let sleep = Theme(top: Color(red: 0.42, green: 0.86, blue: 1.0), bottom: Color(red: 0.30, green: 0.45, blue: 0.98))
    static let weight = Theme(top: Color(red: 0.80, green: 0.55, blue: 1.0), bottom: Color(red: 0.55, green: 0.32, blue: 0.95))
    static let hrv = Theme(top: Color(red: 1.0, green: 0.45, blue: 0.55), bottom: Color(red: 0.95, green: 0.22, blue: 0.42))
    static let steps = Theme(top: Color(red: 1.0, green: 0.72, blue: 0.25), bottom: Color(red: 1.0, green: 0.45, blue: 0.18))
    static let sun = Theme(top: Color(red: 1.0, green: 0.86, blue: 0.30), bottom: Color(red: 1.0, green: 0.55, blue: 0.15))
}

enum HealthColor {
    static let deep = Color(red: 0.30, green: 0.36, blue: 0.95)
    static let core = Color(red: 0.25, green: 0.60, blue: 1.0)
    static let rem = Color(red: 0.42, green: 0.86, blue: 1.0)
    static let other = Color(red: 0.36, green: 0.62, blue: 0.95)
    static let more = Color(red: 0.25, green: 0.88, blue: 0.45)   // 上升 / 变多：绿色
    static let less = Color(red: 1.0, green: 0.30, blue: 0.30)    // 下降 / 变少：红色
}

// MARK: - 数据

struct HealthEntry: TimelineEntry {
    let date: Date
    var sleep: HealthService.Reading<HealthService.SleepData>
    var prevSleep: HealthService.Reading<HealthService.SleepData>
    var weightHistory: HealthService.Reading<[HealthService.WeightPoint]>
    var weight: HealthService.Reading<HealthService.WeightData>
    var hrv: HealthService.Reading<HealthService.HRVData>
    var steps: HealthService.Reading<Int>
    var icons: [IconSlot: UIImage] = [:]

    static var sample: HealthEntry {
        HealthEntry(
            date: Date(),
            sleep: .init(value: .init(asleep: 25200, deep: 3600, core: 15000, rem: 6600, awake: 600, other: 0,
                                      bedtime: Date().addingTimeInterval(-36000), wake: Date().addingTimeInterval(-10800))),
            prevSleep: .init(value: .init(asleep: 23400, deep: 3000, core: 14000, rem: 6400, awake: 600, other: 0, bedtime: nil, wake: nil)),
            weightHistory: .init(value: (0..<30).map { i in
                .init(date: Calendar.current.date(byAdding: .day, value: i - 29, to: Date())!,
                      kg: 66.2 - Double(i) * 0.03 + sin(Double(i) / 2.5) * 0.25)
            }),
            weight: .init(value: .init(kg: 65.25, date: Date(), previousKg: 65.52, previousDate: nil)),
            hrv: .init(value: .init(ms: 48, overnight: true, weekAverage: 45, previous: 44)),
            steps: .init(value: 6543, updated: Date())
        )
    }

    static func load() async -> HealthEntry {
        async let sleep = HealthService.load("sleep", keepFor: 18) { try await HealthService.lastNightSleep() }
        async let weight = HealthService.load("weight", keepFor: 72) { try await HealthService.latestWeight() }
        async let steps = HealthService.load("steps", keepFor: 12) { try await HealthService.todaySteps() }
        async let prevSleep = HealthService.load("sleepPrev", keepFor: 18) { try await HealthService.lastNightSleep(nightsAgo: 1) }
        async let history = HealthService.load("weightHistory", keepFor: 72) { try await HealthService.weightHistory(days: 30) }
        let s = await sleep
        let ps = await prevSleep
        let hrv = await HealthService.load("hrv", keepFor: 24) { try await HealthService.recentHRV(sleep: s.value, prevSleep: ps.value) }
        return HealthEntry(date: Date(), sleep: s, prevSleep: ps, weightHistory: await history,
                           weight: await weight, hrv: hrv, steps: await steps,
                           icons: IconStore.loadAllForWidget())
    }

    // 各项显示用的文字

    /// 比前一晚多睡（正）/ 少睡（负）多少秒
    var sleepDelta: TimeInterval? {
        guard let a = sleep.value?.asleep, let b = prevSleep.value?.asleep else { return nil }
        return a - b
    }
    var sleepDeltaText: String? {
        guard let d = sleepDelta, abs(d) >= 60 else { return nil }
        let m = Int(abs(d) / 60)
        return (d > 0 ? "+" : "-") + (m >= 60 ? "\(m / 60)时\(m % 60)分" : "\(m)分")
    }

    var sleepValue: String { sleep.value.map { HealthFormat.duration($0.asleep) } ?? "--" }
    var sleepFoot: String {
        if let n = sleep.note { return n }
        guard let d = sleep.value, let b = d.bedtime, let w = d.wake else { return " " }
        return HealthFormat.time(b) + " - " + HealthFormat.time(w)
    }

    var weightValue: String { weight.value.map { HealthFormat.kg($0.kg) } ?? "--" }
    var weightTrend: Double? {
        guard let w = weight.value, let p = w.previousKg else { return nil }
        return w.kg - p
    }
    var weightFoot: String {
        if let n = weight.note { return n }
        guard let w = weight.value else { return " " }
        let cal = Calendar.current
        if cal.isDateInToday(w.date) { return w.previousKg == nil ? "今天" : "今天 · 比前一次" }
        if cal.isDateInYesterday(w.date) { return "昨天记录" }
        let c = cal.dateComponents([.month, .day], from: w.date)
        return "\(c.month ?? 0)月\(c.day ?? 0)日记录"
    }

    var hrvValue: String { hrv.value.map { String(Int($0.ms.rounded())) } ?? "--" }
    var hrvDelta: Double? {
        guard let h = hrv.value, let p = h.previous else { return nil }
        return h.ms - p
    }

    /// 体重 / 恢复心率变异性：下降整行红色，上升整行绿色，持平用原来的颜色
    var weightColor: Color? { HealthEntry.trendColor(weightTrend, threshold: 0.005) }
    var hrvColor: Color? { HealthEntry.trendColor(hrvDelta, threshold: 0.5) }
    static func trendColor(_ d: Double?, threshold: Double) -> Color? {
        guard let d, abs(d) >= threshold else { return nil }
        return d > 0 ? HealthColor.more : HealthColor.less
    }

    var hrvFoot: String {
        if let n = hrv.note { return n }
        guard let h = hrv.value else { return " " }
        var t = h.overnight ? "昨晚平均" : "最近一次"
        if let p = h.previous { t += " · 前晚 \(Int(p.rounded()))" }
        else if let a = h.weekAverage { t += " · 7日 \(Int(a.rounded()))" }
        return t
    }

    var stepsValue: String {
        guard let s = steps.value, let t = steps.updated, Calendar.current.isDateInToday(t) else { return "--" }
        return s.formatted()
    }
    var stepsFoot: String {
        if let n = steps.note { return n }
        guard let t = steps.updated, Calendar.current.isDateInToday(t) else { return " " }
        return HealthFormat.time(t) + " 更新"
    }
}

struct HealthProvider: TimelineProvider {
    func placeholder(in context: Context) -> HealthEntry { .sample }

    func getSnapshot(in context: Context, completion: @escaping (HealthEntry) -> Void) {
        if context.isPreview { completion(.sample); return }
        Task { completion(await HealthEntry.load()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HealthEntry>) -> Void) {
        Task {
            let entry = await HealthEntry.load()
            let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date())!
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }
}

struct HealthWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "HealthAll", provider: HealthProvider()) { entry in
            HealthWidgetView(entry: entry)
        }
        .configurationDisplayName("健康")
        .description("睡眠时间、体重、恢复心率变异性、步数、日出日落；大号带体重趋势图")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled() // 自己画底色，避免系统把底色提亮
    }
}

// MARK: - 外框：底色画在内容层，和系统小组件一样黑

struct HealthWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: HealthEntry

    var body: some View {
        Group {
            switch family {
            case .systemSmall: SmallHealthView(entry: entry)
            case .systemMedium: MediumHealthView(entry: entry)
            default: LargeHealthView(entry: entry)
            }
        }
        .padding(family == .systemLarge ? 12 : 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(widgetBackground)
        .containerBackground(widgetBackground, for: .widget)
    }
}

private var sunText: String {
    SunTimes.times().map { HealthFormat.time($0.sunrise) + " / " + HealthFormat.time($0.sunset) } ?? "--"
}

// MARK: - 小号：五行，图标 + 数值，字号统一

struct SmallHealthView: View {
    let entry: HealthEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row(.sleep, .sleep, entry.sleepValue, plainIcon: true, trend: entry.sleepDelta.map { $0 / 60 }, threshold: 1)
            Spacer(minLength: 0)
            row(.weight, .weight, entry.weightValue, unit: entry.weight.value == nil ? "" : "公斤",
                trend: entry.weightTrend, threshold: 0.005, color: entry.weightColor)
            Spacer(minLength: 0)
            row(.hrv, .hrv, entry.hrvValue, unit: entry.hrv.value == nil ? "" : "毫秒",
                trend: entry.hrvDelta, threshold: 0.5, color: entry.hrvColor)
            Spacer(minLength: 0)
            row(.steps, .steps, entry.stepsValue, unit: entry.stepsValue == "--" ? "" : "步")
            Spacer(minLength: 0)
            row(.sun, .sun, sunText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ slot: IconSlot, _ theme: Theme, _ value: String, plainIcon: Bool = false, unit: String = "",
                     trend: Double? = nil, threshold: Double = 0, color: Color? = nil) -> some View {
        HStack(spacing: 6) {
            IconBadge(slot: slot, theme: theme, size: 22, custom: plainIcon ? nil : entry.icons[slot])
            ValueText(value, size: 15, color: color)
            if !unit.isEmpty { UnitText(unit, theme: theme, color: color) }
            if let trend { TrendView(delta: trend, threshold: threshold, compact: true) }
        }
        .lineLimit(1)
    }
}

// MARK: - 中号：左边睡眠，右边四行表格对齐，数值字号统一

struct MediumHealthView: View {
    let entry: HealthEntry

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                SleepRing(sleep: entry.sleep.value, prevAsleep: entry.prevSleep.value?.asleep, size: 52, photo: entry.icons[.sleep])
                    .padding(.bottom, 6)
                HStack(spacing: 4) {
                    CaptionText("睡眠时间", theme: .sleep, size: 13)
                    SleepDeltaText(entry: entry)
                }
                ValueText(entry.sleepValue, size: 18)
                FootText(entry.sleepFoot)
            }
            .frame(width: 104, alignment: .leading)

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 12) {
                gridRow(.weight, .weight, "体重", color: entry.weightColor) {
                    ValueText(entry.weightValue, size: 15, color: entry.weightColor, shrink: false)
                    if entry.weight.value != nil { UnitText("公斤", theme: .weight, color: entry.weightColor) }
                    if let t = entry.weightTrend { TrendView(delta: t, threshold: 0.005, compact: true) }
                }
                gridRow(.hrv, .hrv, "恢复心率变异性", color: entry.hrvColor) {
                    ValueText(entry.hrvValue, size: 15, color: entry.hrvColor, shrink: false)
                    if entry.hrv.value != nil { UnitText("毫秒", theme: .hrv, color: entry.hrvColor) }
                    if let d = entry.hrvDelta { TrendView(delta: d, threshold: 0.5, compact: true) }
                }
                gridRow(.steps, .steps, "今日步数") {
                    ValueText(entry.stepsValue, size: 15, shrink: false)
                    if entry.stepsValue != "--" { UnitText("步", theme: .steps) }
                }
                gridRow(.sun, .sun, "日出日落") {
                    ValueText(sunText, size: 15, shrink: false)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func gridRow<V: View>(_ slot: IconSlot, _ theme: Theme, _ title: String, color: Color? = nil,
                                  @ViewBuilder value: () -> V) -> some View {
        GridRow(alignment: .center) {
            HStack(spacing: 5) {
                IconBadge(slot: slot, theme: theme, size: 22, custom: entry.icons[slot])
                CaptionText(title, theme: theme, size: 12, color: color)
                    .lineLimit(1)
                    .fixedSize()
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                value()
            }
            .lineLimit(1)
        }
    }
}

// MARK: - 大号：三层卡片
//  ┌ 睡眠：圆环 | 时长 + 比前晚 + 入睡醒来 | 各阶段时长 ┐
//  ├ 体重：图标 + 数值 + 升降 | 7天/30天   ＋ 趋势图    ┤
//  └ 恢复心率变异性 | 今日步数 | 日出日落               ┘

struct LargeHealthView: View {
    let entry: HealthEntry

    var body: some View {
        VStack(spacing: 10) {
            sleepCard
            weightCard
                .frame(maxHeight: .infinity)
            HStack(spacing: 6) {
                hrvCard
                stepsCard
                sunCard
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // 睡眠
    private var sleepCard: some View {
        HStack(alignment: .center, spacing: 12) {
            SleepRing(sleep: entry.sleep.value, prevAsleep: entry.prevSleep.value?.asleep, size: 56, photo: entry.icons[.sleep])
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    IconBadge(slot: .sleep, theme: .sleep, size: 18)
                    CaptionText("睡眠时间", theme: .sleep, size: 13)
                        .fixedSize()
                    SleepDeltaText(entry: entry)
                }
                ValueText(entry.sleepValue, size: 22)
                FootText(entry.sleepFoot)
            }
            Spacer(minLength: 4)
            if let s = entry.sleep.value {
                VStack(alignment: .leading, spacing: 3) {
                    stage("深睡", s.deep, HealthColor.deep)
                    stage("核心", s.core, HealthColor.core)
                    stage("快速眼动", s.rem, HealthColor.rem)
                }
            }
        }
        .card()
    }

    private func stage(_ name: String, _ t: TimeInterval, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(name).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(HealthFormat.clock(t))
                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
        }
        .frame(width: 104)
    }

    // 体重 + 趋势图
    private var weightCard: some View {
        let days = WeightRange.current
        let pts = entry.weightPoints(days: days)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                IconBadge(slot: .weight, theme: .weight, size: 30, custom: entry.icons[.weight])
                VStack(alignment: .leading, spacing: 0) {
                    CaptionText("体重", theme: .weight, size: 13, color: entry.weightColor)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        ValueText(entry.weightValue, size: 22, color: entry.weightColor, shrink: false)
                        if entry.weight.value != nil { UnitText("公斤", theme: .weight, color: entry.weightColor) }
                        if let t = entry.weightTrend { TrendView(delta: t, threshold: 0.005, compact: false) }
                    }
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 3) {
                    RangeChip(days: days)
                    if pts.count > 1, let f = pts.first, let l = pts.last {
                        HStack(spacing: 3) {
                            Text("近\(days)天").font(.system(size: 11)).foregroundStyle(.secondary)
                            TrendView(delta: l.kg - f.kg, threshold: 0.005, compact: false, small: true)
                        }
                    }
                }
            }
            WeightChart(points: pts, days: days, note: entry.weightHistory.note)
        }
        .card()
    }

    // 下面三格
    private var hrvCard: some View {
        tile(.hrv, .hrv, "恢复心率变异性", titleColor: entry.hrvColor) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                ValueText(entry.hrvValue, size: 20, color: entry.hrvColor)
                if entry.hrv.value != nil { UnitText("毫秒", theme: .hrv, color: entry.hrvColor) }
            }
            HStack(spacing: 3) {
                if let d = entry.hrvDelta {
                    TrendView(delta: d, threshold: 0.5, text: String(Int(abs(d).rounded())), compact: false, small: true)
                }
                FootText(entry.hrv.value?.previous.map { "前晚 \(Int($0.rounded()))" } ?? entry.hrvFoot)
            }
        }
    }

    private var stepsCard: some View {
        tile(.steps, .steps, "今日步数") {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                ValueText(entry.stepsValue, size: 20)
                if entry.stepsValue != "--" { UnitText("步", theme: .steps) }
            }
            FootText(entry.stepsFoot)
        }
    }

    private var sunCard: some View {
        let t = SunTimes.times()
        return tile(.sun, .sun, "日出日落") {
            sunLine("sunrise.fill", t.map { HealthFormat.time($0.sunrise) } ?? "--")
            sunLine("sunset.fill", t.map { HealthFormat.time($0.sunset) } ?? "--")
        }
    }

    private func sunLine(_ icon: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 12))
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded).monospacedDigit())
        }
    }

    private func tile<C: View>(_ slot: IconSlot, _ theme: Theme, _ title: String, titleColor: Color? = nil,
                               @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                IconBadge(slot: slot, theme: theme, size: 18, custom: entry.icons[slot])
                CaptionText(title, theme: theme, size: 11, color: titleColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card(padding: 10)
    }
}

extension View {
    /// 大号里的分组：不画底框，直接融在底色上，只留一点内边距
    func card(padding: CGFloat = 12) -> some View {
        self
            .padding(.horizontal, padding / 2)
            .padding(.vertical, padding / 3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 体重趋势图（点「7天/30天」切换；点图上某一天显示那天的体重）

enum WeightRange {
    private static let key = "weightRange"
    static var current: Int { UserDefaults.standard.integer(forKey: key) == 7 ? 7 : 30 }
    static func toggle() {
        UserDefaults.standard.set(current == 7 ? 30 : 7, forKey: key)
        WeightSelection.clear()
    }
}

/// 图上选中的那一天（再点一次同一天取消）
enum WeightSelection {
    private static let key = "weightSelectedDay"
    static var day: Date? {
        let t = UserDefaults.standard.double(forKey: key)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }
    static func toggle(_ day: Date) {
        if let d = self.day, Calendar.current.isDate(d, inSameDayAs: day) { clear() }
        else { UserDefaults.standard.set(day.timeIntervalSince1970, forKey: key) }
    }
    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}

struct WeightRangeIntent: AppIntent {
    static var title: LocalizedStringResource = "切换体重范围"
    static var isDiscoverable: Bool = false
    init() {}
    func perform() async throws -> some IntentResult {
        WeightRange.toggle()
        return .result()
    }
}

struct SelectWeightDayIntent: AppIntent {
    static var title: LocalizedStringResource = "查看某天体重"
    static var isDiscoverable: Bool = false
    @Parameter(title: "日期") var time: Double
    init() {}
    init(day: Date) { self.time = day.timeIntervalSince1970 }
    func perform() async throws -> some IntentResult {
        WeightSelection.toggle(Date(timeIntervalSince1970: time))
        return .result()
    }
}

struct RangeChip: View {
    let days: Int
    var body: some View {
        Button(intent: WeightRangeIntent()) {
            HStack(spacing: 0) {
                seg("7天", on: days == 7)
                seg("30天", on: days == 30)
            }
            .padding(2)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    private func seg(_ t: String, on: Bool) -> some View {
        Text(t)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(on ? Color.white : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(on ? AnyShapeStyle(Theme.weight.gradient) : AnyShapeStyle(Color.clear)))
    }
}

extension HealthEntry {
    func weightPoints(days: Int) -> [HealthService.WeightPoint] {
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -(days - 1), to: cal.startOfDay(for: Date()))!
        return (weightHistory.value ?? []).filter { $0.date >= start }
    }
}

struct WeightChart: View {
    let points: [HealthService.WeightPoint]
    let days: Int
    let note: String?

    var body: some View {
        let cal = Calendar.current
        let pts = points
        // 横轴只覆盖有记录的那几天，记录不满 7 / 30 天时也铺满整个宽度
        let start = cal.startOfDay(for: pts.first?.date ?? Date())
        let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: pts.last?.date ?? Date()))!
        let span = max(1, cal.dateComponents([.day], from: start, to: end).day ?? 1)
        let lo = (pts.map(\.kg).min() ?? 0) - 0.3
        let hi = (pts.map(\.kg).max() ?? 1) + 0.3
        let picked: HealthService.WeightPoint? = WeightSelection.day.flatMap { sel in
            pts.min { abs($0.date.timeIntervalSince(sel)) < abs($1.date.timeIntervalSince(sel)) }
        }
        let mid = { (d: Date) in d.addingTimeInterval(12 * 3600) } // 点画在当天中间，和点击格子对齐

        if pts.count >= 2 {
            Chart {
                ForEach(Array(pts.enumerated()), id: \.offset) { _, p in
                    AreaMark(x: .value("日期", mid(p.date)),
                             yStart: .value("下限", lo),
                             yEnd: .value("体重", p.kg))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(LinearGradient(colors: [Theme.weight.top.opacity(0.32), Theme.weight.top.opacity(0.0)],
                                                        startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("日期", mid(p.date)), y: .value("体重", p.kg))
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
                        .foregroundStyle(Theme.weight.gradient)
                    if span <= 10 { // 天数少时把每天的点画出来
                        PointMark(x: .value("日期", mid(p.date)), y: .value("体重", p.kg))
                            .symbolSize(20)
                            .foregroundStyle(Theme.weight.top)
                    }
                }
                if let p = picked {
                    RuleMark(x: .value("日期", mid(p.date)))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                    PointMark(x: .value("日期", mid(p.date)), y: .value("体重", p.kg))
                        .symbolSize(60)
                        .foregroundStyle(.white)
                        .annotation(position: .top, spacing: 4,
                                    overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                            VStack(spacing: 0) {
                                Text(String(format: "%.2f 公斤", p.kg))
                                    .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                                    .foregroundStyle(Color.primary)
                                Text(dayLabel(p.date))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.28)))
                        }
                } else if let l = pts.last {
                    PointMark(x: .value("日期", mid(l.date)), y: .value("体重", l.kg))
                        .symbolSize(40)
                        .foregroundStyle(Theme.weight.top)
                }
            }
            .chartXScale(domain: start...end)
            .chartYScale(domain: lo...hi)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                    AxisValueLabel {
                        if let d = v.as(Double.self) {
                            Text(String(format: "%.1f", d)).font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            // 每天一个透明按钮，点哪天就显示哪天的体重
            .chartOverlay { proxy in
                GeometryReader { geo in
                    if let plot = proxy.plotFrame {
                        let rect = geo[plot]
                        HStack(spacing: 0) {
                            ForEach(0..<span, id: \.self) { i in
                                Button(intent: SelectWeightDayIntent(day: cal.date(byAdding: .day, value: i, to: start)!)) {
                                    Color.clear.contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                    }
                }
            }
        } else {
            FootText(note ?? "近\(days)天体重记录不足两天")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func dayLabel(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.month, .day, .weekday], from: d)
        let w = ["日", "一", "二", "三", "四", "五", "六"][(c.weekday ?? 1) - 1]
        return "\(c.month ?? 0)月\(c.day ?? 0)日 周\(w)"
    }
}

// MARK: - 零件

/// 图标：默认是渐变圆底 + 白色图案；在 App 里换了照片就显示照片
struct IconBadge: View {
    let slot: IconSlot
    let theme: Theme
    let size: CGFloat
    var custom: UIImage? = nil

    var body: some View {
        if let custom {
            Image(uiImage: custom)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else {
            ZStack {
                Circle().fill(theme.gradient)
                Image(systemName: slot.symbol)
                    .font(.system(size: size * 0.48, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
        }
    }
}

struct CaptionText: View {
    let text: String
    let theme: Theme
    var size: CGFloat = 15
    var color: Color? = nil
    init(_ text: String, theme: Theme, size: CGFloat = 15, color: Color? = nil) {
        self.text = text; self.theme = theme; self.size = size; self.color = color
    }
    var body: some View {
        Text(text).font(.system(size: size, weight: .semibold)).foregroundStyle(color ?? theme.text)
    }
}

struct ValueText: View {
    let text: String
    let size: CGFloat
    var color: Color? = nil
    var shrink: Bool = true
    init(_ text: String, size: CGFloat, color: Color? = nil, shrink: Bool = true) {
        self.text = text; self.size = size; self.color = color; self.shrink = shrink
    }
    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .bold, design: .rounded).monospacedDigit())
            .foregroundStyle(text == "--" ? Color.secondary : (color ?? Color.primary))
            .lineLimit(1)
            .minimumScaleFactor(shrink ? 0.7 : 1)
    }
}

struct UnitText: View {
    let text: String
    let theme: Theme
    var color: Color? = nil
    init(_ text: String, theme: Theme, color: Color? = nil) { self.text = text; self.theme = theme; self.color = color }
    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle((color ?? theme.text).opacity(0.85)).fixedSize()
    }
}

struct FootText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
    }
}

/// 比前晚多睡绿色、少睡红色，如「+32分」
struct SleepDeltaText: View {
    let entry: HealthEntry
    var body: some View {
        if let t = entry.sleepDeltaText, let d = entry.sleepDelta {
            Text(t)
                .font(.system(size: 11, weight: .heavy).monospacedDigit())
                .foregroundStyle(d > 0 ? HealthColor.more : HealthColor.less)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

/// 升降箭头：上升绿色 ↑，下降红色 ↓
struct TrendView: View {
    let delta: Double
    var threshold: Double = 0.005
    var text: String? = nil
    let compact: Bool
    var small: Bool = false

    var body: some View {
        let size: CGFloat = compact ? 12 : (small ? 11 : 14)
        if abs(delta) < threshold {
            Image(systemName: "minus")
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 1) {
                Image(systemName: delta > 0 ? "arrow.up" : "arrow.down")
                if !compact { Text(text ?? String(format: "%.2f", abs(delta))) }
            }
            .font(.system(size: size, weight: .heavy, design: .rounded).monospacedDigit())
            .foregroundStyle(delta > 0 ? HealthColor.more : HealthColor.less)
            .fixedSize()
        }
    }
}

/// 睡眠圆环：深睡 / 核心 / 快速眼动三段，中间是小时数。
/// 和前一晚比：多睡的那部分画成绿色；少睡就把缺的那段画成红色。
struct SleepRing: View {
    let sleep: HealthService.SleepData?
    var prevAsleep: TimeInterval? = nil
    var size: CGFloat = 58
    var photo: UIImage? = nil   // 「睡眠」换了照片就放在圆环中间

    /// (起点, 终点, 颜色)，0~1 表示一整圈
    private var arcs: [(Double, Double, Color)] {
        guard let s = sleep, s.asleep > 0 else { return [] }
        var stages: [(Double, Color)] = []
        if s.deep > 0 { stages.append((s.deep, HealthColor.deep)) }
        if s.core > 0 { stages.append((s.core, HealthColor.core)) }
        if s.rem > 0 { stages.append((s.rem, HealthColor.rem)) }
        if s.other > 0 { stages.append((s.other, HealthColor.other)) }
        let stageTotal = stages.reduce(0) { $0 + $1.0 }
        guard stageTotal > 0 else { return [] }

        let today = s.asleep
        let prev = (prevAsleep ?? 0) > 0 ? prevAsleep! : today
        let full = max(today, prev)
        let base = min(today, prev) / full

        var out: [(Double, Double, Color)] = []
        var pos = 0.0
        for st in stages {
            let len = st.0 / stageTotal * base
            out.append((pos, pos + len, st.1))
            pos += len
        }
        if today > prev + 60 { out.append((base, 1, HealthColor.more)) }
        else if prev > today + 60 { out.append((base, 1, HealthColor.less)) }
        return out
    }

    var body: some View {
        let list = arcs
        let gap = list.count > 1 ? 0.03 : 0
        let lw = size * 0.155
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.2), lineWidth: lw)
            ForEach(Array(list.enumerated()), id: \.offset) { _, a in
                Circle()
                    .trim(from: a.0 + gap / 2, to: max(a.0 + gap / 2, a.1 - gap / 2))
                    .stroke(a.2, style: StrokeStyle(lineWidth: lw, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            if let photo {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size - lw * 1.4, height: size - lw * 1.4)
                    .clipShape(Circle())
                    .overlay(Circle().fill(Color.black.opacity(0.32)))
            }
            if let s = sleep {
                Text(String(format: "%.1f", s.asleep / 3600))
                    .font(.system(size: size * 0.33, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(photo == nil ? Color.primary : Color.white)
                    .shadow(color: .black.opacity(photo == nil ? 0 : 0.7), radius: 2)
            } else if photo == nil {
                Image(systemName: IconSlot.sleep.symbol).font(.system(size: size * 0.33)).foregroundStyle(Theme.sleep.text)
            }
        }
        .frame(width: size, height: size)
        .padding(lw / 2)
    }
}
