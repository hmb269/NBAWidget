import WidgetKit
import SwiftUI
import Charts
import HealthKit

// 血糖小组件：直接读健康里的血糖（App 里「写入健康」的那些，带「餐点」标签）
// 小号：最近一次 + 7 天餐后2小时平均；中号：最近一次 + 14 天餐后2小时曲线

private let glucoseRed = Color(red: 1.0, green: 0.40, blue: 0.55)
private let glucoseRedDeep = Color(red: 0.92, green: 0.20, blue: 0.40)

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
        return points.filter { $0.isAfter2 && $0.date >= start }
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
            if family == .systemSmall { small } else { medium }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(widgetBackground)
        .tapToRefresh()
        .containerBackground(widgetBackground, for: .widget)
    }

    // 小号
    private var small: some View {
        let week = entry.after2(days: 7)
        return VStack(alignment: .leading, spacing: 0) {
            header
            Spacer(minLength: 4)
            latestBlock(size: 34)
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                Text("7天餐后2h")
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
        let list = entry.after2(days: 14)
        return HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                header
                Spacer(minLength: 4)
                latestBlock(size: 34)
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    Text("14天平均")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(entry.average(list).map { String(format: "%.1f", $0) } ?? "--")
                        .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(glucoseRed)
                }
            }
            .frame(width: 118, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text("餐后2小时 · 近14天")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(glucoseRed)
                if list.count >= 2 {
                    chart(list)
                } else {
                    Text("记录不足两条")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
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
        let lo = max(0, (list.map(\.mmol).min() ?? 4) - 0.8)
        let hi = (list.map(\.mmol).max() ?? 8) + 0.8
        return Chart {
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
                    .symbolSize(14)
                    .foregroundStyle(glucoseRed)
            }
        }
        .chartYScale(domain: lo...hi)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                AxisValueLabel {
                    if let d = v.as(Double.self) { Text(String(format: "%.0f", d)).font(.system(size: 9)) }
                }
            }
        }
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
