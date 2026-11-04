import WidgetKit
import SwiftUI
import AppIntents

// 吃药小组件（默认：维生素D，隔天一颗）
// - 今天该吃：橙色胶囊发光，「今天要吃」，点一下记成已吃
// - 今天已吃：绿色胶囊，显示几点吃的、下次哪天吃
// - 今天不用吃：灰色胶囊，「今天不用吃」，告诉你明天吃
// 健康 App「用药」里记的「已服用」也算（只能读，不能写，苹果限制）

enum PillLog {
    private static let d = UserDefaults.standard
    static let armWindow: TimeInterval = 8

    /// 在小组件上点的「已吃」时间（保留 90 天）
    static var local: [Date] {
        (d.array(forKey: "pillTaken") as? [Double] ?? []).map(Date.init(timeIntervalSince1970:))
    }
    private static func setLocal(_ list: [Date]) {
        let cut = Date().addingTimeInterval(-90 * 86400)
        d.set(list.filter { $0 > cut }.map(\.timeIntervalSince1970), forKey: "pillTaken")
    }

    // 两步确认：撤销、或者今天不用吃却要记一颗
    static func armed(_ action: String, at now: Date = Date()) -> Bool {
        guard d.string(forKey: "pillArm") == action else { return false }
        let t = Date(timeIntervalSince1970: d.double(forKey: "pillArmAt"))
        return now.timeIntervalSince(t) >= 0 && now.timeIntervalSince(t) < armWindow
    }
    static var armedAt: Date? {
        d.string(forKey: "pillArm") == nil ? nil : Date(timeIntervalSince1970: d.double(forKey: "pillArmAt"))
    }
    static func clearArm() { d.removeObject(forKey: "pillArm") }
    private static func arm(_ action: String) {
        d.set(action, forKey: "pillArm")
        d.set(Date().timeIntervalSince1970, forKey: "pillArmAt")
    }

    static func perform(_ action: String) {
        let cal = Calendar.current
        switch action {
        case "take":
            clearArm()
            setLocal(local + [Date()])
        case "extra":
            if armed("extra") { clearArm(); setLocal(local + [Date()]) } else { arm("extra") }
        case "undo":
            if armed("undo") {
                clearArm()
                setLocal(local.filter { !cal.isDateInToday($0) })
            } else { arm("undo") }
        default:
            clearArm()
        }
    }
}

struct PillIntent: AppIntent {
    static var title: LocalizedStringResource = "记录吃药"
    static var isDiscoverable: Bool = false
    @Parameter(title: "动作") var action: String
    init() {}
    init(_ action: String) { self.action = action }
    func perform() async throws -> some IntentResult {
        PillLog.perform(action)
        return .result()
    }
}

// MARK: - 状态计算

struct PillStatus {
    enum Kind { case due, taken, rest }
    let kind: Kind
    let takenTime: Date?        // 今天几点吃的
    let takenInHealth: Bool     // 今天是在健康里记的
    let lastTaken: Date?        // 今天之前最后一次
    let next: Date              // 下一次该吃的日子
    let takenDays: Set<Date>    // 吃过的日子（当天零点）
    let settings: PillSettings

    init(local: [Date], health: [Date], settings s: PillSettings, now: Date = Date()) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let all = (local.map { ($0, false) } + health.map { ($0, true) }).sorted { $0.0 < $1.0 }
        settings = s
        takenDays = Set(all.map { cal.startOfDay(for: $0.0) })
        let todays = all.filter { cal.isDate($0.0, inSameDayAs: now) }
        takenTime = todays.first?.0
        takenInHealth = !todays.isEmpty && todays.allSatisfy { $0.1 }
        lastTaken = all.last { $0.0 < today }?.0

        if takenTime != nil {
            kind = .taken
            next = cal.date(byAdding: .day, value: s.every, to: today)!
        } else if let last = lastTaken {
            let gap = cal.dateComponents([.day], from: cal.startOfDay(for: last), to: today).day ?? 0
            if gap >= s.every {
                kind = .due; next = today
            } else {
                kind = .rest
                next = cal.date(byAdding: .day, value: s.every, to: cal.startOfDay(for: last))!
            }
        } else {
            kind = .due; next = today
        }
    }

    /// 离上次吃隔了几天（今天该吃时用）
    var gapDays: Int? {
        guard let last = lastTaken else { return nil }
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: last), to: cal.startOfDay(for: Date())).day
    }

    var nextText: String {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: next).day ?? 0
        switch days {
        case ...0: return "今天"
        case 1: return "明天"
        case 2: return "后天"
        default:
            let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "M月d日 EEE"
            return f.string(from: next)
        }
    }

    /// 某天是不是计划要吃的日子（从上次吃的那天往后每隔 every 天）
    func isPlanned(_ day: Date) -> Bool {
        let cal = Calendar.current
        guard day >= cal.startOfDay(for: Date()) else { return false }
        let base = kind == .taken ? cal.startOfDay(for: Date()) : next
        let diff = cal.dateComponents([.day], from: base, to: day).day ?? -1
        if kind == .taken { return diff > 0 && diff % settings.every == 0 }
        return diff >= 0 && diff % settings.every == 0
    }
}

// MARK: - 时间线

struct PillEntry: TimelineEntry {
    let date: Date
    let health: [Date]
}

struct PillProvider: TimelineProvider {
    func placeholder(in context: Context) -> PillEntry { PillEntry(date: Date(), health: []) }
    func getSnapshot(in context: Context, completion: @escaping (PillEntry) -> Void) {
        completion(PillEntry(date: Date(), health: []))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<PillEntry>) -> Void) {
        Task {
            PillSettings.refreshFromAlbum()
            let health = await MedsHealth.takenDates(matching: PillSettings.current.name)
            let now = Date()
            var entries = [PillEntry(date: now, health: health)]
            if let a = PillLog.armedAt, now.timeIntervalSince(a) < PillLog.armWindow {
                entries.append(PillEntry(date: a.addingTimeInterval(PillLog.armWindow), health: health))
            }
            // 零点换天；平时每 30 分钟看一眼健康里有没有新记录
            let midnight = Calendar.current.startOfDay(for: now.addingTimeInterval(86400)).addingTimeInterval(5)
            let next = min(midnight, now.addingTimeInterval(30 * 60))
            completion(Timeline(entries: entries, policy: .after(next)))
        }
    }
}

struct PillWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Pill", provider: PillProvider()) { entry in
            PillWidgetView(entry: entry)
        }
        .configurationDisplayName("吃药")
        .description("维生素D 隔天一颗：该吃时提醒，点一下记录已吃。健康 App 里记的「已服用」也会同步显示。")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

// MARK: - 界面

struct PillWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: PillEntry
    private let s = PillSettings.current

    private var st: PillStatus { PillStatus(local: PillLog.local, health: entry.health, settings: s, now: entry.date) }

    var body: some View {
        let st = st
        Group {
            if family == .systemSmall { small(st) } else { medium(st) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RefreshBackground())
        .background(widgetBackground)
        .containerBackground(widgetBackground, for: .widget)
    }

    // 点胶囊做什么
    private func action(_ st: PillStatus) -> String? {
        switch st.kind {
        case .due: return "take"
        case .rest: return "extra"
        case .taken: return st.takenInHealth ? nil : "undo"
        }
    }

    private var armedUndo: Bool { PillLog.armed("undo", at: entry.date) }
    private var armedExtra: Bool { PillLog.armed("extra", at: entry.date) }

    private func color(_ st: PillStatus) -> Color {
        if armedUndo || armedExtra { return .orange }
        switch st.kind {
        case .due: return pillOrange
        case .taken: return pillGreen
        case .rest: return Color.white.opacity(0.85)
        }
    }

    private func title(_ st: PillStatus) -> String {
        switch st.kind {
        case .due: return "今天要吃"
        case .taken: return "今天已吃"
        case .rest: return "今天不用吃"
        }
    }

    private func subtitle(_ st: PillStatus) -> String {
        if armedUndo { return "再点一次撤销" }
        if armedExtra { return "再点一次记一颗" }
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        switch st.kind {
        case .due:
            if let g = st.gapDays, g > s.every { return "已经隔了 \(g) 天 · 点胶囊记录" }
            return "吃了点一下胶囊"
        case .taken:
            let t = st.takenTime.map { f.string(from: $0) } ?? ""
            return t + (st.takenInHealth ? " 健康已记" : "") + " · 下次" + st.nextText
        case .rest:
            return st.nextText + "再吃"
        }
    }

    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: "pills.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(pillYellow)
            Text(s.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 0)
            Text(s.everyText)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.white.opacity(0.1)))
                .foregroundStyle(.secondary)
        }
    }

    private func pill(_ st: PillStatus, width: CGFloat) -> some View {
        let phase: PillCapsule.Phase = st.kind == .due ? .due : st.kind == .taken ? .taken : .rest
        let content = ZStack {
            PillCapsule(state: phase)
                .opacity(armedUndo ? 0.45 : 1)
            if st.kind == .taken || armedUndo {
                Image(systemName: armedUndo ? "arrow.uturn.backward.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: width * 0.3, weight: .bold))
                    .foregroundStyle(.white, armedUndo ? Color.orange : pillGreen)
                    .shadow(color: .black.opacity(0.3), radius: 3)
            } else if armedExtra {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: width * 0.3, weight: .bold))
                    .foregroundStyle(.white, Color.orange)
            }
        }
        .frame(width: width, height: width * 0.62)
        .contentShape(Rectangle())

        return Group {
            if let a = action(st) {
                Button(intent: PillIntent(a)) { content }.buttonStyle(.plain)
            } else {
                content
            }
        }
    }

    // 最近一周：前 3 天 + 今天 + 后 3 天
    private func strip(_ st: PillStatus, range: ClosedRange<Int>, showLabels: Bool) -> some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: entry.date)
        let wd = ["日", "一", "二", "三", "四", "五", "六"]
        return HStack(spacing: 0) {
            ForEach(Array(range), id: \.self) { off in
                let day = cal.date(byAdding: .day, value: off, to: today)!
                let taken = st.takenDays.contains(day)
                let planned = st.isPlanned(day)
                let isToday = off == 0
                VStack(spacing: 3) {
                    if showLabels {
                        Text(isToday ? "今" : wd[cal.component(.weekday, from: day) - 1])
                            .font(.system(size: 9, weight: isToday ? .bold : .medium))
                            .foregroundStyle(isToday ? Color.primary : Color.secondary)
                    }
                    ZStack {
                        if taken {
                            Circle().fill(pillGreen)
                            Image(systemName: "checkmark").font(.system(size: 7, weight: .heavy)).foregroundStyle(.white)
                        } else if planned {
                            Circle().stroke(pillOrange, lineWidth: 1.5)
                            Circle().fill(pillOrange.opacity(isToday ? 0.6 : 0.2)).padding(3)
                        } else {
                            Circle().fill(Color.white.opacity(0.12)).padding(4)
                        }
                    }
                    .frame(width: 14, height: 14)
                    .padding(2)
                    .overlay(Circle().stroke(isToday ? Color.white.opacity(0.6) : .clear, lineWidth: 1))
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func small(_ st: PillStatus) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Spacer(minLength: 2)
            HStack(alignment: .center, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(st))
                        .font(.system(size: st.kind == .rest ? 17 : 19, weight: .bold))
                        .foregroundStyle(color(st))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
            }
            Text(subtitle(st))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(armedUndo || armedExtra ? Color.orange : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 2)
            HStack {
                Spacer(minLength: 0)
                pill(st, width: 70)
                Spacer(minLength: 0)
            }
            Spacer(minLength: 2)
            strip(st, range: -3...3, showLabels: false)
        }
    }

    private func medium(_ st: PillStatus) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                header
                Spacer(minLength: 0)
                Text(title(st))
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(color(st))
                    .lineLimit(1)
                Text(subtitle(st))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(armedUndo || armedExtra ? Color.orange : .secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                strip(st, range: -3...3, showLabels: true)
            }
            .frame(width: 150)
            pill(st, width: 120)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
