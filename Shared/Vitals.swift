import Foundation
import HealthKit

/// 生命体征（参考 Apple「生命体征」App）：昨晚睡觉时的心率、呼吸频率、腕温、血氧、睡眠时长，
/// 和自己前 4 周的同一项比，超出平时范围就算「偏高 / 偏低」
struct VitalItem: Codable, Identifiable {
    var id: String { name }
    var name: String          // 心率 / 呼吸 / 腕温 / 血氧 / 睡眠
    var value: Double?        // 昨晚的值（腕温是和平时比的偏差）
    var unit: String
    var low: Double?          // 平时范围
    var high: Double?
    var status: Int           // 0 没数据 1 正常 2 偏高 3 偏低

    var statusText: String {
        switch status {
        case 2: return name + (name == "呼吸" ? "偏快" : (name == "睡眠" ? "偏长" : "偏高"))
        case 3: return name + (name == "呼吸" ? "偏慢" : (name == "睡眠" ? "偏短" : "偏低"))
        default: return name + "正常"
        }
    }

    var valueText: String {
        guard let v = value else { return "--" }
        switch name {
        case "腕温": return String(format: "%+.2f", v)
        case "睡眠": return String(format: "%.1f", v)
        case "呼吸": return String(format: "%.1f", v)
        default: return String(Int(v.rounded()))
        }
    }
}

struct VitalsSummary: Codable {
    var night: Date
    var items: [VitalItem]

    var measured: [VitalItem] { items.filter { $0.status != 0 } }
    var abnormal: [VitalItem] { items.filter { $0.status >= 2 } }
    var allNormal: Bool { !measured.isEmpty && abnormal.isEmpty }

    /// 小组件上显示的一句话
    var text: String {
        if measured.isEmpty { return "--" }
        if abnormal.isEmpty { return "正常" }
        return abnormal.map(\.statusText).joined(separator: "·")
    }

    var foot: String {
        if measured.isEmpty { return "戴手表睡觉后显示" }
        if abnormal.isEmpty { return "\(measured.count) 项都在平时范围" }
        return "\(abnormal.count) 项超出平时范围"
    }

    func item(_ name: String) -> VitalItem? { items.first { $0.name == name } }
}

enum Vitals {
    private static let store = HealthService.store

    static var readTypes: [HKObjectType] {
        [HKQuantityType(.heartRate), HKQuantityType(.respiratoryRate), HKQuantityType(.oxygenSaturation),
         HKQuantityType(.appleSleepingWristTemperature), HKQuantityType(.bodyTemperature)]
    }

    private static func samples(_ t: HKQuantityType, from: Date) async -> [HKQuantitySample] {
        let pred = HKQuery.predicateForSamples(withStart: from, end: Date())
        return await withCheckedContinuation { c in
            let q = HKSampleQuery(sampleType: t, predicate: pred, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, r, _ in
                c.resume(returning: (r ?? []).compactMap { $0 as? HKQuantitySample })
            }
            store.execute(q)
        }
    }

    /// 夜里（22 点到第二天 9 点）的样本记到早上那天
    private static func nightKey(_ d: Date) -> Date? {
        let cal = Calendar.current
        let h = cal.component(.hour, from: d)
        if h >= 22 { return cal.startOfDay(for: d.addingTimeInterval(86400)) }
        if h < 9 { return cal.startOfDay(for: d) }
        return nil
    }

    private static func nightly(_ s: [HKQuantitySample], unit: HKUnit, scale: Double = 1) -> [Date: Double] {
        var sum: [Date: (Double, Int)] = [:]
        for x in s {
            guard let k = nightKey(x.startDate) else { continue }
            let v = x.quantity.doubleValue(for: unit) * scale
            let o = sum[k] ?? (0, 0)
            sum[k] = (o.0 + v, o.1 + 1)
        }
        return sum.mapValues { $0.0 / Double($0.1) }
    }

    /// 和前面的夜晚比：平时范围 = 平均 ± max(2 倍标准差, 最小宽度)
    private static func judge(_ name: String, unit: String, series: [Date: Double], today: Date,
                              minBand: Double, deviation: Bool = false) -> VitalItem {
        guard let v = series[today] else { return VitalItem(name: name, value: nil, unit: unit, low: nil, high: nil, status: 0) }
        let past = series.filter { $0.key < today }.map(\.value)
        guard past.count >= 5 else {
            return VitalItem(name: name, value: v, unit: unit, low: nil, high: nil, status: 1)
        }
        let mean = past.reduce(0, +) / Double(past.count)
        let sd = sqrt(past.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(past.count))
        let band = max(2 * sd, minBand)
        let shown = deviation ? v - mean : v
        let lo = deviation ? -band : mean - band
        let hi = deviation ? band : mean + band
        let st = shown > hi ? 2 : (shown < lo ? 3 : 1)
        return VitalItem(name: name, value: shown, unit: unit, low: lo, high: hi, status: st)
    }

    static func lastNight() async throws -> VitalsSummary? {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let from = cal.date(byAdding: .day, value: -29, to: today)!.addingTimeInterval(-3 * 3600)
        async let hrS = samples(HKQuantityType(.heartRate), from: from)
        async let rrS = samples(HKQuantityType(.respiratoryRate), from: from)
        async let o2S = samples(HKQuantityType(.oxygenSaturation), from: from)
        async let wtS = samples(HKQuantityType(.appleSleepingWristTemperature), from: from)
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let hr = nightly(await hrS, unit: bpm)
        let rr = nightly(await rrS, unit: bpm)
        let o2 = nightly(await o2S, unit: .percent(), scale: 100)
        var wt: [Date: Double] = [:]
        for s in await wtS { wt[cal.startOfDay(for: s.endDate)] = s.quantity.doubleValue(for: .degreeCelsius()) }
        var sl: [Date: Double] = [:]
        for n in await HealthService.nightlySleep(days: 29) { sl[cal.startOfDay(for: n.0)] = n.1.asleep / 3600 }
        // 「昨晚」= 今天早上；今天还没数据就看最近有数据的那晚
        let all = [hr, rr, o2, wt, sl]
        let night = all.compactMap { $0[today] != nil ? today : nil }.first
            ?? all.flatMap { Array($0.keys) }.max()
        guard let n = night, (cal.dateComponents([.day], from: n, to: today).day ?? 9) <= 1 else { return nil }
        var items = [
            judge("心率", unit: "次/分", series: hr, today: n, minBand: 5),
            judge("呼吸", unit: "次/分", series: rr, today: n, minBand: 1.5),
            judge("腕温", unit: "℃", series: wt, today: n, minBand: 0.5, deviation: true),
            judge("血氧", unit: "%", series: o2, today: n, minBand: 3),
            judge("睡眠", unit: "小时", series: sl, today: n, minBand: 1.5),
        ]
        // 血氧不看偏高；低于 92% 不管平时如何都算偏低
        if let i = items.firstIndex(where: { $0.name == "血氧" }) {
            if items[i].status == 2 { items[i].status = 1 }
            if let v = items[i].value, v < 92 { items[i].status = 3 }
        }
        return VitalsSummary(night: n, items: items)
    }
}
