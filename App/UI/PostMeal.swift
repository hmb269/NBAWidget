import Foundation
import HealthKit

/// 饭后活动：一条餐后血糖记录，往前 2 小时（大约就是从吃完饭到测血糖）里走了多少步、消耗多少活动卡路里、锻炼了几分钟
struct PostMealActivity: Equatable {
    var steps: Double?
    var kcal: Double?
    var exercise: Double?

    var text: String {
        var parts: [String] = []
        if let s = steps { parts.append("走 \(Int(s.rounded())) 步") }
        if let k = kcal, k >= 1 { parts.append("消耗 \(Int(k.rounded())) 千卡") }
        if let e = exercise, e >= 1 { parts.append("锻炼 \(Int(e.rounded())) 分钟") }
        return parts.isEmpty ? "饭后没有活动数据" : "饭后 " + parts.joined(separator: " · ")
    }
}

enum PostMeal {
    @MainActor private static var memo: [Date: PostMealActivity] = [:]

    /// 测血糖时间 t 之前 2 小时的活动（结果缓存起来，相册滑动时不重复查）
    static func activity(before t: Date) async -> PostMealActivity {
        if let m = await MainActor.run(body: { memo[t] }) { return m }
        let from = t.addingTimeInterval(-2 * 3600)
        async let s = sum(.stepCount, .count(), from, t)
        async let k = sum(.activeEnergyBurned, .kilocalorie(), from, t)
        async let e = sum(.appleExerciseTime, .minute(), from, t)
        let a = PostMealActivity(steps: await s, kcal: await k, exercise: await e)
        await MainActor.run { memo[t] = a }
        return a
    }

    static func sum(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit, _ from: Date, _ to: Date) async -> Double? {
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: [])
        return await withCheckedContinuation { cont in
            let q = HKStatisticsQuery(quantityType: HKQuantityType(id), quantitySamplePredicate: predicate, options: .cumulativeSum) { _, st, _ in
                cont.resume(returning: st?.sumQuantity()?.doubleValue(for: unit))
            }
            HealthService.store.execute(q)
        }
    }

    /// 是不是饭后的记录（标签里有「后」，比如「午餐后2小时」）
    static func isAfterMeal(_ label: String?) -> Bool {
        guard let l = label else { return false }
        return l.contains("后") && l != "睡前"
    }
}
