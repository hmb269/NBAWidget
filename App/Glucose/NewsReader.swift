import SwiftUI
import WebKit
#if canImport(Translation)
import Translation
#endif

// 资讯阅读页：把网页正文抓下来，用 App 自己的样式排版；国外文章自动翻译成中文

struct NewsArticle: Codable {
    var title: String?
    var image: String?
    var paragraphs: [String]
    var zh: [String]?
    var finalURL: String
}

enum NewsExtractor {
    private static let cacheDir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("news-articles")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private static func file(_ link: String) -> URL {
        let name = String(link.unicodeScalars.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1.value) })
        return cacheDir.appendingPathComponent(name + ".json")
    }

    static func cached(_ link: String) -> NewsArticle? {
        guard let d = try? Data(contentsOf: file(link)) else { return nil }
        return try? JSONDecoder().decode(NewsArticle.self, from: d)
    }

    static func save(_ a: NewsArticle, for link: String) {
        if let d = try? JSONEncoder().encode(a) { try? d.write(to: file(link)) }
    }

    static func load(_ link: String) async -> NewsArticle? {
        if let c = cached(link) { return c }
        guard let u = URL(string: link) else { return nil }
        var req = URLRequest(url: u, timeoutInterval: 15)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        req.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return nil }
        var html = decode(data, resp)
        var final = resp.url?.absoluteString ?? link
        // 必应的跳转页：找真正的地址再抓一次
        if final.contains("bing.com"), let real = firstMatch(html, #"(?:url|href)\s*[=:]\s*["']?(https?://(?!www\.bing|cn\.bing)[^"'\s>]+)"#) {
            let r = real.replacingOccurrences(of: "&amp;", with: "&")
            if let u2 = URL(string: r) {
                var req2 = req; req2.url = u2
                if let (d2, resp2) = try? await URLSession.shared.data(for: req2) {
                    html = decode(d2, resp2); final = resp2.url?.absoluteString ?? r
                }
            }
        }
        let a = extract(html, url: final)
        if a.paragraphs.count >= 2 { save(a, for: link) }
        return a
    }

    private static func decode(_ data: Data, _ resp: URLResponse) -> String {
        var enc: String.Encoding = .utf8
        var name = resp.textEncodingName
        if name == nil, let head = String(data: data.prefix(3000), encoding: .ascii) {
            name = firstMatch(head, #"charset=["']?([A-Za-z0-9_\-]+)"#)
        }
        if let n = name?.lowercased() {
            let cf = CFStringConvertIANACharSetNameToEncoding(n as CFString)
            if cf != kCFStringEncodingInvalidId { enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf)) }
        }
        return String(data: data, encoding: enc) ?? String(decoding: data, as: UTF8.self)
    }

    static func firstMatch(_ s: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    private static func all(_ s: String, _ pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { m in
            Range(m.range(at: 1), in: s).map { String(s[$0]) }
        }
    }

    private static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (a, b) in [("&nbsp;", " "), ("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&rsquo;", "'"), ("&lsquo;", "'"),
                       ("&ldquo;", "“"), ("&rdquo;", "”"), ("&mdash;", "—"), ("&ndash;", "–"), ("&lt;", "<"), ("&gt;", ">"), ("&hellip;", "…")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        t = t.replacingOccurrences(of: "&#(\\d+);", with: "", options: .regularExpression)
        return t.replacingOccurrences(of: "[ \\t\\u3000]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let junk = ["copyright", "all rights reserved", "cookie", "subscribe", "newsletter", "sign up", "click here",
                               "版权", "责任编辑", "免责声明", "转载", "扫码", "关注我们", "点击", "下载app", "广告", "原标题",
                               "来源：", "编辑：", "记者：", "联系我们", "举报", "Story Source", "Materials provided by", "Journal Reference",
                               "Cite This Page", "This document is subject to copyright", "More information:", "Provided by"]

    static func extract(_ raw: String, url: String) -> NewsArticle {
        // 去掉脚本、样式、导航、页脚
        var html = raw
        for tag in ["script", "style", "noscript", "nav", "footer", "header", "aside", "form", "figcaption"] {
            html = html.replacingOccurrences(of: "(?s)<\(tag)\\b[^>]*>.*?</\(tag)>", with: "", options: [.regularExpression, .caseInsensitive])
        }
        let title = firstMatch(raw, #"<meta[^>]+property=["']og:title["'][^>]+content=["']([^"']+)"#)
            ?? firstMatch(raw, #"<title[^>]*>([^<]+)</title>"#)
        var image = firstMatch(raw, #"<meta[^>]+property=["']og:image["'][^>]+content=["']([^"']+)"#)
            ?? firstMatch(raw, #"<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:image["']"#)
        if let i = image, i.hasPrefix("//") { image = "https:" + i }

        // 已知网站的正文区域
        var scope = html
        let known: [(String, String)] = [
            ("sciencedaily.com", #"<div[^>]+id=["']text["'][^>]*>(.*?)</div>"#),
            ("medicalxpress.com", #"<div[^>]+class=["'][^"']*article-main[^"']*["'][^>]*>(.*?)<div[^>]+class=["'][^"']*article-main__more"#),
        ]
        for (host, pat) in known where url.contains(host) {
            if let body = all(html, pat).first { scope = body }
        }

        var paras: [String] = []
        for p in all(scope, #"<p\b[^>]*>(.*?)</p>"#) {
            let t = clean(p)
            let cjk = t.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
            guard t.count >= (cjk ? 18 : 50) else { continue }
            guard !junk.contains(where: { t.localizedCaseInsensitiveContains($0) }) else { continue }
            if !paras.contains(t) { paras.append(t) }
        }
        // 没有 <p> 的网站：按 <div> 里的大段文字兜底
        if paras.count < 2 {
            for d in all(scope, #"<div\b[^>]*>([^<]{60,})</div>"#) {
                let t = clean(d)
                if t.count >= 40, !junk.contains(where: { t.localizedCaseInsensitiveContains($0) }) { paras.append(t) }
            }
        }
        return NewsArticle(title: title.map(clean), image: image, paragraphs: Array(paras.prefix(60)), zh: nil, finalURL: url)
    }
}

// MARK: - 阅读页

struct NewsReaderView: View {
    let item: NewsItem
    @State private var article: NewsArticle?
    @State private var loading = true
    @State private var showOriginal = false
    @State private var fontSize: CGFloat = 17

    private let accent = Color(red: 0.35, green: 0.7, blue: 1.0)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if loading {
                    HStack { Spacer(); ProgressView("正在加载正文…"); Spacer() }.padding(.vertical, 40)
                } else if let a = article, a.paragraphs.count >= 2 {
                    if let img = a.image, let u = URL(string: img) {
                        AsyncImage(url: u) { ph in
                            if let i = ph.image { i.resizable().scaledToFill() } else { Color.white.opacity(0.05) }
                        }
                        .frame(maxWidth: .infinity).frame(height: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    if item.foreign {
                        Picker("", selection: $showOriginal) {
                            Text("中文").tag(false)
                            Text("英文原文").tag(true)
                        }
                        .pickerStyle(.segmented)
                        if !showOriginal && a.zh == nil {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("正在翻译…（第一次要下载中文语言包）").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    articleBody(a)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        if !item.shownSummary.isEmpty {
                            Text(item.shownSummary).font(.system(size: fontSize)).lineSpacing(6)
                        }
                        Text("这个网站的正文没法直接排版，点下面「打开原网页」看全文。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                NavigationLink {
                    NewsWebView(url: URL(string: article?.finalURL ?? item.link) ?? URL(string: "about:blank")!)
                        .background(AppBackground())
                        .navigationTitle(item.source)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar(.visible, for: .navigationBar)
                } label: {
                    Label("打开原网页", systemImage: "globe").frame(maxWidth: .infinity)
                }
                .glassButton()
                .padding(.top, 8)

                Text("只是资讯，用药和治疗请听医生的。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(20)
            .padding(.bottom, 100)
        }
        .background(AppBackground())
        .navigationTitle("资讯")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("字大一点") { fontSize = min(24, fontSize + 1) }
                    Button("字小一点") { fontSize = max(14, fontSize - 1) }
                    if let u = URL(string: article?.finalURL ?? item.link) { ShareLink(item: u) }
                } label: { Image(systemName: "textformat.size") }
            }
        }
        .task {
            NewsStore.shared.markRead(item)
            article = await NewsExtractor.load(item.link)
            loading = false
        }
        .modifier(ArticleTranslator(article: $article, link: item.link, enabled: item.foreign))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.shownTitle)
                .font(.system(size: 24, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
            if item.foreign && item.zhTitle != nil {
                Text(item.title).font(.subheadline).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                if item.foreign {
                    Text("国外").font(.caption2.weight(.bold)).foregroundStyle(accent)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(accent.opacity(0.15)))
                }
                Text(item.source)
                Text("·")
                Text(dateText(item.date))
            }
            .font(.caption).foregroundStyle(.secondary)
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
        }
    }

    @ViewBuilder
    private func articleBody(_ a: NewsArticle) -> some View {
        let ps = (item.foreign && !showOriginal) ? (a.zh ?? a.paragraphs) : a.paragraphs
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(ps.enumerated()), id: \.offset) { i, p in
                Text(p)
                    .font(.system(size: fontSize, weight: i == 0 && item.foreign ? .semibold : .regular))
                    .lineSpacing(fontSize * 0.45)
                    .foregroundStyle(.primary.opacity(0.92))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func dateText(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy年M月d日 HH:mm"
        return f.string(from: d)
    }
}

/// 国外文章正文逐段翻译（iOS 18 起）
private struct ArticleTranslator: ViewModifier {
    @Binding var article: NewsArticle?
    let link: String
    let enabled: Bool

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), enabled {
            content.modifier(ArticleTranslator18(article: $article, link: link))
        } else {
            content
        }
    }
}

@available(iOS 18.0, *)
private struct ArticleTranslator18: ViewModifier {
    @Binding var article: NewsArticle?
    let link: String
    @State private var config: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .onChange(of: article?.paragraphs.count ?? 0) { _, n in
                if n >= 2 && article?.zh == nil && config == nil {
                    config = .init(source: Locale.Language(identifier: "en"), target: Locale.Language(identifier: "zh-Hans"))
                }
            }
            .translationTask(config) { session in
                let ps = await MainActor.run { article?.paragraphs ?? [] }
                guard !ps.isEmpty else { return }
                let reqs = ps.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
                guard let res = try? await session.translations(from: reqs) else { return }
                var out = ps
                for r in res { if let i = r.clientIdentifier.flatMap(Int.init), i < out.count { out[i] = r.targetText } }
                await MainActor.run {
                    article?.zh = out
                    if let a = article { NewsExtractor.save(a, for: link) }
                }
            }
    }
}

/// 正文抓不到时，在 App 里直接显示网页
struct NewsWebView: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> WKWebView {
        let w = WKWebView()
        w.isOpaque = false
        w.backgroundColor = .clear
        w.allowsBackForwardNavigationGestures = true
        w.load(URLRequest(url: url))
        return w
    }
    func updateUIView(_ w: WKWebView, context: Context) {}
}
