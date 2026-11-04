import WidgetKit
import SwiftUI
import HealthKit
import AppIntents

// 喝水小组件：默认每天 4 杯 × 350 ml，喝一杯点一下杯子打勾；少一杯算达标，全部喝完算喝满。
// 杯子形状、每杯毫升、每天杯数在 App「设置」里改（通过相簿名传给小组件，见 WaterSettings）。
// 记录存在小组件自己这里（每天零点自动清空），同时尽量写进「健康 → 饮水」。

enum WaterLog {
    static var cupML: Double { Double(WaterSettings.current.ml) }
    static var goal: Int { WaterSettings.current.cups }
    static var enough: Int { WaterSettings.current.enough }
    private static let d = UserDefaults.standard

    private static var todayKey: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    /// 今天每一杯是几点喝的
    static var times: [Date] {
        guard d.string(forKey: "waterDay") == todayKey else { return [] }
        return (d.array(forKey: "waterTimes") as? [Double] ?? []).map(Date.init(timeIntervalSince1970:))
    }
    static var count: Int { times.count }
    private static var healthIDs: [String] {
        d.string(forKey: "waterDay") == todayKey ? (d.stringArray(forKey: "waterHK") ?? []) : []
    }

    /// 今天每一杯的毫升数（中途改了杯子大小，之前喝的按当时的算）
    static var mls: [Double] {
        let t = times.count
        var m = d.string(forKey: "waterDay") == todayKey ? (d.array(forKey: "waterML") as? [Double] ?? []) : []
        if m.count > t { m = Array(m.prefix(t)) }
        while m.count < t { m.append(cupML) }
        return m
    }
    static var totalML: Int { Int(mls.reduce(0, +)) }

    private static func save(_ t: [Date], _ ids: [String]) {
        var m = mls
        if m.count > t.count { m = Array(m.prefix(t.count)) }
        while m.count < t.count { m.append(cupML) }
        d.set(m, forKey: "waterML")
        d.set(todayKey, forKey: "waterDay")
        d.set(t.map(\.timeIntervalSince1970), forKey: "waterTimes")
        d.set(ids, forKey: "waterHK")
    }

    // 撤销要点两次：先点最后一杯 → 变成「再点撤销」，8 秒内再点一次才真正撤销
    static let undoWindow: TimeInterval = 8
    static var undoArmedAt: Date? {
        let t = d.double(forKey: "waterUndo")
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }
    static func undoArmed(at now: Date = Date()) -> Bool {
        guard let a = undoArmedAt else { return false }
        return now.timeIntervalSince(a) >= 0 && now.timeIntervalSince(a) < undoWindow
    }
    static func clearUndo() { d.removeObject(forKey: "waterUndo") }

    /// 点第 i 个杯子：
    /// - 空杯：只加一杯（不会一下子加好几杯）
    /// - 最后一杯：第一次点进入「再点撤销」，8 秒内再点才撤销
    /// - 前面已打勾的杯子：不动
    static func tap(_ i: Int) async {
        var t = times
        var ids = healthIDs
        if i < t.count {
            guard i == t.count - 1 else { clearUndo(); return }
            if undoArmed() {
                clearUndo()
                let removed = ids.count == t.count ? [ids.removeLast()] : []
                t.removeLast()
                if ids.count > t.count { ids = Array(ids.prefix(t.count)) }
                save(t, ids)
                await deleteFromHealth(removed)
            } else {
                d.set(Date().timeIntervalSince1970, forKey: "waterUndo")
            }
        } else {
            clearUndo()
            guard t.count < goal else { return }
            let now = Date()
            let id = await writeToHealth(now)
            ids = Array(ids.prefix(t.count))
            while ids.count < t.count { ids.append("") }
            t.append(now)
            ids.append(id ?? "")
            save(t, ids)
        }
    }

    // MARK: 健康（尽力而为：没授权就只记在小组件里）

    private static let store = HKHealthStore()
    private static let type = HKQuantityType(.dietaryWater)

    private static func writeToHealth(_ date: Date) async -> String? {
        guard HKHealthStore.isHealthDataAvailable(),
              store.authorizationStatus(for: type) == .sharingAuthorized else { return nil }
        let s = HKQuantitySample(type: type, quantity: HKQuantity(unit: .literUnit(with: .milli), doubleValue: cupML),
                                 start: date, end: date)
        do { try await store.save(s); return s.uuid.uuidString } catch { return nil }
    }

    private static func deleteFromHealth(_ ids: [String]) async {
        let uuids = Set(ids.compactMap(UUID.init(uuidString:)))
        guard !uuids.isEmpty, store.authorizationStatus(for: type) == .sharingAuthorized else { return }
        _ = try? await store.deleteObjects(of: type, predicate: HKQuery.predicateForObjects(with: uuids))
    }
}

struct DrinkWaterIntent: AppIntent {
    static var title: LocalizedStringResource = "喝了一杯水"
    static var isDiscoverable: Bool = false
    @Parameter(title: "第几杯") var index: Int
    init() {}
    init(index: Int) { self.index = index }
    func perform() async throws -> some IntentResult {
        await WaterLog.tap(index)
        return .result()
    }
}

// MARK: - 时间线：零点自动换新的一天

struct WaterEntry: TimelineEntry {
    let date: Date
}

struct WaterProvider: TimelineProvider {
    func placeholder(in context: Context) -> WaterEntry { WaterEntry(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (WaterEntry) -> Void) {
        completion(WaterEntry(date: Date()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<WaterEntry>) -> Void) {
        WaterSettings.refreshFromAlbum()
        let midnight = Calendar.current.startOfDay(for: Date().addingTimeInterval(86400)).addingTimeInterval(5)
        var entries = [WaterEntry(date: Date())]
        // 「再点撤销」8 秒后自动恢复成打勾的样子
        if let a = WaterLog.undoArmedAt, WaterLog.undoArmed() {
            entries.append(WaterEntry(date: a.addingTimeInterval(WaterLog.undoWindow)))
        }
        completion(Timeline(entries: entries, policy: .after(midnight)))
    }
}

struct WaterWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Water", provider: WaterProvider()) { entry in
            WaterWidgetView(now: entry.date)
        }
        .configurationDisplayName("喝水")
        .description("喝一杯点一下杯子打勾；撤销要连点两次最后一杯。杯子形状和容量在 App 设置里改。")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

// MARK: - 界面

struct WaterWidgetView: View {
    @Environment(\.widgetFamily) var family
    var now = Date()
    private let times = WaterLog.times
    private var undo: Bool { WaterLog.undoArmed(at: now) }
    private var count: Int { times.count }
    private var ml: Int { WaterLog.totalML }
    private let style = WaterSettings.current
    private var done: Bool { count >= WaterLog.enough }

    var body: some View {
        Group {
            if family == .systemSmall { small } else { medium }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RefreshBackground())
        .background(widgetBackground)
        .containerBackground(widgetBackground, for: .widget)
    }

    private var statusText: String {
        if undo { return "再点一次撤销第\(count)杯" }
        switch count {
        case 0: return "今天还没喝水"
        case WaterLog.goal...: return "今天喝满了 🎉"
        case WaterLog.enough: return "已达标，再来一杯"
        default: return "还差 \(WaterLog.enough - count) 杯达标"
        }
    }

    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: "drop.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: [waterCyan, waterBlue], startPoint: .top, endPoint: .bottom))
            Text("喝水").font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 0)
            Text("\(count)/\(WaterLog.goal)")
                .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(undo ? Color.orange : (done ? waterGreen : .secondary))
        }
    }

    private var amount: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text("\(ml)")
                .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(LinearGradient(colors: [waterCyan, waterBlue], startPoint: .top, endPoint: .bottom))
                .contentTransition(.numericText())
            Text("ml").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
        }
    }

    // 小号：标题 + 毫升数 + 四个杯子
    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Spacer(minLength: 4)
            amount
            Text(statusText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(undo ? Color.orange : (done ? waterGreen : .secondary))
                .lineLimit(1)
            Spacer(minLength: 6)
            if WaterLog.goal <= 4 {
                HStack(spacing: 5) {
                    ForEach(0..<WaterLog.goal, id: \.self) { i in
                        cupButton(i, height: 50, showTime: false)
                    }
                }
            } else {
                // 5、6 杯：分两行
                let perRow = (WaterLog.goal + 1) / 2
                VStack(spacing: 4) {
                    ForEach(0..<2, id: \.self) { row in
                        HStack(spacing: 6) {
                            ForEach(row * perRow..<min(WaterLog.goal, (row + 1) * perRow), id: \.self) { i in
                                cupButton(i, height: 27, showTime: false)
                            }
                            if row == 1 && WaterLog.goal % 2 == 1 { Color.clear.frame(maxWidth: .infinity) }
                        }
                    }
                }
            }
        }
    }

    // 中号：左边进度环，右边四个大杯子 + 每杯的时间
    private var medium: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                header.frame(width: 104)
                Spacer(minLength: 0)
                ring
                Spacer(minLength: 0)
                Text(statusText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(undo ? Color.orange : (done ? waterGreen : .secondary))
                    .lineLimit(1)
                    .frame(width: 104, alignment: .center)
            }
            .frame(width: 104)
            HStack(spacing: WaterLog.goal > 4 ? 5 : 10) {
                ForEach(0..<WaterLog.goal, id: \.self) { i in
                    cupButton(i, height: 86, showTime: true)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var ring: some View {
        let p = min(Double(count) / Double(WaterLog.goal), 1)
        return ZStack {
            Circle().stroke(waterBlue.opacity(0.15), lineWidth: 9)
            // 达标线的小刻度
            Circle()
                .trim(from: Double(WaterLog.enough) / Double(WaterLog.goal) - 0.005,
                      to: Double(WaterLog.enough) / Double(WaterLog.goal) + 0.005)
                .stroke(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: 9))
                .rotationEffect(.degrees(-90))
            Circle()
                .trim(from: 0, to: p)
                .stroke(AngularGradient(colors: [waterCyan, waterBlue, waterCyan], center: .center),
                        style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(ml)")
                    .font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
                Text("/ \(Int(Double(WaterLog.goal) * WaterLog.cupML)) ml")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 78, height: 78)
        .frame(maxWidth: .infinity)
    }

    private func cupButton(_ i: Int, height: CGFloat, showTime: Bool) -> some View {
        let filled = i < count
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return Button(intent: DrinkWaterIntent(index: i)) {
            VStack(spacing: 4) {
                let arming = undo && i == count - 1
                CupView(kind: style.kind, filled: filled, isNext: i == count && !undo, arming: arming,
                        time: filled ? f.string(from: times[i]) : nil, big: showTime)
                    .frame(height: height)
                if showTime {
                    Text(arming ? "再点撤销" : WaterLog.goal > 4 ? "\(i + 1)" : "第\(i + 1)杯")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(arming ? Color.orange : filled ? Color.primary.opacity(0.8) : Color.secondary.opacity(0.7))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

