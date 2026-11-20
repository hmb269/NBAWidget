import SwiftUI
import Charts

// 精简版首页「体温」卡片和体温曲线页：基础体温、手表腕温、体温计量的体温

struct TemperatureHomeCard: View {
    @ObservedObject private var store = FertilityStore.shared

    var body: some View {
        let v = value
        MetricCard(icon: "thermometer.medium",
                   colors: (Color(red: 1.0, green: 0.62, blue: 0.30), Color(red: 1.0, green: 0.35, blue: 0.45)),
                   title: "体温", value: v.0, unit: v.1,
                   delta: nil, deltaText: nil, threshold: 0, sub: v.2)
    }

    /// (数值, 单位, 下面一行)
    private var value: (String, String, String) {
        let recent = FertilityStore.addDays(Date(), -2)
        let wrist = store.wristDeviation(from: recent).last
        let wristText = wrist.map { String(format: "腕温 %+.2f℃", $0.1) }
        if let b = store.bbtPoints(from: recent).last {
            return (String(format: "%.2f", b.1), "℃", wristText ?? "基础体温")
        }
        if let w = wrist {
            return (String(format: "%+.2f", w.1), "℃", "手表腕温（和平时比）")
        }
        let k = FertilityStore.key(Date())
        if let t = store.bodyTemps[k] {
            return (String(format: "%.1f", t), "℃", t >= 37.3 ? "有点发烧" : "今天量的体温")
        }
        return ("--", "℃", "点进去看体温曲线")
    }
}

struct TemperatureDetailView: View {
    @ObservedObject private var store = FertilityStore.shared
    @State private var days = 30

    private var from: Date { FertilityStore.addDays(Date(), -(days - 1)) }

    var body: some View {
        let bbt = store.bbtPoints(from: from)
        let wrist = store.wristDeviation(from: from)
        let bodyPts = bodyPoints
        let starts = store.periodStarts.filter { $0 >= from }
        ScrollView {
            VStack(spacing: 14) {
                Picker("范围", selection: $days) {
                    Text("30天").tag(30)
                    Text("90天").tag(90)
                    Text("180天").tag(180)
                }
                .pickerStyle(.segmented)

                section("基础体温", "早上醒来测的体温；排卵后会升高 0.3～0.5℃，一直到来月经", FertilityColor.temp) {
                    if bbt.isEmpty {
                        empty("还没有基础体温。到「备孕」页的「记录今天」里填，或者用能同步到健康 App 的体温计。")
                    } else {
                        bbtChart(bbt, starts: starts)
                            .chartZoom(dates: from...FertilityStore.addDays(Date(), 1), fixed: true)
                            .frame(height: 200)
                        stats(bbt.map(\.1), fmt: "%.2f")
                    }
                }

                section("手表腕温", "Apple Watch 睡觉时测的手腕温度，和你自己平时比的变化", Color(red: 1.0, green: 0.45, blue: 0.35)) {
                    if wrist.isEmpty {
                        empty("没有腕温数据。需要 Apple Watch Series 8 / Ultra 及以上，戴着睡觉，并在手表上打开「睡眠」和「腕温」。")
                    } else {
                        wristChart(wrist, starts: starts)
                            .chartZoom(dates: from...FertilityStore.addDays(Date(), 1), fixed: true)
                            .frame(height: 170)
                        stats(wrist.map(\.1), fmt: "%+.2f")
                    }
                }

                if !bodyPts.isEmpty {
                    section("体温（体温计）", "健康 App 里体温计量的体温，37.3℃ 以上算发烧", Color(red: 1.0, green: 0.35, blue: 0.45)) {
                        bodyChart(bodyPts)
                            .chartZoom(dates: from...FertilityStore.addDays(Date(), 1), fixed: true)
                            .frame(height: 160)
                    }
                }

                dayList(bbt: bbt, wrist: wrist, body: bodyPts)

                Text("红色竖线是月经第一天。基础体温「连续 3 天高于前 6 天最高值、且高出 0.2℃」说明排卵了；高温期超过 18 天还没来月经，可能怀孕了。")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(14).glassCard(18)
            }
            .padding(16)
            .padding(.bottom, 100)
        }
        .background(AppBackground())
        .navigationTitle("体温")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task { await store.syncFromHealth() }
    }

    private var bodyPoints: [(Date, Double)] {
        store.bodyTemps.compactMap { k, v -> (Date, Double)? in
            guard let d = FertilityStore.date(k), d >= from else { return nil }
            return (d, v)
        }.sorted { $0.0 < $1.0 }
    }

    private func section<C: View>(_ title: String, _ sub: String, _ color: Color, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).foregroundStyle(color)
            Text(sub).font(.caption).foregroundStyle(.secondary)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(22)
    }

    private func empty(_ t: String) -> some View {
        Text(t).font(.footnote).foregroundStyle(.secondary).padding(.vertical, 8)
    }

    private func stats(_ v: [Double], fmt: String) -> some View {
        let avg = v.reduce(0, +) / Double(max(v.count, 1))
        return HStack {
            stat("最近", v.last.map { String(format: fmt, $0) } ?? "--")
            stat("平均", String(format: fmt, avg))
            stat("最高", v.max().map { String(format: fmt, $0) } ?? "--")
            stat("最低", v.min().map { String(format: fmt, $0) } ?? "--")
        }
    }

    private func stat(_ k: String, _ v: String) -> some View {
        VStack(spacing: 2) {
            Text(v).font(.subheadline.weight(.bold).monospacedDigit())
            Text(k).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func xAxis() -> some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 5)) { v in
            AxisGridLine().foregroundStyle(.white.opacity(0.05))
            AxisValueLabel {
                if let d = v.as(Date.self) { Text(FertilityStore.shortMD(d)).font(.caption2) }
            }
        }
    }

    private func bbtChart(_ pts: [(Date, Double)], starts: [Date]) -> some View {
        let vals = pts.map(\.1)
        let lo = (vals.min() ?? 36.2) - 0.15
        let hi = (vals.max() ?? 36.8) + 0.15
        let shift = store.lastStart.flatMap { store.bbtShift(from: $0) }
        return Chart {
            ForEach(starts, id: \.self) { s in
                RuleMark(x: .value("月经", s, unit: .day)).foregroundStyle(FertilityColor.period.opacity(0.6))
            }
            if let shift, shift.date >= from {
                RuleMark(y: .value("覆盖线", shift.cover))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            ForEach(Array(pts.enumerated()), id: \.offset) { _, p in
                LineMark(x: .value("日期", p.0, unit: .day), y: .value("体温", p.1))
                    .foregroundStyle(FertilityColor.temp)
                PointMark(x: .value("日期", p.0, unit: .day), y: .value("体温", p.1))
                    .foregroundStyle(FertilityColor.temp)
                    .symbolSize(days > 30 ? 10 : 22)
            }
        }
        .chartYScale(domain: lo...hi)
        .chartXAxis { xAxis() }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { v in
                AxisGridLine().foregroundStyle(.white.opacity(0.06))
                AxisValueLabel {
                    if let d = v.as(Double.self) { Text(String(format: "%.1f", d)).font(.caption2) }
                }
            }
        }
    }

    private func wristChart(_ pts: [(Date, Double)], starts: [Date]) -> some View {
        Chart {
            ForEach(starts, id: \.self) { s in
                RuleMark(x: .value("月经", s, unit: .day)).foregroundStyle(FertilityColor.period.opacity(0.6))
            }
            RuleMark(y: .value("基线", 0.0)).foregroundStyle(Color.white.opacity(0.3))
            ForEach(Array(pts.enumerated()), id: \.offset) { _, p in
                BarMark(x: .value("日期", p.0, unit: .day), y: .value("偏差", p.1))
                    .foregroundStyle(p.1 >= 0 ? FertilityColor.temp : Color(red: 0.4, green: 0.7, blue: 1.0))
            }
        }
        .chartXAxis { xAxis() }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { v in
                AxisGridLine().foregroundStyle(.white.opacity(0.06))
                AxisValueLabel {
                    if let d = v.as(Double.self) { Text(String(format: "%+.1f", d)).font(.caption2) }
                }
            }
        }
    }

    private func bodyChart(_ pts: [(Date, Double)]) -> some View {
        let vals = pts.map(\.1)
        let lo = min(vals.min() ?? 36, 36.0) - 0.2
        let hi = max(vals.max() ?? 37.5, 37.5) + 0.2
        return Chart {
            RuleMark(y: .value("发烧", 37.3))
                .foregroundStyle(Color.red.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            ForEach(Array(pts.enumerated()), id: \.offset) { _, p in
                LineMark(x: .value("日期", p.0, unit: .day), y: .value("体温", p.1))
                    .foregroundStyle(Color(red: 1.0, green: 0.35, blue: 0.45))
                PointMark(x: .value("日期", p.0, unit: .day), y: .value("体温", p.1))
                    .foregroundStyle(p.1 >= 37.3 ? Color.red : Color(red: 1.0, green: 0.35, blue: 0.45))
            }
        }
        .chartYScale(domain: lo...hi)
        .chartXAxis { xAxis() }
    }

    // 每天一行（最近的在上面）
    private func dayList(bbt: [(Date, Double)], wrist: [(Date, Double)], body: [(Date, Double)]) -> some View {
        var keys = Set<String>()
        var b: [String: Double] = [:]
        var w: [String: Double] = [:]
        var t: [String: Double] = [:]
        for p in bbt { let k = FertilityStore.key(p.0); b[k] = p.1; keys.insert(k) }
        for p in wrist { let k = FertilityStore.key(p.0); w[k] = p.1; keys.insert(k) }
        for p in body { let k = FertilityStore.key(p.0); t[k] = p.1; keys.insert(k) }
        let sorted = Array(keys.sorted(by: >).prefix(60))
        return VStack(spacing: 0) {
            ForEach(Array(sorted.enumerated()), id: \.element) { i, k in
                if i > 0 { RowDivider() }
                HStack {
                    Text(FertilityStore.date(k).map(FertilityStore.md) ?? k).font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    if let v = t[k] {
                        Text(String(format: "体温 %.1f", v)).font(.caption.monospacedDigit())
                            .foregroundStyle(v >= 37.3 ? Color.red : Color.secondary)
                    }
                    if let v = w[k] { Text(String(format: "腕温 %+.2f", v)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                    Text(b[k].map { String(format: "%.2f℃", $0) } ?? "--")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .frame(width: 70, alignment: .trailing)
                }
                .padding(.vertical, 9)
            }
        }
        .padding(.horizontal, 16)
        .glassCard(22)
        .opacity(sorted.isEmpty ? 0 : 1)
    }
}
