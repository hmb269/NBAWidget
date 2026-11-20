import WidgetKit
import SwiftUI
import Charts
import HealthKit

// 精简版：备孕体温小组件（直接读健康 App 里的月经、基础体温、手表腕温）

struct FertilityEntry: TimelineEntry {
    var date = Date()
    var status: CycleMath.Status?
    var bbt: [(Date, Double)] = []        // 最近 35 天基础体温
    var wrist: [(Date, Double)] = []      // 最近 35 天腕温偏差
    var note: String?

    static var sample: FertilityEntry {
        let today = CycleMath.day(Date())
        var e = FertilityEntry()
        e.status = CycleMath.Status(cycleDay: 15, nextStart: CycleMath.add(today, 13), lateDays: 0,
                                    ovulation: today, ovulationSource: "预测", fertileFrom: CycleMath.add(today, -5),
                                    fertileTo: CycleMath.add(today, 1), phase: "排卵日")
        e.bbt = (0..<20).map { i in (CycleMath.add(today, i - 19), i < 12 ? 36.3 + Double(i % 3) * 0.05 : 36.7 + Double(i % 2) * 0.05) }
        return e
    }

    static func load() async -> FertilityEntry {
        var e = FertilityEntry()
        let store = HealthService.store
        let now = Date()
        func samples(_ t: HKSampleType, days: Int) async -> [HKSample] {
            let pred = HKQuery.predicateForSamples(withStart: CycleMath.add(now, -days), end: now)
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            return await withCheckedContinuation { c in
                let q = HKSampleQuery(sampleType: t, predicate: pred, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, r, _ in
                    c.resume(returning: r ?? [])
                }
                store.execute(q)
            }
        }
        // 月经（2 少 3 中 4 多 1 未指定）
        let flow = await samples(HKCategoryType(.menstrualFlow), days: 240).compactMap { $0 as? HKCategorySample }
        let bleed: [Date] = flow.filter { [1, 2, 3, 4].contains($0.value) }.map(\.startDate)
        // 基础体温：一天取第一次
        var bbtMap: [Date: Double] = [:]
        for s in await samples(HKQuantityType(.basalBodyTemperature), days: 60).compactMap({ $0 as? HKQuantitySample }) {
            let d = CycleMath.day(s.startDate)
            if bbtMap[d] == nil { bbtMap[d] = s.quantity.doubleValue(for: .degreeCelsius()) }
        }
        let bbtAll = bbtMap.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
        // 腕温：记在醒来那天，用 90 天算基线
        var wMap: [Date: Double] = [:]
        for s in await samples(HKQuantityType(.appleSleepingWristTemperature), days: 90).compactMap({ $0 as? HKQuantitySample }) {
            wMap[CycleMath.day(s.endDate)] = s.quantity.doubleValue(for: .degreeCelsius())
        }
        let wAll = CycleMath.deviation(wMap.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 })
        let from = CycleMath.add(now, -34)
        e.status = CycleMath.status(bleed: bleed, bbt: bbtAll)
        e.bbt = bbtAll.filter { $0.0 >= from }
        e.wrist = wAll.filter { $0.0 >= from }
        if e.status == nil && e.bbt.isEmpty && e.wrist.isEmpty { e.note = "打开阿波精简版记录月经和体温" }
        return e
    }
}

struct FertilityProvider: TimelineProvider {
    func placeholder(in context: Context) -> FertilityEntry { .sample }

    func getSnapshot(in context: Context, completion: @escaping (FertilityEntry) -> Void) {
        if context.isPreview { completion(.sample); return }
        Task { completion(await FertilityEntry.load()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FertilityEntry>) -> Void) {
        Task {
            let e = await FertilityEntry.load()
            // 每 2 小时，或者过了零点就更新（周期第几天会变）
            let midnight = CycleMath.add(Date(), 1).addingTimeInterval(60)
            let next = min(Date().addingTimeInterval(2 * 3600), midnight)
            completion(Timeline(entries: [e], policy: .after(next)))
        }
    }
}

struct FertilityWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "FertilityTemp", provider: FertilityProvider()) { entry in
            FertilityWidgetView(entry: entry)
        }
        .configurationDisplayName("备孕体温")
        .description("周期第几天、易孕期、排卵日和基础体温 / 手表腕温曲线")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

private enum FW {
    static let period = Color(red: 1.0, green: 0.35, blue: 0.45)
    static let fertile = Color(red: 0.25, green: 0.85, blue: 0.75)
    static let ovulation = Color(red: 0.70, green: 0.50, blue: 1.0)
    static let temp = Color(red: 1.0, green: 0.62, blue: 0.30)

    static func color(_ phase: String) -> Color {
        if phase == "经期" || phase.hasPrefix("推迟") { return period }
        if phase == "排卵日" { return ovulation }
        if phase == "易孕期" { return fertile }
        return Color.white.opacity(0.6)
    }
}

struct FertilityWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: FertilityEntry

    var body: some View {
        Group {
            if family == .systemMedium {
                HStack(spacing: 12) {
                    status.frame(width: 120, alignment: .leading)
                    chart
                }
            } else {
                status
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tapToRefresh()
        .background(widgetBackground)
        .containerBackground(widgetBackground, for: .widget)
    }

    private var latestTemp: String {
        if let b = entry.bbt.last, CycleMath.between(b.0, Date()) <= 1 { return String(format: "体温 %.2f℃", b.1) }
        if let w = entry.wrist.last, CycleMath.between(w.0, Date()) <= 1 { return String(format: "腕温 %+.2f℃", w.1) }
        return " "
    }

    @ViewBuilder
    private var status: some View {
        if let s = entry.status {
            VStack(alignment: .leading, spacing: 4) {
                Text("周期第").font(.caption2).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(s.cycleDay)").font(.system(size: 34, weight: .heavy, design: .rounded).monospacedDigit())
                    Text("天").font(.caption).foregroundStyle(.secondary)
                }
                Text(s.phase).font(.caption.weight(.bold)).foregroundStyle(FW.color(s.phase))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(FW.color(s.phase).opacity(0.18)))
                Spacer(minLength: 0)
                Text(subLine(s)).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                Text(latestTemp).font(.caption2.weight(.semibold)).foregroundStyle(FW.temp).lineLimit(1)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Label("备孕体温", systemImage: "thermometer.medium").font(.caption.weight(.bold)).foregroundStyle(FW.temp)
                Spacer(minLength: 0)
                Text(entry.note ?? "还没有月经记录").font(.caption2).foregroundStyle(.secondary)
                Text(latestTemp).font(.caption.weight(.semibold)).foregroundStyle(FW.temp)
            }
        }
    }

    private func subLine(_ s: CycleMath.Status) -> String {
        let today = Date()
        let toOv = CycleMath.between(today, s.ovulation)
        if toOv > 0 && toOv <= 10 { return "排卵日 " + CycleMath.md(s.ovulation) + "（\(toOv) 天后）" }
        if s.lateDays > 0 { return "可以验孕了" }
        let left = CycleMath.between(today, s.nextStart)
        return "下次月经 " + CycleMath.md(s.nextStart) + (left > 0 ? "（\(left) 天）" : "")
    }

    @ViewBuilder
    private var chart: some View {
        if entry.bbt.count >= 3 {
            bbtChart
        } else if entry.wrist.count >= 3 {
            wristChart
        } else {
            Text("记录基础体温或戴手表睡觉后，这里显示体温曲线").font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var bbtChart: some View {
        let v = entry.bbt.map(\.1)
        let lo = (v.min() ?? 36.2) - 0.1
        let hi = (v.max() ?? 36.8) + 0.1
        let sh = CycleMath.shift(entry.bbt)
        return VStack(alignment: .leading, spacing: 2) {
            Text("基础体温").font(.caption2.weight(.semibold)).foregroundStyle(FW.temp)
            Chart {
                if let sh {
                    RuleMark(y: .value("覆盖线", sh.cover)).foregroundStyle(Color.white.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 2]))
                }
                if let s = entry.status, s.fertileTo >= (entry.bbt.first?.0 ?? Date()) {
                    RectangleMark(xStart: .value("易孕始", s.fertileFrom), xEnd: .value("易孕止", CycleMath.add(s.fertileTo, 1)))
                        .foregroundStyle(FW.fertile.opacity(0.15))
                }
                ForEach(Array(entry.bbt.enumerated()), id: \.offset) { _, p in
                    LineMark(x: .value("日期", p.0), y: .value("体温", p.1)).foregroundStyle(FW.temp)
                    PointMark(x: .value("日期", p.0), y: .value("体温", p.1)).foregroundStyle(FW.temp).symbolSize(10)
                }
            }
            .chartYScale(domain: lo...hi)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { val in
                    AxisValueLabel {
                        if let d = val.as(Double.self) { Text(String(format: "%.1f", d)).font(.system(size: 8)) }
                    }
                }
            }
        }
    }

    private var wristChart: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("手表腕温（和平时比）").font(.caption2.weight(.semibold)).foregroundStyle(FW.temp)
            Chart {
                RuleMark(y: .value("基线", 0.0)).foregroundStyle(Color.white.opacity(0.3))
                ForEach(Array(entry.wrist.enumerated()), id: \.offset) { _, p in
                    BarMark(x: .value("日期", p.0, unit: .day), y: .value("偏差", p.1))
                        .foregroundStyle(p.1 >= 0 ? FW.temp : Color(red: 0.4, green: 0.7, blue: 1.0))
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { val in
                    AxisValueLabel {
                        if let d = val.as(Double.self) { Text(String(format: "%+.1f", d)).font(.system(size: 8)) }
                    }
                }
            }
        }
    }
}
