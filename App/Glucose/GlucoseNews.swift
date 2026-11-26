import SwiftUI
import SafariServices
#if canImport(Translation)
import Translation
#endif

// 糖尿病资讯：每天从几个新闻源抓最新的糖尿病研究 / 新药 / 治疗突破
// 中文：必应新闻、Google 新闻（按关键词搜）；国外：ScienceDaily、Medical Xpress 的糖尿病频道（iOS 18 起自动翻译标题）

struct NewsItem: Codable, Identifiable, Hashable {
    var id: String { link }
    var title: String
    var summary: String
    var source: String
    var date: Date
    var link: String
    var foreign: Bool
    var zhTitle: String?
    var zhSummary: String?

    var shownTitle: String { zhTitle ?? title }
    var shownSummary: String { zhSummary ?? summary }
}

// MARK: - RSS 解析

private final class RSSParser: NSObject, XMLParserDelegate {
    struct Raw { var title = "", link = "", date = "", desc = "", source = "" }
    var items: [Raw] = []
    private var cur: Raw?
    private var text = ""

    static func parse(_ data: Data) -> [Raw] {
        let p = RSSParser()
        let x = XMLParser(data: data)
        x.delegate = p
        x.parse()
        return p.items
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        if name == "item" || name == "entry" { cur = Raw() }
        // Atom 的链接在属性里
        if name == "link", cur != nil, let href = attributes["href"], cur?.link.isEmpty == true { cur?.link = href }
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { text += String(data: CDATABlock, encoding: .utf8) ?? "" }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard cur != nil else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = name.lowercased()
        switch n {
        case "item", "entry":
            if let c = cur { items.append(c) }
            cur = nil
        case "title": cur?.title = t
        case "link": if !t.isEmpty { cur?.link = t }
        case "pubdate", "published", "updated", "dc:date": if cur?.date.isEmpty == true { cur?.date = t }
        case "description", "summary", "content": if cur?.desc.isEmpty == true { cur?.desc = t }
        default:
            if n.hasSuffix("source") { cur?.source = t }   // <source> 或必应的 <News:Source>
        }
        text = ""
    }
}

// MARK: - 抓取和缓存

@MainActor
final class NewsStore: ObservableObject {
    static let shared = NewsStore()

    @Published var items: [NewsItem] = []
    @Published var loading = false
    @Published var lastFetch: Date?
    @Published var error: String?
    @Published var readIDs: Set<String> = []

    private static let feeds: [(url: String, name: String, foreign: Bool, filter: Bool)] = {
        func bing(_ q: String) -> String {
            "https://cn.bing.com/news/search?format=rss&setmkt=zh-CN&q=" + (q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q)
        }
        let g = "糖尿病 (研究 OR 新药 OR 突破 OR 临床试验 OR 获批 OR 治愈) when:14d"
        let google = "https://news.google.com/rss/search?hl=zh-CN&gl=CN&ceid=CN:zh-Hans&q=" + (g.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? g)
        return [
            (bing("糖尿病 研究"), "必应新闻", false, true),
            (bing("糖尿病 新药"), "必应新闻", false, true),
            (bing("糖尿病 突破"), "必应新闻", false, true),
            (bing("胰岛 干细胞"), "必应新闻", false, true),
            (google, "Google 新闻", false, true),
            ("https://www.sciencedaily.com/rss/health_medicine/diabetes.xml", "ScienceDaily", true, false),
            ("https://medicalxpress.com/rss-feed/diabetes-news/", "Medical Xpress", true, false),
        ]
    }()

    /// 中文新闻要包含其中一个词才算「研究 / 治疗」类
    nonisolated private static let keep = ["研究", "突破", "新药", "获批", "批准", "临床", "试验", "疗法", "治疗", "干细胞", "胰岛", "细胞",
                               "论文", "科学家", "团队", "发现", "首次", "首个", "全球首", "治愈", "逆转", "缓解", "GLP", "司美格鲁肽",
                               "替尔泊肽", "胰岛素", "基因", "靶点", "疫苗", "期刊", "Nature", "Cell", "Lancet", "柳叶刀", "NEJM", "医学"]
    /// 广告、偏方、股票之类的不要
    nonisolated private static let drop = ["偏方", "秘方", "根治糖尿病的", "加盟", "招聘", "股价", "涨停", "跌停", "概念股", "主力资金", "龙虎榜",
                               "研报", "券商", "保健品", "代理", "直播带货", "优惠", "促销"]

    private let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("diabetes-news.json")
    private let readKey = "newsReadIDs"

    private struct Cache: Codable { var items: [NewsItem]; var fetched: Date }

    init() {
        if let d = try? Data(contentsOf: cacheURL), let c = try? JSONDecoder().decode(Cache.self, from: d) {
            items = c.items; lastFetch = c.fetched
        }
        readIDs = Set(UserDefaults.standard.stringArray(forKey: readKey) ?? [])
    }

    var todayCount: Int { items.filter { Calendar.current.isDateInToday($0.date) }.count }
    var unreadCount: Int { items.filter { !readIDs.contains($0.id) && Date().timeIntervalSince($0.date) < 3 * 86400 }.count }

    func markRead(_ it: NewsItem) {
        readIDs.insert(it.id)
        UserDefaults.standard.set(Array(readIDs.suffix(800)), forKey: readKey)
    }

    /// 每天一次；超过 6 小时或者跨天就重新抓
    func refreshIfNeeded() async {
        if let l = lastFetch, Calendar.current.isDateInToday(l), Date().timeIntervalSince(l) < 6 * 3600, !items.isEmpty { return }
        await refresh()
    }

    func refresh() async {
        guard !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        let feeds = Self.feeds
        let results: [[NewsItem]] = await withTaskGroup(of: [NewsItem].self) { group in
            for f in feeds {
                group.addTask { await Self.fetch(f.url, name: f.name, foreign: f.foreign, filter: f.filter) }
            }
            var all: [[NewsItem]] = []
            for await r in group { all.append(r) }
            return all
        }
        let fresh = results.flatMap { $0 }
        if fresh.isEmpty {
            error = items.isEmpty ? "没抓到新闻，检查一下网络（Google 新闻需要能访问外网）" : "这次没刷新到，先显示上次的"
            return
        }
        // 合并：保留已经翻译好的
        var old: [String: NewsItem] = [:]
        for i in items { old[i.id] = i }
        var seen = Set<String>()
        var merged: [NewsItem] = []
        let cutoff = Date().addingTimeInterval(-30 * 86400)
        for var it in (fresh + items).sorted(by: { $0.date > $1.date }) where it.date > cutoff {
            let key = Self.normalize(it.title)
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            if let o = old[it.id] { it.zhTitle = it.zhTitle ?? o.zhTitle; it.zhSummary = it.zhSummary ?? o.zhSummary }
            merged.append(it)
        }
        items = Array(merged.prefix(150))
        lastFetch = Date()
        save()
    }

    func setTranslation(_ id: String, title: String?, summary: String?) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        if let title { items[i].zhTitle = title }
        if let summary { items[i].zhSummary = summary }
    }

    func save() {
        if let d = try? JSONEncoder().encode(Cache(items: items, fetched: lastFetch ?? Date())) { try? d.write(to: cacheURL) }
    }

    private static func normalize(_ t: String) -> String {
        var s = t
        // Google 新闻标题后面带「 - 来源」
        if let r = s.range(of: " - ", options: .backwards), s.distance(from: r.lowerBound, to: s.endIndex) < 30 { s = String(s[..<r.lowerBound]) }
        return s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    nonisolated private static func fetch(_ url: String, name: String, foreign: Bool, filter: Bool) async -> [NewsItem] {
        guard let u = URL(string: url) else { return [] }
        var req = URLRequest(url: u, timeoutInterval: 12)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return [] }
        return RSSParser.parse(data).compactMap { r -> NewsItem? in
            var title = stripHTML(r.title)
            var source = r.source.isEmpty ? name : r.source
            // Google 新闻：「标题 - 来源」
            if name == "Google 新闻", let rg = title.range(of: " - ", options: .backwards) {
                let tail = String(title[rg.upperBound...])
                if tail.count < 30 { source = tail; title = String(title[..<rg.lowerBound]) }
            }
            guard !title.isEmpty, !r.link.isEmpty, let date = parseDate(r.date) else { return nil }
            var summary = stripHTML(r.desc)
            if name == "Google 新闻" { summary = "" }   // 它的描述只是标题重复
            if summary.count > 160 { summary = String(summary.prefix(160)) + "…" }
            if filter {
                let text = title + summary
                guard text.contains("糖尿病") || text.contains("血糖") || text.contains("胰岛") else { return nil }
                guard keep.contains(where: { text.localizedCaseInsensitiveContains($0) }) else { return nil }
                guard !drop.contains(where: { text.contains($0) }) else { return nil }
            }
            return NewsItem(title: title, summary: summary, source: source, date: date, link: r.link, foreign: foreign)
        }
    }

    nonisolated private static func stripHTML(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (a, b) in [("&nbsp;", " "), ("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&#8217;", "'"), ("&#8220;", "\""), ("&#8221;", "\"")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        return t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func parseDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, dd MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss zzz", "EEE, d MMM yyyy HH:mm:ss Z",
                    "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm:ssXXXXX", "MM/dd/yyyy HH:mm:ss"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        return ISO8601DateFormatter().date(from: s)
    }
}

// MARK: - 血糖页入口卡片

struct GlucoseNewsCard: View {
    @ObservedObject private var store = NewsStore.shared

    var body: some View {
        NavigationLink {
            GlucoseNewsView()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "newspaper.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Color(red: 0.35, green: 0.7, blue: 1.0))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("糖尿病资讯").font(.headline)
                        if store.unreadCount > 0 {
                            Text("\(store.unreadCount) 条新").font(.caption2.weight(.bold)).foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(Color.red.opacity(0.85)))
                        }
                    }
                    Text(store.items.first?.shownTitle ?? "新研究、新药、治疗突破，每天更新")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            }
            .padding(18)
            .glassCard(24)
        }
        .buttonStyle(.plain)
        .task { await store.refreshIfNeeded() }
    }
}

// MARK: - 资讯列表

struct GlucoseNewsView: View {
    @ObservedObject private var store = NewsStore.shared
    @State private var scope = 0          // 0 全部 1 国内 2 国外
    @State private var opening: NewsItem?

    private var shown: [NewsItem] {
        switch scope {
        case 1: return store.items.filter { !$0.foreign }
        case 2: return store.items.filter(\.foreign)
        default: return store.items
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                Picker("范围", selection: $scope) {
                    Text("全部").tag(0)
                    Text("国内").tag(1)
                    Text("国外研究").tag(2)
                }
                .pickerStyle(.segmented)

                HStack {
                    if store.loading { ProgressView().controlSize(.small) }
                    Text(statusText).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }

                if let e = store.error {
                    Text(e).font(.footnote).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
                }

                ForEach(groups, id: \.0) { g in
                    Text(g.0).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                    ForEach(g.1) { it in
                        Button { store.markRead(it); opening = it } label: { row(it) }
                            .buttonStyle(.plain)
                    }
                }

                Text("新闻来自必应新闻、Google 新闻、ScienceDaily、Medical Xpress，自动按「研究 / 新药 / 临床 / 突破」筛选。只是资讯，用药和治疗请听医生的。")
                    .font(.caption2).foregroundStyle(.tertiary).padding(.top, 8)
            }
            .padding(16)
            .padding(.bottom, 100)
        }
        .background(AppBackground())
        .navigationTitle("糖尿病资讯")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(store.loading)
            }
        }
        .refreshable { await store.refresh() }
        .task { await store.refreshIfNeeded() }
        .modifier(NewsTranslator())
        .sheet(item: $opening) { it in
            if let u = URL(string: it.link) { SafariView(url: u).ignoresSafeArea() }
        }
    }

    private var statusText: String {
        guard let l = store.lastFetch else { return store.loading ? "正在获取…" : "" }
        let f = DateFormatter(); f.dateFormat = "M月d日 HH:mm"
        return "\(store.items.count) 条 · 更新于 \(f.string(from: l))"
    }

    private var groups: [(String, [NewsItem])] {
        let cal = Calendar.current
        var out: [(String, [NewsItem])] = []
        for it in shown {
            let k: String
            if cal.isDateInToday(it.date) { k = "今天" }
            else if cal.isDateInYesterday(it.date) { k = "昨天" }
            else if Date().timeIntervalSince(it.date) < 7 * 86400 { k = "本周" }
            else { k = "更早" }
            if let i = out.firstIndex(where: { $0.0 == k }) { out[i].1.append(it) } else { out.append((k, [it])) }
        }
        return out
    }

    private func row(_ it: NewsItem) -> some View {
        let read = store.readIDs.contains(it.id)
        return VStack(alignment: .leading, spacing: 6) {
            Text(it.shownTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(read ? .secondary : .primary)
                .multilineTextAlignment(.leading)
            if !it.shownSummary.isEmpty {
                Text(it.shownSummary).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            HStack(spacing: 6) {
                if it.foreign {
                    Text("国外").font(.caption2.weight(.bold)).foregroundStyle(Color(red: 0.35, green: 0.7, blue: 1.0))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color(red: 0.35, green: 0.7, blue: 1.0).opacity(0.15)))
                }
                Text(it.source).lineLimit(1)
                Text("·")
                Text(timeText(it.date))
                Spacer()
            }
            .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(18)
        .contentShape(Rectangle())
    }

    private func timeText(_ d: Date) -> String {
        let s = Date().timeIntervalSince(d)
        if s < 3600 { return "\(max(1, Int(s / 60))) 分钟前" }
        if s < 86400 { return "\(Int(s / 3600)) 小时前" }
        let f = DateFormatter(); f.dateFormat = "M月d日"
        return f.string(from: d)
    }
}

/// 国外新闻：iOS 18 起用系统自带翻译（第一次会提示下载中文语言包）
private struct NewsTranslator: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.modifier(NewsTranslator18())
        } else {
            content
        }
    }
}

@available(iOS 18.0, *)
private struct NewsTranslator18: ViewModifier {
    @ObservedObject private var store = NewsStore.shared
    @State private var config: TranslationSession.Configuration?

    private var pending: [NewsItem] { store.items.filter { $0.foreign && $0.zhTitle == nil } }

    func body(content: Content) -> some View {
        content
            .onAppear { if !pending.isEmpty { config = .init(source: Locale.Language(identifier: "en"), target: Locale.Language(identifier: "zh-Hans")) } }
            .onChange(of: store.items.count) { _, _ in
                if !pending.isEmpty {
                    if config == nil { config = .init(source: Locale.Language(identifier: "en"), target: Locale.Language(identifier: "zh-Hans")) }
                    else { config?.invalidate() }
                }
            }
            .translationTask(config) { session in
                let todo = await MainActor.run { Array(pending.prefix(40)) }
                var reqs: [TranslationSession.Request] = []
                for it in todo {
                    reqs.append(.init(sourceText: it.title, clientIdentifier: "t|" + it.id))
                    if !it.summary.isEmpty { reqs.append(.init(sourceText: it.summary, clientIdentifier: "s|" + it.id)) }
                }
                guard !reqs.isEmpty, let res = try? await session.translations(from: reqs) else { return }
                await MainActor.run {
                    for r in res {
                        guard let cid = r.clientIdentifier else { continue }
                        let id = String(cid.dropFirst(2))
                        if cid.hasPrefix("t|") { store.setTranslation(id, title: r.targetText, summary: nil) }
                        else { store.setTranslation(id, title: nil, summary: r.targetText) }
                    }
                    store.save()
                }
            }
    }
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}
