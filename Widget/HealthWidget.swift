import WidgetKit
import SwiftUI

// 一个大号小组件放下全部健康数据，样式照系统「睡眠评分」：
//  ┌──────────────┬──────────────┐
//  │ 睡眠圆环      │ 体重 ↑↓       │
//  │ 睡眠时间      │              │
//  ├──────────────┼──────────────┤
//  │ 心率变异性    │ 今日步数      │
//  ├──────────────┴──────────────┤
//  │ 日出 ───── 太阳弧线 ───── 日落 │
//  └─────────────────────────────┘

enum HealthColor {
    static let deep = Color(red: 0.24, green: 0.33, blue: 0.93)
    static let core = Color(red: 0.25, green: 0.56, blue: 0.98)
    static let rem = Color(red: 0.36, green: 0.82, blue: 0.85)
    static let other = Color(red: 0.36, green: 0.62, blue: 0.95)
    static let weight = Color(red: 0.62, green: 0.45, blue: 0.95)
    static let hrv = Color(red: 0.36, green: 0.82, blue: 0.85)
    static let steps = Color(red: 0.2, green: 0.85, blue: 0.4)
    static let sun = Color(red: 1.0, green: 0.62, blue: 0.2)
    static let up = Color(red: 1.0, green: 0.42, blue: 0.35)
    static let down = Color(red: 0.2, green: 0.85, blue: 0.4)
}

// MARK: - 数据

struct HealthEntry: TimelineEntry {
    let date: Date
    var sleep: HealthService.Reading<HealthService.SleepData>
    var weight: HealthService.Reading<HealthService.WeightData>
    var hrv: HealthService.Reading<HealthService.HRVData>
    var steps: HealthService.Reading<Int>

    static var sample: HealthEntry {
        HealthEntry(
            date: Date(),
            sleep: .init(value: .init(asleep: 25200, deep: 3600, core: 15000, rem: 6600, awake: 600, other: 0,
                                      bedtime: Date().addingTimeInterval(-36000), wake: Date().addingTimeInterval(-10800))),
            weight: .init(value: .init(kg: 65.2, date: Date(), previousKg: 65.5, previousDate: nil)),
            hrv: .init(value: .init(ms: 48, overnight: true, weekAverage: 45)),
            steps: .init(value: 6543, updated: Date())
        )
    }

    static func load() async -> HealthEntry {
        async let sleep = HealthService.load("sleep", keepFor: 18) { try await HealthService.lastNightSleep() }
        async let weight = HealthService.load("weight", keepFor: 72) { try await HealthService.latestWeight() }
        async let steps = HealthService.load("steps", keepFor: 12) { try await HealthService.todaySteps() }
        let s = await sleep
        let hrv = await HealthService.load("hrv", keepFor: 24) { try await HealthService.recentHRV(sleep: s.value) }
        return HealthEntry(date: Date(), sleep: s, weight: await weight, hrv: hrv, steps: await steps)
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
        .description("睡眠时间、体重、心率变异性、步数、日出日落")
        .supportedFamilies([.systemLarge])
        .contentMarginsDisabled() // 自己画底色，避免系统把底色提亮
    }
}

// MARK: - 视图

struct HealthWidgetView: View {
    let entry: HealthEntry

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                sleepCell
                weightCell
            }
            .frame(maxHeight: .infinity, alignment: .top)

            divider

            HStack(alignment: .top, spacing: 12) {
                hrvCell
                stepsCell
            }
            .padding(.vertical, 10)

            divider

            SunRow()
                .padding(.top, 10)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(widgetBackground)
        .containerBackground(widgetBackground, for: .widget)
    }

    private var divider: some View {
        Rectangle().fill(Color.secondary.opacity(0.2)).frame(height: 0.5)
    }

    // 睡眠：圆环 + 时长 + 入睡/醒来
    private var sleepCell: some View {
        let s = entry.sleep.value
        return VStack(alignment: .leading, spacing: 2) {
            SleepRing(sleep: s)
                .padding(.bottom, 8)
            caption("睡眠时间")
            bigValue(s.map { HealthFormat.duration($0.asleep) } ?? "--")
            foot(entry.sleep.note ?? s.flatMap { d in
                guard let b = d.bedtime, let w = d.wake else { return nil }
                return HealthFormat.time(b) + " - " + HealthFormat.time(w)
            } ?? " ")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // 体重：图标 + 数值 + 和前一次比较的箭头
    private var weightCell: some View {
        let w = entry.weight.value
        return VStack(alignment: .leading, spacing: 2) {
            badge("scalemass.fill", HealthColor.weight)
                .padding(.bottom, 8)
            caption("体重")
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                bigValue(w.map { HealthFormat.kg($0.kg) } ?? "--")
                if w != nil { unit("公斤") }
                if let w, let p = w.previousKg { trend(w.kg - p) }
            }
            foot(entry.weight.note ?? w.map(weightFoot) ?? " ")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func weightFoot(_ w: HealthService.WeightData) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(w.date) { return w.previousKg == nil ? "今天" : "今天 · 比前一次" }
        if cal.isDateInYesterday(w.date) { return "昨天记录" }
        let c = cal.dateComponents([.month, .day], from: w.date)
        return "\(c.month ?? 0)月\(c.day ?? 0)日记录"
    }

    private var hrvCell: some View {
        let h = entry.hrv.value
        var footText = entry.hrv.note ?? " "
        if entry.hrv.note == nil, let h {
            footText = h.overnight ? "昨晚平均" : "最近一次"
            if let a = h.weekAverage { footText += " · 7日 \(Int(a.rounded()))" }
        }
        return smallCell(icon: "waveform.path.ecg", color: HealthColor.hrv, title: "心率变异性",
                         value: h.map { String(Int($0.ms.rounded())) } ?? "--", unit: h == nil ? "" : "毫秒", foot: footText)
    }

    private var stepsCell: some View {
        var value = "--"
        var footText = entry.steps.note ?? " "
        if let s = entry.steps.value, let t = entry.steps.updated, Calendar.current.isDateInToday(t) {
            value = s.formatted()
            if entry.steps.note == nil { footText = HealthFormat.time(t) + " 更新" }
        }
        return smallCell(icon: "figure.walk", color: HealthColor.steps, title: "今日步数", value: value, unit: "", foot: footText)
    }

    private func smallCell(icon: String, color: Color, title: String, value: String, unit u: String, foot f: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(color)
                caption(title)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if !u.isEmpty { unit(u) }
            }
            foot(f)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 小零件

    private func caption(_ t: String) -> some View {
        Text(t).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
    }

    private func bigValue(_ t: String) -> some View {
        Text(t)
            .font(.system(size: 24, weight: .bold, design: .rounded).monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }

    private func unit(_ t: String) -> some View {
        Text(t).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }

    private func foot(_ t: String) -> some View {
        Text(t).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
    }

    private func badge(_ symbol: String, _ color: Color) -> some View {
        ZStack {
            Circle().fill(color.opacity(0.18))
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(color)
        }
        .frame(width: 64, height: 64)
    }

    @ViewBuilder
    private func trend(_ t: Double) -> some View {
        if abs(t) < 0.05 {
            Image(systemName: "minus").font(.caption.weight(.bold)).foregroundStyle(.secondary)
        } else {
            HStack(spacing: 1) {
                Image(systemName: t > 0 ? "arrow.up" : "arrow.down")
                Text(String(format: "%.1f", abs(t)))
            }
            .font(.subheadline.weight(.bold).monospacedDigit())
            .foregroundStyle(t > 0 ? HealthColor.up : HealthColor.down)
        }
    }
}

/// 睡眠圆环：深睡 / 核心 / 快速眼动三段，中间是小时数
struct SleepRing: View {
    let sleep: HealthService.SleepData?

    private var segments: [(Double, Color)] {
        guard let s = sleep, s.asleep > 0 else { return [] }
        var list: [(Double, Color)] = []
        if s.deep > 0 { list.append((s.deep, HealthColor.deep)) }
        if s.core > 0 { list.append((s.core, HealthColor.core)) }
        if s.rem > 0 { list.append((s.rem, HealthColor.rem)) }
        if s.other > 0 { list.append((s.other, HealthColor.other)) }
        let total = list.reduce(0) { $0 + $1.0 }
        return list.map { ($0.0 / total, $0.1) }
    }

    var body: some View {
        let segs = segments
        let gap = segs.count > 1 ? 0.03 : 0
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 9)
            ForEach(Array(segs.enumerated()), id: \.offset) { i, seg in
                let start = segs.prefix(i).reduce(0) { $0 + $1.0 }
                Circle()
                    .trim(from: start + gap / 2, to: max(start + gap / 2, start + seg.0 - gap / 2))
                    .stroke(seg.1, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            if let s = sleep {
                Text(String(format: "%.1f", s.asleep / 3600))
                    .font(.system(size: 19, weight: .bold, design: .rounded).monospacedDigit())
            } else {
                Image(systemName: "bed.double.fill").font(.system(size: 20)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 58, height: 58)
        .padding(3)
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
                Image(systemName: icon).foregroundStyle(HealthColor.sun)
                Text(title).foregroundStyle(.secondary)
            }
            .font(.subheadline.weight(.medium))
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
            // 用压扁的半椭圆，横向占满
            let cx = w / 2, cy = h - 2
            let rx = w / 2 - 8, ry = h - 8
            let angle = Double.pi * (1 - progress)
            let sun = CGPoint(x: cx + rx * cos(angle), y: cy - ry * sin(angle))

            ZStack {
                Path { p in
                    for i in 0...40 {
                        let a = Double.pi * (1 - Double(i) / 40)
                        let pt = CGPoint(x: cx + rx * cos(a), y: cy - ry * sin(a))
                        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                    }
                }
                .stroke(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [3, 4]))

                Path { p in
                    p.move(to: CGPoint(x: 0, y: cy))
                    p.addLine(to: CGPoint(x: w, y: cy))
                }
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)

                Circle()
                    .fill(daytime ? HealthColor.sun : Color.secondary.opacity(0.5))
                    .frame(width: 12, height: 12)
                    .shadow(color: daytime ? HealthColor.sun.opacity(0.7) : .clear, radius: 4)
                    .position(daytime ? sun : CGPoint(x: now < rise ? cx - rx : cx + rx, y: cy))
            }
        }
    }
}
