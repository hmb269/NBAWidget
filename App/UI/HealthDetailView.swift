import SwiftUI
import Charts

/// 健康首页卡片点进去的详情：最近 7 / 30 天的变化
enum HealthDetailKind: String {
    case sleep = "睡眠"
    case weight = "体重"
    case hrv = "恢复HRV"
    case steps = "步数"

    var unit: String {
        switch self {
        case .sleep: return "小时"
        case .weight: return "公斤"
        case .hrv: return "毫秒"
        case .steps: return "步"
        }
    }

    var color: Color {
        switch self {
        case .sleep: return AppColor.sleep
        case .weight: return Color(red: 0.80, green: 0.55, blue: 1.0)
        case .hrv: return Color(red: 1.0, green: 0.45, blue: 0.55)
        case .steps: return Color(red: 1.0, green: 0.68, blue: 0.25)
        }
    }

    func format(_ v: Double) -> String {
        switch self {
        case .sleep: return HealthFormat.duration(v * 3600)
        case .weight: return String(format: "%.2f", v)
        case .hrv: return String(Int(v.rounded()))
        case .steps: return Int(v.rounded()).formatted()
        }
    }
}

struct HealthDetailView: View {
    let kind: HealthDetailKind

    @State private var days = 7
    @State private var values: [DayValue] = []
    @State private var nights: [(Date, HealthService.SleepData)] = []
    @State private var loading = false
    @State private var selected: Date?

    private var picked: DayValue? {
        guard let s = selected else { return nil }
        return values.min { abs($0.date.timeIntervalSince(s)) < abs($1.date.timeIntervalSince(s)) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Picker("范围", selection: $days) {
                    Text("7天").tag(7)
                    Text("30天").tag(30)
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 12) {
                    header
                    if loading && values.isEmpty {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                    } else if values.isEmpty {
                        Text("这段时间没有数据").font(.footnote).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 200)
                    } else {
                        chart.frame(height: 220)
                    }
                    if kind == .sleep && !nights.isEmpty { sleepLegend }
                }
                .padding(18)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { selected = nil } }
                .glassCard(26)

                stats

                dayList
            }
            .padding(16)
        }
        .background(AppBackground())
        .navigationTitle(kind.rawValue)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: days) { await load() }
    }

    // 图表上方：选中的那天，或者最新一天
    private var header: some View {
        let p = picked ?? values.last
        return VStack(alignment: .leading, spacing: 2) {
            Text(picked == nil ? "最近" : dayText(p?.date ?? Date(), weekday: true))
                .font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(p.map { kind.format($0.value) } ?? "--")
                    .font(.system(size: 32, weight: .bold, design: .rounded).monospacedDigit())
                if kind != .sleep {
                    Text(kind.unit).font(.subheadline.weight(.semibold)).foregroundStyle(kind.color)
                }
            }
        }
    }

    @ViewBuilder
    private var chart: some View {
        switch kind {
        case .sleep:
            Chart {
                ForEach(Array(nights.enumerated()), id: \.offset) { _, n in
                    BarMark(x: .value("日期", n.0, unit: .day), y: .value("小时", n.1.deep / 3600))
                        .foregroundStyle(AppColor.deep)
                    BarMark(x: .value("日期", n.0, unit: .day), y: .value("小时", (n.1.core + n.1.other) / 3600))
                        .foregroundStyle(AppColor.core)
                    BarMark(x: .value("日期", n.0, unit: .day), y: .value("小时", n.1.rem / 3600))
                        .foregroundStyle(AppColor.rem)
                }
                if let p = picked {
                    RuleMark(x: .value("日期", p.date, unit: .day))
                        .foregroundStyle(.white.opacity(0.3))
                        .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            bubble(p)
                        }
                }
            }
            .tapToSelect($selected, dates: nights.map(\.0), byDay: true)
            .chartYAxis { axisY }
            .chartXAxis { axisX }
        case .steps:
            Chart {
                ForEach(values) { v in
                    BarMark(x: .value("日期", v.date, unit: .day), y: .value("步数", v.value))
                        .foregroundStyle(picked?.date == v.date ? Color.white : kind.color)
                        .cornerRadius(4)
                }
                if let p = picked {
                    RuleMark(x: .value("日期", p.date, unit: .day))
                        .foregroundStyle(.clear)
                        .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            bubble(p)
                        }
                }
            }
            .tapToSelect($selected, dates: values.map(\.date), byDay: true)
            .chartYAxis { axisY }
            .chartXAxis { axisX }
        default:
            let lo = (values.map(\.value).min() ?? 0)
            let hi = (values.map(\.value).max() ?? 1)
            let pad = max((hi - lo) * 0.25, kind == .weight ? 0.3 : 3)
            Chart {
                ForEach(values) { v in
                    AreaMark(x: .value("日期", v.date, unit: .day), yStart: .value("下限", lo - pad), yEnd: .value("值", v.value))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(LinearGradient(colors: [kind.color.opacity(0.32), kind.color.opacity(0)],
                                                        startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("日期", v.date, unit: .day), y: .value("值", v.value))
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .foregroundStyle(kind.color)
                    PointMark(x: .value("日期", v.date, unit: .day), y: .value("值", v.value))
                        .symbolSize(days == 7 ? 36 : 16)
                        .foregroundStyle(kind.color)
                }
                if let p = picked {
                    RuleMark(x: .value("日期", p.date, unit: .day)).foregroundStyle(.white.opacity(0.3))
                    PointMark(x: .value("日期", p.date, unit: .day), y: .value("值", p.value))
                        .symbolSize(90).foregroundStyle(.white)
                        .annotation(position: .top, spacing: 6, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                            bubble(p)
                        }
                }
            }
            .chartYScale(domain: (lo - pad)...(hi + pad))
            .tapToSelect($selected, dates: values.map(\.date), byDay: true)
            .chartYAxis { axisY }
            .chartXAxis { axisX }
        }
    }

    private var axisY: some AxisContent {
        AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { v in
            AxisGridLine().foregroundStyle(.white.opacity(0.08))
            AxisValueLabel {
                if let d = v.as(Double.self) {
                    Text(kind == .weight ? String(format: "%.1f", d) : (kind == .steps && d >= 1000 ? "\(Int(d / 1000))k" : String(Int(d))))
                        .font(.caption2)
                }
            }
        }
    }

    private var axisX: some AxisContent {
        AxisMarks(values: .automatic(desiredCount: days == 7 ? 7 : 5)) { v in
            AxisValueLabel {
                if let d = v.as(Date.self) { Text(dayText(d, weekday: false)).font(.caption2) }
            }
        }
    }

    private var sleepLegend: some View {
        HStack(spacing: 14) {
            legend("深睡", AppColor.deep)
            legend("核心", AppColor.core)
            legend("快速眼动", AppColor.rem)
        }
    }

    private func legend(_ t: String, _ c: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(c).frame(width: 7, height: 7)
            Text(t).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // 统计
    private var stats: some View {
        let v = values.map(\.value)
        let maxDay = values.max { $0.value < $1.value }?.date
        let minDay = values.min { $0.value < $1.value }?.date
        return HStack(spacing: 0) {
            stat("平均", v.isEmpty ? nil : kind.format(v.reduce(0, +) / Double(v.count)))
            stat("最高", v.max().map(kind.format), jump: maxDay)
            stat("最低", v.min().map(kind.format), jump: minDay)
            stat("天数", v.isEmpty ? nil : "\(v.count)")
        }
        .padding(.vertical, 14)
        .glassCard(22)
    }

    /// 统计数字；带 jump 的点一下会在图上选中那一天
    private func stat(_ t: String, _ v: String?, jump: Date? = nil) -> some View {
        Button {
            if let jump { withAnimation(.easeOut(duration: 0.2)) { selected = jump } }
        } label: {
            VStack(spacing: 3) {
                Text(v ?? "--").font(.system(size: 16, weight: .bold, design: .rounded).monospacedDigit())
                    .lineLimit(1).minimumScaleFactor(0.7)
                HStack(spacing: 2) {
                    Text(t)
                    if jump != nil { Image(systemName: "scope").font(.system(size: 8)) }
                }
                .font(.caption2)
                .foregroundStyle(jump != nil ? kind.color : .secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(jump == nil)
    }

    /// 图上的小气泡：日期 + 数值
    private func bubble(_ p: DayValue) -> some View {
        VStack(spacing: 1) {
            Text(kind.format(p.value) + (kind == .sleep ? "" : " " + kind.unit))
                .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
            Text(dayText(p.date, weekday: true))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .glassCard(10)
    }

    // 每天一行
    private var dayList: some View {
        VStack(spacing: 0) {
            ForEach(Array(values.reversed().enumerated()), id: \.element.id) { i, v in
                if i > 0 { Divider().overlay(Color.white.opacity(0.06)) }
                HStack {
                    Text(dayText(v.date, weekday: true)).font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    if kind == .sleep, let n = nights.first(where: { Calendar.current.isDate($0.0, inSameDayAs: v.date) })?.1 {
                        Text("深 \(HealthFormat.clock(n.deep)) · 核 \(HealthFormat.clock(n.core)) · 眼 \(HealthFormat.clock(n.rem))")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Text(kind.format(v.value) + (kind == .sleep ? "" : " " + kind.unit))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                }
                .padding(.vertical, 10)
            }
        }
        .padding(.horizontal, 16)
        .glassCard(22)
    }

    // 读取
    private func load() async {
        loading = true
        defer { loading = false }
        selected = nil
        switch kind {
        case .sleep:
            nights = await HealthService.nightlySleep(days: days)
            values = nights.map { DayValue(date: $0.0, value: $0.1.asleep / 3600) }
        case .weight:
            let pts = (try? await HealthService.weightHistory(days: days)) ?? []
            values = pts.map { DayValue(date: $0.date, value: $0.kg) }
        case .hrv:
            values = (try? await HealthService.daily(.hrv, days: days)) ?? []
        case .steps:
            values = (try? await HealthService.daily(.steps, days: days)) ?? []
        }
    }

    private func dayText(_ d: Date, weekday: Bool) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = weekday ? "M月d日 EEE" : "M/d"
        return f.string(from: d)
    }
}

extension View {
    /// 在图表上点一下，选中最近的那个日期（和左右翻页不冲突）
    /// 点曲线上的点 → 选中；点离点较远的空白处、或再点一次同一个点 → 取消选中
    func tapToSelect(_ selected: Binding<Date?>, dates: [Date], byDay: Bool = false) -> some View {
        self.chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onTapGesture { location in
                        guard let plot = proxy.plotFrame else { return }
                        let origin = geo[plot].origin
                        let x = location.x - origin.x
                        // 找横向最近的点（按天的柱子以当天中午为中心）
                        var best: (Date, CGFloat)?
                        for d in dates {
                            let center = byDay ? d.addingTimeInterval(12 * 3600) : d
                            guard let px = proxy.position(forX: center) else { continue }
                            let dist = abs(px - x)
                            if best == nil || dist < best!.1 { best = (d, dist) }
                        }
                        withAnimation(.easeOut(duration: 0.15)) {
                            if let best, best.1 <= 24,
                               location.x >= origin.x - 4, location.x <= origin.x + geo[plot].size.width + 4,
                               selected.wrappedValue.map({ abs($0.timeIntervalSince(best.0)) > 1 }) ?? true {
                                selected.wrappedValue = best.0
                            } else {
                                selected.wrappedValue = nil
                            }
                        }
                    }
            }
        }
    }
}
