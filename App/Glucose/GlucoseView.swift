import SwiftUI
import HealthKit

// MARK: - 健康 App 里的血糖

struct GlucoseRecord: Identifiable {
    let id: String          // 同步标识（血糖仪导入的）或样本 UUID
    let date: Date
    let mmol: Double
    let meterMeal: String?  // 血糖仪自带的餐点标记（或上次同步进健康的标签）
    let source: String
    var syncVersion: Int = 1
    var isMine: Bool = false  // 是不是阿波自己写进健康的（只有这种能改）
}

enum GlucoseStore {
    static let type = HKQuantityType(.bloodGlucose)
    static let unit = HKUnit.moleUnit(with: .milli, molarMass: HKUnitMolarMassBloodGlucose).unitDivided(by: .liter())
    private static let mealKey = "阿波餐点"

    static func requestAccess() async throws {
        try await HealthService.store.requestAuthorization(toShare: [type], read: [type])
    }

    static func mealName(_ code: UInt8?) -> String? {
        switch code {
        case 1: return "餐前"
        case 2: return "餐后"
        case 3: return "空腹"
        case 4: return "随机"
        case 5: return "睡前"
        default: return nil
        }
    }

    /// 写进健康 App。每条带「同步标识」（血糖仪序列号 + 序号 + 时间），重复同步不会出现重复记录
    static func save(_ readings: [MeterReading], serial: String) async throws {
        let samples = readings.map { r -> HKQuantitySample in
            var meta: [String: Any] = [
                HKMetadataKeySyncIdentifier: "accuchek-\(serial)-\(r.seq)-\(Int(r.date.timeIntervalSince1970))",
                HKMetadataKeySyncVersion: 1,
                HKMetadataKeyWasUserEntered: false
            ]
            switch r.meal {
            case 1, 3: meta[HKMetadataKeyBloodGlucoseMealTime] = HKBloodGlucoseMealTime.preprandial.rawValue
            case 2: meta[HKMetadataKeyBloodGlucoseMealTime] = HKBloodGlucoseMealTime.postprandial.rawValue
            default: break
            }
            if let name = mealName(r.meal) { meta[mealKey] = name }
            return HKQuantitySample(type: type, quantity: HKQuantity(unit: unit, doubleValue: r.mmol),
                                    start: r.date, end: r.date, metadata: meta)
        }
        guard !samples.isEmpty else { return }
        try await HealthService.store.save(samples)
    }

    /// 把 App 里的餐点标签写进健康：同一个同步标识、版本号加 1 再存一次，健康会用新的替换旧的。
    /// 别的 App（比如 mySugr）写的记录改不了，跳过。返回（更新条数，跳过条数）
    static func pushTags(_ records: [GlucoseRecord], tag: (GlucoseRecord) -> String?) async throws -> (Int, Int) {
        var samples: [HKQuantitySample] = []
        var skipped = 0
        for r in records {
            guard let t = tag(r), t != r.meterMeal else { continue }   // 没标签或者和健康里一样，不用动
            guard r.isMine else { skipped += 1; continue }
            var meta: [String: Any] = [
                HKMetadataKeySyncIdentifier: r.id,
                HKMetadataKeySyncVersion: r.syncVersion + 1,
                HKMetadataKeyWasUserEntered: false,
                mealKey: t
            ]
            if t.contains("后") {
                meta[HKMetadataKeyBloodGlucoseMealTime] = HKBloodGlucoseMealTime.postprandial.rawValue
            } else if t.contains("前") || t == "空腹" {
                meta[HKMetadataKeyBloodGlucoseMealTime] = HKBloodGlucoseMealTime.preprandial.rawValue
            }
            samples.append(HKQuantitySample(type: type, quantity: HKQuantity(unit: unit, doubleValue: r.mmol),
                                            start: r.date, end: r.date, metadata: meta))
        }
        if !samples.isEmpty { try await HealthService.store.save(samples) }
        return (samples.count, skipped)
    }

    static func load(days: Int = 180) async throws -> [GlucoseRecord] {
        let start = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let samples: [HKQuantitySample] = try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, r, e in
                if let e { cont.resume(throwing: e) } else { cont.resume(returning: (r as? [HKQuantitySample]) ?? []) }
            }
            HealthService.store.execute(q)
        }
        return samples.map { s in
            let meta = s.metadata ?? [:]
            var meal = meta[mealKey] as? String
            if meal == nil, let raw = meta[HKMetadataKeyBloodGlucoseMealTime] as? NSNumber {
                meal = raw.intValue == HKBloodGlucoseMealTime.preprandial.rawValue ? "餐前" : "餐后"
            }
            let mine = s.sourceRevision.source.bundleIdentifier == Bundle.main.bundleIdentifier
                && meta[HKMetadataKeySyncIdentifier] != nil
            return GlucoseRecord(id: (meta[HKMetadataKeySyncIdentifier] as? String) ?? s.uuid.uuidString,
                                 date: s.startDate, mmol: s.quantity.doubleValue(for: unit),
                                 meterMeal: meal, source: s.sourceRevision.source.name,
                                 syncVersion: (meta[HKMetadataKeySyncVersion] as? NSNumber)?.intValue ?? 1,
                                 isMine: mine)
        }
    }
}

/// 自己改的餐点标签（存在 App 里，按记录的标识对应）
enum GlucoseTags {
    static let options = ["空腹", "早餐后", "午餐前", "午餐后", "晚餐前", "晚餐后", "睡前", "随机"]
    private static let key = "glucoseTags"
    static var all: [String: String] { (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:] }
    /// 三餐时间（从当天 0 点起的分钟数），在血糖页里可以改
    static var breakfast: Int { minutes("mealBreakfast", 7 * 60 + 30) }
    static var lunch: Int { minutes("mealLunch", 12 * 60) }
    static var dinner: Int { minutes("mealDinner", 18 * 60 + 30) }
    private static func minutes(_ k: String, _ def: Int) -> Int {
        UserDefaults.standard.object(forKey: k) == nil ? def : UserDefaults.standard.integer(forKey: k)
    }

    /// 血糖仪只记了「餐后 / 餐前」时，按测量时间换成具体餐次；餐后再算出是饭后几小时
    static func auto(_ r: GlucoseRecord) -> String? {
        let c = Calendar.current.dateComponents([.hour, .minute], from: r.date)
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        switch r.meterMeal {
        case "餐后":
            let (name, meal): (String, Int)
            if m >= breakfast - 60 && m < lunch { (name, meal) = ("早餐后", breakfast) }
            else if m >= lunch && m < dinner { (name, meal) = ("午餐后", lunch) }
            else if m >= dinner { (name, meal) = ("晚餐后", dinner) }
            else { (name, meal) = ("晚餐后", dinner - 24 * 60) }   // 过了半夜算前一天晚餐
            _ = meal
            return name + "2小时"   // 大部分是餐后 2 小时测的，默认就按 2 小时；不是的话手动改
        case "餐前":
            if m < 10 * 60 && m >= 4 * 60 { return "空腹" }
            if m >= 10 * 60 && m < 15 * 60 { return "午餐前" }
            if m >= 15 * 60 && m < 21 * 60 { return "晚餐前" }
            return "睡前"
        default:
            return r.meterMeal
        }
    }

    static func set(_ tag: String?, for id: String) {
        var d = all
        d[id] = tag
        UserDefaults.standard.set(d, forKey: key)
    }
}

// MARK: - 血糖页面

struct GlucoseView: View {
    @StateObject private var sync = AccuChekSync()
    @State private var records: [GlucoseRecord] = []
    @State private var tags: [String: String] = GlucoseTags.all
    @State private var message: String?
    @State private var mealTick = 0   // 改了三餐时间后刷新标签
    @State private var pushing = false

    var body: some View {
        List {
            Section {
                Button {
                    sync.start()
                } label: {
                    HStack {
                        Image(systemName: "dot.radiowaves.left.and.right")
                        Text(sync.busy ? "同步中…" : "从罗氏智航同步")
                        Spacer()
                        if sync.busy { ProgressView() }
                    }
                }
                .disabled(sync.busy)
                Button {
                    Task { await pushToHealth() }
                } label: {
                    HStack {
                        Image(systemName: "heart.text.square")
                        Text(pushing ? "正在同步…" : "从软件同步至健康")
                        Spacer()
                        if pushing { ProgressView() }
                    }
                }
                .disabled(pushing || records.isEmpty)
                Text(sync.status).font(.footnote).foregroundStyle(.secondary)
                if let message {
                    Text(message).font(.footnote).foregroundStyle(.green)
                }
            } footer: {
                Text("第一次连接：先把血糖仪关机，再长按「OK」键，直到屏幕上蓝牙图标闪烁，然后点上面的按钮。手机弹出配对框时，输入血糖仪背面的 6 位 PIN 码。\n以后同步：按一下血糖仪开机键让它亮屏，再点同步。\n读到的记录会保存到健康 App，重复同步不会重复。")
            }

            Section {
                mealPicker("早餐", key: "mealBreakfast", minutes: GlucoseTags.breakfast)
                mealPicker("午餐", key: "mealLunch", minutes: GlucoseTags.lunch)
                mealPicker("晚餐", key: "mealDinner", minutes: GlucoseTags.dinner)
            } header: {
                Text("三餐时间")
            } footer: {
                Text("血糖仪记成「餐后」的，按这里的时间判断是哪一餐，默认标成「餐后2小时」，例如「午餐后2小时」。不是 2 小时的点标签手动改。")
            }

            if records.isEmpty {
                Section { Text("还没有血糖记录").foregroundStyle(.secondary) }
            }

            ForEach(groupedDays, id: \.0) { day, items in
                Section(header: Text(dayTitle(day))) {
                    ForEach(items) { r in row(r) }
                }
            }
        }
        .navigationTitle("血糖")
        .refreshable { await reload() }
        .task {
            sync.onFinished = { readings, serial in
                Task { @MainActor in
                    do {
                        try await GlucoseStore.requestAccess()
                        try await GlucoseStore.save(readings, serial: serial)
                        message = "已保存 \(readings.count) 条到健康 App"
                    } catch {
                        message = "保存失败：\(error.localizedDescription)"
                    }
                    await reload()
                }
            }
            try? await GlucoseStore.requestAccess()
            await reload()
        }
    }

    private func row(_ r: GlucoseRecord) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(timeText(r.date))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
            Text(String(format: "%.1f", r.mmol))
                .font(.system(size: 24, weight: .bold, design: .rounded).monospacedDigit())
            Text("mmol/L").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Menu {
                ForEach(GlucoseTags.options, id: \.self) { t in
                    if t.hasSuffix("餐后") {
                        Menu(t) {
                            ForEach(1...4, id: \.self) { h in
                                Button("\(t)\(h)小时") { setTag("\(t)\(h)小时", for: r) }
                            }
                            Button("不指定时间") { setTag(t, for: r) }
                        }
                    } else {
                        Button(t) { setTag(t, for: r) }
                    }
                }
                if tags[r.id] != nil {
                    Divider()
                    Button("恢复血糖仪的标记", role: .destructive) { setTag(nil, for: r) }
                }
            } label: {
                Text(tags[r.id] ?? GlucoseTags.auto(r) ?? "标记餐点")
                    .id(mealTick)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
            }
        }
    }

    private func mealPicker(_ title: String, key: String, minutes: Int) -> some View {
        let base = Calendar.current.startOfDay(for: Date())
        return DatePicker(title, selection: Binding(
            get: { base.addingTimeInterval(TimeInterval(minutes * 60)) },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                UserDefaults.standard.set((c.hour ?? 0) * 60 + (c.minute ?? 0), forKey: key)
                mealTick += 1
            }
        ), displayedComponents: .hourAndMinute)
        .id("\(key)-\(mealTick)")
    }

    private func setTag(_ t: String?, for r: GlucoseRecord) {
        GlucoseTags.set(t, for: r.id)
        tags = GlucoseTags.all
    }

    private var groupedDays: [(Date, [GlucoseRecord])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: records) { cal.startOfDay(for: $0.date) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0]!.sorted { $0.date > $1.date }) }
    }

    private func dayTitle(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "今天" }
        if cal.isDateInYesterday(d) { return "昨天" }
        let f = DateFormatter()
        f.dateFormat = "M月d日 EEE"
        f.locale = Locale(identifier: "zh_CN")
        return f.string(from: d)
    }

    private func timeText(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    private func pushToHealth() async {
        pushing = true
        defer { pushing = false }
        do {
            try await GlucoseStore.requestAccess()
            let current = GlucoseTags.all
            let (done, skipped) = try await GlucoseStore.pushTags(records) { current[$0.id] ?? GlucoseTags.auto($0) }
            var t = done > 0 ? "已把 \(done) 条记录的餐点标签写进健康" : "健康里的标签已经是最新的"
            if skipped > 0 { t += "；\(skipped) 条是别的 App（如 mySugr）写的，健康不允许修改，已跳过" }
            message = t
        } catch {
            message = "同步至健康失败：\(error.localizedDescription)"
        }
        await reload()
    }

    private func reload() async {
        do { records = try await GlucoseStore.load() }
        catch { message = "读取健康数据失败：\(error.localizedDescription)" }
    }
}
