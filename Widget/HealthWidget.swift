import WidgetKit
import SwiftUI
import Charts
import AppIntents

// 健康小组件，小 / 中 / 大三种尺寸。
// 睡眠固定显示；另外 4 项和它们的颜色在「编辑小组件」里自己选。
// 小号：五行；中号：左边睡眠，右边 4 项；大号：睡眠、第 1 项趋势图、下面 3 项。
// 图标可以在 App 里换成自己的照片（经系统相簿传给小组件）。

// MARK: - 颜色

struct Theme {
    let top: Color
    let bottom: Color
    var gradient: LinearGradient { LinearGradient(colors: [top, bottom], startPoint: .topLeading, endPoint: .bottomTrailing) }
    var text: Color { top }

    init(top: Color, bottom: Color) { self.top = top; self.bottom = bottom }
    init(_ c: (Color, Color)) { self.top = c.0; self.bottom = c.1 }

    static let sleep = Theme(top: Color(red: 0.42, green: 0.86, blue: 1.0), bottom: Color(red: 0.30, green: 0.45, blue: 0.98))
}

enum HealthColor {
    static let deep = Color(red: 0.30, green: 0.36, blue: 0.95)
    static let core = Color(red: 0.25, green: 0.60, blue: 1.0)
    static let rem = Color(red: 0.42, green: 0.86, blue: 1.0)
    static let other = Color(red: 0.36, green: 0.62, blue: 0.95)
    static let more = Color(red: 0.25, green: 0.88, blue: 0.45)   // 上升 / 变多：绿色
    static let less = Color(red: 1.0, green: 0.30, blue: 0.30)    // 下降 / 变少：红色
}

// MARK: - 编辑小组件里的设置

struct HealthConfigIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "健康小组件"
    static var description = IntentDescription("选择要显示的 4 项数据和颜色。大号里第 1 项会画趋势图。")

    @Parameter(title: "第 1 项", default: .weight) var item1: MetricKind
    @Parameter(title: "第 1 项颜色", default: .auto) var color1: ColorChoice
    @Parameter(title: "第 2 项", default: .hrv) var item2: MetricKind
    @Parameter(title: "第 2 项颜色", default: .auto) var color2: ColorChoice
    @Parameter(title: "第 3 项", default: .steps) var item3: MetricKind
    @Parameter(title: "第 3 项颜色", default: .auto) var color3: ColorChoice
    @Parameter(title: "第 4 项", default: .sun) var item4: MetricKind
    @Parameter(title: "第 4 项颜色", default: .auto) var color4: ColorChoice

    init() {}

    var items: [MetricKind] { [item1, item2, item3, item4] }
    var colors: [ColorChoice] { [color1, color2, color3, color4] }
}

// MARK: - 一项数据（显示用）

struct ItemModel {
    let kind: MetricKind
    let theme: Theme
    let reading: HealthService.Reading<MetricReading>
    let icon: UIImage?

    var value: Double? {
        guard let r = reading.value else { return nil }
        // 今天累计的数据，缓存要是昨天的就不显示
        if kind.cumulative || kind == .stand {
            guard let t = reading.updated, Calendar.current.isDateInToday(t) else { return nil }
        }
        return r.value
    }

    var valueText: String {
        if kind == .sun { return sunText }
        return value.map { kind.format($0) } ?? "--"
    }

    var delta: Double? {
        guard kind.comparable, let v = value, let p = reading.value?.previous else { return nil }
        return v - p
    }

    /// 上升整行绿、下降整行红（只对能比较的项）
    var trendColor: Color? {
        guard let d = delta, abs(d) >= kind.trendThreshold else { return nil }
        return d > 0 ? HealthColor.more : HealthColor.less
    }

    var deltaText: String? {
        guard let d = delta else { return nil }
        return kind.format(abs(d))
    }

    var foot: String {
        if let n = reading.note { return n }
        guard let r = reading.value else { return " " }
        let cal = Calendar.current
        switch kind {
        case .hrv:
            var t = (r.overnight ?? false) ? "昨晚平均" : "最近一次"
            if let p = r.previous { t += " · 前晚 \(Int(p.rounded()))" }
            return t
        case .sun:
            return " "
        default:
            if kind.cumulative || kind == .stand {
                guard let t = reading.updated, cal.isDateInToday(t) else { return " " }
                return HealthFormat.time(t) + " 更新"
            }
            var t: String
            if cal.isDateInToday(r.date) { t = "今天 " + HealthFormat.time(r.date) }
            else if cal.isDateInYesterday(r.date) { t = "昨天" }
            else {
                let c = cal.dateComponents([.month, .day], from: r.date)
                t = "\(c.month ?? 0)月\(c.day ?? 0)日"
            }
            if let p = r.previous, kind.comparable { t += " · 前次 " + kind.format(p) }
            return t
        }
    }
}

private var sunText: String {
    SunTimes.times().map { HealthFormat.time($0.sunrise) + " / " + HealthFormat.time($0.sunset) } ?? "--"
}

// MARK: - 时间线

struct HealthEntry: TimelineEntry {
    let date: Date
    var sleep: HealthService.Reading<HealthService.SleepData>
    var prevSleep: HealthService.Reading<HealthService.SleepData>
    var items: [ItemModel]
    var history: HealthService.Reading<[DayPoint]>
    var sleepPhoto: UIImage?

    static func sample(_ config: HealthConfigIntent = HealthConfigIntent()) -> HealthEntry {
        let kinds = config.items
        let demo: [MetricKind: Double] = [.weight: 65.25, .hrv: 48, .steps: 6543, .restingHR: 58, .heartRate: 72,
                                          .activeEnergy: 420, .exercise: 32, .stand: 9, .distance: 4.85, .flights: 6,
                                          .oxygen: 98, .respiratory: 14.5, .vo2max: 41.2, .bodyFat: 18.4]
        let items = zip(kinds, config.colors).map { k, c in
            ItemModel(kind: k, theme: Theme(c.colors ?? k.defaultColors),
                      reading: .init(value: MetricReading(value: demo[k] ?? 0, previous: (demo[k] ?? 0) * 0.98, date: Date()),
                                     updated: Date()),
                      icon: nil)
        }
        return HealthEntry(
            date: Date(),
            sleep: .init(value: .init(asleep: 25320, deep: 3600, core: 15000, rem: 6600, awake: 600, other: 0,
                                      bedtime: Date().addingTimeInterval(-36000), wake: Date().addingTimeInterval(-10800))),
            prevSleep: .init(value: .init(asleep: 23400, deep: 3000, core: 14000, rem: 6400, awake: 600, other: 0, bedtime: nil, wake: nil)),
            items: items,
            history: .init(value: (0..<30).map { i in
                DayPoint(date: Calendar.current.date(byAdding: .day, value: i - 29, to: Calendar.current.startOfDay(for: Date()))!,
                         value: (demo[kinds[0]] ?? 60) * (1 + sin(Double(i) / 2.5) * 0.01))
            }),
            sleepPhoto: nil
        )
    }

    static func load(_ config: HealthConfigIntent) async -> HealthEntry {
        // 先把所有健康数据同时读，不排队
        async let sleep = HealthService.load("sleep", keepFor: 18) { try await HealthService.lastNightSleep() }
        async let prevSleep = HealthService.load("sleepPrev", keepFor: 18) { try await HealthService.lastNightSleep(nightsAgo: 1) }
        let kinds = config.items
        let first = kinds[0]
        async let history: HealthService.Reading<[DayPoint]> = first.chartable
            ? HealthService.load("history_" + first.rawValue, keepFor: 72) { try await HealthService.dailyHistory(first, days: 30) }
            : HealthService.Reading<[DayPoint]>(value: [])

        let s = await sleep
        let ps = await prevSleep
        let readings = await withTaskGroup(of: (MetricKind, HealthService.Reading<MetricReading>).self) { group in
            for k in Set(kinds) where k != .sun {
                group.addTask {
                    (k, await HealthService.load("metric_" + k.rawValue, keepFor: k.cumulative ? 12 : 72) {
                        try await HealthService.fetch(k, sleep: s.value, prevSleep: ps.value)
                    })
                }
            }
            var out: [MetricKind: HealthService.Reading<MetricReading>] = [:]
            for await (k, r) in group { out[k] = r }
            return out
        }

        let icons = IconStore.loadAllForWidget([.sleep] + kinds.map { IconSlot($0) })
        let items = zip(kinds, config.colors).map { k, c in
            ItemModel(kind: k, theme: Theme(c.colors ?? k.defaultColors),
                      reading: readings[k] ?? .init(value: nil), icon: icons[IconSlot(k)])
        }
        return HealthEntry(date: Date(), sleep: s, prevSleep: ps, items: items, history: await history, sleepPhoto: icons[.sleep])
    }

    /// 带超时：超过 8 秒还没读完，就先用上次的结果，避免小组件一直停在灰色占位
    static func loadWithTimeout(_ config: HealthConfigIntent) async -> HealthEntry {
        await withTaskGroup(of: HealthEntry?.self) { group in
            group.addTask { await load(config) }
            group.addTask {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                return nil
            }
            for await result in group {
                if let entry = result {
                    group.cancelAll()
                    LastEntry.save(entry)
                    return entry
                }
                // 超时：用上次成功的那份
                if let last = LastEntry.last {
                    group.cancelAll()
                    return last
                }
            }
            return .sample(config)
        }
    }

    // 睡眠显示

    var sleepDelta: TimeInterval? {
        guard let a = sleep.value?.asleep, let b = prevSleep.value?.asleep else { return nil }
        return a - b
    }
    var sleepDeltaText: String? {
        guard let d = sleepDelta, abs(d) >= 60 else { return nil }
        let m = Int((abs(d) / 60).rounded())
        return (d > 0 ? "+" : "-") + (m >= 60 ? "\(m / 60)时\(m % 60)分" : "\(m)分")
    }
    var sleepValue: String { sleep.value.map { HealthFormat.duration($0.asleep) } ?? "--" }
    var sleepFoot: String {
        if let n = sleep.note { return n }
        guard let d = sleep.value, let b = d.bedtime, let w = d.wake else { return " " }
        return HealthFormat.time(b) + " - " + HealthFormat.time(w)
    }
}

struct HealthProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> HealthEntry { .sample() }

    func snapshot(for configuration: HealthConfigIntent, in context: Context) async -> HealthEntry {
        if context.isPreview { return .sample(configuration) }
        return await HealthEntry.loadWithTimeout(configuration)
    }

    func timeline(for configuration: HealthConfigIntent, in context: Context) async -> Timeline<HealthEntry> {
        let entry = await HealthEntry.loadWithTimeout(configuration)
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date())!
        return Timeline(entries: [entry], policy: .after(next))
    }
}

struct HealthWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "HealthAll", intent: HealthConfigIntent.self, provider: HealthProvider()) { entry in
            HealthWidgetView(entry: entry)
        }
        .configurationDisplayName("健康")
        .description("睡眠 + 自选 4 项数据（长按小组件 → 编辑小组件），大号带趋势图")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled() // 自己画底色，避免系统把底色提亮
    }
}

/// 小组件进程里记住上一次成功读到的结果（超时时先拿来顶上）
enum LastEntry {
    private static var cached: HealthEntry?
    static var last: HealthEntry? { cached }
    static func save(_ e: HealthEntry) { cached = e }
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

// MARK: - 小号：睡眠 + 4 项，一行一项

struct SmallHealthView: View {
    let entry: HealthEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                IconBadge(symbol: IconSlot.sleep.symbol, theme: .sleep, size: 22)
                ValueText(entry.sleepValue, size: 15)
                if let d = entry.sleepDelta { TrendView(delta: d / 60, threshold: 1, compact: true) }
            }
            ForEach(Array(entry.items.enumerated()), id: \.offset) { _, item in
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    IconBadge(symbol: item.kind.symbol, theme: item.theme, size: 22, custom: item.icon)
                    ValueText(item.valueText, size: 15, color: item.trendColor)
                    if item.value != nil && !item.kind.unit.isEmpty {
                        UnitText(item.kind.unit, theme: item.theme, color: item.trendColor)
                    }
                    if let d = item.delta { TrendView(delta: d, threshold: item.kind.trendThreshold, compact: true) }
                }
                .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 中号：左边睡眠，右边 4 项表格对齐

struct MediumHealthView: View {
    let entry: HealthEntry

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                SleepRing(sleep: entry.sleep.value, prevAsleep: entry.prevSleep.value?.asleep, size: 52, photo: entry.sleepPhoto)
                    .padding(.bottom, 6)
                HStack(spacing: 4) {
                    CaptionText("睡眠时间", theme: .sleep, size: 13).fixedSize()
                    SleepDeltaText(entry: entry)
                }
                ValueText(entry.sleepValue, size: 18)
                FootText(entry.sleepFoot)
            }
            .frame(width: 104, alignment: .leading)

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 12) {
                ForEach(Array(entry.items.enumerated()), id: \.offset) { _, item in
                    GridRow(alignment: .center) {
                        HStack(spacing: 5) {
                            IconBadge(symbol: item.kind.symbol, theme: item.theme, size: 22, custom: item.icon)
                            CaptionText(item.kind.title, theme: item.theme, size: 12, color: item.trendColor)
                                .lineLimit(1)
                                .fixedSize()
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            ValueText(item.valueText, size: 15, color: item.trendColor, shrink: false)
                            if item.value != nil && !item.kind.unit.isEmpty {
                                UnitText(item.kind.unit, theme: item.theme, color: item.trendColor)
                            }
                            if let d = item.delta { TrendView(delta: d, threshold: item.kind.trendThreshold, compact: true) }
                        }
                        .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - 大号：睡眠 / 第 1 项 + 趋势图 / 第 2~4 项

struct LargeHealthView: View {
    let entry: HealthEntry

    var body: some View {
        VStack(spacing: 10) {
            sleepSection
            mainSection
                .frame(maxHeight: .infinity)
            HStack(alignment: .top, spacing: 6) {
                ForEach(Array(entry.items.dropFirst().enumerated()), id: \.offset) { _, item in
                    tile(item)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // 睡眠
    private var sleepSection: some View {
        HStack(alignment: .center, spacing: 12) {
            SleepRing(sleep: entry.sleep.value, prevAsleep: entry.prevSleep.value?.asleep, size: 56, photo: entry.sleepPhoto)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    IconBadge(symbol: IconSlot.sleep.symbol, theme: .sleep, size: 18)
                    CaptionText("睡眠时间", theme: .sleep, size: 13).fixedSize()
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
        .section()
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

    // 第 1 项 + 趋势图
    private var mainSection: some View {
        let item = entry.items[0]
        let days = ChartRange.current
        let pts = chartPoints(days: days)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                IconBadge(symbol: item.kind.symbol, theme: item.theme, size: 30, custom: item.icon)
                VStack(alignment: .leading, spacing: 0) {
                    CaptionText(item.kind.title, theme: item.theme, size: 13, color: item.trendColor)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        ValueText(item.valueText, size: 22, color: item.trendColor, shrink: false)
                        if item.value != nil && !item.kind.unit.isEmpty {
                            UnitText(item.kind.unit, theme: item.theme, color: item.trendColor)
                        }
                        if let d = item.delta {
                            TrendView(delta: d, threshold: item.kind.trendThreshold, text: item.deltaText, compact: false)
                        }
                    }
                }
                Spacer(minLength: 4)
                if item.kind.chartable {
                    VStack(alignment: .trailing, spacing: 3) {
                        RangeChip(days: days, theme: item.theme)
                        if pts.count > 1, let f = pts.first, let l = pts.last {
                            HStack(spacing: 3) {
                                Text("近\(days)天").font(.system(size: 11)).foregroundStyle(.secondary)
                                TrendView(delta: l.value - f.value, threshold: item.kind.trendThreshold,
                                          text: item.kind.format(abs(l.value - f.value)), compact: false, small: true)
                            }
                        }
                    }
                }
            }
            if item.kind.chartable {
                TrendChart(kind: item.kind, theme: item.theme, points: pts, days: days, note: entry.history.note)
            } else {
                Spacer(minLength: 0)
            }
        }
        .section()
    }

    private func chartPoints(days: Int) -> [DayPoint] {
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -(days - 1), to: cal.startOfDay(for: Date()))!
        return (entry.history.value ?? []).filter { $0.date >= start }
    }

    // 下面的小格
    private func tile(_ item: ItemModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                IconBadge(symbol: item.kind.symbol, theme: item.theme, size: 18, custom: item.icon)
                CaptionText(item.kind.title, theme: item.theme, size: 11, color: item.trendColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            if item.kind == .sun {
                sunLine("sunrise.fill", SunTimes.times().map { HealthFormat.time($0.sunrise) } ?? "--", item.theme)
                sunLine("sunset.fill", SunTimes.times().map { HealthFormat.time($0.sunset) } ?? "--", item.theme)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    ValueText(item.valueText, size: 20, color: item.trendColor)
                    if item.value != nil && !item.kind.unit.isEmpty {
                        UnitText(item.kind.unit, theme: item.theme, color: item.trendColor)
                    }
                }
                HStack(spacing: 3) {
                    if let d = item.delta {
                        TrendView(delta: d, threshold: item.kind.trendThreshold, text: item.deltaText, compact: false, small: true)
                    }
                    FootText(item.delta != nil ? shortFoot(item) : item.foot)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .section(padding: 10)
    }

    /// 小格里有箭头时，小字只留「前晚 / 前次」
    private func shortFoot(_ item: ItemModel) -> String {
        guard let p = item.reading.value?.previous else { return item.foot }
        return (item.kind == .hrv ? "前晚 " : "前次 ") + item.kind.format(p)
    }

    private func sunLine(_ icon: String, _ value: String, _ theme: Theme) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.gradient)
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded).monospacedDigit())
        }
    }
}

extension View {
    /// 大号里的分组：不画底框，直接融在底色上，只留一点内边距
    func section(padding: CGFloat = 12) -> some View {
        self
            .padding(.horizontal, padding / 2)
            .padding(.vertical, padding / 3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 趋势图（点「7天/30天」切换；点图上某一天显示那天的数值）

enum ChartRange {
    private static let key = "weightRange"
    static var current: Int { UserDefaults.standard.integer(forKey: key) == 7 ? 7 : 30 }
    static func toggle() {
        UserDefaults.standard.set(current == 7 ? 30 : 7, forKey: key)
        ChartSelection.clear()
    }
}

/// 图上选中的那一天（再点一次同一天取消）
enum ChartSelection {
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
    static var title: LocalizedStringResource = "切换趋势图范围"
    static var isDiscoverable: Bool = false
    init() {}
    func perform() async throws -> some IntentResult {
        ChartRange.toggle()
        return .result()
    }
}

struct SelectWeightDayIntent: AppIntent {
    static var title: LocalizedStringResource = "查看某天数值"
    static var isDiscoverable: Bool = false
    @Parameter(title: "日期") var time: Double
    init() {}
    init(day: Date) { self.time = day.timeIntervalSince1970 }
    func perform() async throws -> some IntentResult {
        ChartSelection.toggle(Date(timeIntervalSince1970: time))
        return .result()
    }
}

struct RangeChip: View {
    let days: Int
    let theme: Theme
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
            .background(Capsule().fill(on ? AnyShapeStyle(theme.gradient) : AnyShapeStyle(Color.clear)))
    }
}

struct TrendChart: View {
    let kind: MetricKind
    let theme: Theme
    let points: [DayPoint]
    let days: Int
    let note: String?

    var body: some View {
        let cal = Calendar.current
        let pts = points
        // 横轴只覆盖有记录的那几天，记录不满 7 / 30 天时也铺满整个宽度
        let start = cal.startOfDay(for: pts.first?.date ?? Date())
        let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: pts.last?.date ?? Date()))!
        let span = max(1, cal.dateComponents([.day], from: start, to: end).day ?? 1)
        let minV = pts.map(\.value).min() ?? 0
        let maxV = pts.map(\.value).max() ?? 1
        let pad = max((maxV - minV) * 0.2, max(abs(maxV) * 0.004, 0.1))
        let lo = minV - pad
        let hi = maxV + pad
        let picked: DayPoint? = ChartSelection.day.flatMap { sel in
            pts.min { abs($0.date.timeIntervalSince(sel)) < abs($1.date.timeIntervalSince(sel)) }
        }
        let mid = { (d: Date) in d.addingTimeInterval(12 * 3600) } // 点画在当天中间，和点击格子对齐

        if pts.count >= 2 {
            Chart {
                ForEach(Array(pts.enumerated()), id: \.offset) { _, p in
                    AreaMark(x: .value("日期", mid(p.date)),
                             yStart: .value("下限", lo),
                             yEnd: .value("数值", p.value))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(LinearGradient(colors: [theme.top.opacity(0.32), theme.top.opacity(0.0)],
                                                        startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("日期", mid(p.date)), y: .value("数值", p.value))
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
                        .foregroundStyle(theme.gradient)
                    if span <= 10 { // 天数少时把每天的点画出来
                        PointMark(x: .value("日期", mid(p.date)), y: .value("数值", p.value))
                            .symbolSize(20)
                            .foregroundStyle(theme.top)
                    }
                }
                if let p = picked {
                    RuleMark(x: .value("日期", mid(p.date)))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                    PointMark(x: .value("日期", mid(p.date)), y: .value("数值", p.value))
                        .symbolSize(60)
                        .foregroundStyle(.white)
                        .annotation(position: .top, spacing: 4,
                                    overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                            VStack(spacing: 0) {
                                Text(kind.format(p.value) + " " + kind.unit)
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
                    PointMark(x: .value("日期", mid(l.date)), y: .value("数值", l.value))
                        .symbolSize(40)
                        .foregroundStyle(theme.top)
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
                            Text(kind.format(d)).font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            // 每天一个透明按钮，点哪天就显示哪天的数值
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
            FootText(note ?? "近\(days)天记录不足两天")
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
    let symbol: String
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
                Image(systemName: symbol)
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

/// 睡眠圆环：深睡 / 核心 / 快速眼动三段。
/// 和前一晚比：多睡的那部分画成绿色；少睡就把缺的那段画成红色。
/// 中间：换了照片就只显示照片；没换就显示小时数。
struct SleepRing: View {
    let sleep: HealthService.SleepData?
    var prevAsleep: TimeInterval? = nil
    var size: CGFloat = 58
    var photo: UIImage? = nil

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
            } else if let s = sleep {
                Text(String(format: "%.1f", s.asleep / 3600))
                    .font(.system(size: size * 0.33, weight: .bold, design: .rounded).monospacedDigit())
            } else {
                Image(systemName: IconSlot.sleep.symbol).font(.system(size: size * 0.33)).foregroundStyle(Theme.sleep.text)
            }
        }
        .frame(width: size, height: size)
        .padding(lw / 2)
    }
}
