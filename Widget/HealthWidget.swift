import WidgetKit
import SwiftUI
import Charts
import AppIntents

// 健康小组件，小 / 中 / 大三种尺寸，样式照系统「睡眠评分」，每项一种颜色：
// 小号：五行，图标 + 数值
// 中号：左边睡眠圆环，右边体重 / 心率变异性 / 步数 / 日出日落
// 大号：睡眠 | 体重，心率变异性 | 步数，最下面日出日落弧线

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

enum Icon {
    static let sleep = "bed.double.fill"
    static let weight = "figure"
    static let hrv = "waveform.path.ecg"
    static let steps = "figure.walk"
    static let sun = "sun.horizon.fill"
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
                           weight: await weight, hrv: hrv, steps: await steps)
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
        .padding(.horizontal, family == .systemSmall ? 14 : 18)
        .padding(.vertical, family == .systemSmall ? 14 : 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(widgetBackground)
        .containerBackground(widgetBackground, for: .widget)
    }
}

// MARK: - 小号

struct SmallHealthView: View {
    let entry: HealthEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row(Icon.sleep, .sleep, entry.sleepValue, trend: entry.sleepDelta.map { $0 / 60 }, threshold: 1)
            Spacer(minLength: 0)
            row(Icon.weight, .weight, entry.weightValue, trend: entry.weightTrend, threshold: 0.005, color: entry.weightColor)
            Spacer(minLength: 0)
            row(Icon.hrv, .hrv, entry.hrvValue, unit: entry.hrv.value == nil ? "" : "毫秒", trend: entry.hrvDelta, threshold: 0.5, color: entry.hrvColor)
            Spacer(minLength: 0)
            row(Icon.steps, .steps, entry.stepsValue, unit: entry.stepsValue == "--" ? "" : "步")
            Spacer(minLength: 0)
            row(Icon.sun, .sun, SunTimes.times().map { HealthFormat.time($0.sunrise) + " / " + HealthFormat.time($0.sunset) } ?? "--")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ icon: String, _ theme: Theme, _ value: String, unit: String = "", trend: Double? = nil, threshold: Double = 0, color: Color? = nil) -> some View {
        HStack(spacing: 6) {
            IconBadge(symbol: icon, theme: theme, size: 22)
            ValueText(value, size: 15, color: color)
            if !unit.isEmpty { UnitText(unit, theme: theme, color: color) }
            if let trend { TrendView(delta: trend, threshold: threshold, compact: true) }
        }
    }
}

// MARK: - 中号

struct MediumHealthView: View {
    let entry: HealthEntry

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                SleepRing(sleep: entry.sleep.value, prevAsleep: entry.prevSleep.value?.asleep, size: 52)
                    .padding(.bottom, 6)
                HStack(spacing: 4) {
                    CaptionText("睡眠时间", theme: .sleep)
                    SleepDeltaText(entry: entry)
                }
                ValueText(entry.sleepValue, size: 20)
                FootText(entry.sleepFoot)
            }
            .frame(width: 112, alignment: .leading)

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 13) {
                gridRow(Icon.weight, .weight, "体重", color: entry.weightColor) {
                    ValueText(entry.weightValue, size: 16, color: entry.weightColor)
                    if entry.weight.value != nil { UnitText("公斤", theme: .weight, color: entry.weightColor) }
                    if let t = entry.weightTrend { TrendView(delta: t, threshold: 0.005, compact: true) }
                }
                gridRow(Icon.hrv, .hrv, "恢复心率变异性", color: entry.hrvColor) {
                    ValueText(entry.hrvValue, size: 16, color: entry.hrvColor)
                    if entry.hrv.value != nil { UnitText("毫秒", theme: .hrv, color: entry.hrvColor) }
                    if let d = entry.hrvDelta { TrendView(delta: d, threshold: 0.5, compact: true) }
                }
                gridRow(Icon.steps, .steps, "今日步数") {
                    ValueText(entry.stepsValue, size: 16)
                }
                gridRow(Icon.sun, .sun, "日出日落") {
                    ValueText(SunTimes.times().map { HealthFormat.time($0.sunrise) + " / " + HealthFormat.time($0.sunset) } ?? "--", size: 16)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func gridRow<V: View>(_ icon: String, _ theme: Theme, _ title: String, color: Color? = nil,
                                  @ViewBuilder value: () -> V) -> some View {
        GridRow(alignment: .center) {
            HStack(spacing: 6) {
                IconBadge(symbol: icon, theme: theme, size: 22)
                CaptionText(title, theme: theme, size: 13, color: color)
                    .lineLimit(1)
                    .fixedSize()
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                value()
            }
            .lineLimit(1)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 大号

struct LargeHealthView: View {
    let entry: HealthEntry

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    SleepRing(sleep: entry.sleep.value, prevAsleep: entry.prevSleep.value?.asleep, size: 50)
                        .padding(.bottom, 5)
                    HStack(spacing: 4) {
                        CaptionText("睡眠时间", theme: .sleep)
                        SleepDeltaText(entry: entry)
                    }
                    ValueText(entry.sleepValue, size: 22)
                    FootText(entry.sleepFoot)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 1) {
                    IconBadge(symbol: Icon.weight, theme: .weight, size: 54)
                        .padding(.bottom, 5)
                    CaptionText("体重", theme: .weight, color: entry.weightColor)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        ValueText(entry.weightValue, size: 22, color: entry.weightColor)
                        if entry.weight.value != nil { UnitText("公斤", theme: .weight, color: entry.weightColor) }
                        if let t = entry.weightTrend { TrendView(delta: t, threshold: 0.005, compact: false) }
                    }
                    FootText(entry.weightFoot)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            WeightChart(points: entry.weightHistory.value ?? [], note: entry.weightHistory.note)
                .frame(maxHeight: .infinity)
                .padding(.vertical, 8)

            Divider().overlay(Color.secondary.opacity(0.2))

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        IconBadge(symbol: Icon.hrv, theme: .hrv, size: 20)
                        CaptionText("恢复心率变异性", theme: .hrv, size: 14, color: entry.hrvColor).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        ValueText(entry.hrvValue, size: 20, color: entry.hrvColor)
                        if entry.hrv.value != nil { UnitText("毫秒", theme: .hrv, color: entry.hrvColor) }
                        if let d = entry.hrvDelta { TrendView(delta: d, threshold: 0.5, text: String(Int(abs(d).rounded())), compact: false) }
                    }
                    FootText(entry.hrvFoot)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        IconBadge(symbol: Icon.steps, theme: .steps, size: 20)
                        CaptionText("今日步数", theme: .steps, size: 14)
                    }
                    ValueText(entry.stepsValue, size: 20)
                    FootText(entry.stepsFoot)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 8)

            Divider().overlay(Color.secondary.opacity(0.2))

            SunRow()
                .padding(.top, 8)
        }
    }
}

// MARK: - 体重趋势图（点右上角切换 7 天 / 30 天）

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

struct WeightChart: View {
    let points: [HealthService.WeightPoint]
    let note: String?

    var body: some View {
        let days = WeightRange.current
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -(days - 1), to: today)!
        let end = cal.date(byAdding: .day, value: 1, to: today)!
        let pts = points.filter { $0.date >= start }
        let lo = (pts.map(\.kg).min() ?? 0) - 0.3
        let hi = (pts.map(\.kg).max() ?? 1) + 0.3
        // 选中的那天：有记录就用当天，没有就找最近的一天
        let picked: HealthService.WeightPoint? = WeightSelection.day.flatMap { sel in
            pts.min { abs($0.date.timeIntervalSince(sel)) < abs($1.date.timeIntervalSince(sel)) }
        }
        let mid = { (d: Date) in d.addingTimeInterval(12 * 3600) } // 点画在当天中间，和点击格子对齐

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                CaptionText("体重趋势", theme: .weight, size: 13)
                if pts.count > 1, let f = pts.first, let l = pts.last {
                    FootText("近\(days)天")
                    TrendView(delta: l.kg - f.kg, threshold: 0.005, compact: false)
                }
                Spacer(minLength: 0)
                Button(intent: WeightRangeIntent()) {
                    Text(days == 7 ? "7天" : "30天")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Theme.weight.text)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Theme.weight.top.opacity(0.18)))
                }
                .buttonStyle(.plain)
            }

            if pts.count >= 2 {
                Chart {
                    ForEach(Array(pts.enumerated()), id: \.offset) { _, p in
                        AreaMark(x: .value("日期", mid(p.date)),
                                 yStart: .value("下限", lo),
                                 yEnd: .value("体重", p.kg))
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(LinearGradient(colors: [Theme.weight.top.opacity(0.35), Theme.weight.top.opacity(0.02)],
                                                            startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("日期", mid(p.date)), y: .value("体重", p.kg))
                            .interpolationMethod(.catmullRom)
                            .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
                            .foregroundStyle(Theme.weight.gradient)
                        if days == 7 {
                            PointMark(x: .value("日期", mid(p.date)), y: .value("体重", p.kg))
                                .symbolSize(22)
                                .foregroundStyle(Theme.weight.top)
                        }
                    }
                    if let p = picked {
                        RuleMark(x: .value("日期", mid(p.date)))
                            .foregroundStyle(Color.secondary.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                        PointMark(x: .value("日期", mid(p.date)), y: .value("体重", p.kg))
                            .symbolSize(70)
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
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.25)))
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
                                ForEach(0..<days, id: \.self) { i in
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
                Spacer(minLength: 0)
                FootText(note ?? "近\(days)天体重记录不足两天")
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            }
        }
    }

    private func dayLabel(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.month, .day, .weekday], from: d)
        let w = ["日", "一", "二", "三", "四", "五", "六"][(c.weekday ?? 1) - 1]
        return "\(c.month ?? 0)月\(c.day ?? 0)日 周\(w)"
    }
}

// MARK: - 零件

/// 渐变圆底 + 白色图标
struct IconBadge: View {
    let symbol: String
    let theme: Theme
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(theme.gradient)
            Image(systemName: symbol)
                .font(.system(size: size * 0.48, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
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
    init(_ text: String, size: CGFloat, color: Color? = nil) { self.text = text; self.size = size; self.color = color }
    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .bold, design: .rounded).monospacedDigit())
            .foregroundStyle(text == "--" ? Color.secondary : (color ?? Color.primary))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }
}

struct UnitText: View {
    let text: String
    let theme: Theme
    var color: Color? = nil
    init(_ text: String, theme: Theme, color: Color? = nil) { self.text = text; self.theme = theme; self.color = color }
    var body: some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle((color ?? theme.text).opacity(0.85)).fixedSize()
    }
}

struct FootText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
    }
}

/// 比前晚多睡绿色、少睡红色，如「+32分」
struct SleepDeltaText: View {
    let entry: HealthEntry
    var body: some View {
        if let t = entry.sleepDeltaText, let d = entry.sleepDelta {
            Text(t)
                .font(.caption.weight(.heavy).monospacedDigit())
                .foregroundStyle(d > 0 ? HealthColor.more : HealthColor.less)
                .lineLimit(1)
        }
    }
}

/// 升降箭头：上升绿色 ↑，下降红色 ↓（体重、恢复心率变异性、睡眠都一样）
struct TrendView: View {
    let delta: Double
    var threshold: Double = 0.005
    var text: String? = nil
    let compact: Bool

    var body: some View {
        if abs(delta) < threshold {
            Image(systemName: "minus")
                .font((compact ? Font.caption2 : .caption).weight(.bold))
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 1) {
                Image(systemName: delta > 0 ? "arrow.up" : "arrow.down")
                if !compact { Text(text ?? String(format: "%.2f", abs(delta))) }
            }
            .font((compact ? Font.caption : .subheadline).weight(.heavy).monospacedDigit())
            .foregroundStyle(delta > 0 ? HealthColor.more : HealthColor.less)
        }
    }
}

/// 睡眠圆环：深睡 / 核心 / 快速眼动三段，中间是小时数。
/// 和前一晚比：多睡的那部分画成绿色；少睡就把缺的那段画成红色。
struct SleepRing: View {
    let sleep: HealthService.SleepData?
    var prevAsleep: TimeInterval? = nil
    var size: CGFloat = 58

    /// (起点, 终点, 颜色)，0~1 表示一整圈
    private var arcs: [(Double, Double, Color)] {
        guard let s = sleep, s.asleep > 0 else { return [] }
        var stages: [(Double, Color)] = []
        if s.deep > 0 { stages.append((s.deep, HealthColor.deep)) }
        if s.core > 0 { stages.append((s.core, HealthColor.core)) }
        if s.rem > 0 { stages.append((s.rem, HealthColor.rem)) }
        if s.other > 0 { stages.append((s.other, HealthColor.other)) }
        let stageTotal = stages.reduce(0) { $0 + $1.0 }

        let today = s.asleep
        let prev = (prevAsleep ?? 0) > 0 ? prevAsleep! : today
        let full = max(today, prev)          // 一整圈 = 两晚里较长的那晚
        let base = min(today, prev) / full   // 两晚都有的部分，按阶段上色

        var out: [(Double, Double, Color)] = []
        var pos = 0.0
        for st in stages {
            let len = st.0 / stageTotal * base
            out.append((pos, pos + len, st.1))
            pos += len
        }
        if today > prev + 60 { out.append((base, 1, HealthColor.more)) }       // 多睡：绿色
        else if prev > today + 60 { out.append((base, 1, HealthColor.less)) }  // 少睡：红色
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
            if let s = sleep {
                Text(String(format: "%.1f", s.asleep / 3600))
                    .font(.system(size: size * 0.33, weight: .bold, design: .rounded).monospacedDigit())
            } else {
                Image(systemName: Icon.sleep).font(.system(size: size * 0.33)).foregroundStyle(Theme.sleep.text)
            }
        }
        .frame(width: size, height: size)
        .padding(lw / 2)
    }
}

/// 日出日落：左边日出、右边日落，中间一道弧线，太阳在当前位置
struct SunRow: View {
    var body: some View {
        let t = SunTimes.times()
        HStack(alignment: .bottom, spacing: 10) {
            sideLabel("日出", t.map { HealthFormat.time($0.sunrise) } ?? "--", icon: "sunrise.fill", alignment: .leading)
            if let t {
                VStack(spacing: 2) {
                    SunArc(rise: t.sunrise, set: t.sunset)
                        .frame(height: 30)
                    Text(remaining(t))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            } else {
                Spacer()
            }
            sideLabel("日落", t.map { HealthFormat.time($0.sunset) } ?? "--", icon: "sunset.fill", alignment: .trailing)
        }
    }

    private func sideLabel(_ title: String, _ value: String, icon: String, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .symbolRenderingMode(.multicolor)
                Text(title).foregroundStyle(Theme.sun.text)
            }
            .font(.system(size: 15, weight: .semibold))
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
        }
    }

    private func remaining(_ t: (sunrise: Date, sunset: Date)) -> String {
        let now = Date()
        if now < t.sunrise { return "距日出 " + HealthFormat.duration(t.sunrise.timeIntervalSince(now)) }
        if now < t.sunset { return "距日落 " + HealthFormat.duration(t.sunset.timeIntervalSince(now)) }
        return "白昼 " + HealthFormat.duration(t.sunset.timeIntervalSince(t.sunrise))
    }
}

struct SunArc: View {
    let rise: Date
    let set: Date

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let now = Date()
            let daytime = now >= rise && now <= set
            let progress = min(max(now.timeIntervalSince(rise) / set.timeIntervalSince(rise), 0), 1)
            let cx = w / 2, cy = h - 2
            let rx = w / 2 - 8, ry = h - 8
            let angle = Double.pi * (1 - progress)
            let sun = CGPoint(x: cx + rx * cos(angle), y: cy - ry * sin(angle))

            ZStack {
                // 已经走过的部分用橙色实线，没走到的用虚线
                Path { p in arc(&p, cx, cy, rx, ry, from: 0, to: 1) }
                    .stroke(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [3, 4]))
                if daytime {
                    Path { p in arc(&p, cx, cy, rx, ry, from: 0, to: progress) }
                        .stroke(Theme.sun.gradient, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                }
                Path { p in
                    p.move(to: CGPoint(x: 0, y: cy))
                    p.addLine(to: CGPoint(x: w, y: cy))
                }
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)

                Circle()
                    .fill(daytime ? AnyShapeStyle(Theme.sun.gradient) : AnyShapeStyle(Color.secondary.opacity(0.5)))
                    .frame(width: 12, height: 12)
                    .shadow(color: daytime ? Theme.sun.bottom.opacity(0.8) : .clear, radius: 4)
                    .position(daytime ? sun : CGPoint(x: now < rise ? cx - rx : cx + rx, y: cy))
            }
        }
    }

    private func arc(_ p: inout Path, _ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat, from: Double, to: Double) {
        let steps = 40
        for i in 0...steps {
            let f = from + (to - from) * Double(i) / Double(steps)
            let a = Double.pi * (1 - f)
            let pt = CGPoint(x: cx + rx * cos(a), y: cy - ry * sin(a))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
    }
}
