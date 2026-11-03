import WidgetKit
import SwiftUI

// 健康小组件，小 / 中 / 大三种尺寸，样式照系统「睡眠评分」，每项一种颜色：
// 小号：五行，图标 + 数值
// 中号：左边睡眠圆环，右边体重 / 心率变异性 / 步数 / 日出日落
// 大号：睡眠 | 体重，心率变异性 | 步数，最下面日出日落弧线

// MARK: - 颜色（参考健康 App 各分类的颜色）

struct Theme {
    let top: Color
    let bottom: Color
    var gradient: LinearGradient { LinearGradient(colors: [top, bottom], startPoint: .topLeading, endPoint: .bottomTrailing) }
    var text: Color { top }

    static let sleep = Theme(top: Color(red: 0.42, green: 0.86, blue: 1.0), bottom: Color(red: 0.30, green: 0.45, blue: 0.98))
    static let weight = Theme(top: Color(red: 0.80, green: 0.55, blue: 1.0), bottom: Color(red: 0.55, green: 0.32, blue: 0.95))
    static let hrv = Theme(top: Color(red: 1.0, green: 0.45, blue: 0.55), bottom: Color(red: 0.95, green: 0.22, blue: 0.42))
    static let steps = Theme(top: Color(red: 1.0, green: 0.72, blue: 0.25), bottom: Color(red: 1.0, green: 0.45, blue: 0.18))
    static let sun = Theme(top: Color(red: 1.0, green: 0.86, blue: 0.30), bottom: Color(red: 1.0, green: 0.55, blue: 0.15))
}

enum HealthColor {
    static let deep = Color(red: 0.30, green: 0.36, blue: 0.95)
    static let core = Color(red: 0.25, green: 0.60, blue: 1.0)
    static let rem = Color(red: 0.42, green: 0.86, blue: 1.0)
    static let other = Color(red: 0.36, green: 0.62, blue: 0.95)
    static let up = Color(red: 1.0, green: 0.42, blue: 0.35)
    static let down = Color(red: 0.25, green: 0.88, blue: 0.45)
}

enum Icon {
    static let sleep = "bed.double.fill"
    static let weight = "figure"
    static let hrv = "waveform.path.ecg"
    static let steps = "figure.walk"
    static let sun = "sun.horizon.fill"
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
            weight: .init(value: .init(kg: 65.25, date: Date(), previousKg: 65.52, previousDate: nil)),
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

    // 各项显示用的文字

    var sleepValue: String { sleep.value.map { HealthFormat.duration($0.asleep) } ?? "--" }
    var sleepFoot: String {
        if let n = sleep.note { return n }
        guard let d = sleep.value, let b = d.bedtime, let w = d.wake else { return " " }
        return HealthFormat.time(b) + " - " + HealthFormat.time(w)
    }

    var weightValue: String { weight.value.map { HealthFormat.kg($0.kg) } ?? "--" }
    var weightTrend: Double? {
        guard let w = weight.value, let p = w.previousKg else { return nil }
        return w.kg - p
    }
    var weightFoot: String {
        if let n = weight.note { return n }
        guard let w = weight.value else { return " " }
        let cal = Calendar.current
        if cal.isDateInToday(w.date) { return w.previousKg == nil ? "今天" : "今天 · 比前一次" }
        if cal.isDateInYesterday(w.date) { return "昨天记录" }
        let c = cal.dateComponents([.month, .day], from: w.date)
        return "\(c.month ?? 0)月\(c.day ?? 0)日记录"
    }

    var hrvValue: String { hrv.value.map { String(Int($0.ms.rounded())) } ?? "--" }
    var hrvFoot: String {
        if let n = hrv.note { return n }
        guard let h = hrv.value else { return " " }
        var t = h.overnight ? "昨晚平均" : "最近一次"
        if let a = h.weekAverage { t += " · 7日 \(Int(a.rounded()))" }
        return t
    }

    var stepsValue: String {
        guard let s = steps.value, let t = steps.updated, Calendar.current.isDateInToday(t) else { return "--" }
        return s.formatted()
    }
    var stepsFoot: String {
        if let n = steps.note { return n }
        guard let t = steps.updated, Calendar.current.isDateInToday(t) else { return " " }
        return HealthFormat.time(t) + " 更新"
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
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled() // 自己画底色，避免系统把底色提亮
    }
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
        .padding(.horizontal, family == .systemSmall ? 14 : 18)
        .padding(.vertical, family == .systemSmall ? 14 : 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(widgetBackground)
        .containerBackground(widgetBackground, for: .widget)
    }
}

// MARK: - 小号

struct SmallHealthView: View {
    let entry: HealthEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row(Icon.sleep, .sleep, entry.sleepValue)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                IconBadge(symbol: Icon.weight, theme: .weight, size: 22)
                ValueText(entry.weightValue, size: 15)
                if let t = entry.weightTrend { TrendView(delta: t, compact: true) }
            }
            Spacer(minLength: 0)
            row(Icon.hrv, .hrv, entry.hrvValue, unit: entry.hrv.value == nil ? "" : "毫秒")
            Spacer(minLength: 0)
            row(Icon.steps, .steps, entry.stepsValue, unit: entry.stepsValue == "--" ? "" : "步")
            Spacer(minLength: 0)
            row(Icon.sun, .sun, SunTimes.times().map { HealthFormat.time($0.sunrise) + " / " + HealthFormat.time($0.sunset) } ?? "--")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ icon: String, _ theme: Theme, _ value: String, unit: String = "") -> some View {
        HStack(spacing: 6) {
            IconBadge(symbol: icon, theme: theme, size: 22)
            ValueText(value, size: 15)
            if !unit.isEmpty { UnitText(unit, theme: theme) }
        }
    }
}

// MARK: - 中号

struct MediumHealthView: View {
    let entry: HealthEntry

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                SleepRing(sleep: entry.sleep.value, size: 58)
                    .padding(.bottom, 6)
                CaptionText("睡眠时间", theme: .sleep)
                ValueText(entry.sleepValue, size: 22)
                FootText(entry.sleepFoot)
            }
            .frame(width: 120, alignment: .leading)

            VStack(spacing: 0) {
                line(Icon.weight, .weight, "体重") {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        ValueText(entry.weightValue, size: 16)
                        if entry.weight.value != nil { UnitText("公斤", theme: .weight) }
                        if let t = entry.weightTrend { TrendView(delta: t, compact: true) }
                    }
                }
                Spacer(minLength: 0)
                line(Icon.hrv, .hrv, "心率变异性") {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        ValueText(entry.hrvValue, size: 16)
                        if entry.hrv.value != nil { UnitText("毫秒", theme: .hrv) }
                    }
                }
                Spacer(minLength: 0)
                line(Icon.steps, .steps, "今日步数") {
                    ValueText(entry.stepsValue, size: 16)
                }
                Spacer(minLength: 0)
                line(Icon.sun, .sun, "日出日落") {
                    ValueText(SunTimes.times().map { HealthFormat.time($0.sunrise) + " / " + HealthFormat.time($0.sunset) } ?? "--", size: 16)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func line<V: View>(_ icon: String, _ theme: Theme, _ title: String, @ViewBuilder value: () -> V) -> some View {
        HStack(spacing: 7) {
            IconBadge(symbol: icon, theme: theme, size: 22)
            CaptionText(title, theme: theme, size: 13)
                .lineLimit(1)
            Spacer(minLength: 4)
            value()
        }
    }
}

// MARK: - 大号

struct LargeHealthView: View {
    let entry: HealthEntry

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    SleepRing(sleep: entry.sleep.value, size: 58)
                        .padding(.bottom, 8)
                    CaptionText("睡眠时间", theme: .sleep)
                    ValueText(entry.sleepValue, size: 24)
                    FootText(entry.sleepFoot)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    IconBadge(symbol: Icon.weight, theme: .weight, size: 64)
                        .padding(.bottom, 8)
                    CaptionText("体重", theme: .weight)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        ValueText(entry.weightValue, size: 24)
                        if entry.weight.value != nil { UnitText("公斤", theme: .weight) }
                        if let t = entry.weightTrend { TrendView(delta: t, compact: false) }
                    }
                    FootText(entry.weightFoot)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity, alignment: .top)

            Divider().overlay(Color.secondary.opacity(0.2))

            HStack(alignment: .top, spacing: 12) {
                cell(Icon.hrv, .hrv, "心率变异性", entry.hrvValue, unit: entry.hrv.value == nil ? "" : "毫秒", foot: entry.hrvFoot)
                cell(Icon.steps, .steps, "今日步数", entry.stepsValue, unit: "", foot: entry.stepsFoot)
            }
            .padding(.vertical, 10)

            Divider().overlay(Color.secondary.opacity(0.2))

            SunRow()
                .padding(.top, 10)
        }
    }

    private func cell(_ icon: String, _ theme: Theme, _ title: String, _ value: String, unit: String, foot: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                IconBadge(symbol: icon, theme: theme, size: 22)
                CaptionText(title, theme: theme)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                ValueText(value, size: 22)
                if !unit.isEmpty { UnitText(unit, theme: theme) }
            }
            FootText(foot)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 零件

/// 渐变圆底 + 白色图标
struct IconBadge: View {
    let symbol: String
    let theme: Theme
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(theme.gradient)
            Image(systemName: symbol)
                .font(.system(size: size * 0.48, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

struct CaptionText: View {
    let text: String
    let theme: Theme
    var size: CGFloat = 15
    init(_ text: String, theme: Theme, size: CGFloat = 15) {
        self.text = text; self.theme = theme; self.size = size
    }
    var body: some View {
        Text(text).font(.system(size: size, weight: .semibold)).foregroundStyle(theme.text)
    }
}

struct ValueText: View {
    let text: String
    let size: CGFloat
    init(_ text: String, size: CGFloat) { self.text = text; self.size = size }
    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .bold, design: .rounded).monospacedDigit())
            .foregroundStyle(text == "--" ? Color.secondary : Color.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }
}

struct UnitText: View {
    let text: String
    let theme: Theme
    init(_ text: String, theme: Theme) { self.text = text; self.theme = theme }
    var body: some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(theme.text.opacity(0.85))
    }
}

struct FootText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
    }
}

/// 体重变化：变重红色 ↑，变轻绿色 ↓
struct TrendView: View {
    let delta: Double
    let compact: Bool

    var body: some View {
        if abs(delta) < 0.005 {
            Image(systemName: "minus")
                .font((compact ? Font.caption2 : .caption).weight(.bold))
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 1) {
                Image(systemName: delta > 0 ? "arrow.up" : "arrow.down")
                if !compact { Text(String(format: "%.2f", abs(delta))) }
            }
            .font((compact ? Font.caption : .subheadline).weight(.heavy).monospacedDigit())
            .foregroundStyle(delta > 0 ? HealthColor.up : HealthColor.down)
        }
    }
}

/// 睡眠圆环：深睡 / 核心 / 快速眼动三段，中间是小时数
struct SleepRing: View {
    let sleep: HealthService.SleepData?
    var size: CGFloat = 58

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
        let lw = size * 0.155
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.2), lineWidth: lw)
            ForEach(Array(segs.enumerated()), id: \.offset) { i, seg in
                let start = segs.prefix(i).reduce(0) { $0 + $1.0 }
                Circle()
                    .trim(from: start + gap / 2, to: max(start + gap / 2, start + seg.0 - gap / 2))
                    .stroke(seg.1, style: StrokeStyle(lineWidth: lw, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            if let s = sleep {
                Text(String(format: "%.1f", s.asleep / 3600))
                    .font(.system(size: size * 0.33, weight: .bold, design: .rounded).monospacedDigit())
            } else {
                Image(systemName: Icon.sleep).font(.system(size: size * 0.33)).foregroundStyle(Theme.sleep.text)
            }
        }
        .frame(width: size, height: size)
        .padding(lw / 2)
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
                Image(systemName: icon)
                    .symbolRenderingMode(.multicolor)
                Text(title).foregroundStyle(Theme.sun.text)
            }
            .font(.system(size: 15, weight: .semibold))
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
            let cx = w / 2, cy = h - 2
            let rx = w / 2 - 8, ry = h - 8
            let angle = Double.pi * (1 - progress)
            let sun = CGPoint(x: cx + rx * cos(angle), y: cy - ry * sin(angle))

            ZStack {
                // 已经走过的部分用橙色实线，没走到的用虚线
                Path { p in arc(&p, cx, cy, rx, ry, from: 0, to: 1) }
                    .stroke(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [3, 4]))
                if daytime {
                    Path { p in arc(&p, cx, cy, rx, ry, from: 0, to: progress) }
                        .stroke(Theme.sun.gradient, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                }
                Path { p in
                    p.move(to: CGPoint(x: 0, y: cy))
                    p.addLine(to: CGPoint(x: w, y: cy))
                }
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)

                Circle()
                    .fill(daytime ? AnyShapeStyle(Theme.sun.gradient) : AnyShapeStyle(Color.secondary.opacity(0.5)))
                    .frame(width: 12, height: 12)
                    .shadow(color: daytime ? Theme.sun.bottom.opacity(0.8) : .clear, radius: 4)
                    .position(daytime ? sun : CGPoint(x: now < rise ? cx - rx : cx + rx, y: cy))
            }
        }
    }

    private func arc(_ p: inout Path, _ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat, from: Double, to: Double) {
        let steps = 40
        for i in 0...steps {
            let f = from + (to - from) * Double(i) / Double(steps)
            let a = Double.pi * (1 - f)
            let pt = CGPoint(x: cx + rx * cos(a), y: cy - ry * sin(a))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
    }
}
