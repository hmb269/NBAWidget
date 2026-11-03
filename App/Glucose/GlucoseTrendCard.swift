import SwiftUI
import Charts

/// 血糖分类：从餐点标签里看出是空腹、餐后 1 小时还是餐后 2 小时
enum GlucoseKind: String, CaseIterable, Identifiable {
    case fasting = "空腹"
    case after1 = "餐后1h"
    case after2 = "餐后2h"

    var id: String { rawValue }

    static func of(_ tag: String?) -> GlucoseKind? {
        guard let t = tag else { return nil }
        if t == "空腹" { return .fasting }
        if t.hasSuffix("后1小时") { return .after1 }
        if t.hasSuffix("后2小时") { return .after2 }
        return nil
    }

    /// 安全线：空腹 6.1（WHO/中国指南正常上限）、餐后2小时 7.8（WHO 正常糖耐量上限）、
    /// 餐后1小时 8.6（IDF 2024 立场声明）。是「正常与否」的界值，不是个人治疗目标
    var safeLine: Double {
        switch self {
        case .fasting: return 6.1
        case .after1: return 8.6
        case .after2: return 7.8
        }
    }

    var color: Color {
        switch self {
        case .fasting: return Color(red: 0.40, green: 0.80, blue: 1.0)
        case .after1: return Color(red: 1.0, green: 0.70, blue: 0.30)
        case .after2: return Color(red: 1.0, green: 0.40, blue: 0.55)
        }
    }
}

/// 趋势图上的一个点：时间、数值、餐点、备注、照片小图
typealias GPoint = (Date, Double, String, String?, UIImage?, String)   // 最后一个是记录 id

/// 只看某一餐
enum MealFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case lunchDinner = "午餐+晚餐"
    case breakfast = "早餐"
    case lunch = "午餐"
    case dinner = "晚餐"

    var id: String { rawValue }

    func matches(_ tag: String) -> Bool {
        switch self {
        case .all: return true
        case .lunchDinner: return tag.hasPrefix("午餐") || tag.hasPrefix("晚餐")
        case .breakfast: return tag.hasPrefix("早餐")
        case .lunch: return tag.hasPrefix("午餐")
        case .dinner: return tag.hasPrefix("晚餐")
        }
    }
}

/// 血糖页最上面的趋势卡片：选空腹 / 餐后1h / 餐后2h 和时间范围，按住曲线看每个点
struct GlucoseTrendCard: View {
    /// (时间, 数值, 标签)
    let points: [GPoint]
    /// 点「这条记录」打开详情
    var onOpen: (String) -> Void = { _ in }

    @State private var kind: GlucoseKind = .after2
    @State private var days = 30
    @State private var meal: MealFilter = .all
    @State private var selected: Date?

    private var series: [GPoint] {
        let start = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        return points.filter {
            $0.0 >= start && GlucoseKind.of($0.2) == kind && (kind == .fasting || meal.matches($0.2))
        }.sorted { $0.0 < $1.0 }
    }

    private var picked: GPoint? {
        guard let s = selected else { return nil }
        return series.min { abs($0.0.timeIntervalSince(s)) < abs($1.0.timeIntervalSince(s)) }
    }

    var body: some View {
        let data = series
        let values = data.map(\.1)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("血糖趋势", systemImage: "drop.fill")
                    .font(.headline)
                    .foregroundStyle(kind.color)
                Spacer()
                Picker("范围", selection: $days) {
                    Text("7天").tag(7)
                    Text("30天").tag(30)
                    Text("90天").tag(90)
                }
                .pickerStyle(.menu)
                .tint(.secondary)
            }

            Picker("类型", selection: $kind) {
                ForEach(GlucoseKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            if kind != .fasting {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(MealFilter.allCases) { m in
                            Button {
                                meal = m
                            } label: {
                                Text(m.rawValue)
                                    .font(.footnote.weight(.semibold))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .foregroundStyle(meal == m ? Color.white : Color.secondary)
                                    .background(Capsule().fill(meal == m ? kind.color.opacity(0.85) : Color.white.opacity(0.08)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            if data.count >= 1 {
                chart(data)
                    .frame(height: 180)
            } else {
                Text("这段时间没有「\(kind.rawValue)」的记录。\n在下面的记录里把餐点标成「\(kind == .fasting ? "空腹" : kind == .after1 ? "午餐后1小时" : "午餐后2小时")」这类，就会出现在这里。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }

            if let p = picked {
                pickedRow(p)
            }

            HStack(spacing: 0) {
                stat("最新", data.last.map { String(format: "%.1f", $0.1) }, jump: data.last?.0)
                stat("平均", values.isEmpty ? nil : String(format: "%.1f", values.reduce(0, +) / Double(values.count)))
                stat("最高", values.max().map { String(format: "%.1f", $0) }, jump: data.max { $0.1 < $1.1 }?.0)
                stat("最低", values.min().map { String(format: "%.1f", $0) }, jump: data.min { $0.1 < $1.1 }?.0)
                stat("超线", values.isEmpty ? nil : "\(values.filter { $0 > kind.safeLine }.count)/\(values.count)")
            }
        }
        .padding(18)
        .glassCard(26)
        .onChange(of: kind) { _, _ in selected = nil }
        .onChange(of: days) { _, _ in selected = nil }
        .onChange(of: meal) { _, _ in selected = nil }
    }

    /// 选中的点：照片 + 数值 + 时间 + 备注，点一下打开这条记录的「照片和备注」
    private func pickedRow(_ p: GPoint) -> some View {
        Button {
            onOpen(p.5)
        } label: {
            HStack(spacing: 10) {
                Group {
                    if let img = p.4 {
                        Image(uiImage: img).resizable().scaledToFill()
                    } else {
                        Image(systemName: "camera").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.white.opacity(0.08))
                    }
                }
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(String(format: "%.1f", p.1))
                            .font(.system(size: 18, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(p.1 > kind.safeLine ? Color(red: 1.0, green: 0.32, blue: 0.32) : .primary)
                        Text(label(p.0) + " · " + p.2).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(p.3.flatMap { $0.isEmpty ? nil : $0 } ?? (p.4 == nil ? "点这里加照片和备注" : "点这里查看照片和备注"))
                        .font(.caption)
                        .foregroundStyle(p.3 == nil ? Color.secondary : Color.primary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func chart(_ data: [GPoint]) -> some View {
        let line = kind.safeLine
        let lo = max(0, min(data.map(\.1).min() ?? 4, line) - 1)
        let hi = max(data.map(\.1).max() ?? 8, line) + 1
        let danger = Color(red: 1.0, green: 0.32, blue: 0.32)
        return Chart {
            RuleMark(y: .value("安全线", line))
                .foregroundStyle(danger.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                .annotation(position: .top, alignment: .leading, spacing: 2) {
                    Text("安全线 \(String(format: "%.1f", line))")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(danger)
                }
            ForEach(Array(data.enumerated()), id: \.offset) { _, p in
                AreaMark(x: .value("时间", p.0), yStart: .value("下限", lo), yEnd: .value("血糖", p.1))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(LinearGradient(colors: [kind.color.opacity(0.35), kind.color.opacity(0.0)],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("时间", p.0), y: .value("血糖", p.1))
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .foregroundStyle(kind.color)
                PointMark(x: .value("时间", p.0), y: .value("血糖", p.1))
                    .symbolSize(p.1 > line ? 46 : 28)
                    .foregroundStyle(p.1 > line ? danger : kind.color)
            }
            if let p = picked {
                RuleMark(x: .value("时间", p.0))
                    .foregroundStyle(.white.opacity(0.35))
                PointMark(x: .value("时间", p.0), y: .value("血糖", p.1))
                    .symbolSize(90)
                    .foregroundStyle(.white)
                    .annotation(position: .top, spacing: 6,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        HStack(spacing: 6) {
                            if let img = p.4 {
                                Image(uiImage: img).resizable().scaledToFill()
                                    .frame(width: 34, height: 34)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(String(format: "%.1f mmol/L", p.1))
                                    .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                                Text(label(p.0) + " · " + p.2)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                if let n = p.3, !n.isEmpty {
                                    Text(n).font(.system(size: 10, weight: .medium)).lineLimit(1)
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .glassCard(10)
                    }
            }
        }
        .chartYScale(domain: lo...hi)
        .tapToSelect($selected)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { v in
                AxisGridLine().foregroundStyle(.white.opacity(0.08))
                AxisValueLabel {
                    if let d = v.as(Double.self) { Text(String(format: "%.0f", d)).font(.caption2) }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { v in
                AxisValueLabel {
                    if let d = v.as(Date.self) { Text(shortDay(d)).font(.caption2) }
                }
            }
        }
    }

    /// 统计数字；带 jump 的点一下会在图上选中那个点
    private func stat(_ title: String, _ value: String?, jump: Date? = nil) -> some View {
        Button {
            if let jump { withAnimation(.easeOut(duration: 0.2)) { selected = jump } }
        } label: {
            VStack(spacing: 3) {
                Text(value ?? "--")
                    .font(.system(size: 17, weight: .bold, design: .rounded).monospacedDigit())
                HStack(spacing: 2) {
                    Text(title)
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

    private func label(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm"
        return f.string(from: d)
    }

    private func shortDay(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "M/d"
        return f.string(from: d)
    }
}
