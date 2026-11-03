import SwiftUI
import HealthKit

// MARK: - 健康 App 里的血糖

struct GlucoseRecord: Identifiable {
    let id: String          // 同步标识（血糖仪导入的）或样本 UUID
    let date: Date
    let mmol: Double
    let meterMeal: String?  // 血糖仪自带的餐点标记
    let source: String
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
            return GlucoseRecord(id: (meta[HKMetadataKeySyncIdentifier] as? String) ?? s.uuid.uuidString,
                                 date: s.startDate, mmol: s.quantity.doubleValue(for: unit),
                                 meterMeal: meal, source: s.sourceRevision.source.name)
        }
    }
}

/// 自己改的餐点标签（存在 App 里，按记录的标识对应）
enum GlucoseTags {
    static let options = ["空腹", "早餐后", "午餐前", "午餐后", "晚餐前", "晚餐后", "睡前", "随机"]
    private static let key = "glucoseTags"
    static var all: [String: String] { (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:] }
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
                Text(sync.status).font(.footnote).foregroundStyle(.secondary)
                if let message {
                    Text(message).font(.footnote).foregroundStyle(.green)
                }
            } footer: {
                Text("第一次连接：先把血糖仪关机，再长按「OK」键，直到屏幕上蓝牙图标闪烁，然后点上面的按钮。手机弹出配对框时，输入血糖仪背面的 6 位 PIN 码。\n以后同步：按一下血糖仪开机键让它亮屏，再点同步。\n读到的记录会保存到健康 App，重复同步不会重复。")
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
                    Button(t) { setTag(t, for: r) }
                }
                if tags[r.id] != nil {
                    Divider()
                    Button("恢复血糖仪的标记", role: .destructive) { setTag(nil, for: r) }
                }
            } label: {
                Text(tags[r.id] ?? r.meterMeal ?? "标记餐点")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
            }
        }
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

    private func reload() async {
        do { records = try await GlucoseStore.load() }
        catch { message = "读取健康数据失败：\(error.localizedDescription)" }
    }
}
