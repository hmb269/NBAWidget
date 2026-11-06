import SwiftUI
import Security

// 大模型看图识别彩票：国内几家都支持 OpenAI 兼容接口（/chat/completions + 图片），
// 在设置里选厂商、填 API Key、选模型。照片会上传到所选厂商。

enum LotteryAIProvider: String, CaseIterable, Identifiable {
    case qwen, doubao, glm, kimi, siliconflow, custom
    var id: String { rawValue }

    var name: String {
        switch self {
        case .qwen: return "通义千问"
        case .doubao: return "豆包"
        case .glm: return "智谱 GLM"
        case .kimi: return "Kimi"
        case .siliconflow: return "硅基流动"
        case .custom: return "自定义"
        }
    }

    var site: String {
        switch self {
        case .qwen: return "阿里云百炼 bailian.console.aliyun.com"
        case .doubao: return "火山方舟 console.volcengine.com/ark"
        case .glm: return "智谱开放平台 open.bigmodel.cn"
        case .kimi: return "Kimi 开放平台 platform.moonshot.cn"
        case .siliconflow: return "硅基流动 cloud.siliconflow.cn"
        case .custom: return "任何 OpenAI 兼容接口"
        }
    }

    var baseURL: String {
        switch self {
        case .qwen: return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .doubao: return "https://ark.cn-beijing.volces.com/api/v3"
        case .glm: return "https://open.bigmodel.cn/api/paas/v4"
        case .kimi: return "https://api.moonshot.cn/v1"
        case .siliconflow: return "https://api.siliconflow.cn/v1"
        case .custom: return ""
        }
    }

    /// 可选的看图模型（第一个是默认）；也可以自己填
    var models: [String] {
        switch self {
        case .qwen: return ["qwen-vl-max", "qwen3-vl-plus", "qwen-vl-plus"]
        case .doubao: return ["doubao-seed-1-6-vision-250815", "doubao-1-5-vision-pro-32k-250115"]
        case .glm: return ["glm-4v-plus", "glm-4.5v", "glm-4v-flash"]
        case .kimi: return ["moonshot-v1-8k-vision-preview", "kimi-latest"]
        case .siliconflow: return ["Qwen/Qwen2.5-VL-72B-Instruct", "Qwen/Qwen2.5-VL-32B-Instruct"]
        case .custom: return []
        }
    }
}

enum LotteryAIMode: String, CaseIterable, Identifiable {
    case off, fallback, always
    var id: String { rawValue }
    var name: String {
        switch self {
        case .off: return "不用"
        case .fallback: return "本地认不出时"
        case .always: return "总是用"
        }
    }
}

enum LotteryAISettings {
    private static let d = UserDefaults.standard

    static var mode: LotteryAIMode {
        get { LotteryAIMode(rawValue: d.string(forKey: "lotteryAIMode") ?? "") ?? .off }
        set { d.set(newValue.rawValue, forKey: "lotteryAIMode") }
    }
    static var provider: LotteryAIProvider {
        get { LotteryAIProvider(rawValue: d.string(forKey: "lotteryAIProvider") ?? "") ?? .qwen }
        set { d.set(newValue.rawValue, forKey: "lotteryAIProvider") }
    }
    static func model(_ p: LotteryAIProvider) -> String {
        let m = d.string(forKey: "lotteryAIModel." + p.rawValue) ?? ""
        return m.isEmpty ? (p.models.first ?? "") : m
    }
    static func setModel(_ m: String, for p: LotteryAIProvider) { d.set(m, forKey: "lotteryAIModel." + p.rawValue) }
    static var customBase: String {
        get { d.string(forKey: "lotteryAIBase") ?? "" }
        set { d.set(newValue, forKey: "lotteryAIBase") }
    }
    static func baseURL(_ p: LotteryAIProvider) -> String { p == .custom ? customBase : p.baseURL }
    static func key(_ p: LotteryAIProvider) -> String { Keychain.get("lotteryAIKey." + p.rawValue) ?? "" }
    static func setKey(_ k: String, for p: LotteryAIProvider) { Keychain.set(k, for: "lotteryAIKey." + p.rawValue) }

    static var ready: Bool {
        let p = provider
        return !key(p).isEmpty && !model(p).isEmpty && !baseURL(p).isEmpty
    }
}

/// API Key 存在钥匙串里（不进备份文件）
enum Keychain {
    static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func set(_ value: String, for account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        guard !value.isEmpty else { return }
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

enum LotteryAI {
    struct AIError: LocalizedError {
        let msg: String
        var errorDescription: String? { msg }
    }

    static let prompt = """
    你是中国彩票识别助手。仔细看这张彩票照片，只输出一个 JSON 对象，不要输出任何其他文字。格式：
    {"game":"ssq|dlt|kl8|qxc","issue":"期号","periods":期数,"multiple":倍数,"amount":票面金额,"added":是否追加,"pick":快乐8选几,"draw_date":"YYYY-MM-DD","bets":[{"front":[前区号码],"back":[后区号码]}]}
    规则：
    - game：双色球=ssq，超级大乐透=dlt，快乐8=kl8，7星彩/七星彩=qxc。
    - issue：票上「第xxxx期」的数字，原样照抄（七星彩、大乐透常是 5 位，如 26107）。
    - periods：多期票写的期数（如「10期10倍」→ periods=10，multiple=10），单期为 1。
    - multiple：倍数，如「[1倍]」「10倍」，没写为 1。
    - amount：票面「金额」或「合计」的数字（元）。
    - added：大乐透写了「追加」为 true，否则 false。
    - pick：快乐8 的「选几」（选十=10），其他玩法填 null。
    - draw_date：票上的开奖日期，没有填 ""。
    - bets：每一注一项。号码用整数。
      双色球 front 是红球（1~33），back 是蓝球（1~16）；
      大乐透 front 是前区（1~35），back 是后区（1~12）；
      快乐8 front 是这一注的全部号码（1~80，复式会有多于「选几」个号码，号码之间常用 + 连接、可能跨行），back 为空；
      七星彩 front 是前 6 位（每位 0~9，按顺序），back 是最后 1 位（0~14）。
    - 票上的票号、流水号、验票码、站点编号、时间、金额都不是号码，不要放进 bets。
    - 看不清的地方按彩票格式合理判断，不要编造多余的注。
    """

    /// 把照片缩到长边 1600、转成 JPEG
    private static func jpeg(_ image: UIImage) -> Data? {
        let maxSide: CGFloat = 1600
        let s = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * s, height: image.size.height * s)
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
        let img = UIGraphicsImageRenderer(size: size, format: fmt).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return img.jpegData(compressionQuality: 0.85)
    }

    /// 调用所选的大模型，返回识别结果
    static func read(_ image: UIImage) async throws -> TicketScan {
        let p = LotteryAISettings.provider
        let text = try await ask(image: image, provider: p, model: LotteryAISettings.model(p),
                                 key: LotteryAISettings.key(p), base: LotteryAISettings.baseURL(p))
        var t = try parse(text)
        t.engine = p.name + "大模型"
        return t
    }

    /// 发请求，返回模型回复的文字
    static func ask(image: UIImage, provider: LotteryAIProvider, model: String, key: String, base: String) async throws -> String {
        guard let data = jpeg(image) else { throw AIError(msg: "照片处理失败") }
        var b = base.trimmingCharacters(in: .whitespaces)
        while b.hasSuffix("/") { b.removeLast() }
        guard let url = URL(string: b + "/chat/completions") else { throw AIError(msg: "接口地址不对") }
        let body: [String: Any] = [
            "model": model,
            "temperature": 0,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + data.base64EncodedString()]],
                    ["type": "text", "text": prompt],
                ],
            ]],
        ]
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer " + key.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (resp, http) = try await URLSession.shared.data(for: req)
        let obj = try? JSONSerialization.jsonObject(with: resp) as? [String: Any]
        guard let code = (http as? HTTPURLResponse)?.statusCode, code == 200 else {
            let err = (obj?["error"] as? [String: Any])?["message"] as? String
                ?? obj?["message"] as? String
                ?? String(data: resp, encoding: .utf8)?.prefix(200).description ?? ""
            let code = (http as? HTTPURLResponse)?.statusCode ?? 0
            throw AIError(msg: (code == 401 || code == 403 ? "API Key 不对或没开通（\(code)）" : "接口返回 \(code)") + (err.isEmpty ? "" : "：" + err))
        }
        guard let choices = obj?["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any] else { throw AIError(msg: "返回内容看不懂") }
        if let s = msg["content"] as? String { return s }
        if let parts = msg["content"] as? [[String: Any]] { return parts.compactMap { $0["text"] as? String }.joined() }
        throw AIError(msg: "返回内容为空")
    }

    /// 从模型回复里取出 JSON，转成识别结果
    static func parse(_ text: String) throws -> TicketScan {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              let data = String(text[start...end]).data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError(msg: "没返回 JSON：" + text.prefix(80))
        }
        func int(_ v: Any?) -> Int? {
            if let i = v as? Int { return i }
            if let d = v as? Double { return Int(d) }
            if let s = v as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
            return nil
        }
        func ints(_ v: Any?) -> [Int] { (v as? [Any] ?? []).compactMap(int) }

        var t = TicketScan()
        switch (j["game"] as? String ?? "").lowercased() {
        case "dlt": t.game = .dlt
        case "kl8": t.game = .kl8
        case "qxc": t.game = .qxc
        default: t.game = .ssq
        }
        t.gameFound = true
        t.issue = (j["issue"] as? String) ?? int(j["issue"]).map(String.init) ?? ""
        t.issue = t.issue.filter(\.isNumber)
        t.multiple = max(1, int(j["multiple"]) ?? 1)
        t.added = (j["added"] as? Bool) ?? false
        if let a = j["amount"] as? Double { t.amount = a } else if let a = int(j["amount"]) { t.amount = Double(a) }
        else if let s = j["amount"] as? String { t.amount = Double(s) }
        t.drawDate = (j["draw_date"] as? String) ?? ""
        if let n = int(j["periods"]), n > 1, let start = LotteryAPI.issueNumber(t.issue) {
            let end = start + n - 1
            t.issueTo = t.issue.count == 5 ? String(end - 2_000_000) : String(end)
        }
        let pick = int(j["pick"])
        for b in (j["bets"] as? [[String: Any]]) ?? [] {
            let f = ints(b["front"]), bk = ints(b["back"])
            switch t.game {
            case .kl8:
                let nums = Array(Set(f)).sorted()
                guard !nums.isEmpty, nums.allSatisfy({ (1...80).contains($0) }) else { continue }
                let k = pick ?? nums.count
                t.bets.append(LotteryBet(front: nums, back: [], pick: nums.count > k ? k : nil))
            case .qxc:
                guard f.count == 6, f.allSatisfy({ (0...9).contains($0) }), bk.count == 1, (0...14).contains(bk[0]) else { continue }
                t.bets.append(LotteryBet(front: f, back: bk))
            case .dlt:
                guard f.count >= 5, bk.count >= 2, f.allSatisfy({ (1...35).contains($0) }), bk.allSatisfy({ (1...12).contains($0) }) else { continue }
                t.bets.append(LotteryBet(front: f.sorted(), back: bk.sorted()))
            default:
                guard f.count >= 6, bk.count >= 1, f.allSatisfy({ (1...33).contains($0) }), bk.allSatisfy({ (1...16).contains($0) }) else { continue }
                t.bets.append(LotteryBet(front: f.sorted(), back: bk.sorted()))
            }
        }
        return t
    }
}

// MARK: - 设置页卡片

struct LotteryAISettingsCard: View {
    @State private var mode = LotteryAISettings.mode
    @State private var provider = LotteryAISettings.provider
    @State private var key = LotteryAISettings.key(LotteryAISettings.provider)
    @State private var model = LotteryAISettings.model(LotteryAISettings.provider)
    @State private var base = LotteryAISettings.customBase
    @State private var testing = false
    @State private var message: String?

    var body: some View {
        CardSection(footer: message ?? "拍照对奖时让大模型看图识别，比手机本地识别准很多。照片会上传到所选厂商；需要自己在厂商网站注册、创建 API Key，按量付费，一张票通常不到一分钱。API Key 只存在本机钥匙串里。") {
            CardTitle("彩票识别 · 大模型")
            RowDivider()
            HStack {
                Text("什么时候用")
                Spacer()
                Picker("", selection: $mode) {
                    ForEach(LotteryAIMode.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.menu).tint(.secondary)
            }
            .padding(.vertical, 6)
            if mode != .off {
                RowDivider()
                HStack {
                    Text("厂商")
                    Spacer()
                    Picker("", selection: $provider) {
                        ForEach(LotteryAIProvider.allCases) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.menu).tint(.secondary)
                }
                .padding(.vertical, 6)
                Text("在 " + provider.site + " 创建 API Key")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.bottom, 6)
                RowDivider()
                if provider == .custom {
                    TextField("接口地址，如 https://…/v1", text: $base)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.URL)
                        .padding(.vertical, 10)
                    RowDivider()
                }
                SecureField("API Key", text: $key)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(.vertical, 10)
                RowDivider()
                HStack {
                    TextField("模型", text: $model)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if !provider.models.isEmpty {
                        Menu {
                            ForEach(provider.models, id: \.self) { m in Button(m) { model = m } }
                        } label: {
                            Image(systemName: "chevron.up.chevron.down").foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 10)
                RowDivider()
                Button {
                    Task { await test() }
                } label: {
                    HStack {
                        if testing { ProgressView() }
                        Label("测试连接", systemImage: "bolt.horizontal.circle")
                    }
                    .padding(.vertical, 10)
                }
                .disabled(testing || key.isEmpty)
            }
        }
        .onChange(of: mode) { _, v in LotteryAISettings.mode = v }
        .onChange(of: provider) { _, p in
            LotteryAISettings.provider = p
            key = LotteryAISettings.key(p)
            model = LotteryAISettings.model(p)
            message = nil
        }
        .onChange(of: key) { _, v in LotteryAISettings.setKey(v.trimmingCharacters(in: .whitespacesAndNewlines), for: provider) }
        .onChange(of: model) { _, v in LotteryAISettings.setModel(v.trimmingCharacters(in: .whitespaces), for: provider) }
        .onChange(of: base) { _, v in LotteryAISettings.customBase = v.trimmingCharacters(in: .whitespaces) }
    }

    /// 发一张小图测试 Key 和模型能不能用
    private func test() async {
        testing = true
        defer { testing = false }
        let size = CGSize(width: 320, height: 120)
        let img = UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            ("双色球 01 05 12 18 23 30 + 07" as NSString).draw(at: CGPoint(x: 12, y: 45),
                withAttributes: [.font: UIFont.systemFont(ofSize: 18), .foregroundColor: UIColor.black])
        }
        do {
            let text = try await LotteryAI.ask(image: img, provider: provider, model: LotteryAISettings.model(provider),
                                               key: LotteryAISettings.key(provider), base: LotteryAISettings.baseURL(provider))
            let t = try? LotteryAI.parse(text)
            message = (t?.bets.isEmpty == false) ? "✅ 连接成功，模型能看图识别号码" : "⚠️ 连接成功，但模型没按要求返回号码，换个模型试试：" + text.prefix(60)
        } catch {
            message = "❌ " + error.localizedDescription
        }
    }
}
