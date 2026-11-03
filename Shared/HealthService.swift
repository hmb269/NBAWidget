import Foundation
import HealthKit

/// 健康数据：App 和小组件共用。
/// 第一版只读「今日步数」，用来验证重签后 HealthKit 还能不能用。
enum HealthService {
    static let store = HKHealthStore()
    private static let stepType = HKQuantityType(.stepCount)

    /// 小组件自己的缓存：锁屏时健康数据读不到，就显示上一次的值
    private static let cache = UserDefaults.standard
    private static let cacheValueKey = "health_steps_value"
    private static let cacheTimeKey = "health_steps_time"

    struct StepResult {
        var steps: Int?
        var updated: Date?
        var note: String?   // 出错或用的是缓存时给出说明
    }

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// 只在 App 里调用：弹出授权页
    static func requestAccess() async -> String? {
        guard isAvailable else { return "这台设备不支持健康数据" }
        do {
            try await store.requestAuthorization(toShare: [], read: [stepType])
            return nil
        } catch {
            return "授权失败：\(error.localizedDescription)"
        }
    }

    /// 今天 0 点到现在的步数（会自动去掉 iPhone 和手表的重复计数）
    static func todaySteps() async throws -> Int {
        let start = Calendar.current.startOfDay(for: Date())
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: .strictStartDate)
        return try await withCheckedThrowingContinuation { cont in
            let q = HKStatisticsQuery(quantityType: stepType, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, stats, error in
                if let error {
                    // 今天还没有任何数据时也会报 noData，当作 0 步
                    if let hk = error as? HKError, hk.code == .errorNoData {
                        cont.resume(returning: 0)
                    } else {
                        cont.resume(throwing: error)
                    }
                    return
                }
                let v = stats?.sumQuantity()?.doubleValue(for: .count()) ?? 0
                cont.resume(returning: Int(v))
            }
            store.execute(q)
        }
    }

    /// 读步数，失败时退回缓存
    static func loadSteps() async -> StepResult {
        do {
            let s = try await todaySteps()
            cache.set(s, forKey: cacheValueKey)
            cache.set(Date(), forKey: cacheTimeKey)
            return StepResult(steps: s, updated: Date(), note: nil)
        } catch {
            let reason = describe(error)
            if let t = cache.object(forKey: cacheTimeKey) as? Date,
               Calendar.current.isDateInToday(t) {
                return StepResult(steps: cache.integer(forKey: cacheValueKey), updated: t, note: reason)
            }
            return StepResult(steps: nil, updated: nil, note: reason)
        }
    }

    static func describe(_ error: Error) -> String {
        if let hk = error as? HKError {
            switch hk.code {
            case .errorDatabaseInaccessible: return "锁屏中，暂时读不到"
            case .errorAuthorizationNotDetermined: return "还没授权，请打开 App"
            case .errorAuthorizationDenied: return "没有读取权限"
            case .errorHealthDataUnavailable: return "设备不支持"
            default: break
            }
        }
        let text = error.localizedDescription
        if text.localizedCaseInsensitiveContains("entitlement") {
            return "签名里缺少 HealthKit 权限"
        }
        return text
    }
}
