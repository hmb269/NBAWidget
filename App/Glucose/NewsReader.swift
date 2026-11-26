import SwiftUI
import WebKit
#if canImport(Translation)
import Translation
#endif

// 资讯阅读页：在后台用看不见的网页把文章打开（能处理跳转和要运行脚本的网站），
// 用 Mozilla Readability 提取正文（段落、小标题、图片），再用 App 自己的样式排版；国外文章逐段翻译

struct NewsBlock: Codable, Hashable {
    var k: String      // p 段落 / h 小标题 / li 列表 / q 引用 / img 图片
    var v: String
}

struct NewsArticle: Codable {
    var title: String?
    var site: String?
    var image: String?
    var blocks: [NewsBlock]
    var zh: [String]?          // 和 blocks 一一对应（图片位置放原地址）
    var finalURL: String

    var textCount: Int { blocks.filter { $0.k != "img" }.map(\.v.count).reduce(0, +) }
}

enum NewsCache {
    private static let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("news-articles-v2")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private static func file(_ link: String) -> URL {
        let name = String(link.unicodeScalars.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1.value) })
        return dir.appendingPathComponent(name + ".json")
    }
    static func get(_ link: String) -> NewsArticle? {
        guard let d = try? Data(contentsOf: file(link)) else { return nil }
        return try? JSONDecoder().decode(NewsArticle.self, from: d)
    }
    static func put(_ a: NewsArticle, for link: String) {
        if let d = try? JSONEncoder().encode(a) { try? d.write(to: file(link)) }
    }
}

// MARK: - 后台网页提取

@MainActor
final class WebArticleExtractor: NSObject, WKNavigationDelegate {
    private var web: WKWebView?
    private var cont: CheckedContinuation<NewsArticle?, Never>?
    private var best: NewsArticle?
    private var attempts = 0
    private var pending: DispatchWorkItem?

    private static let script = ReadabilityJS.source + "\n" + #"""
    (function(){
      try {
        function txt(e){ return (e.textContent || '').replace(/\s+/g, ' ').trim(); }
        function abs(u){ try { return new URL(u, location.href).href; } catch(e) { return null; } }
        function imgSrc(i){
          var s = i.getAttribute('data-src') || i.getAttribute('data-original') || i.getAttribute('data-lazy-src') || i.getAttribute('src');
          if (!s || /^data:/.test(s)) return null;
          return abs(s);
        }
        var og = document.querySelector('meta[property="og:image"]');
        var doc = document.cloneNode(true);
        var art = new Readability(doc, { charThreshold: 150 }).parse();
        if (!art) return JSON.stringify({ ok: false });
        var box = document.createElement('div');
        box.innerHTML = art.content;
        var out = [];
        function pushImgs(el){ el.querySelectorAll('img').forEach(function(i){ var s = imgSrc(i); if (s) out.push({k:'img', v:s}); }); }
        function directText(el){
          for (var n = el.firstChild; n; n = n.nextSibling) if (n.nodeType === 3 && n.textContent.trim().length > 0) return true;
          return false;
        }
        function walk(n){
          for (var c = n.firstElementChild; c; c = c.nextElementSibling) {
            var t = c.tagName;
            if (/^H[1-6]$/.test(t)) { var s = txt(c); if (s) out.push({k:'h', v:s}); continue; }
            if (t === 'IMG') { var s2 = imgSrc(c); if (s2) out.push({k:'img', v:s2}); continue; }
            if (t === 'FIGURE' || t === 'PICTURE') { pushImgs(c); continue; }
            if (t === 'P' || t === 'BLOCKQUOTE' || t === 'LI' || t === 'PRE' || t === 'TABLE' || directText(c) || c.children.length === 0) {
              pushImgs(c);
              var s3 = txt(c);
              if (s3.length > 1) out.push({k: t === 'LI' ? 'li' : (t === 'BLOCKQUOTE' ? 'q' : 'p'), v: s3});
              continue;
            }
            walk(c);
          }
        }
        walk(box);
        return JSON.stringify({ ok: true, title: art.title, site: art.siteName, image: og ? abs(og.getAttribute('content')) : null, blocks: out, url: location.href });
      } catch (e) { return JSON.stringify({ ok: false, err: String(e) }); }
    })();
    """#

    func extract(_ url: URL) async -> NewsArticle? {
        await withCheckedContinuation { c in
            cont = c
            let cfg = WKWebViewConfiguration()
            cfg.websiteDataStore = .nonPersistent()
            let w = WKWebView(frame: CGRect(x: -3000, y: 0, width: 390, height: 844), configuration: cfg)
            w.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
            w.navigationDelegate = self
            w.alpha = 0.01
            w.isUserInteractionEnabled = false
            // 挂到窗口上，脚本才会正常跑
            if let win = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first {
                win.insertSubview(w, at: 0)
            }
            web = w
            w.load(URLRequest(url: url, timeoutInterval: 20))
            DispatchQueue.main.asyncAfter(deadline: .now() + 22) { [weak self] in self?.finish() }
        }
    }

    private func schedule(_ delay: Double) {
        pending?.cancel()
        let job = DispatchWorkItem { [weak self] in Task { @MainActor in await self?.attempt() } }
        pending = job
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: job)
    }

    private func attempt() async {
        guard let w = web, cont != nil else { return }
        attempts += 1
        let host = w.url?.host ?? ""
        let redirecting = host.contains("news.google.") || host.contains("bing.com")
        if !redirecting, let s = try? await w.evaluateJavaScript(Self.script) as? String,
           let d = s.data(using: .utf8),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], j["ok"] as? Bool == true {
            let raw = (j["blocks"] as? [[String: String]]) ?? []
            let blocks = Self.clean(raw.compactMap { b in b["k"].flatMap { k in b["v"].map { NewsBlock(k: k, v: $0) } } })
            let a = NewsArticle(title: j["title"] as? String, site: j["site"] as? String, image: j["image"] as? String,
                                blocks: blocks, zh: nil, finalURL: (j["url"] as? String) ?? w.url?.absoluteString ?? "")
            if a.textCount > (best?.textCount ?? 0) { best = a }
            // 正文够长就不用再等了
            if a.textCount >= 300 && attempts >= 2 { finish(); return }
        }
        if attempts < 8 { schedule(1.5) } else { finish() }
    }

    private func finish() {
        pending?.cancel()
        guard let c = cont else { return }
        cont = nil
        web?.stopLoading()
        web?.navigationDelegate = nil
        web?.removeFromSuperview()
        web = nil
        c.resume(returning: (best?.textCount ?? 0) >= 80 ? best : nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        schedule(1.0)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        schedule(0.5)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        schedule(0.5)
    }
    /// 不让它跳到别的 App（比如「打开搜狐 App」）
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let scheme = action.request.url?.scheme?.lowercased() ?? ""
        decisionHandler(["http", "https", "about", "data", "blob"].contains(scheme) ? .allow : .cancel)
    }

    // 去掉广告、下载 App、版权声明之类的段落和小图标
    private static let junk = ["打开APP", "打开App", "下载APP", "下载App", "返回搜狐", "查看更多", "责任编辑", "免责声明", "版权归", "版权所有",
                               "未经授权", "转载请", "扫码", "扫描二维码", "关注我们", "关注公众号", "点击关注", "点击查看", "阅读原文", "广告",
                               "Copyright", "All rights reserved", "Cookie", "Subscribe", "newsletter", "Sign up", "Click here",
                               "Story Source", "Materials provided by", "Cite This Page", "Journal Reference", "Provided by", "More information:",
                               "This document is subject to copyright", "Explore further"]
    private static let badImg = ["logo", "icon", "avatar", "qrcode", "qr_code", "erweima", "share", "banner", "/ad/", "ads.", "pixel", "1x1", ".gif", ".svg"]

    private static func clean(_ blocks: [NewsBlock]) -> [NewsBlock] {
        var out: [NewsBlock] = []
        var seen = Set<String>()
        for b in blocks {
            if b.k == "img" {
                let l = b.v.lowercased()
                guard !badImg.contains(where: { l.contains($0) }), !seen.contains(b.v) else { continue }
            } else {
                let t = b.v
                guard t.count >= 2, !(t.count < 60 && junk.contains(where: { t.localizedCaseInsensitiveContains($0) })) else { continue }
                guard !seen.contains(t) else { continue }
            }
            seen.insert(b.v)
            out.append(b)
        }
        // 末尾的短小杂项（编辑、来源之类）
        while let last = out.last, last.k != "img", last.v.count < 25 { out.removeLast() }
        return out
    }
}

enum NewsExtractor {
    @MainActor
    static func load(_ link: String) async -> NewsArticle? {
        if let c = NewsCache.get(link) { return c }
        guard let u = URL(string: link) else { return nil }
        let a = await WebArticleExtractor().extract(u)
        if let a { NewsCache.put(a, for: link) }
        return a
    }
}

// MARK: - 阅读页

struct NewsReaderView: View {
    let item: NewsItem
    @State private var article: NewsArticle?
    @State private var loading = true
    @State private var showOriginal = false
    @AppStorage("newsFontSize") private var fontSize: Double = 17

    private let accent = Color(red: 0.35, green: 0.7, blue: 1.0)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if loading {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("正在提取正文…").font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 50)
                } else if let a = article {
                    if a.blocks.first?.k != "img", let img = a.image, let u = URL(string: img) {
                        imageView(u)
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
                        Text("这篇没提取到正文，可以点下面「打开原网页」看。")
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
                Text(article?.site?.isEmpty == false ? article!.site! : item.source).lineLimit(1)
                Text("·")
                Text(dateText(item.date))
            }
            .font(.caption).foregroundStyle(.secondary)
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
        }
    }

    private func imageView(_ u: URL) -> some View {
        AsyncImage(url: u) { ph in
            if let i = ph.image {
                i.resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else if ph.error != nil {
                EmptyView()
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.05)).frame(height: 180)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func articleBody(_ a: NewsArticle) -> some View {
        let useZh = item.foreign && !showOriginal
        let titleKey = (a.title ?? item.title).filter { !$0.isWhitespace }
        return VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(a.blocks.enumerated()), id: \.offset) { i, b in
                let text = useZh ? (a.zh?[safe: i] ?? b.v) : b.v
                // 正文开头重复的标题不再显示
                if i < 3 && b.k != "img" && b.v.filter({ !$0.isWhitespace }) == titleKey {
                    EmptyView()
                } else {
                    block(b, text: text)
                }
            }
        }
    }

    @ViewBuilder
    private func block(_ b: NewsBlock, text: String) -> some View {
        switch b.k {
        case "img":
            if let u = URL(string: b.v) { imageView(u) }
        case "h":
            Text(text).font(.system(size: fontSize + 2, weight: .bold))
                .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
        case "li":
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(accent).frame(width: 5, height: 5).offset(y: -3)
                Text(text).font(.system(size: fontSize)).lineSpacing(fontSize * 0.4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case "q":
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(accent.opacity(0.7)).frame(width: 3)
                Text(text).font(.system(size: fontSize - 1)).italic().foregroundStyle(.secondary)
                    .lineSpacing(fontSize * 0.4).fixedSize(horizontal: false, vertical: true)
            }
        default:
            Text(text)
                .font(.system(size: fontSize))
                .lineSpacing(fontSize * 0.45)
                .foregroundStyle(.primary.opacity(0.92))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func dateText(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy年M月d日 HH:mm"
        return f.string(from: d)
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
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
            .onChange(of: article?.blocks.count ?? 0) { _, n in
                if n >= 1 && article?.zh == nil && config == nil {
                    config = .init(source: Locale.Language(identifier: "en"), target: Locale.Language(identifier: "zh-Hans"))
                }
            }
            .translationTask(config) { session in
                let bs = await MainActor.run { article?.blocks ?? [] }
                guard !bs.isEmpty else { return }
                let reqs = bs.enumerated().filter { $0.element.k != "img" }
                    .map { TranslationSession.Request(sourceText: $0.element.v, clientIdentifier: String($0.offset)) }
                guard let res = try? await session.translations(from: reqs) else { return }
                var out = bs.map(\.v)
                for r in res { if let i = r.clientIdentifier.flatMap(Int.init), i < out.count { out[i] = r.targetText } }
                await MainActor.run {
                    article?.zh = out
                    if let a = article { NewsCache.put(a, for: link) }
                }
            }
    }
}

/// 打开原网页（在 App 里）
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
