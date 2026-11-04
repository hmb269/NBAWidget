import WidgetKit
import SwiftUI
import HealthKit
import AppIntents

// 喝水小组件：每天 4 杯 × 350 ml，喝一杯点一下杯子打勾；3 杯达标，4 杯喝满。
// 记录存在小组件自己这里（每天零点自动清空），同时尽量写进「健康 → 饮水」。

private let waterBlue = Color(red: 0.30, green: 0.68, blue: 1.0)
private let waterCyan = Color(red: 0.35, green: 0.90, blue: 0.95)
private let waterGreen = Color(red: 0.30, green: 0.85, blue: 0.55)

enum WaterLog {
    static let cupML = 350.0
    static let goal = 4      // 一天 4 杯
    static let enough = 3    // 3 杯算达标
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

    private static func save(_ t: [Date], _ ids: [String]) {
        d.set(todayKey, forKey: "waterDay")
        d.set(t.map(\.timeIntervalSince1970), forKey: "waterTimes")
        d.set(ids, forKey: "waterHK")
    }

    /// 点第 i 个杯子：空杯 → 喝到这一杯；已打勾 → 撤销到这一杯之前
    static func tap(_ i: Int) async {
        var t = times
        var ids = healthIDs
        if i < t.count {
            let removed = Array(ids.dropFirst(i))
            t = Array(t.prefix(i))
            ids = Array(ids.prefix(i))
            save(t, ids)
            await deleteFromHealth(removed)
        } else {
            let now = Date()
            var added: [String] = []
            while t.count <= i && t.count < goal {
                t.append(now)
                let id = await writeToHealth(now)
                added.append(id ?? "")
            }
            ids = Array(ids.prefix(t.count - added.count)) + added
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
        let midnight = Calendar.current.startOfDay(for: Date().addingTimeInterval(86400)).addingTimeInterval(5)
        completion(Timeline(entries: [WaterEntry(date: Date())], policy: .after(midnight)))
    }
}

struct WaterWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Water", provider: WaterProvider()) { _ in
            WaterWidgetView()
        }
        .configurationDisplayName("喝水")
        .description("每天 4 杯，每杯 350 ml。喝一杯点一下杯子打勾，点已打勾的杯子可以撤销。")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

// MARK: - 界面

struct WaterWidgetView: View {
    @Environment(\.widgetFamily) var family
    private let times = WaterLog.times
    private var count: Int { times.count }
    private var ml: Int { Int(Double(count) * WaterLog.cupML) }
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
                .foregroundStyle(done ? waterGreen : .secondary)
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
                .foregroundStyle(done ? waterGreen : .secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                ForEach(0..<WaterLog.goal, id: \.self) { i in
                    cupButton(i, height: 44, showTime: false)
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
                    .foregroundStyle(done ? waterGreen : .secondary)
                    .lineLimit(1)
                    .frame(width: 104, alignment: .center)
            }
            .frame(width: 104)
            HStack(spacing: 10) {
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
            // 达标线（3 杯）的小刻度
            Circle()
                .trim(from: 0.745, to: 0.755)
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
                CupView(filled: filled, isNext: i == count)
                    .frame(height: height)
                if showTime {
                    Text(filled ? f.string(from: times[i]) : "第\(i + 1)杯")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(filled ? Color.primary.opacity(0.8) : Color.secondary.opacity(0.7))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 一个玻璃杯：上宽下窄，喝了就装满水、带水波和勾
struct CupView: View {
    let filled: Bool
    let isNext: Bool

    var body: some View {
        ZStack {
            CupShape()
                .fill(Color.white.opacity(filled ? 0.04 : 0.06))
            if filled {
                WaveShape()
                    .fill(LinearGradient(colors: [waterCyan.opacity(0.95), waterBlue], startPoint: .top, endPoint: .bottom))
                    .clipShape(CupShape())
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 2)
                    .offset(y: 4)
            } else if isNext {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(waterBlue.opacity(0.9))
            }
            CupShape()
                .stroke(filled ? waterCyan.opacity(0.9) : (isNext ? waterBlue.opacity(0.7) : Color.white.opacity(0.22)),
                        style: StrokeStyle(lineWidth: 1.6, dash: filled || isNext ? [] : [3, 3]))
        }
        .aspectRatio(0.72, contentMode: .fit)
    }
}

/// 杯子外形：上宽下窄的梯形，底部圆角
struct CupShape: Shape {
    func path(in r: CGRect) -> Path {
        let inset = r.width * 0.13
        let radius = r.width * 0.12
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - inset, y: r.maxY - radius))
        p.addQuadCurve(to: CGPoint(x: r.maxX - inset - radius, y: r.maxY),
                       control: CGPoint(x: r.maxX - inset, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + inset + radius, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX + inset, y: r.maxY - radius),
                       control: CGPoint(x: r.minX + inset, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// 水面：从杯底到约 82% 高度，顶上一道水波
struct WaveShape: Shape {
    func path(in r: CGRect) -> Path {
        let top = r.minY + r.height * 0.18
        let amp = r.height * 0.035
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: top))
        let steps = 24
        for s in 0...steps {
            let x = r.minX + r.width * CGFloat(s) / CGFloat(steps)
            let y = top + sin(CGFloat(s) / CGFloat(steps) * .pi * 2) * amp
            p.addLine(to: CGPoint(x: x, y: y))
        }
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}
