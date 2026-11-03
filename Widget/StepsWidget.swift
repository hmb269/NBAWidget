import WidgetKit
import SwiftUI

// 仿系统「睡眠评分」小组件的样式：上面一个圆环/图标，下面灰色标题 + 大号数值 + 一行小字。
// 每项一个小号小组件，自己在桌面上摆位置。

// MARK: - 颜色

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

// MARK: - 卡片模型

enum CardTop {
    case sleepRing(HealthService.SleepData?)
    case badge(String, Color)
    case sun(rise: Date, set: Date)
}

struct CardModel {
    var top: CardTop
    var caption: String
    var value: String
    var unit: String = ""
    var trend: Double? = nil   // 体重：和前一天的差值
    var foot: String = " "
}

struct HealthEntry: TimelineEntry {
    let date: Date
    let card: CardModel
}

// MARK: - 每项数据怎么读、怎么显示

enum HealthMetric {
    case sleep, weight, hrv, steps, sun

    var refreshMinutes: Int {
        switch self {
        case .steps: return 15
        case .sun: return 30
        default: return 60
        }
    }

    func placeholder() -> CardModel {
        switch self {
        case .sleep:
            return CardModel(top: .sleepRing(.init(asleep: 27000, deep: 4200, core: 16000, rem: 6800, awake: 600, other: 0, bedtime: nil, wake: nil)),
                             caption: "睡眠时间", value: "7小时30分", foot: "23:40 - 7:20")
        case .weight:
            return CardModel(top: .badge("scalemass.fill", HealthColor.weight), caption: "体重", value: "65.2", unit: "公斤", trend: -0.3, foot: "比前一天")
        case .hrv:
            return CardModel(top: .badge("waveform.path.ecg", HealthColor.hrv), caption: "心率变异性", value: "48", unit: "毫秒", foot: "昨晚平均 · 7日 45")
        case .steps:
            return CardModel(top: .badge("figure.walk", HealthColor.steps), caption: "今日步数", value: "6,543", foot: "10:30 更新")
        case .sun:
            let t = SunTimes.times() ?? (sunrise: Date(), sunset: Date())
            return sunCard(t)
        }
    }

    func load() async -> CardModel {
        switch self {
        case .sleep:
            let r = await HealthService.load("sleep", keepFor: 18) { try await HealthService.lastNightSleep() }
            var c = CardModel(top: .sleepRing(r.value), caption: "睡眠时间", value: "--")
            if let s = r.value {
                c.value = HealthFormat.duration(s.asleep)
                if let b = s.bedtime, let w = s.wake { c.foot = HealthFormat.time(b) + " - " + HealthFormat.time(w) }
            }
            if let n = r.note { c.foot = n }
            return c

        case .weight:
            let r = await HealthService.load("weight", keepFor: 72) { try await HealthService.latestWeight() }
            var c = CardModel(top: .badge("scalemass.fill", HealthColor.weight), caption: "体重", value: "--", unit: "公斤")
            if let w = r.value {
                c.value = HealthFormat.kg(w.kg)
                let cal = Calendar.current
                let when = cal.isDateInToday(w.date) ? "今天" : (cal.isDateInYesterday(w.date) ? "昨天" : monthDay(w.date))
                if let p = w.previousKg {
                    c.trend = w.kg - p
                    c.foot = "\(when) · 比前一次"
                } else {
                    c.foot = "\(when)记录"
                }
            }
            if let n = r.note { c.foot = n }
            return c

        case .hrv:
            let r = await HealthService.load("hrv", keepFor: 24) { () async throws -> HealthService.HRVData? in
                let sleep = try? await HealthService.lastNightSleep()
                return try await HealthService.recentHRV(sleep: sleep)
            }
            var c = CardModel(top: .badge("waveform.path.ecg", HealthColor.hrv), caption: "心率变异性", value: "--", unit: "毫秒")
            if let h = r.value {
                c.value = String(Int(h.ms.rounded()))
                var foot = h.overnight ? "昨晚平均" : "最近一次"
                if let a = h.weekAverage { foot += " · 7日 \(Int(a.rounded()))" }
                c.foot = foot
            }
            if let n = r.note { c.foot = n }
            return c

        case .steps:
            let r = await HealthService.load("steps", keepFor: 12) { try await HealthService.todaySteps() }
            var c = CardModel(top: .badge("figure.walk", HealthColor.steps), caption: "今日步数", value: "--")
            // 缓存是昨天的就不显示
            if let s = r.value, let t = r.updated, Calendar.current.isDateInToday(t) {
                c.value = s.formatted()
                c.foot = HealthFormat.time(t) + " 更新"
            }
            if let n = r.note { c.foot = n }
            return c

        case .sun:
            guard let t = SunTimes.times() else {
                return CardModel(top: .badge("sun.max.fill", HealthColor.sun), caption: "日出 / 日落", value: "--")
            }
            return sunCard(t)
        }
    }

    private func sunCard(_ t: (sunrise: Date, sunset: Date)) -> CardModel {
        let now = Date()
        let foot: String
        if now < t.sunrise {
            foot = "距日出 " + HealthFormat.duration(t.sunrise.timeIntervalSince(now))
        } else if now < t.sunset {
            foot = "距日落 " + HealthFormat.duration(t.sunset.timeIntervalSince(now))
        } else {
            foot = "白昼 " + HealthFormat.duration(t.sunset.timeIntervalSince(t.sunrise))
        }
        return CardModel(top: .sun(rise: t.sunrise, set: t.sunset), caption: "日出 / 日落",
                         value: HealthFormat.time(t.sunrise) + " / " + HealthFormat.time(t.sunset), foot: foot)
    }

    private func monthDay(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.month, .day], from: d)
        return "\(c.month ?? 0)月\(c.day ?? 0)日"
    }
}

struct HealthProvider: TimelineProvider {
    let metric: HealthMetric

    func placeholder(in context: Context) -> HealthEntry {
        HealthEntry(date: Date(), card: metric.placeholder())
    }

    func getSnapshot(in context: Context, completion: @escaping (HealthEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
            return
        }
        Task { completion(HealthEntry(date: Date(), card: await metric.load())) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HealthEntry>) -> Void) {
        Task {
            let entry = HealthEntry(date: Date(), card: await metric.load())
            let next = Calendar.current.date(byAdding: .minute, value: metric.refreshMinutes, to: Date())!
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }
}

// MARK: - 五个小组件

private func healthWidget(kind: String, metric: HealthMetric, name: String, desc: String) -> some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: HealthProvider(metric: metric)) { entry in
        HealthCardView(card: entry.card)
    }
    .configurationDisplayName(name)
    .description(desc)
    .supportedFamilies([.systemSmall])
}

struct SleepWidget: Widget {
    var body: some WidgetConfiguration {
        healthWidget(kind: "HealthSleep", metric: .sleep, name: "睡眠时间", desc: "昨晚睡了多久，圆环是深睡 / 核心 / 快速眼动的比例")
    }
}

struct WeightWidget: Widget {
    var body: some WidgetConfiguration {
        healthWidget(kind: "HealthWeight", metric: .weight, name: "体重", desc: "最新体重，和前一天比较：↑ 变重，↓ 变轻")
    }
}

struct HRVWidget: Widget {
    var body: some WidgetConfiguration {
        healthWidget(kind: "HealthHRV", metric: .hrv, name: "心率变异性", desc: "昨晚睡眠期间的平均 HRV，越高说明恢复越好")
    }
}

struct StepsWidget: Widget {
    var body: some WidgetConfiguration {
        healthWidget(kind: "HealthSteps", metric: .steps, name: "今日步数", desc: "今天走了多少步（iPhone + 手表合并）")
    }
}

struct SunWidget: Widget {
    var body: some WidgetConfiguration {
        healthWidget(kind: "HealthSun", metric: .sun, name: "日出日落", desc: "玉林今天的日出、日落时间")
    }
}

// MARK: - 卡片视图

struct HealthCardView: View {
    let card: CardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            top
                .frame(height: 56)
            Spacer(minLength: 4)
            Text(card.caption)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            valueRow
            Text(card.foot)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.top, 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(widgetBackground, for: .widget)
    }

    private var valueRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(card.value)
                .font(.system(size: 24, weight: .bold, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if !card.unit.isEmpty && card.value != "--" {
                Text(card.unit)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if let t = card.trend {
                trendView(t)
            }
        }
    }

    @ViewBuilder
    private func trendView(_ t: Double) -> some View {
        if abs(t) < 0.05 {
            Image(systemName: "minus")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 1) {
                Image(systemName: t > 0 ? "arrow.up" : "arrow.down")
                Text(String(format: "%.1f", abs(t)))
            }
            .font(.caption.weight(.bold).monospacedDigit())
            .foregroundStyle(t > 0 ? HealthColor.up : HealthColor.down)
        }
    }

    @ViewBuilder
    private var top: some View {
        switch card.top {
        case .sleepRing(let s):
            SleepRing(sleep: s)
        case .badge(let symbol, let color):
            ZStack {
                Circle().fill(color.opacity(0.18))
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(color)
            }
            .frame(width: 56, height: 56)
        case .sun(let rise, let set):
            SunArc(rise: rise, set: set)
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
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 8)
            let segs = segments
            let gap = segs.count > 1 ? 0.025 : 0
            ForEach(Array(segs.enumerated()), id: \.offset) { i, seg in
                let start = segs.prefix(i).reduce(0) { $0 + $1.0 }
                Circle()
                    .trim(from: start + gap / 2, to: max(start + gap / 2, start + seg.0 - gap / 2))
                    .stroke(seg.1, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            if let s = sleep {
                Text(String(format: "%.1f", s.asleep / 3600))
                    .font(.system(size: 17, weight: .bold, design: .rounded).monospacedDigit())
            } else {
                Image(systemName: "bed.double.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 52, height: 52)
        .padding(2)
    }
}

/// 日出日落：一道弧线，太阳在当前位置
struct SunArc: View {
    let rise: Date
    let set: Date

    var body: some View {
        GeometryReader { geo in
            let w = min(geo.size.width, 110.0)
            let h = geo.size.height
            let progress = min(max(Date().timeIntervalSince(rise) / set.timeIntervalSince(rise), 0), 1)
            let daytime = Date() >= rise && Date() <= set
            let center = CGPoint(x: w / 2, y: h - 4)
            let r = min(w / 2 - 6, h - 10)
            let angle = Double.pi * (1 - progress)
            let sunPoint = CGPoint(x: center.x + r * cos(angle), y: center.y - r * sin(angle))

            ZStack(alignment: .topLeading) {
                Path { p in
                    p.addArc(center: center, radius: r, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
                }
                .stroke(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 2, dash: [3, 4]))

                Path { p in
                    p.move(to: CGPoint(x: center.x - r - 4, y: center.y))
                    p.addLine(to: CGPoint(x: center.x + r + 4, y: center.y))
                }
                .stroke(Color.secondary.opacity(0.35), lineWidth: 1)

                Circle()
                    .fill(daytime ? HealthColor.sun : Color.secondary.opacity(0.5))
                    .frame(width: 14, height: 14)
                    .shadow(color: daytime ? HealthColor.sun.opacity(0.7) : .clear, radius: 5)
                    .position(daytime ? sunPoint : CGPoint(x: Date() < rise ? center.x - r : center.x + r, y: center.y))
            }
        }
    }
}
