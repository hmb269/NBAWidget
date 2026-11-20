import Foundation
import HealthKit
import SwiftUI

// 备孕 / 孕期：数据、周期推算、体温分析、和健康 App 同步
// 精简版用（全能版也会编译进去，但不显示）

enum FertilityMode: String, CaseIterable, Identifiable {
    case trying = "备孕"
    case pregnant = "怀孕"
    var id: String { rawValue }
}

/// 某一天记的东西（用 Int 存选项，方便以后加）
struct FertilityDay: Codable, Equatable {
    var key: String
    var flow: Int = 0          // 0 无 1 点滴 2 少 3 中 4 多
    var bbt: Double? = nil     // 基础体温 ℃
    var lh: Int = 0            // 排卵试纸：0 未测 1 阴性 2 弱阳 3 阳性 4 强阳
    var mucus: Int = 0         // 宫颈黏液：0 未记 1 干 2 黏稠 3 乳状 4 水样 5 蛋清样
    var sex: Bool = false      // 同房
    var test: Int = 0          // 验孕：0 未测 1 阴性 2 阳性
    var symptoms: [String] = []
    var note: String = ""
    var weight: Double? = nil  // 孕期体重（自己记的，健康里有的也会读）

    var isEmpty: Bool {
        flow == 0 && bbt == nil && lh == 0 && mucus == 0 && !sex && test == 0 && symptoms.isEmpty && note.isEmpty && weight == nil
    }

    static let flowNames = ["无", "点滴", "少", "中", "多"]
    static let lhNames = ["未测", "阴性", "弱阳", "阳性", "强阳"]
    static let mucusNames = ["未记", "干", "黏稠", "乳状", "水样", "蛋清样"]
    static let testNames = ["未测", "阴性", "阳性"]
    static let tryingSymptoms = ["小腹痛", "乳房胀痛", "腰酸", "头痛", "疲劳", "情绪波动", "长痘", "失眠"]
    static let pregnantSymptoms = ["孕吐", "恶心", "乏力", "嗜睡", "尿频", "便秘", "腰背痛", "腿抽筋", "水肿", "头晕", "胃灼热", "见红", "腹痛", "头痛"]
}

struct FertilitySettings: Codable, Equatable {
    var cycleLen: Int = 28
    var periodLen: Int = 5
    var autoCycle: Bool = true          // 用记录自动算平均周期
    var lmp: Date? = nil                // 末次月经第一天（怀孕时用来算孕周）
    var prePregWeight: Double? = nil    // 孕前体重
    var syncHealth: Bool = true         // 记录同时写进健康
    var checkupsDone: [String] = []     // 已做的产检
    var kickMerge: Bool = true          // 胎动：5 分钟内连续动算 1 次
}

struct KickSession: Codable, Identifiable, Equatable {
    var id = UUID()
    var start: Date
    var end: Date? = nil
    var kicks: [Date] = []      // 算进去的胎动
    var taps: Int = 0           // 一共点了几下
}

struct Contraction: Codable, Identifiable, Equatable {
    var id = UUID()
    var start: Date
    var end: Date? = nil
    var duration: TimeInterval? { end.map { $0.timeIntervalSince(start) } }
}

struct FertilityData: Codable {
    var days: [String: FertilityDay] = [:]
    var settings = FertilitySettings()
    var kicks: [KickSession] = []
    var contractions: [Contraction] = []
}

/// 一天在周期里的状态（日历上色用）
enum CyclePhase {
    case period, predictedPeriod, fertile, ovulation, other
}

final class FertilityStore: ObservableObject {
    static let shared = FertilityStore()
    static let modeKey = "fertilityMode"

    @Published var data = FertilityData()
    /// 健康里读到的手表腕温（夜里），key = 日期
    @Published var wristTemps: [String: Double] = [:]
    /// 健康里读到的经期（自己没记的那几天），key = 日期，值 = 流量
    @Published var healthFlow: [String: Int] = [:]
    /// 健康里的体温（体温计量的，不是基础体温），key = 日期，一天取最高
    @Published var bodyTemps: [String: Double] = [:]
    @Published var healthMessage: String?

    var mode: FertilityMode {
        get { FertilityMode(rawValue: UserDefaults.standard.string(forKey: Self.modeKey) ?? "") ?? .trying }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.modeKey); objectWillChange.send() }
    }

    private init() { load() }

    // MARK: 存取

    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("fertility.json")
    }

    private func load() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let d = try? Data(contentsOf: Self.url), let v = try? dec.decode(FertilityData.self, from: d) { data = v }
    }

    func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(data) { try? d.write(to: Self.url, options: .atomic) }
    }

    /// 备份用
    static func exportData() -> Data? { try? Data(contentsOf: url) }

    /// 从备份恢复：已有的日子不覆盖，只补缺的
    static func importData(_ d: Data) -> Int {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let v = try? dec.decode(FertilityData.self, from: d) else { return 0 }
        var n = 0
        let s = FertilityStore.shared
        var cur = s.data
        for (k, day) in v.days where cur.days[k] == nil { cur.days[k] = day; n += 1 }
        if cur.settings.lmp == nil { cur.settings.lmp = v.settings.lmp }
        if cur.settings.prePregWeight == nil { cur.settings.prePregWeight = v.settings.prePregWeight }
        let ids = Set(cur.kicks.map(\.id))
        cur.kicks += v.kicks.filter { !ids.contains($0.id) }
        let cids = Set(cur.contractions.map(\.id))
        cur.contractions += v.contractions.filter { !cids.contains($0.id) }
        DispatchQueue.main.async {
            s.data = cur
            s.save()
        }
        return n
    }

    // MARK: 日期

    static let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }()

    static func key(_ d: Date) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04ld-%02ld-%02ld", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func date(_ key: String) -> Date? {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }

    static func addDays(_ d: Date, _ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: cal.startOfDay(for: d))! }

    static func daysBetween(_ a: Date, _ b: Date) -> Int {
        cal.dateComponents([.day], from: cal.startOfDay(for: a), to: cal.startOfDay(for: b)).day ?? 0
    }

    static func md(_ d: Date) -> String {
        let c = cal.dateComponents([.month, .day], from: d)
        return "\(c.month ?? 0)月\(c.day ?? 0)日"
    }

    static func shortMD(_ d: Date) -> String {
        let c = cal.dateComponents([.month, .day], from: d)
        return "\(c.month ?? 0)/\(c.day ?? 0)"
    }

    // MARK: 记录

    func day(_ d: Date) -> FertilityDay {
        let k = Self.key(d)
        return data.days[k] ?? FertilityDay(key: k)
    }

    /// 某天的流量：自己记的优先，没有就看健康里的
    func flow(_ k: String) -> Int {
        let own = data.days[k]?.flow ?? 0
        return own > 0 ? own : (healthFlow[k] ?? 0)
    }

    func update(_ day: FertilityDay) {
        let old = data.days[day.key]
        if day.isEmpty { data.days[day.key] = nil } else { data.days[day.key] = day }
        save()
        objectWillChange.send()
        if data.settings.syncHealth, old != day, let d = Self.date(day.key) {
            Task { await FertilityHealth.write(day, date: d, isStart: isPeriodStart(day.key)) }
        }
    }

    // MARK: 周期推算

    /// 每次月经第一天（前 10 天内没有出血才算新的一次）
    var periodStarts: [Date] {
        var keys = Set(data.days.values.filter { $0.flow >= 2 }.map(\.key))
        for (k, f) in healthFlow where f >= 2 { keys.insert(k) }
        let dates = keys.compactMap(Self.date).sorted()
        var out: [Date] = []
        var prev: Date?
        for d in dates {
            // 前 10 天内没有出血，才算新的一次月经
            if prev == nil || Self.daysBetween(prev!, d) > 10 { out.append(d) }
            prev = d
        }
        return out
    }

    func isPeriodStart(_ k: String) -> Bool {
        guard let d = Self.date(k) else { return false }
        return periodStarts.contains { Self.cal.isDate($0, inSameDayAs: d) }
    }

    /// 历次周期长度（天），只要 18～50 天的
    var cycleLengths: [Int] {
        let s = periodStarts
        guard s.count >= 2 else { return [] }
        return (1..<s.count).map { Self.daysBetween(s[$0 - 1], s[$0]) }.filter { (18...50).contains($0) }
    }

    var avgCycle: Int {
        let l = cycleLengths.suffix(6)
        guard data.settings.autoCycle, !l.isEmpty else { return data.settings.cycleLen }
        return Int((Double(l.reduce(0, +)) / Double(l.count)).rounded())
    }

    /// 每次经期持续几天
    func periodLength(from start: Date) -> Int {
        var n = 0
        var gap = 0
        var d = start
        while n + gap < 12 {
            if flow(Self.key(d)) >= 1 { n += 1 + gap; gap = 0 } else { gap += 1; if gap > 1 { break } }
            d = Self.addDays(d, 1)
        }
        return max(n, 1)
    }

    var avgPeriod: Int {
        let s = periodStarts.suffix(6)
        let today = Self.cal.startOfDay(for: Date())
        let lens = s.filter { Self.daysBetween($0, today) >= 8 }.map(periodLength)
        guard !lens.isEmpty else { return data.settings.periodLen }
        return Int((Double(lens.reduce(0, +)) / Double(lens.count)).rounded())
    }

    var lastStart: Date? {
        let today = Self.cal.startOfDay(for: Date())
        return periodStarts.last { $0 <= today }
    }

    var cycleDay: Int? { lastStart.map { Self.daysBetween($0, Date()) + 1 } }

    var nextStart: Date? { lastStart.map { Self.addDays($0, avgCycle) } }

    /// 月经推迟了几天（超过预计日期才算）
    var lateDays: Int {
        guard let n = nextStart else { return 0 }
        return max(0, Self.daysBetween(n, Date()))
    }

    /// 本周期的排卵日：体温确认 > 试纸阳性 > 按周期预测
    var ovulation: (date: Date, source: String)? {
        guard let s = lastStart else { return nil }
        if let shift = bbtShift(from: s) { return (Self.addDays(shift.date, -1), "体温升高确认") }
        // 本周期最后一次强阳 / 阳性试纸，排卵一般在之后 24～36 小时
        let lhDays = data.days.values.filter { $0.lh >= 3 }.compactMap { v -> Date? in
            guard let d = Self.date(v.key), d >= s else { return nil }
            return d
        }.sorted()
        if let l = lhDays.last { return (Self.addDays(l, 1), "排卵试纸阳性") }
        guard let n = nextStart else { return nil }
        return (Self.addDays(n, -14), "按周期预测")
    }

    var fertileWindow: (Date, Date)? {
        guard let o = ovulation?.date else { return nil }
        return (Self.addDays(o, -5), Self.addDays(o, 1))
    }

    /// 今天怀孕几率（粗略）
    var chanceToday: String {
        guard let o = ovulation?.date else { return "--" }
        let diff = Self.daysBetween(o, Date())   // 正数 = 排卵日之后
        if (-2...0).contains(diff) { return "高" }
        if (-5 ... -3).contains(diff) || diff == 1 { return "较高" }
        return "低"
    }

    /// 日历上色：已记录的经期、以后 3 个周期的预测经期、每个周期的易孕期 / 排卵日
    func phaseMap() -> [String: CyclePhase] {
        var m: [String: CyclePhase] = [:]
        let starts = periodStarts
        let cyc = avgCycle
        let per = avgPeriod
        // 每个周期 [开始, 下次开始)
        var bounds: [(Date, Date, Bool)] = []   // (开始, 下次开始, 下次是预测的)
        for (i, s) in starts.enumerated() {
            if i + 1 < starts.count { bounds.append((s, starts[i + 1], false)) }
        }
        if let last = starts.last {
            var s = last
            for _ in 0..<4 {
                let n = Self.addDays(s, cyc)
                bounds.append((s, n, true))
                s = n
            }
        }
        let today = Self.cal.startOfDay(for: Date())
        for (s, n, predicted) in bounds {
            var ov = Self.addDays(n, -14)
            if s == lastStart, let o = ovulation?.date { ov = o }
            for i in -5...1 {
                let k = Self.key(Self.addDays(ov, i))
                m[k] = i == 0 ? .ovulation : .fertile
            }
            if predicted && n > today {
                for i in 0..<per { m[Self.key(Self.addDays(n, i))] = .predictedPeriod }
            }
        }
        // 真实记录的经期最优先
        for (k, v) in data.days where v.flow >= 1 { m[k] = .period }
        for (k, f) in healthFlow where f >= 1 { m[k] = .period }
        return m
    }

    // MARK: 体温

    /// 基础体温（某天以后），按日期排好
    func bbtPoints(from: Date) -> [(Date, Double)] {
        data.days.values.compactMap { v -> (Date, Double)? in
            guard let t = v.bbt, let d = Self.date(v.key), d >= Self.cal.startOfDay(for: from) else { return nil }
            return (d, t)
        }.sorted { $0.0 < $1.0 }
    }

    /// 「3 高于 6」：连续 3 天都高于前 6 天最高值，第 3 天至少高 0.2℃ → 体温升高（排卵后）
    func bbtShift(from: Date) -> (date: Date, cover: Double)? {
        Self.detectShift(bbtPoints(from: from), rise: 0.2)
    }

    static func detectShift(_ p: [(Date, Double)], rise: Double) -> (date: Date, cover: Double)? {
        guard p.count >= 9 else { return nil }
        for i in 6..<(p.count - 2) {
            let m = p[(i - 6)..<i].map(\.1).max() ?? 0
            if p[i].1 > m && p[i + 1].1 > m && p[i + 2].1 >= m + rise {
                return (p[i].0, m + 0.05)
            }
        }
        return nil
    }

    /// 高温期持续了几天（体温升高那天算第 1 天）
    var highPhaseDays: Int? {
        guard let s = lastStart, let sh = bbtShift(from: s) else { return nil }
        return Self.daysBetween(sh.date, Date()) + 1
    }

    /// 手表腕温和自己基线的偏差（基线 = 中位数）
    func wristDeviation(from: Date) -> [(Date, Double)] {
        let all = wristTemps.values.sorted()
        guard all.count >= 5 else { return [] }
        let base = all[all.count / 2]
        return wristTemps.compactMap { k, v -> (Date, Double)? in
            guard let d = Self.date(k), d >= Self.cal.startOfDay(for: from) else { return nil }
            return (d, v - base)
        }.sorted { $0.0 < $1.0 }
    }

    // MARK: 孕期

    var lmp: Date? { data.settings.lmp }

    /// 孕几周几天
    var gestation: (week: Int, day: Int, days: Int)? {
        guard let l = lmp else { return nil }
        let n = Self.daysBetween(l, Date())
        guard n >= 0 else { return nil }
        return (n / 7, n % 7, n)
    }

    var dueDate: Date? { lmp.map { Self.addDays($0, 280) } }

    func startPregnancy(lmp: Date?) {
        data.settings.lmp = lmp ?? lastStart ?? data.settings.lmp
        save()
        mode = .pregnant
    }

    // MARK: 健康 App

    @MainActor
    func syncFromHealth() async {
        let r = await FertilityHealth.read(days: 400)
        healthFlow = r.flow.filter { (data.days[$0.key]?.flow ?? 0) == 0 }
        wristTemps = r.wrist
        bodyTemps = r.body
        var changed = false
        for (k, t) in r.bbt where data.days[k]?.bbt == nil {
            var d = data.days[k] ?? FertilityDay(key: k)
            d.bbt = t
            data.days[k] = d
            changed = true
        }
        if changed { save() }
        healthMessage = r.error
    }
}

// MARK: - 健康 App 读写

enum FertilityHealth {
    static let store = HealthService.store
    static let flowType = HKCategoryType(.menstrualFlow)
    static let bbtType = HKQuantityType(.basalBodyTemperature)
    static let wristType = HKQuantityType(.appleSleepingWristTemperature)
    static let lhType = HKCategoryType(.ovulationTestResult)
    static let mucusType = HKCategoryType(.cervicalMucusQuality)
    static let massType = HKQuantityType(.bodyMass)
    static let sysType = HKQuantityType(.bloodPressureSystolic)
    static let diaType = HKQuantityType(.bloodPressureDiastolic)
    static let restingType = HKQuantityType(.restingHeartRate)
    static let heightType = HKQuantityType(.height)
    static let bodyTempType = HKQuantityType(.bodyTemperature)

    static func requestAccess() async -> String? {
        guard HKHealthStore.isHealthDataAvailable() else { return "这台设备不支持健康数据" }
        let share: Set<HKSampleType> = [flowType, bbtType, lhType, mucusType]
        let read: Set<HKObjectType> = [flowType, bbtType, wristType, lhType, mucusType, massType, sysType, diaType,
                                       restingType, heightType, bodyTempType, HKCategoryType(.pregnancyTestResult)]
        do {
            try await store.requestAuthorization(toShare: share, read: read)
            return nil
        } catch {
            return "授权失败：\(error.localizedDescription)"
        }
    }

    static func samples(_ type: HKSampleType, from: Date, to: Date = Date()) async -> [HKSample] {
        let pred = HKQuery.predicateForSamples(withStart: from, end: to)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        return await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: type, predicate: pred, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, r, _ in
                cont.resume(returning: r ?? [])
            }
            store.execute(q)
        }
    }

    struct ReadResult {
        var flow: [String: Int] = [:]
        var bbt: [String: Double] = [:]
        var wrist: [String: Double] = [:]
        var body: [String: Double] = [:]
        var error: String?
    }

    static func read(days: Int) async -> ReadResult {
        var r = ReadResult()
        if let e = await requestAccess() { r.error = e; return r }
        let from = FertilityStore.addDays(Date(), -days)
        // 月经：1 未指定 2 少 3 中 4 多 5 无
        for s in await samples(flowType, from: from).compactMap({ $0 as? HKCategorySample }) {
            let v: Int
            switch s.value {
            case 2: v = 2
            case 3, 1: v = 3
            case 4: v = 4
            default: v = 0
            }
            if v > 0 { r.flow[FertilityStore.key(s.startDate)] = v }
        }
        // 基础体温：一天取最早的一次（早上醒来量的）
        for s in await samples(bbtType, from: from).compactMap({ $0 as? HKQuantitySample }) {
            let k = FertilityStore.key(s.startDate)
            if r.bbt[k] == nil { r.bbt[k] = (s.quantity.doubleValue(for: .degreeCelsius()) * 100).rounded() / 100 }
        }
        // 手表睡眠腕温：记在醒来那天
        for s in await samples(wristType, from: from).compactMap({ $0 as? HKQuantitySample }) {
            r.wrist[FertilityStore.key(s.endDate)] = s.quantity.doubleValue(for: .degreeCelsius())
        }
        // 体温计量的体温：一天取最高
        for s in await samples(bodyTempType, from: from).compactMap({ $0 as? HKQuantitySample }) {
            let k = FertilityStore.key(s.startDate)
            let v = s.quantity.doubleValue(for: .degreeCelsius())
            r.body[k] = max(r.body[k] ?? 0, v)
        }
        return r
    }

    /// 写进健康：先删掉阿波之前写的这一天的记录，再写新的
    static func write(_ day: FertilityDay, date: Date, isStart: Bool) async {
        let start = FertilityStore.cal.startOfDay(for: date)
        let end = FertilityStore.addDays(start, 1)
        let when = start.addingTimeInterval(7 * 3600)
        let pred = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: start, end: end),
            HKQuery.predicateForObjects(from: HKSource.default()),
        ])
        for t in [flowType, lhType, mucusType] as [HKObjectType] {
            _ = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                store.deleteObjects(of: t, predicate: pred) { ok, _, _ in c.resume(returning: ok) }
            }
        }
        _ = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            store.deleteObjects(of: bbtType, predicate: pred) { ok, _, _ in c.resume(returning: ok) }
        }
        var objs: [HKObject] = []
        if day.flow >= 2 {
            objs.append(HKCategorySample(type: flowType, value: day.flow, start: when, end: when,
                                         metadata: [HKMetadataKeyMenstrualCycleStart: isStart]))
        }
        if let t = day.bbt {
            objs.append(HKQuantitySample(type: bbtType, quantity: HKQuantity(unit: .degreeCelsius(), doubleValue: t), start: when, end: when))
        }
        if day.lh > 0 {
            // 1 阴性 2 LH 峰（阳性）3 不确定
            let v = day.lh == 1 ? 1 : (day.lh == 2 ? 3 : 2)
            objs.append(HKCategorySample(type: lhType, value: v, start: when, end: when))
        }
        if day.mucus > 0 {
            objs.append(HKCategorySample(type: mucusType, value: day.mucus, start: when, end: when))
        }
        if !objs.isEmpty { try? await store.save(objs) }
    }

    /// 最近一次的值
    static func latest(_ type: HKQuantityType, unit: HKUnit, days: Int = 60) async -> (Double, Date)? {
        let s = await samples(type, from: FertilityStore.addDays(Date(), -days)).compactMap { $0 as? HKQuantitySample }
        guard let l = s.last else { return nil }
        return (l.quantity.doubleValue(for: unit), l.endDate)
    }

    /// 体重：每天最后一次（kg）
    static func weights(from: Date) async -> [(Date, Double)] {
        var m: [String: (Date, Double)] = [:]
        for s in await samples(massType, from: from).compactMap({ $0 as? HKQuantitySample }) {
            m[FertilityStore.key(s.endDate)] = (FertilityStore.cal.startOfDay(for: s.endDate), s.quantity.doubleValue(for: .gramUnit(with: .kilo)))
        }
        return m.values.sorted { $0.0 < $1.0 }
    }

    /// 血压：最近几次（收缩压、舒张压、时间）
    static func bloodPressure(days: Int) async -> [(Double, Double, Date)] {
        let from = FertilityStore.addDays(Date(), -days)
        let sys = await samples(sysType, from: from).compactMap { $0 as? HKQuantitySample }
        let dia = await samples(diaType, from: from).compactMap { $0 as? HKQuantitySample }
        let mmHg = HKUnit.millimeterOfMercury()
        return sys.compactMap { s -> (Double, Double, Date)? in
            guard let d = dia.first(where: { abs($0.startDate.timeIntervalSince(s.startDate)) < 120 }) else { return nil }
            return (s.quantity.doubleValue(for: mmHg), d.quantity.doubleValue(for: mmHg), s.startDate)
        }
    }
}
