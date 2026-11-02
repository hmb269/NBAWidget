import Foundation
import Security

/// 喜欢的球队：App 里保存，小组件读取。
/// 重签名后 App Group 不一定可用，所以同时写钥匙串共享组，哪个能用读哪个。
enum FavoriteStore {
    static let groupID = "group.com.hmb269.nbawidget"
    private static let key = "favoriteTeams"

    private static var groupDefaults: UserDefaults? {
        guard FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) != nil else { return nil }
        return UserDefaults(suiteName: groupID)
    }

    static func load() -> Set<String> {
        if let d = groupDefaults, let arr = d.stringArray(forKey: key) { return Set(arr) }
        if let arr = SharedKeychain.load() { return Set(arr) }
        // 都不通时，至少 App 自己能记住
        return Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    static func save(_ teams: Set<String>) {
        let arr = teams.sorted()
        UserDefaults.standard.set(arr, forKey: key)
        groupDefaults?.set(arr, forKey: key)
        SharedKeychain.save(arr)
    }

    /// App 里显示：小组件能不能读到
    static var syncStatus: (ok: Bool, text: String) {
        if groupDefaults != nil { return (true, "已同步到小组件（App Group）") }
        if SharedKeychain.group != nil { return (true, "已同步到小组件（钥匙串）") }
        return (false, "小组件暂时读不到这里的设置（签名不支持共享）")
    }
}

enum SharedKeychain {
    private static let service = "com.hmb269.nbawidget.favorites"
    private static let account = "teams"

    /// 形如 TEAMID.com.hmb269.nbawidget.shared，签名不允许时为 nil
    static let group: String? = {
        guard let prefix = teamPrefix() else { return nil }
        let g = prefix + ".com.hmb269.nbawidget.shared"
        var probe: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.hmb269.nbawidget.probe",
            kSecAttrAccount as String: "probe",
            kSecAttrAccessGroup as String: g
        ]
        SecItemDelete(probe as CFDictionary)
        probe[kSecValueData as String] = Data([1])
        probe[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let st = SecItemAdd(probe as CFDictionary, nil)
        return (st == errSecSuccess || st == errSecDuplicateItem) ? g : nil
    }()

    static func load() -> [String]? {
        guard let g = group else { return nil }
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: g,
            kSecReturnData as String: true
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let arr = try? JSONDecoder().decode([String].self, from: data)
        else { return nil }
        return arr
    }

    static func save(_ teams: [String]) {
        guard let g = group, let data = try? JSONEncoder().encode(teams) else { return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: g
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    /// 用一条临时钥匙串记录读出签名的 Team ID 前缀
    private static func teamPrefix() -> String? {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.hmb269.nbawidget.prefix",
            kSecAttrAccount as String: "prefix"
        ]
        var q = base
        q[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        var st = SecItemCopyMatching(q as CFDictionary, &result)
        if st == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = Data()
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            add[kSecReturnAttributes as String] = true
            st = SecItemAdd(add as CFDictionary, &result)
        }
        guard st == errSecSuccess,
              let attrs = result as? [String: Any],
              let accessGroup = attrs[kSecAttrAccessGroup as String] as? String,
              let prefix = accessGroup.split(separator: ".").first
        else { return nil }
        return String(prefix)
    }
}
