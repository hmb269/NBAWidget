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

    var color: Color {
        switch self {
        case .fasting: return Color(red: 0.40, green: 0.80, blue: 1.0)
        case .after1: return Color(red: 1.0, green: 0.70, blue: 0.30)
        case .after2: return Color(red: 1.0, green: 0.40, blue: 0.55)
        }
    }
}

/// 血糖页最上面的趋势卡片：选空腹 / 餐后1h / 餐后2h 和时间范围，按住曲线看每个点
struct GlucoseTrendCard: View {
    /// (时间, 数值, 标签)
    let points: [(Date, Double, String)]

    @State private var kind: GlucoseKind = .after2
    @State private var days = 30
    @State private var selected: Date?

    private var series: [(Date, Double, String)] {
        let start = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        return points.filter { $0.0 >= start && GlucoseKind.of($0.2) == kind }.sorted { $0.0 < $1.0 }
    }

    private var picked: (Date, Double, String)? {
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

            if data.count >= 1 {
                chart(data)
                    .frame(height: 180)
            } else {
                Text("这段时间没有「\(kind.rawValue)」的记录。\n在下面的记录里把餐点标成「\(kind == .fasting ? "空腹" : kind == .after1 ? "午餐后1小时" : "午餐后2小时")」这类，就会出现在这里。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }

            HStack(spacing: 0) {
                stat("最新", data.last.map { String(format: "%.1f", $0.1) })
                stat("平均", values.isEmpty ? nil : String(format: "%.1f", values.reduce(0, +) / Double(values.count)))
                stat("最高", values.max().map { String(format: "%.1f", $0) })
                stat("最低", values.min().map { String(format: "%.1f", $0) })
                stat("次数", values.isEmpty ? nil : "\(values.count)")
            }
        }
        .padding(18)
        .glassCard(26)
        .onChange(of: kind) { _, _ in selected = nil }
        .onChange(of: days) { _, _ in selected = nil }
    }

    private func chart(_ data: [(Date, Double, String)]) -> some View {
        let lo = max(0, (data.map(\.1).min() ?? 4) - 1)
        let hi = (data.map(\.1).max() ?? 8) + 1
        return Chart {
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
                    .symbolSize(28)
                    .foregroundStyle(kind.color)
            }
            if let p = picked {
                RuleMark(x: .value("时间", p.0))
                    .foregroundStyle(.white.opacity(0.35))
                PointMark(x: .value("时间", p.0), y: .value("血糖", p.1))
                    .symbolSize(90)
                    .foregroundStyle(.white)
                    .annotation(position: .top, spacing: 6,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        VStack(spacing: 1) {
                            Text(String(format: "%.1f mmol/L", p.1))
                                .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                            Text(label(p.0) + " · " + p.2)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .glassCard(10)
                    }
            }
        }
        .chartYScale(domain: lo...hi)
        .chartXSelection(value: $selected)
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

    private func stat(_ title: String, _ value: String?) -> some View {
        VStack(spacing: 3) {
            Text(value ?? "--")
                .font(.system(size: 17, weight: .bold, design: .rounded).monospacedDigit())
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
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
