import SwiftUI
import Photos
import HealthKit

// 吃药提醒（维生素D，隔天一颗）：App 和小组件共用。
// 设置同样通过空相簿名传给小组件：「阿波设置·用药·维生素D·每2天」。
// 健康 App 的「用药」：第三方 App 只能读、不能写（苹果限制），所以
// - 在健康 / 手表上记了「已服用」→ 小组件读得到，自动显示已吃；
// - 在小组件上点「已吃」→ 只记在阿波里，健康那边不会变。

let pillYellow = Color(red: 1.0, green: 0.78, blue: 0.25)
let pillOrange = Color(red: 1.0, green: 0.55, blue: 0.20)
let pillGreen = Color(red: 0.30, green: 0.85, blue: 0.55)

struct PillSettings: Equatable {
    var name: String = "维生素D"
    var every: Int = 2          // 每几天吃一次（2 = 隔天）

    static let prefix = "阿波设置·用药·"
    static let everyRange = 1...7

    var everyText: String {
        switch every {
        case 1: return "每天"
        case 2: return "隔天"
        case 7: return "每周"
        default: return "每\(every)天"
        }
    }

    var albumTitle: String {
        let clean = name.replacingOccurrences(of: "·", with: " ").trimmingCharacters(in: .whitespaces)
        return Self.prefix + (clean.isEmpty ? "维生素D" : clean) + "·每\(every)天"
    }

    init(name: String = "维生素D", every: Int = 2) { self.name = name; self.every = every }

    init?(albumTitle t: String) {
        guard t.hasPrefix(Self.prefix) else { return nil }
        let parts = t.dropFirst(Self.prefix.count).split(separator: "·").map(String.init)
        guard parts.count == 2,
              let n = Int(parts[1].replacingOccurrences(of: "每", with: "").replacingOccurrences(of: "天", with: "")) else { return nil }
        name = parts[0]
        every = min(max(n, Self.everyRange.lowerBound), Self.everyRange.upperBound)
    }

    // MARK: 缓存 + 相簿

    private static let key = "pillSettingsTitle"
    static var current: PillSettings {
        UserDefaults.standard.string(forKey: key).flatMap(PillSettings.init(albumTitle:)) ?? PillSettings()
    }
    static var savedTitle: String? { UserDefaults.standard.string(forKey: "pillSettingsSaved") }

    private static func album() -> PHAssetCollection? {
        let st = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard st == .authorized || st == .limited else { return nil }
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "title BEGINSWITH %@", prefix)
        return PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: opts).firstObject
    }

    /// 小组件里调用
    static func refreshFromAlbum() {
        if let t = album()?.localizedTitle, PillSettings(albumTitle: t) != nil {
            UserDefaults.standard.set(t, forKey: key)
        }
    }

    /// App 里调用
    static func save(_ s: PillSettings) async throws {
        UserDefaults.standard.set(s.albumTitle, forKey: key)
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw NSError(domain: "阿波", code: 1, userInfo: [NSLocalizedDescriptionKey: "没有相册权限，小组件读不到设置"])
        }
        let title = s.albumTitle
        if let col = album() {
            if col.localizedTitle != title {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCollectionChangeRequest(for: col)?.title = title
                }
            }
        } else {
            try await PHPhotoLibrary.shared().performChanges {
                _ = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            }
        }
        UserDefaults.standard.set(title, forKey: "pillSettingsSaved")
    }
}

// MARK: - 读健康里的「用药」（iOS 26 起）

enum MedsHealth {
    static let store = HKHealthStore()

    /// App 里调用：申请读取用药（会弹出让你勾选哪些药）
    static func requestAccess() async throws {
        guard #available(iOS 26.0, *) else { return }
        try await store.requestPerObjectReadAuthorization(for: HKObjectType.userAnnotatedMedicationType(), predicate: nil)
        try await store.requestAuthorization(toShare: [], read: [HKObjectType.medicationDoseEventType()])
    }

    /// 健康里登记的药名（App 设置里给你选）
    static func medicationNames() async -> [String] {
        guard #available(iOS 26.0, *) else { return [] }
        let meds = (try? await HKUserAnnotatedMedicationQueryDescriptor().result(for: store)) ?? []
        return meds.map { $0.nickname ?? $0.medication.displayText }
    }

    /// 最近 days 天里，在健康里记了「已服用」的时间（按药名匹配）
    static func takenDates(matching name: String, days: Int = 30) async -> [Date] {
        guard #available(iOS 26.0, *), HKHealthStore.isHealthDataAvailable() else { return [] }
        let key = name.lowercased().replacingOccurrences(of: " ", with: "")
        guard !key.isEmpty else { return [] }
        let meds = (try? await HKUserAnnotatedMedicationQueryDescriptor().result(for: store)) ?? []
        let ids = Set(meds.filter { m in
            [m.nickname, m.medication.displayText].compactMap { $0?.lowercased().replacingOccurrences(of: " ", with: "") }
                .contains { $0.contains(key) || key.contains($0) }
        }.map { $0.medication.identifier })
        guard !ids.isEmpty else { return [] }

        let start = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.sample(type: HKObjectType.medicationDoseEventType(),
                                 predicate: HKQuery.predicateForSamples(withStart: start, end: nil))],
            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)])
        let samples = (try? await descriptor.result(for: store)) ?? []
        return samples.compactMap { s -> Date? in
            guard let e = s as? HKMedicationDoseEvent, ids.contains(e.medicationConceptIdentifier) else { return nil }
            return String(describing: e.logStatus).lowercased().contains("taken") ? e.startDate : nil
        }
    }
}

// MARK: - 药丸图形

/// 一颗胶囊：左右两色，斜着放
struct PillCapsule: View {
    enum Phase { case due, taken, rest }
    let state: Phase

    var body: some View {
        let left: Color, right: Color
        switch state {
        case .due: left = pillOrange; right = pillYellow
        case .taken: left = pillGreen; right = pillGreen.opacity(0.55)
        case .rest: left = Color.white.opacity(0.22); right = Color.white.opacity(0.10)
        }
        return GeometryReader { g in
            let w = g.size.width, h = g.size.height
            HStack(spacing: 0) {
                UnevenRoundedRectangle(topLeadingRadius: h / 2, bottomLeadingRadius: h / 2, style: .continuous)
                    .fill(LinearGradient(colors: [left, left.opacity(0.8)], startPoint: .top, endPoint: .bottom))
                UnevenRoundedRectangle(bottomTrailingRadius: h / 2, topTrailingRadius: h / 2, style: .continuous)
                    .fill(LinearGradient(colors: [right, right.opacity(0.75)], startPoint: .top, endPoint: .bottom))
            }
            .overlay(alignment: .top) {
                // 高光
                Capsule().fill(Color.white.opacity(state == .rest ? 0.06 : 0.35))
                    .frame(width: w * 0.62, height: h * 0.16)
                    .padding(.top, h * 0.16)
            }
            .overlay {
                Capsule().stroke(Color.white.opacity(state == .rest ? 0.18 : 0.25), lineWidth: 1)
            }
            .shadow(color: state == .due ? pillOrange.opacity(0.55) : .clear, radius: 8)
        }
        .aspectRatio(2.4, contentMode: .fit)
        .rotationEffect(.degrees(-35))
    }
}
