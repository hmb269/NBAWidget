import Foundation
import Photos

// 企业微信推送（自建应用直推）：App 和小组件共用。
// - App 设置里填 corpid / secret / agentid / 接收人，以及要推哪些内容；
// - 配置混淆后写进一个空相簿的名字，小组件读它（重签名后两边不能共享存储）；
// - 定时提醒（吃药、喝水、每日汇总）由小组件刷新时检查并发送，
//   所以时间会有几分钟到半小时的误差，并且对应的小组件要放在桌面上。

struct PushConfig: Codable, Equatable {
    var corpID = ""
    var secret = ""
    var agentID = ""
    var toUser = "@all"

    var pill = true
    var pillTime = 9 * 60          // 分钟（从零点算）
    var water = true
    var waterTime = 17 * 60
    var glucose = true
    var daily = false
    var dailyTime = 21 * 60 + 30

    var isReady: Bool { !corpID.isEmpty && !secret.isEmpty && !agentID.isEmpty }

    // MARK: 存储

    private static let key = "wecomConfig"
    static let prefix = "阿波设置·推送·"

    static var current: PushConfig {
        guard let data = UserDefaults.standard.data(forKey: key),
              let c = try? JSONDecoder().decode(PushConfig.self, from: data) else { return PushConfig() }
        return c
    }

    private static func cache(_ c: PushConfig) {
        if let data = try? JSONEncoder().encode(c) { UserDefaults.standard.set(data, forKey: key) }
    }

    // 简单混淆：相簿名里不出现明文密钥
    private static let mask: [UInt8] = Array("AboWeComPush-2026".utf8)
    private static func scramble(_ d: [UInt8]) -> [UInt8] { d.enumerated().map { $0.element ^ mask[$0.offset % mask.count] } }

    private var albumTitle: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        let b64 = Data(Self.scramble(Array(data))).base64EncodedString()
        return Self.prefix + b64
    }

    private init?(albumTitle t: String) {
        guard t.hasPrefix(Self.prefix),
              let raw = Data(base64Encoded: String(t.dropFirst(Self.prefix.count))),
              let c = try? JSONDecoder().decode(PushConfig.self, from: Data(Self.scramble(Array(raw)))) else { return nil }
        self = c
    }

    init() {}

    private static func album() -> PHAssetCollection? {
        let st = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard st == .authorized || st == .limited else { return nil }
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "title BEGINSWITH %@", prefix)
        return PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: opts).firstObject
    }

    /// 小组件里调用
    static func refreshFromAlbum() {
        if let t = album()?.localizedTitle, let c = PushConfig(albumTitle: t) { cache(c) }
    }

    /// App 里调用
    static func save(_ c: PushConfig) async throws {
        cache(c)
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw NSError(domain: "阿波", code: 1, userInfo: [NSLocalizedDescriptionKey: "没有相册权限，小组件读不到推送设置（定时提醒发不了）"])
        }
        guard let title = c.albumTitle else { return }
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
    }
}

enum WeCom {
    struct PushError: LocalizedError {
        let code: Int
        let msg: String
        var errorDescription: String? {
            switch code {
            case 60020:
                return "企业微信拒绝了手机的 IP（60020）。到企业微信管理后台 → 应用管理 → 这个应用 →「企业可信IP」，把手机当前的出口 IP 加进去；手机换网络 IP 会变，需要重新加。原始信息：\(msg)"
            case 40001, 42001, 40014:
                return "Secret 不对或已失效（\(code)）：\(msg)"
            case 40013:
                return "企业ID（corpid）不对：\(msg)"
            case 40056, 301002:
                return "AgentId 不对：\(msg)"
            case 81013:
                return "接收人不对，填成员账号，多个用 | 分隔，全部人填 @all：\(msg)"
            default:
                return "企业微信返回错误 \(code)：\(msg)"
            }
        }
    }

    private static let d = UserDefaults.standard

    private static func token(_ c: PushConfig, force: Bool = false) async throws -> String {
        let id = c.corpID + "|" + c.secret
        if !force, d.string(forKey: "wecomTokenFor") == id,
           let t = d.string(forKey: "wecomToken"), d.double(forKey: "wecomTokenExp") > Date().timeIntervalSince1970 {
            return t
        }
        var comp = URLComponents(string: "https://qyapi.weixin.qq.com/cgi-bin/gettoken")!
        comp.queryItems = [URLQueryItem(name: "corpid", value: c.corpID), URLQueryItem(name: "corpsecret", value: c.secret)]
        let (data, _) = try await URLSession.shared.data(from: comp.url!)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let code = obj["errcode"] as? Int ?? -1
        guard code == 0, let t = obj["access_token"] as? String else {
            throw PushError(code: code, msg: obj["errmsg"] as? String ?? String(data: data, encoding: .utf8) ?? "")
        }
        let exp = Double(obj["expires_in"] as? Int ?? 7200) - 300
        d.set(id, forKey: "wecomTokenFor")
        d.set(t, forKey: "wecomToken")
        d.set(Date().timeIntervalSince1970 + exp, forKey: "wecomTokenExp")
        return t
    }

    /// 第一行日期时间 + 星期，第二行开始是内容
    static func format(_ text: String, at date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss EEEE"
        return f.string(from: date) + "\n" + text
    }

    static func send(_ text: String, config c: PushConfig = .current) async throws {
        guard c.isReady else { throw PushError(code: -2, msg: "还没填企业微信的 corpid / secret / agentid") }
        var lastError: Error?
        for attempt in 0..<2 {
            let t = try await token(c, force: attempt > 0)
            var req = URLRequest(url: URL(string: "https://qyapi.weixin.qq.com/cgi-bin/message/send?access_token=\(t)")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = [
                "touser": c.toUser.isEmpty ? "@all" : c.toUser,
                "msgtype": "text",
                "agentid": Int(c.agentID) ?? 0,
                "text": ["content": format(text)],
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, _) = try await URLSession.shared.data(for: req)
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let code = obj["errcode"] as? Int ?? -1
            if code == 0 { return }
            let err = PushError(code: code, msg: obj["errmsg"] as? String ?? "")
            // token 过期：重新拿一次再发
            if [40014, 42001, 41001].contains(code) { lastError = err; continue }
            throw err
        }
        throw lastError ?? PushError(code: -1, msg: "发送失败")
    }

    // MARK: 定时推送：每天每种只推一次

    private static var todayKey: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date())
    }
    static func sentToday(_ kind: String) -> Bool { d.string(forKey: "wecomSent_" + kind) == todayKey }

    /// 到点、没推过才推；先占位再发，失败就退回（避免几个小组件同时刷新时重复推送）
    static func pushOnce(_ kind: String, text: String, config c: PushConfig) async {
        guard !sentToday(kind) else { return }
        d.set(todayKey, forKey: "wecomSent_" + kind)
        do { try await send(text, config: c) } catch { d.removeObject(forKey: "wecomSent_" + kind) }
    }

    static func isTime(_ minutes: Int, now: Date = Date()) -> Bool {
        let c = Calendar.current.dateComponents([.hour, .minute], from: now)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0) >= minutes
    }

    static func date(today minutes: Int) -> Date {
        Calendar.current.startOfDay(for: Date()).addingTimeInterval(TimeInterval(minutes * 60))
    }

    // MARK: 每日健康汇总

    static func dailySummary() async -> String {
        var lines: [String] = ["今日健康汇总"]
        let sleep = try? await HealthService.lastNightSleep()
        if let s = sleep {
            lines.append("😴 睡眠 " + HealthFormat.duration(s.asleep) +
                         "（深睡 \(HealthFormat.clock(s.deep)) 核心 \(HealthFormat.clock(s.core + s.other)) 眼动 \(HealthFormat.clock(s.rem)) 清醒 \(HealthFormat.clock(s.awake))）")
        }
        if let w = try? await HealthService.latestWeight() {
            var t = "⚖️ 体重 \(HealthFormat.kg(w.kg)) kg"
            if let p = w.previousKg { t += w.kg < p ? " ↓\(HealthFormat.kg(p - w.kg))" : w.kg > p ? " ↑\(HealthFormat.kg(w.kg - p))" : "" }
            lines.append(t)
        }
        if let h = try? await HealthService.recentHRV(sleep: sleep) {
            lines.append("💓 恢复HRV \(Int(h.ms.rounded())) 毫秒")
        }
        if let steps = try? await HealthService.todaySteps() {
            lines.append("🚶 今日步数 \(steps)")
        }
        return lines.joined(separator: "\n")
    }
}
