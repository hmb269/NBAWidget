import Foundation
import HealthKit

/// 健康数据：App 和小组件共用，小组件扩展自己查 HealthKit（重签后 App Group 不通）。
enum HealthService {
    static let store = HKHealthStore()

    private static let stepType = HKQuantityType(.stepCount)
    private static let massType = HKQuantityType(.bodyMass)
    private static let hrvType = HKQuantityType(.heartRateVariabilitySDNN)
    private static let sleepType = HKCategoryType(.sleepAnalysis)

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// 只在 App 里调用：弹出授权页
    static func requestAccess() async -> String? {
        guard isAvailable else { return "这台设备不支持健康数据" }
        do {
            try await store.requestAuthorization(toShare: [], read: [stepType, massType, hrvType, sleepType])
            return nil
        } catch {
            return "授权失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 数据结构

    struct SleepData: Codable {
        var asleep: TimeInterval      // 总睡眠
        var deep: TimeInterval
        var core: TimeInterval
        var rem: TimeInterval
        var awake: TimeInterval
        var other: TimeInterval       // 没分阶段的睡眠（只有 iPhone 记录时）
        var bedtime: Date?
        var wake: Date?
    }

    struct WeightData: Codable {
        var kg: Double
        var date: Date
        var previousKg: Double?       // 前一天（最近一次更早的记录）
        var previousDate: Date?
    }

    struct HRVData: Codable {
        var ms: Double                // 昨晚睡眠期间的平均值；没有就用最近一次
        var overnight: Bool
        var weekAverage: Double?
        var previous: Double?         // 前一晚的平均值，用来比较升降
    }

    /// 读取结果：值 + 更新时间 + 说明（出错或用了缓存时）
    struct Reading<T: Codable>: Codable {
        var value: T?
        var updated: Date?
        var note: String?
    }

    // MARK: - 步数

    static func todaySteps() async throws -> Int {
        let start = Calendar.current.startOfDay(for: Date())
        let v = try await sum(stepType, unit: .count(), from: start, to: Date())
        return Int(v)
    }

    // MARK: - 睡眠

    /// 昨晚的睡眠：昨天 18:00 到今天 15:00 之间（nightsAgo = 1 是前一晚）。
    /// iPhone 和手表都会记，选睡眠最长的那个来源，避免重复。
    static func lastNightSleep(nightsAgo: Int = 0) async throws -> SleepData? {
        let cal = Calendar.current
        let today = cal.date(byAdding: .day, value: -nightsAgo, to: cal.startOfDay(for: Date()))!
        let start = cal.date(byAdding: .hour, value: -6, to: today)!
        let end = min(Date(), cal.date(byAdding: .hour, value: 15, to: today)!)
        let samples = try await categorySamples(sleepType, from: start, to: end)
        guard !samples.isEmpty else { return nil }

        let bySource = Dictionary(grouping: samples) { $0.sourceRevision.source.bundleIdentifier }
        func asleepSeconds(_ list: [HKCategorySample]) -> TimeInterval {
            list.filter { HKCategoryValueSleepAnalysis.allAsleepValues.contains(HKCategoryValueSleepAnalysis(rawValue: $0.value)!) }
                .reduce(0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }
        }
        guard let best = bySource.values.max(by: { asleepSeconds($0) < asleepSeconds($1) }) else { return nil }

        var d = SleepData(asleep: 0, deep: 0, core: 0, rem: 0, awake: 0, other: 0, bedtime: nil, wake: nil)
        for s in best {
            let t = s.endDate.timeIntervalSince(s.startDate)
            switch HKCategoryValueSleepAnalysis(rawValue: s.value) {
            case .asleepDeep: d.deep += t
            case .asleepCore: d.core += t
            case .asleepREM: d.rem += t
            case .asleepUnspecified: d.other += t
            case .awake: d.awake += t
            default: continue // inBed 不算
            }
            if HKCategoryValueSleepAnalysis(rawValue: s.value) != .awake {
                d.bedtime = min(d.bedtime ?? s.startDate, s.startDate)
                d.wake = max(d.wake ?? s.endDate, s.endDate)
            }
        }
        // 总时长和健康 App 一样：所有来源的睡眠时段合并（重叠只算一次），
        // 再扣掉主来源（通常是手表）标记为清醒的时段
        let asleepIntervals = samples
            .filter { HKCategoryValueSleepAnalysis.allAsleepValues.contains(HKCategoryValueSleepAnalysis(rawValue: $0.value)!) }
            .map { ($0.startDate, $0.endDate) }
        let awakeIntervals = best
            .filter { HKCategoryValueSleepAnalysis(rawValue: $0.value) == .awake }
            .map { ($0.startDate, $0.endDate) }
        let merged = subtract(merge(asleepIntervals), merge(awakeIntervals))
        d.asleep = merged.reduce(0) { $0 + $1.1.timeIntervalSince($1.0) }
        if let first = merged.first, let last = merged.last {
            d.bedtime = first.0
            d.wake = last.1
        }
        return d.asleep > 0 ? d : nil
    }

    /// 排查用：列出昨晚每个来源的原始数据，和几种算法的结果
    static func sleepDebug() async throws -> [String] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .hour, value: -6, to: today)!
        let end = min(Date(), cal.date(byAdding: .hour, value: 15, to: today)!)
        let samples = try await categorySamples(sleepType, from: start, to: end)
        func hms(_ t: TimeInterval) -> String {
            let x = Int(t.rounded())
            return String(format: "%d:%02d:%02d", x / 3600, x / 60 % 60, x % 60)
        }
        func isAsleep(_ s: HKCategorySample) -> Bool {
            HKCategoryValueSleepAnalysis.allAsleepValues.contains(HKCategoryValueSleepAnalysis(rawValue: s.value)!)
        }
        var lines: [String] = ["样本 \(samples.count) 条"]
        let bySource = Dictionary(grouping: samples) { $0.sourceRevision.source.name + "（" + $0.sourceRevision.source.bundleIdentifier + "）" }
        for (name, list) in bySource.sorted(by: { $0.key < $1.key }) {
            var sums: [String: TimeInterval] = [:]
            for x in list {
                let k: String
                switch HKCategoryValueSleepAnalysis(rawValue: x.value) {
                case .asleepDeep: k = "深睡"
                case .asleepCore: k = "核心"
                case .asleepREM: k = "快速眼动"
                case .asleepUnspecified: k = "睡眠"
                case .awake: k = "清醒"
                case .inBed: k = "卧床"
                default: k = "其他"
                }
                sums[k, default: 0] += x.endDate.timeIntervalSince(x.startDate)
            }
            let asleep = list.filter(isAsleep).reduce(0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }
            let detail = sums.sorted { $0.key < $1.key }.map { "\($0.key) \(hms($0.value))" }.joined(separator: "，")
            lines.append("\(name)：睡着合计 \(hms(asleep))；\(detail)")
        }
        let asleepAll = merge(samples.filter(isAsleep).map { ($0.startDate, $0.endDate) })
        let unionTotal = asleepAll.reduce(0) { $0 + $1.1.timeIntervalSince($1.0) }
        lines.append("A 所有来源合并：\(hms(unionTotal))")
        if let f = asleepAll.first, let l = asleepAll.last {
            let awake = merge(samples.filter { HKCategoryValueSleepAnalysis(rawValue: $0.value) == .awake }.map { ($0.startDate, $0.endDate) })
            let span = l.1.timeIntervalSince(f.0)
            let awakeInSpan = awake.reduce(0.0) { acc, iv in
                acc + max(0, min(iv.1, l.1).timeIntervalSince(max(iv.0, f.0)))
            }
            lines.append("B 入睡到醒来：\(hms(span))（\(HealthFormat.time(f.0)) - \(HealthFormat.time(l.1))）")
            lines.append("C 入睡到醒来减清醒：\(hms(span - awakeInSpan))")
        }
        if let d = try await lastNightSleep() {
            lines.append("小组件现在用的：\(hms(d.asleep))")
        }
        return lines
    }

    /// 合并重叠的时段
    private static func merge(_ list: [(Date, Date)]) -> [(Date, Date)] {
        var out: [(Date, Date)] = []
        for iv in list.sorted(by: { $0.0 < $1.0 }) {
            if let last = out.last, iv.0 <= last.1 {
                out[out.count - 1].1 = max(last.1, iv.1)
            } else {
                out.append(iv)
            }
        }
        return out
    }

    /// 从 a 里挖掉 b 覆盖的部分（两边都已合并、按时间排好）
    private static func subtract(_ a: [(Date, Date)], _ b: [(Date, Date)]) -> [(Date, Date)] {
        var out: [(Date, Date)] = []
        for iv in a {
            var pieces = [iv]
            for cut in b where cut.1 > iv.0 && cut.0 < iv.1 {
                pieces = pieces.flatMap { p -> [(Date, Date)] in
                    guard cut.1 > p.0 && cut.0 < p.1 else { return [p] }
                    var r: [(Date, Date)] = []
                    if cut.0 > p.0 { r.append((p.0, cut.0)) }
                    if cut.1 < p.1 { r.append((cut.1, p.1)) }
                    return r
                }
            }
            out += pieces
        }
        return out
    }

    // MARK: - 体重

    /// 最新体重，和「更早一天」的最后一次记录对比
    static func latestWeight() async throws -> WeightData? {
        let start = Calendar.current.date(byAdding: .day, value: -60, to: Date())!
        let samples = try await quantitySamples(massType, from: start, to: Date(), limit: 200)
        guard let latest = samples.first else { return nil }
        let cal = Calendar.current
        let prev = samples.first { !cal.isDate($0.endDate, inSameDayAs: latest.endDate) && $0.endDate < latest.endDate }
        return WeightData(
            kg: latest.quantity.doubleValue(for: .gramUnit(with: .kilo)),
            date: latest.endDate,
            previousKg: prev?.quantity.doubleValue(for: .gramUnit(with: .kilo)),
            previousDate: prev?.endDate
        )
    }

    // MARK: - 心率变异性

    /// 恢复心率变异性：昨晚睡眠期间的平均 HRV（手表夜间测量），没有就用最近一次；
    /// 附前一晚的平均值和 7 日均值
    static func recentHRV(sleep: SleepData?, prevSleep: SleepData? = nil) async throws -> HRVData? {
        let ms = HKUnit.secondUnit(with: .milli)
        let cal = Calendar.current
        let from = cal.date(byAdding: .day, value: -8, to: Date())!
        let samples = try await quantitySamples(hrvType, from: from, to: Date(), limit: 800)
        guard let latest = samples.first else { return nil }

        let week = samples.filter { $0.endDate > cal.date(byAdding: .day, value: -7, to: Date())! }
            .map { $0.quantity.doubleValue(for: ms) }
        let weekAvg = week.isEmpty ? nil : week.reduce(0, +) / Double(week.count)

        // 某一晚的平均：有睡眠记录就按入睡到醒来，没有就按 20:00 到次日 10:00
        func nightAverage(_ sleep: SleepData?, nightsAgo: Int) -> Double? {
            let s: Date, e: Date
            if let b = sleep?.bedtime, let w = sleep?.wake {
                s = b.addingTimeInterval(-1800); e = w.addingTimeInterval(1800)
            } else {
                let day = cal.date(byAdding: .day, value: -nightsAgo, to: cal.startOfDay(for: Date()))!
                s = day.addingTimeInterval(-4 * 3600); e = day.addingTimeInterval(10 * 3600)
            }
            let v = samples.filter { $0.startDate >= s && $0.endDate <= e }.map { $0.quantity.doubleValue(for: ms) }
            return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
        }

        let last = nightAverage(sleep, nightsAgo: 0)
        let prev = nightAverage(prevSleep, nightsAgo: 1)
        if let last {
            return HRVData(ms: last, overnight: true, weekAverage: weekAvg, previous: prev)
        }
        // 昨晚没测到：用最近一次，和它之前那一晚比
        return HRVData(ms: latest.quantity.doubleValue(for: ms), overnight: false, weekAverage: weekAvg, previous: prev)
    }

    // MARK: - 体重趋势

    struct WeightPoint: Codable {
        var date: Date
        var kg: Double
    }

    /// 最近若干天的体重，每天取最后一次记录，按日期从早到晚
    static func weightHistory(days: Int) async throws -> [WeightPoint] {
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -days, to: cal.startOfDay(for: Date()))!
        let samples = try await quantitySamples(massType, from: start, to: Date(), limit: 1000)
        var perDay: [Date: HKQuantitySample] = [:]
        for smp in samples { // 最新的在前，所以每天第一次遇到的就是当天最后一次
            let d = cal.startOfDay(for: smp.endDate)
            if perDay[d] == nil { perDay[d] = smp }
        }
        return perDay.keys.sorted().map {
            WeightPoint(date: $0, kg: perDay[$0]!.quantity.doubleValue(for: .gramUnit(with: .kilo)))
        }
    }

    // MARK: - 带缓存的读取（锁屏时读不到就显示上一次的值）

    static func load<T: Codable>(_ key: String, keepFor hours: Double = 24, _ fetch: () async throws -> T?) async -> Reading<T> {
        let d = UserDefaults.standard
        let k = "health_cache_" + key
        do {
            let v = try await fetch()
            let r = Reading(value: v, updated: Date(), note: v == nil ? "暂无数据" : nil)
            if v != nil, let data = try? JSONEncoder().encode(r) { d.set(data, forKey: k) }
            return r
        } catch {
            let reason = describe(error)
            if let data = d.data(forKey: k),
               var cached = try? JSONDecoder().decode(Reading<T>.self, from: data),
               let t = cached.updated, Date().timeIntervalSince(t) < hours * 3600 {
                cached.note = reason
                return cached
            }
            return Reading(value: nil, updated: nil, note: reason)
        }
    }

    static func describe(_ error: Error) -> String {
        if let hk = error as? HKError {
            switch hk.code {
            case .errorDatabaseInaccessible: return "锁屏中"
            case .errorAuthorizationNotDetermined: return "请打开 App 授权"
            case .errorAuthorizationDenied: return "没有读取权限"
            case .errorHealthDataUnavailable: return "设备不支持"
            default: break
            }
        }
        let text = error.localizedDescription
        if text.localizedCaseInsensitiveContains("entitlement") { return "签名缺少 HealthKit 权限" }
        return text
    }

    // MARK: - 底层查询

    private static func sum(_ type: HKQuantityType, unit: HKUnit, from: Date, to: Date) async throws -> Double {
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: .strictStartDate)
        return try await withCheckedThrowingContinuation { cont in
            let q = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, stats, error in
                if let error {
                    if let hk = error as? HKError, hk.code == .errorNoData { cont.resume(returning: 0) }
                    else { cont.resume(throwing: error) }
                    return
                }
                cont.resume(returning: stats?.sumQuantity()?.doubleValue(for: unit) ?? 0)
            }
            store.execute(q)
        }
    }

    /// 按时间倒序（最新的在前）
    private static func quantitySamples(_ type: HKQuantityType, from: Date, to: Date, limit: Int) async throws -> [HKQuantitySample] {
        try await samples(type, from: from, to: to, limit: limit, ascending: false).compactMap { $0 as? HKQuantitySample }
    }

    private static func categorySamples(_ type: HKCategoryType, from: Date, to: Date) async throws -> [HKCategorySample] {
        try await samples(type, from: from, to: to, limit: HKObjectQueryNoLimit, ascending: true).compactMap { $0 as? HKCategorySample }
    }

    private static func samples(_ type: HKSampleType, from: Date, to: Date, limit: Int, ascending: Bool) async throws -> [HKSample] {
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: ascending)
        return try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: type, predicate: predicate, limit: limit, sortDescriptors: [sort]) { _, results, error in
                if let error {
                    if let hk = error as? HKError, hk.code == .errorNoData { cont.resume(returning: []) }
                    else { cont.resume(throwing: error) }
                    return
                }
                cont.resume(returning: results ?? [])
            }
            store.execute(q)
        }
    }
}

// MARK: - 日出日落（按玉林的经纬度本地计算，不需要定位和联网）

enum SunTimes {
    static let latitude = 22.63
    static let longitude = 110.15

    /// NOAA 算法，返回当天的日出、日落（系统时区）
    static func times(for date: Date = Date()) -> (sunrise: Date, sunset: Date)? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let local = Calendar.current.dateComponents([.year, .month, .day], from: date)
        guard let dayStartUTC = cal.date(from: local) else { return nil }
        let n = Double(cal.ordinality(of: .day, in: .year, for: dayStartUTC) ?? 1)

        let gamma = 2 * Double.pi / 365 * (n - 1)
        let eqTime = 229.18 * (0.000075 + 0.001868 * cos(gamma) - 0.032077 * sin(gamma)
                               - 0.014615 * cos(2 * gamma) - 0.040849 * sin(2 * gamma))
        let decl = 0.006918 - 0.399912 * cos(gamma) + 0.070257 * sin(gamma)
            - 0.006758 * cos(2 * gamma) + 0.000907 * sin(2 * gamma)
            - 0.002697 * cos(3 * gamma) + 0.00148 * sin(3 * gamma)
        let lat = latitude * .pi / 180
        let zenith = 90.833 * Double.pi / 180
        let cosHA = cos(zenith) / (cos(lat) * cos(decl)) - tan(lat) * tan(decl)
        guard abs(cosHA) <= 1 else { return nil }
        let ha = acos(cosHA) * 180 / .pi

        let riseMin = 720 - 4 * (longitude + ha) - eqTime   // UTC 分钟
        let setMin = 720 - 4 * (longitude - ha) - eqTime
        return (dayStartUTC.addingTimeInterval(riseMin * 60), dayStartUTC.addingTimeInterval(setMin * 60))
    }
}

// MARK: - 显示用的格式

enum HealthFormat {
    static func duration(_ t: TimeInterval) -> String {
        let m = Int(t / 60)
        return "\(m / 60)小时\(m % 60)分"
    }

    static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "H:mm"
        return f.string(from: d)
    }

    /// 时长写成 1:05 这种
    static func clock(_ t: TimeInterval) -> String {
        let m = Int(t / 60)
        return String(format: "%d:%02d", m / 60, m % 60)
    }

    static func kg(_ v: Double) -> String { String(format: "%.2f", v) }
}
