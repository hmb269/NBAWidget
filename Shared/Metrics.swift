import Foundation
import HealthKit
import SwiftUI
import AppIntents

// MARK: - 可选的数据项（小组件编辑菜单里选）

enum MetricKind: String, CaseIterable, Codable {
    case weight, hrv, steps, sun
    case restingHR, heartRate, activeEnergy, exercise, stand, distance, flights
    case oxygen, respiratory, vo2max, bodyFat

    var title: String {
        switch self {
        case .weight: return "体重"
        case .hrv: return "恢复心率变异性"
        case .steps: return "今日步数"
        case .sun: return "日出日落"
        case .restingHR: return "静息心率"
        case .heartRate: return "心率"
        case .activeEnergy: return "活动能量"
        case .exercise: return "锻炼时间"
        case .stand: return "站立小时"
        case .distance: return "步行跑步距离"
        case .flights: return "已爬楼层"
        case .oxygen: return "血氧"
        case .respiratory: return "呼吸频率"
        case .vo2max: return "最大摄氧量"
        case .bodyFat: return "体脂率"
        }
    }

    var unit: String {
        switch self {
        case .weight: return "公斤"
        case .hrv: return "毫秒"
        case .steps: return "步"
        case .sun: return ""
        case .restingHR, .heartRate, .respiratory: return "次/分"
        case .activeEnergy: return "千卡"
        case .exercise: return "分钟"
        case .stand: return "小时"
        case .distance: return "公里"
        case .flights: return "层"
        case .oxygen, .bodyFat: return "%"
        case .vo2max: return "毫升"
        }
    }

    var symbol: String {
        switch self {
        case .weight: return "figure"
        case .hrv: return "waveform.path.ecg"
        case .steps: return "figure.walk"
        case .sun: return "sun.horizon.fill"
        case .restingHR: return "heart.fill"
        case .heartRate: return "heart.text.square.fill"
        case .activeEnergy: return "flame.fill"
        case .exercise: return "figure.run"
        case .stand: return "figure.stand"
        case .distance: return "point.topleft.down.to.point.bottomright.curvepath.fill"
        case .flights: return "figure.stairs"
        case .oxygen: return "drop.fill"
        case .respiratory: return "lungs.fill"
        case .vo2max: return "bolt.heart.fill"
        case .bodyFat: return "percent"
        }
    }

    /// 默认颜色（渐变的上、下两色）
    var defaultColors: (Color, Color) {
        switch self {
        case .weight, .bodyFat: return (Color(red: 0.80, green: 0.55, blue: 1.0), Color(red: 0.55, green: 0.32, blue: 0.95))
        case .hrv: return (Color(red: 1.0, green: 0.45, blue: 0.55), Color(red: 0.95, green: 0.22, blue: 0.42))
        case .steps, .flights: return (Color(red: 1.0, green: 0.68, blue: 0.25), Color(red: 1.0, green: 0.45, blue: 0.15))
        case .sun: return (Color(red: 1.0, green: 0.88, blue: 0.30), Color(red: 1.0, green: 0.68, blue: 0.10))
        case .restingHR, .heartRate: return (Color(red: 1.0, green: 0.42, blue: 0.40), Color(red: 0.92, green: 0.18, blue: 0.25))
        case .activeEnergy: return (Color(red: 1.0, green: 0.35, blue: 0.50), Color(red: 0.95, green: 0.10, blue: 0.35))
        case .exercise, .vo2max: return (Color(red: 0.70, green: 1.0, blue: 0.25), Color(red: 0.35, green: 0.85, blue: 0.20))
        case .stand: return (Color(red: 0.35, green: 0.95, blue: 0.95), Color(red: 0.10, green: 0.72, blue: 0.90))
        case .distance, .respiratory: return (Color(red: 0.35, green: 0.90, blue: 0.80), Color(red: 0.10, green: 0.65, blue: 0.70))
        case .oxygen: return (Color(red: 0.45, green: 0.72, blue: 1.0), Color(red: 0.22, green: 0.45, blue: 0.95))
        }
    }

    var decimals: Int {
        switch self {
        case .weight, .distance: return 2
        case .respiratory, .vo2max, .bodyFat: return 1
        default: return 0
        }
    }

    /// 今天累计的（步数、能量……）还是取最近一次的（体重、心率……）
    var cumulative: Bool { [.steps, .activeEnergy, .exercise, .distance, .flights].contains(self) }

    /// 和前一次比较、显示升降箭头（上升绿、下降红）
    var comparable: Bool { [.weight, .hrv, .restingHR, .vo2max, .bodyFat].contains(self) }

    /// 能画趋势图（大号里第 1 项）
    var chartable: Bool { self != .sun && self != .stand }

    var trendThreshold: Double { 0.5 * pow(10, -Double(decimals)) }

    var quantityType: HKQuantityType? {
        switch self {
        case .weight: return HKQuantityType(.bodyMass)
        case .hrv: return HKQuantityType(.heartRateVariabilitySDNN)
        case .steps: return HKQuantityType(.stepCount)
        case .restingHR: return HKQuantityType(.restingHeartRate)
        case .heartRate: return HKQuantityType(.heartRate)
        case .activeEnergy: return HKQuantityType(.activeEnergyBurned)
        case .exercise: return HKQuantityType(.appleExerciseTime)
        case .distance: return HKQuantityType(.distanceWalkingRunning)
        case .flights: return HKQuantityType(.flightsClimbed)
        case .oxygen: return HKQuantityType(.oxygenSaturation)
        case .respiratory: return HKQuantityType(.respiratoryRate)
        case .vo2max: return HKQuantityType(.vo2Max)
        case .bodyFat: return HKQuantityType(.bodyFatPercentage)
        case .sun, .stand: return nil
        }
    }

    var hkUnit: HKUnit {
        let perMin = HKUnit.count().unitDivided(by: .minute())
        switch self {
        case .weight: return .gramUnit(with: .kilo)
        case .hrv: return .secondUnit(with: .milli)
        case .steps, .flights: return .count()
        case .restingHR, .heartRate, .respiratory: return perMin
        case .activeEnergy: return .kilocalorie()
        case .exercise: return .minute()
        case .distance: return .meterUnit(with: .kilo)
        case .oxygen, .bodyFat: return .percent()
        case .vo2max: return HKUnit(from: "ml/kg*min")
        case .sun, .stand: return .count()
        }
    }

    /// 百分比在 HealthKit 里是 0~1，显示成 0~100
    func convert(_ v: Double) -> Double { (self == .oxygen || self == .bodyFat) ? v * 100 : v }

    func format(_ v: Double) -> String {
        if decimals == 0 { return Int(v.rounded()).formatted() }
        return String(format: "%.\(decimals)f", v)
    }

    static var readTypes: Set<HKObjectType> {
        var s = Set<HKObjectType>(allCases.compactMap { $0.quantityType })
        s.insert(HKCategoryType(.appleStandHour))
        return s
    }
}

// MARK: - 小组件编辑菜单用的选项

extension MetricKind: AppEnum {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "数据")
    static var caseDisplayRepresentations: [MetricKind: DisplayRepresentation] = [
        .weight: "体重", .hrv: "恢复心率变异性", .steps: "今日步数", .sun: "日出日落",
        .restingHR: "静息心率", .heartRate: "心率", .activeEnergy: "活动能量", .exercise: "锻炼时间",
        .stand: "站立小时", .distance: "步行跑步距离", .flights: "已爬楼层", .oxygen: "血氧",
        .respiratory: "呼吸频率", .vo2max: "最大摄氧量", .bodyFat: "体脂率"
    ]
}

enum ColorChoice: String, CaseIterable, AppEnum {
    case auto, red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple, pink, gray

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "颜色")
    static var caseDisplayRepresentations: [ColorChoice: DisplayRepresentation] = [
        .auto: "默认", .red: "红", .orange: "橙", .yellow: "黄", .green: "绿", .mint: "薄荷绿",
        .teal: "青绿", .cyan: "青", .blue: "蓝", .indigo: "靛蓝", .purple: "紫", .pink: "粉", .gray: "灰白"
    ]

    /// 渐变的上、下两色；默认时返回 nil，用数据项自己的颜色
    var colors: (Color, Color)? {
        switch self {
        case .auto: return nil
        case .red: return (Color(red: 1.0, green: 0.42, blue: 0.40), Color(red: 0.92, green: 0.18, blue: 0.22))
        case .orange: return (Color(red: 1.0, green: 0.68, blue: 0.25), Color(red: 1.0, green: 0.45, blue: 0.15))
        case .yellow: return (Color(red: 1.0, green: 0.88, blue: 0.30), Color(red: 1.0, green: 0.68, blue: 0.10))
        case .green: return (Color(red: 0.45, green: 0.92, blue: 0.45), Color(red: 0.18, green: 0.75, blue: 0.30))
        case .mint: return (Color(red: 0.50, green: 1.0, blue: 0.80), Color(red: 0.15, green: 0.82, blue: 0.62))
        case .teal: return (Color(red: 0.35, green: 0.90, blue: 0.80), Color(red: 0.10, green: 0.65, blue: 0.70))
        case .cyan: return (Color(red: 0.42, green: 0.86, blue: 1.0), Color(red: 0.15, green: 0.65, blue: 0.95))
        case .blue: return (Color(red: 0.45, green: 0.65, blue: 1.0), Color(red: 0.20, green: 0.42, blue: 0.98))
        case .indigo: return (Color(red: 0.55, green: 0.55, blue: 1.0), Color(red: 0.35, green: 0.30, blue: 0.90))
        case .purple: return (Color(red: 0.80, green: 0.55, blue: 1.0), Color(red: 0.55, green: 0.32, blue: 0.95))
        case .pink: return (Color(red: 1.0, green: 0.55, blue: 0.75), Color(red: 0.95, green: 0.30, blue: 0.55))
        case .gray: return (Color(white: 0.92), Color(white: 0.65))
        }
    }
}

// MARK: - 读取

struct MetricReading: Codable {
    var value: Double
    var previous: Double?        // 前一次 / 前一晚，用来比较升降
    var date: Date               // 这条记录的时间
    var overnight: Bool? = nil   // HRV：是不是昨晚睡眠期间的平均
}

struct DayPoint: Codable {
    var date: Date
    var value: Double
}

extension HealthService {
    static func fetch(_ kind: MetricKind, sleep: SleepData?, prevSleep: SleepData?) async throws -> MetricReading? {
        switch kind {
        case .sun:
            return nil
        case .weight:
            guard let w = try await latestWeight() else { return nil }
            return MetricReading(value: w.kg, previous: w.previousKg, date: w.date)
        case .hrv:
            guard let h = try await recentHRV(sleep: sleep, prevSleep: prevSleep) else { return nil }
            return MetricReading(value: h.ms, previous: h.previous, date: Date(), overnight: h.overnight)
        case .stand:
            let start = Calendar.current.startOfDay(for: Date())
            let s = try await categorySamples(HKCategoryType(.appleStandHour), from: start, to: Date())
            let stood = s.filter { $0.value == HKCategoryValueAppleStandHour.stood.rawValue }.count
            return MetricReading(value: Double(stood), date: Date())
        default:
            guard let type = kind.quantityType else { return nil }
            if kind.cumulative {
                let start = Calendar.current.startOfDay(for: Date())
                let v = try await sum(type, unit: kind.hkUnit, from: start, to: Date())
                return MetricReading(value: kind.convert(v), date: Date())
            }
            // 取最近一次，和更早一天的最后一次比较
            let from = Calendar.current.date(byAdding: .day, value: -60, to: Date())!
            let samples = try await quantitySamples(type, from: from, to: Date(), limit: 300)
            guard let latest = samples.first else { return nil }
            let cal = Calendar.current
            let prev = samples.first { !cal.isDate($0.endDate, inSameDayAs: latest.endDate) && $0.endDate < latest.endDate }
            return MetricReading(
                value: kind.convert(latest.quantity.doubleValue(for: kind.hkUnit)),
                previous: prev.map { kind.convert($0.quantity.doubleValue(for: kind.hkUnit)) },
                date: latest.endDate
            )
        }
    }

    /// 最近若干天每天一个值：累计的取当天总和，其余取当天平均；体重取当天最后一次
    static func dailyHistory(_ kind: MetricKind, days: Int) async throws -> [DayPoint] {
        if kind == .weight {
            return try await weightHistory(days: days).map { DayPoint(date: $0.date, value: $0.kg) }
        }
        guard let type = kind.quantityType else { return [] }
        let cal = Calendar.current
        let end = Date()
        let start = cal.date(byAdding: .day, value: -(days - 1), to: cal.startOfDay(for: end))!
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        return try await withCheckedThrowingContinuation { cont in
            let q = HKStatisticsCollectionQuery(quantityType: type, quantitySamplePredicate: predicate,
                                                options: kind.cumulative ? .cumulativeSum : .discreteAverage,
                                                anchorDate: start, intervalComponents: DateComponents(day: 1))
            q.initialResultsHandler = { _, results, error in
                if let error {
                    if let hk = error as? HKError, hk.code == .errorNoData { cont.resume(returning: []) }
                    else { cont.resume(throwing: error) }
                    return
                }
                var out: [DayPoint] = []
                results?.enumerateStatistics(from: start, to: end) { st, _ in
                    let qty = kind.cumulative ? st.sumQuantity() : st.averageQuantity()
                    if let qty { out.append(DayPoint(date: st.startDate, value: kind.convert(qty.doubleValue(for: kind.hkUnit)))) }
                }
                cont.resume(returning: out)
            }
            store.execute(q)
        }
    }
}
