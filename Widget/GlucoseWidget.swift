import WidgetKit
import SwiftUI
import Charts
import HealthKit
import AppIntents

// 血糖小组件：直接读健康里的血糖（App 里「写入健康」的那些，带「餐点」标签）
// 小号：最近一次 + 7 天餐后2小时平均；中号：最近一次 + 14 天餐后2小时曲线

private let glucoseRed = Color(red: 1.0, green: 0.40, blue: 0.55)
private let glucoseRedDeep = Color(red: 0.92, green: 0.20, blue: 0.40)

private let dangerRed = Color(red: 1.0, green: 0.32, blue: 0.32)
/// 安全线：餐后2小时 7.8（WHO），餐后1小时 8.6（IDF 2024），空腹 6.1（WHO/中国指南）
private var safeLine2h: Double {
    switch GlucosePrefs.kind {
    case "空腹": return 6.1
    case "餐后1h": return 8.6
    default: return 7.8
    }
}

/// 小组件上的切换：天数 7 / 30，餐次 全部 / 午+晚 / 午餐 / 晚餐 / 早餐
enum GlucosePrefs {
    private static let d = UserDefaults.standard
    static var days: Int { d.integer(forKey: "glucoseDays") == 30 ? 30 : 7 }
    static func toggleDays() { d.set(days == 7 ? 30 : 7, forKey: "glucoseDays"); clearSelection() }

    /// 曲线上点中的那个点（再点一次同一个点取消）
    static var selected: Double { d.double(forKey: "glucoseSelected") }
    static func select(_ t: Double) { d.set(abs(selected - t) < 1 ? 0 : t, forKey: "glucoseSelected") }
    static func clearSelection() { d.removeObject(forKey: "glucoseSelected") }

    /// 类型：餐后2h → 餐后1h → 空腹
    static let kinds = ["餐后2h", "餐后1h", "空腹"]
    static var kind: String { d.string(forKey: "glucoseKind").flatMap { kinds.contains($0) ? $0 : nil } ?? "餐后2h" }
    static func nextKind() {
        let i = kinds.firstIndex(of: kind) ?? 0
        d.set(kinds[(i + 1) % kinds.count], forKey: "glucoseKind")
        clearSelection()
    }
    static func isKind(_ tag: String?) -> Bool {
        guard let t = tag else { return false }
        switch kind {
        case "空腹": return t == "空腹"
        case "餐后1h": return t.hasSuffix("后1小时")
        default: return t.hasSuffix("后2小时")
        }
    }

    static let meals = ["全部", "午+晚", "午餐", "晚餐", "早餐"]
    static var meal: String { d.string(forKey: "glucoseMeal").flatMap { meals.contains($0) ? $0 : nil } ?? "全部" }
    static func nextMeal() {
        let i = meals.firstIndex(of: meal) ?? 0
        d.set(meals[(i + 1) % meals.count], forKey: "glucoseMeal")
        clearSelection()
    }
    static func matches(_ tag: String?) -> Bool {
        guard let t = tag else { return false }
        switch meal {
        case "午+晚": return t.hasPrefix("午餐") || t.hasPrefix("晚餐")
        case "午餐": return t.hasPrefix("午餐")
        case "晚餐": return t.hasPrefix("晚餐")
        case "早餐": return t.hasPrefix("早餐")
        default: return true
        }
    }
}

struct GlucoseDaysIntent: AppIntent {
    static var title: LocalizedStringResource = "切换血糖天数"
    static var isDiscoverable: Bool = false
    init() {}
    func perform() async throws -> some IntentResult { GlucosePrefs.toggleDays(); return .result() }
}

struct GlucoseKindIntent: AppIntent {
    static var title: LocalizedStringResource = "切换血糖类型"
    static var isDiscoverable: Bool = false
    init() {}
    func perform() async throws -> some IntentResult { GlucosePrefs.nextKind(); return .result() }
}

struct GlucoseMealIntent: AppIntent {
    static var title: LocalizedStringResource = "切换血糖餐次"
    static var isDiscoverable: Bool = false
    init() {}
    func perform() async throws -> some IntentResult { GlucosePrefs.nextMeal(); return .result() }
}

struct SelectGlucosePointIntent: AppIntent {
    static var title: LocalizedStringResource = "查看血糖点"
    static var isDiscoverable: Bool = false
    @Parameter(title: "时间") var time: Double
    init() {}
    init(time: Double) { self.time = time }
    func perform() async throws -> some IntentResult { GlucosePrefs.select(time); return .result() }
}

struct GlucosePoint: Codable {
    var date: Date
    var mmol: Double
    var tag: String?

    var isAfter2: Bool { tag?.hasSuffix("后2小时") ?? false }
}

enum GlucoseWidgetData {
    static func load(days: Int = 30) async throws -> [GlucosePoint] {
        let type = HKQuantityType(.bloodGlucose)
        let unit = HKUnit.moleUnit(with: .milli, molarMass: HKUnitMolarMassBloodGlucose).unitDivided(by: .liter())
        let start = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let samples: [HKQuantitySample] = try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, r, e in
                if let e { cont.resume(throwing: e) } else { cont.resume(returning: (r as? [HKQuantitySample]) ?? []) }
            }
            HealthService.store.execute(q)
        }
        return samples.map { s in
            let meta = s.metadata ?? [:]
            var tag = (meta["餐点"] as? String) ?? (meta["阿波餐点"] as? String)
            if tag == nil, let raw = meta[HKMetadataKeyBloodGlucoseMealTime] as? NSNumber {
                tag = raw.intValue == HKBloodGlucoseMealTime.preprandial.rawValue ? "餐前" : "餐后"
            }
            return GlucosePoint(date: s.startDate, mmol: s.quantity.doubleValue(for: unit), tag: tag)
        }
    }
}

struct GlucoseEntry: TimelineEntry {
    let date: Date
    let reading: HealthService.Reading<[GlucosePoint]>

    var points: [GlucosePoint] { reading.value ?? [] }
    var latest: GlucosePoint? { points.last }

    func after2(days: Int) -> [GlucosePoint] {
        let start = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        return points.filter {
            GlucosePrefs.isKind($0.tag) && $0.date >= start
                && (GlucosePrefs.kind == "空腹" || GlucosePrefs.matches($0.tag))
        }
    }

    func average(_ list: [GlucosePoint]) -> Double? {
        list.isEmpty ? nil : list.map(\.mmol).reduce(0, +) / Double(list.count)
    }

    static var sample: GlucoseEntry {
        let pts = (0..<14).map { i in
            GlucosePoint(date: Calendar.current.date(byAdding: .day, value: i - 13, to: Date())!,
                         mmol: 6.8 + sin(Double(i) / 2) * 0.9, tag: "午餐后2小时")
        }
        return GlucoseEntry(date: Date(), reading: .init(value: pts, updated: Date()))
    }
}

struct GlucoseProvider: TimelineProvider {
    private static var lastEntry: GlucoseEntry?

    func placeholder(in context: Context) -> GlucoseEntry { .sample }

    func getSnapshot(in context: Context, completion: @escaping (GlucoseEntry) -> Void) {
        if context.isPreview { completion(.sample); return }
        if let last = GlucoseProvider.lastEntry { completion(last); return }
        Task { completion(await load()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GlucoseEntry>) -> Void) {
        Task {
            let entry = await load()
            GlucoseProvider.lastEntry = entry
            let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date())!
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    private func load() async -> GlucoseEntry {
        let r = await HealthService.load("glucose", keepFor: 72) { try await GlucoseWidgetData.load() }
        return GlucoseEntry(date: Date(), reading: r)
    }
}

struct GlucoseWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Glucose", provider: GlucoseProvider()) { entry in
            GlucoseWidgetView(entry: entry)
        }
        .configurationDisplayName("血糖")
        .description("最近一次血糖和餐后 2 小时的变化（读健康里的血糖）")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

struct GlucoseWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: GlucoseEntry

    var body: some View {
        Group {
            if family == .systemSmall { small.tapToRefresh() } else { medium }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RefreshBackground())
        .background(widgetBackground)
        .containerBackground(widgetBackground, for: .widget)
    }

    // 小号
    private var small: some View {
        let week = entry.after2(days: GlucosePrefs.days)
        return VStack(alignment: .leading, spacing: 0) {
            header
            Spacer(minLength: 2)
            latestBlock(size: 30)
            Spacer(minLength: 2)
            if let hi = week.map(\.mmol).max(), let lo = week.map(\.mmol).min() {
                HStack(spacing: 6) {
                    Text("高 " + String(format: "%.1f", hi)).foregroundStyle(hi > safeLine2h ? dangerRed : .primary)
                    Text("低 " + String(format: "%.1f", lo))
                }
                .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                .padding(.bottom, 2)
            }
            HStack(spacing: 4) {
                Text("\(GlucosePrefs.days)天" + (GlucosePrefs.kind == "空腹" || GlucosePrefs.meal == "全部" ? "" : GlucosePrefs.meal) + GlucosePrefs.kind)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(entry.average(week).map { String(format: "%.1f", $0) } ?? "--")
                    .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(glucoseRed)
            }
        }
    }

    // 中号
    private var medium: some View {
        let days = GlucosePrefs.days
        let list = entry.after2(days: days)
        let over = list.filter { $0.mmol > safeLine2h }.count
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                header.tapToRefresh()
                Spacer(minLength: 2)
                latestBlock(size: 30).tapToRefresh()
                Spacer(minLength: 2)
                HStack(spacing: 4) {
                    Text("平均")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(entry.average(list).map { String(format: "%.1f", $0) } ?? "--")
                        .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(glucoseRed)
                    if !list.isEmpty {
                        Text("超线 \(over)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(over > 0 ? dangerRed : .secondary)
                    }
                }
                .tapToRefresh()
                // 最高、最低：点一下跳到曲线上那个点
                HStack(spacing: 6) {
                    if let hi = list.max(by: { $0.mmol < $1.mmol }) { extreme("高", hi) }
                    if let lo = list.min(by: { $0.mmol < $1.mmol }) { extreme("低", lo) }
                }
                .padding(.top, 3)
            }
            .frame(width: 112, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    chip(GlucosePrefs.kind, intent: GlucoseKindIntent(), strong: true)
                    Spacer(minLength: 0)
                    if GlucosePrefs.kind != "空腹" {
                        chip(GlucosePrefs.meal, intent: GlucoseMealIntent())
                    }
                    chip("\(days)天", intent: GlucoseDaysIntent())
                }
                if list.count >= 2 {
                    chart(list)
                } else {
                    Text(list.isEmpty ? "这段时间没有记录" : "记录不足两条")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    /// 「高 8.5」「低 4.6」小按钮，点了在曲线上选中那个点
    private func extreme(_ title: String, _ p: GlucosePoint) -> some View {
        let on = abs(GlucosePrefs.selected - p.date.timeIntervalSince1970) < 1
        return Button(intent: SelectGlucosePointIntent(time: p.date.timeIntervalSince1970)) {
            HStack(spacing: 2) {
                Text(title).font(.system(size: 9, weight: .semibold))
                Text(String(format: "%.1f", p.mmol))
                    .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
            }
            .foregroundStyle(p.mmol > safeLine2h ? dangerRed : Color.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(on ? glucoseRed.opacity(0.5) : Color.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
    }

    private func chip<I: AppIntent>(_ title: String, intent: I, strong: Bool = false) -> some View {
        Button(intent: intent) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(glucoseRed.opacity(strong ? 0.7 : 0.35)))
        }
        .buttonStyle(.plain)
    }

    private var header: some View {
        HStack(spacing: 5) {
            ZStack {
                Circle().fill(LinearGradient(colors: [glucoseRed, glucoseRedDeep], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "drop.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
            }
            .frame(width: 20, height: 20)
            Text("血糖").font(.system(size: 13, weight: .semibold)).foregroundStyle(glucoseRed)
        }
    }

    @ViewBuilder
    private func latestBlock(size: CGFloat) -> some View {
        if let l = entry.latest {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(String(format: "%.1f", l.mmol))
                        .font(.system(size: size, weight: .bold, design: .rounded).monospacedDigit())
                    Text("mmol/L").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }
                Text((l.tag ?? "未标记") + " · " + whenText(l.date))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        } else {
            Text(entry.reading.note ?? "健康里还没有血糖")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private func chart(_ list: [GlucosePoint]) -> some View {
        let lo = max(0, min(list.map(\.mmol).min() ?? 4, safeLine2h) - 0.8)
        let hi = max(list.map(\.mmol).max() ?? 8, safeLine2h) + 1.6   // 顶部留出放气泡的位置
        let sel = GlucosePrefs.selected
        let picked = sel > 0 ? list.first { abs($0.date.timeIntervalSince1970 - sel) < 1 } : nil
        return Chart {
            RuleMark(y: .value("安全线", safeLine2h))
                .foregroundStyle(dangerRed.opacity(0.75))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .annotation(position: .top, alignment: .leading, spacing: 1) {
                    Text(String(format: "%.1f", safeLine2h)).font(.system(size: 8, weight: .bold)).foregroundStyle(dangerRed)
                }
            ForEach(Array(list.enumerated()), id: \.offset) { _, p in
                AreaMark(x: .value("时间", p.date), yStart: .value("下限", lo), yEnd: .value("血糖", p.mmol))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(LinearGradient(colors: [glucoseRed.opacity(0.32), glucoseRed.opacity(0)],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("时间", p.date), y: .value("血糖", p.mmol))
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
                    .foregroundStyle(LinearGradient(colors: [glucoseRed, glucoseRedDeep], startPoint: .leading, endPoint: .trailing))
                PointMark(x: .value("时间", p.date), y: .value("血糖", p.mmol))
                    .symbolSize(p.mmol > safeLine2h ? 26 : 14)
                    .foregroundStyle(p.mmol > safeLine2h ? dangerRed : glucoseRed)
            }
            if let p = picked {
                RuleMark(x: .value("时间", p.date))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value("时间", p.date), y: .value("血糖", p.mmol))
                    .symbolSize(50)
                    .foregroundStyle(.white)
                    .annotation(position: .top, spacing: 3,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        VStack(spacing: 0) {
                            Text(String(format: "%.1f", p.mmol))
                                .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                            Text(pointLabel(p))
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color(white: 0.25)))
                    }
            }
        }
        .chartYScale(domain: lo...hi)
        .chartXAxis(.hidden)
        // 每个点上放一个透明按钮：点一下显示这个点的数值和时间
        .chartOverlay { proxy in
            GeometryReader { geo in
                if let plot = proxy.plotFrame {
                    let rect = geo[plot]
                    // 每个点只占一小块，点之间的空白处点了就是刷新 + 取消选中
                    let w = max(14, min(26, rect.width / CGFloat(max(list.count, 1))))
                    ForEach(Array(list.enumerated()), id: \.offset) { _, p in
                        if let x = proxy.position(forX: p.date) {
                            Button(intent: SelectGlucosePointIntent(time: p.date.timeIntervalSince1970)) {
                                Color.clear.contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .frame(width: w, height: rect.height)
                            .position(x: rect.minX + x, y: rect.midY)
                        }
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                AxisValueLabel {
                    if let d = v.as(Double.self) { Text(String(format: "%.0f", d)).font(.system(size: 9)) }
                }
            }
        }
    }

    private func pointLabel(_ p: GlucosePoint) -> String {
        let f = DateFormatter()
        f.dateFormat = "M/d HH:mm"
        let meal = (p.tag ?? "").replacingOccurrences(of: "2小时", with: "")
        return f.string(from: p.date) + (meal.isEmpty ? "" : " " + meal)
    }

    private func whenText(_ d: Date) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        if cal.isDateInToday(d) { return "今天 " + f.string(from: d) }
        if cal.isDateInYesterday(d) { return "昨天 " + f.string(from: d) }
        f.dateFormat = "M/d HH:mm"
        return f.string(from: d)
    }
}
