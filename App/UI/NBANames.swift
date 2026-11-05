import Foundation

// 球员中文名：
// 1. 先查 NBA 中国官网的球员名单（官方译名，一周更新一次，缓存在本机）
// 2. 再查内置的常见球星
// 3. 都没有就按英文读音自动音译

enum NBANames {
    private static let cacheKey = "nbaChinaNames"
    private static let cacheTimeKey = "nbaChinaNamesTime"

    /// 英文全名（规范化后）→ (中文全名, 中文姓)
    private static var official: [String: [String]] = {
        (UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: [String]]) ?? [:]
    }()

    static func normalize(_ s: String) -> String {
        var t = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "en_US"))
        for junk in [".", "'", "’", ",", " jr", " sr", " iii", " ii", " iv"] { t = t.replacingOccurrences(of: junk, with: "") }
        return t.replacingOccurrences(of: "-", with: " ").split(separator: " ").joined(separator: " ")
    }

    /// 后台拉一次官方名单（7 天内拉过就不拉）
    static func refreshIfNeeded() async {
        let last = UserDefaults.standard.double(forKey: cacheTimeKey)
        guard Date().timeIntervalSince1970 - last > 7 * 86400 || official.isEmpty else { return }
        for url in ["https://china.nba.cn/static/data/league/playerlist.json",
                    "https://china.nba.com/static/data/league/playerlist.json"] {
            guard let u = URL(string: url), let res = try? await URLSession.shared.data(from: u),
                  let root = (try? JSONSerialization.jsonObject(with: res.0)) as? [String: Any],
                  let players = (root["payload"] as? [String: Any])?["players"] as? [[String: Any]] else { continue }
            var map: [String: [String]] = [:]
            for p in players {
                guard let prof = p["playerProfile"] as? [String: Any],
                      let en = prof["displayNameEn"] as? String, let zh = prof["displayName"] as? String, !zh.isEmpty else { continue }
                let last = (prof["lastName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? zh.split(whereSeparator: { "-·• ".contains($0) }).last.map(String.init) ?? zh
                map[normalize(en)] = [zh.replacingOccurrences(of: "-", with: "·"), last]
            }
            if map.count > 100 {
                official = map
                UserDefaults.standard.set(map, forKey: cacheKey)
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: cacheTimeKey)
                return
            }
        }
    }

    /// 表格里用的短名（一般是姓）
    static func short(_ english: String) -> String {
        if let o = official[normalize(english)] { return o[1] }
        if let c = NBAPlayers.chinese[english] { return c }
        let parts = normalize(english).split(separator: " ")
        return transliterate(String(parts.last ?? ""))
    }

    /// 全名（详细一点的地方用）
    static func full(_ english: String) -> String {
        if let o = official[normalize(english)] { return o[0] }
        let parts = normalize(english).split(separator: " ").map(String.init)
        let last = NBAPlayers.chinese[english] ?? transliterate(parts.last ?? "")
        guard parts.count > 1 else { return last }
        return transliterate(parts[0]) + "·" + last
    }

    // MARK: - 音译（按《英语姓名译名手册》的常用字，粗略版）

    private static let chunks: [(String, String)] = {
        var t: [(String, String)] = [
            // 常见结尾 / 整块
            ("son", "森"), ("ton", "顿"), ("man", "曼"), ("ford", "福德"), ("field", "菲尔德"), ("berg", "伯格"),
            ("ley", "利"), ("ly", "利"), ("ney", "尼"), ("ny", "尼"), ("rey", "雷"), ("ry", "里"), ("dy", "迪"),
            ("ty", "蒂"), ("cy", "西"), ("ky", "基"), ("by", "比"), ("gy", "吉"), ("my", "米"), ("sy", "西"),
            ("tion", "申"), ("sh", "什"), ("ch", "奇"), ("ck", "克"), ("ph", "夫"), ("th", "斯"), ("qu", "奎"),
            ("ee", "伊"), ("ea", "伊"), ("oo", "乌"), ("ou", "欧"), ("au", "奥"), ("ai", "艾"), ("ay", "艾"),
            ("ei", "艾"), ("ey", "伊"), ("ie", "伊"), ("oa", "奥"), ("oy", "伊"), ("oi", "奥伊"),
            ("ll", "尔"), ("ss", "斯"), ("tt", "特"), ("nn", "恩"), ("mm", "姆"), ("rr", "尔"), ("ff", "夫"), ("dd", "德"),
            ("er", "尔"), ("ar", "阿"), ("or", "奥"), ("ir", "尔"), ("ur", "尔"),
        ]
        // 辅音 + an/en/in/on/un
        let nas: [String: [String: String]] = [
            "b": ["an": "班", "en": "本", "in": "宾", "on": "邦"],
            "c": ["an": "坎", "on": "康"],
            "d": ["an": "丹", "en": "登", "in": "丁", "on": "东", "un": "邓"],
            "f": ["an": "范", "en": "芬", "in": "芬", "on": "丰"],
            "g": ["an": "甘", "en": "根", "in": "金", "on": "贡", "un": "冈"],
            "h": ["an": "汉", "en": "亨", "in": "欣", "on": "洪", "un": "亨"],
            "j": ["an": "扬", "en": "珍", "in": "金", "on": "琼"],
            "k": ["an": "坎", "en": "肯", "in": "金", "on": "孔"],
            "l": ["an": "兰", "en": "伦", "in": "林", "on": "隆", "un": "伦"],
            "m": ["an": "曼", "en": "门", "in": "明", "on": "蒙", "un": "蒙"],
            "n": ["an": "南", "en": "嫩", "in": "宁", "on": "农"],
            "p": ["an": "潘", "en": "彭", "in": "平", "on": "庞"],
            "r": ["an": "兰", "en": "伦", "in": "林", "on": "朗", "un": "伦"],
            "s": ["an": "桑", "en": "森", "in": "辛", "on": "森", "un": "孙"],
            "t": ["an": "坦", "en": "滕", "in": "廷", "on": "通"],
            "v": ["an": "万", "en": "文", "in": "文", "on": "冯"],
            "w": ["an": "万", "en": "文", "in": "温", "on": "旺"],
            "z": ["an": "赞", "en": "曾", "in": "津"],
        ]
        for (c, m) in nas { for (v, ch) in m { t.append((c + v, ch)) } }
        // 辅音 + 元音
        let cv: [String: [String]] = [   // a e i o u
            "b": ["巴", "贝", "比", "博", "布"], "c": ["卡", "塞", "西", "科", "库"], "d": ["达", "德", "迪", "多", "杜"],
            "f": ["法", "费", "菲", "福", "富"], "g": ["加", "格", "吉", "戈", "古"], "h": ["哈", "赫", "希", "霍", "胡"],
            "j": ["贾", "杰", "吉", "乔", "朱"], "k": ["卡", "凯", "基", "科", "库"], "l": ["拉", "莱", "利", "洛", "卢"],
            "m": ["马", "梅", "米", "莫", "穆"], "n": ["纳", "内", "尼", "诺", "努"], "p": ["帕", "佩", "皮", "波", "普"],
            "r": ["拉", "雷", "里", "罗", "鲁"], "s": ["萨", "塞", "西", "索", "苏"], "t": ["塔", "特", "蒂", "托", "图"],
            "v": ["瓦", "维", "维", "沃", "武"], "w": ["沃", "韦", "威", "沃", "伍"], "y": ["亚", "耶", "伊", "约", "尤"],
            "z": ["扎", "泽", "齐", "佐", "祖"], "x": ["克萨", "克塞", "克西", "克索", "克苏"],
        ]
        let vs = ["a", "e", "i", "o", "u"]
        for (c, arr) in cv { for (i, v) in vs.enumerated() { t.append((c + v, arr[i])) } }
        for (c, arr) in [("ch", ["查", "切", "奇", "乔", "丘"]), ("sh", ["沙", "谢", "希", "肖", "舒"]),
                         ("th", ["萨", "西", "西", "索", "瑟"]), ("ph", ["法", "费", "菲", "福", "富"])] {
            for (i, v) in vs.enumerated() { t.append((c + v, arr[i])) }
        }
        return t.sorted { $0.0.count > $1.0.count }
    }()

    private static let single: [Character: String] = [
        "a": "阿", "e": "埃", "i": "伊", "o": "奥", "u": "乌", "y": "伊",
        "b": "布", "c": "克", "d": "德", "f": "夫", "g": "格", "h": "赫", "j": "杰", "k": "克", "l": "尔",
        "m": "姆", "n": "恩", "p": "普", "q": "克", "r": "尔", "s": "斯", "t": "特", "v": "夫", "w": "沃",
        "x": "克斯", "z": "兹",
    ]

    static func transliterate(_ word: String) -> String {
        var w = Array(word.lowercased().filter { $0.isLetter })
        guard !w.isEmpty else { return word }
        // 词尾不发音的 e（Wade、Blake）
        if w.count > 3, w.last == "e", let p = w.dropLast().last, !"aeiou".contains(p) { w.removeLast() }
        var out = "", i = 0
        while i < w.count {
            var matched = false
            for (k, v) in chunks where k.count <= w.count - i {
                if String(w[i..<(i + k.count)]) == k {
                    // 开头的 h 不发音（Hayes 照译）；其他照表
                    out += v; i += k.count; matched = true; break
                }
            }
            if !matched {
                if let s = single[w[i]] { out += s }
                i += 1
            }
        }
        return out
    }
}
