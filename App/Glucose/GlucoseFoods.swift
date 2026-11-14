import SwiftUI

// 三餐食材：给每条餐后血糖记录标上吃了什么，之后分析「吃哪些东西餐后血糖容易高」

enum GlucoseFoods {
    private static let key = "glucoseFoods"

    /// 记录 id → 食材
    static var all: [String: [String]] {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: [String]]) ?? [:]
    }
    static func get(_ id: String) -> [String] { all[id] ?? [] }
    static func set(_ foods: [String], for id: String) {
        var m = all
        m[id] = foods.isEmpty ? nil : foods
        UserDefaults.standard.set(m, forKey: key)
        AutoBackup.schedule()
    }
    static func importAll(_ incoming: [String: [String]]) {
        var m = all
        for (k, v) in incoming where m[k] == nil { m[k] = v }
        UserDefaults.standard.set(m, forKey: key)
    }

    /// 常见的，没用过时也列出来
    static let common = ["米饭", "粥", "面条", "米粉", "馒头", "面包", "红薯", "玉米", "土豆", "南瓜",
                         "鸡肉", "猪肉", "牛肉", "鱼", "虾", "鸡蛋", "豆腐",
                         "青菜", "胡萝卜", "番茄", "木耳", "黄瓜", "芹菜", "豆角",
                         "水果", "牛奶", "坚果", "甜品", "油炸"]

    /// 用过的按次数排前面，再接常见的
    static var suggestions: [String] {
        var count: [String: Int] = [:]
        for list in all.values { for f in list { count[f, default: 0] += 1 } }
        let used = count.sorted { $0.value > $1.value }.map(\.key)
        return used + common.filter { !used.contains($0) }
    }

    static let aiPrompt = """
    这是一顿饭的照片。请列出照片里能看出来的主要食物和食材（主食、肉、蔬菜等），用常见的中文叫法，比如：米饭、胡萝卜、鸡肉、青菜、豆腐、木耳。
    只输出一个 JSON 数组，例如 ["米饭","胡萝卜","鸡肉"]，不要输出其他文字。看不清的不要猜。
    """

    /// 让设置里选的大模型看照片认食材
    static func recognize(_ image: UIImage) async throws -> [String] {
        let p = LotteryAISettings.provider
        let text = try await LotteryAI.ask(image: image, provider: p, model: LotteryAISettings.model(p),
                                           key: LotteryAISettings.key(p), base: LotteryAISettings.baseURL(p),
                                           customPrompt: aiPrompt)
        guard let a = text.firstIndex(of: "["), let b = text.lastIndex(of: "]"),
              let data = String(text[a...b]).data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw LotteryAI.AIError(msg: "没认出食材")
        }
        return list.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

// MARK: - 记录详情里的「吃了什么」

struct FoodTagsCard: View {
    @Binding var foods: [String]
    let photo: GlucosePhoto?
    @State private var custom = ""
    @State private var recognizing = false
    @State private var message: String?
    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("吃了什么").font(.headline)
                Spacer()
                if photo != nil {
                    Button {
                        Task { await recognize() }
                    } label: {
                        HStack(spacing: 4) {
                            if recognizing { ProgressView().controlSize(.small) }
                            Label("从照片识别", systemImage: "sparkles")
                        }
                        .font(.caption.weight(.semibold))
                    }
                    .disabled(recognizing)
                }
            }
            if !foods.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(foods, id: \.self) { f in
                        Button {
                            withAnimation { foods.removeAll { $0 == f } }
                        } label: {
                            HStack(spacing: 3) {
                                Text(f)
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(Color(red: 0.95, green: 0.55, blue: 0.3).opacity(0.75)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack {
                TextField("输入食材，比如：胡萝卜", text: $custom)
                    .submitLabel(.done)
                    .onSubmit(addCustom)
                Button("添加", action: addCustom).disabled(custom.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))

            let sugg = GlucoseFoods.suggestions.filter { !foods.contains($0) }
            FlowLayout(spacing: 6) {
                ForEach(showAll ? sugg : Array(sugg.prefix(16)), id: \.self) { f in
                    Button {
                        withAnimation { foods.append(f) }
                    } label: {
                        Text("+ " + f).font(.caption)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                }
                if sugg.count > 16 {
                    Button(showAll ? "收起" : "更多…") { withAnimation { showAll.toggle() } }.font(.caption)
                }
            }
            if let message { Text(message).font(.caption).foregroundStyle(.orange) }
            Text("点上面的词添加，点已选的去掉。标得越多，「三餐食材分析」越准。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(18)
        .glassCard(24)
    }

    private func addCustom() {
        let parts = custom.split(whereSeparator: { "，,、 ".contains($0) }).map { String($0) }
        for p in parts where !foods.contains(p) { foods.append(p) }
        custom = ""
    }

    private func recognize() async {
        guard LotteryAISettings.ready else {
            message = "要先在 设置 → 彩票识别 · 大模型 里选厂商、填 API Key（不用打开彩票识别开关）"
            return
        }
        guard let p = photo, let img = await fullImage(p) else { message = "读不到照片"; return }
        recognizing = true
        defer { recognizing = false }
        do {
            let list = try await GlucoseFoods.recognize(img)
            withAnimation { for f in list where !foods.contains(f) { foods.append(f) } }
            message = list.isEmpty ? "没认出食材" : nil
        } catch {
            message = "识别失败：" + error.localizedDescription
        }
    }

    private func fullImage(_ p: GlucosePhoto) async -> UIImage? {
        if let id = p.assetID, let img = await GlucoseMedia.fullImage(id, side: 1600) { return img }
        return GlucoseMedia.thumb(p)
    }
}

/// 自动换行的横排
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > w, x > 0 { x = 0; y += row + spacing; row = 0 }
            x += sz.width + spacing
            row = max(row, sz.height)
        }
        return CGSize(width: w, height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += row + spacing; row = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += sz.width + spacing
            row = max(row, sz.height)
        }
    }
}

// MARK: - 三餐食材分析

struct GlucoseFoodAnalysisView: View {
    struct Row: Identifiable {
        let food: String
        let n: Int              // 吃了这个的次数
        let avgWith: Double
        let avgWithout: Double
        let overRate: Double    // 吃了时超标的比例
        let records: [(Date, Double, [String])]
        var id: String { food }
        var diff: Double { avgWith - avgWithout }
    }

    @State private var rows: [Row] = []
    @State private var total = 0
    @State private var tagged = 0
    @State private var open: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("用你自己「餐后2小时」的记录：比较吃了某样东西和没吃时的餐后血糖平均值。")
                        .font(.subheadline)
                    Text("共 \(total) 条餐后2小时记录，其中 \(tagged) 条标了食材。至少吃过 3 次的食材才下结论。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading).glassCard(20)

                if tagged < 5 {
                    Text("标了食材的记录还太少。打开血糖记录（或血糖相册里的照片）→ 编辑 →「吃了什么」，把每顿吃的标上；有照片的可以点「从照片识别」自动填。")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading).glassCard(20)
                }

                let high = rows.filter { $0.n >= 3 && $0.diff >= 0.5 }
                let low = rows.filter { $0.n >= 3 && $0.diff <= -0.5 }
                if !high.isEmpty { section("吃了餐后血糖容易偏高", high, Color(red: 1, green: 0.45, blue: 0.4)) }
                if !low.isEmpty { section("吃了餐后血糖反而偏低", low, Color(red: 0.4, green: 0.85, blue: 0.55)) }
                section("全部食材", rows, .secondary)

                Text("这是简单对比，不是医学结论：一顿饭里好几样东西一起吃，吃的量、饭后有没有走动也会影响血糖。次数越多越可信。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(16)
            .padding(.bottom, 100)
        }
        .background(AppBackground())
        .navigationTitle("三餐食材分析")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task { compute() }
    }

    private func section(_ title: String, _ list: [Row], _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).foregroundStyle(color == .secondary ? Color.primary : color)
            ForEach(list) { r in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(r.food).font(.subheadline.weight(.bold))
                        Text("吃了 \(r.n) 次").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(diffText(r)).font(.subheadline.weight(.bold).monospacedDigit())
                            .foregroundStyle(r.n < 3 ? Color.secondary : r.diff >= 0.5 ? Color(red: 1, green: 0.45, blue: 0.4)
                                             : r.diff <= -0.5 ? Color(red: 0.4, green: 0.85, blue: 0.55) : Color.primary)
                    }
                    Text(detailText(r)).font(.caption).foregroundStyle(.secondary)
                    if open == r.id {
                        ForEach(Array(r.records.enumerated()), id: \.offset) { _, x in
                            HStack(alignment: .top) {
                                Text(day(x.0)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
                                Text(String(format: "%.1f", x.1)).font(.caption.weight(.bold).monospacedDigit())
                                    .foregroundStyle(x.1 > 7.8 ? Color.red : x.1 < 3.9 ? Color.blue : Color.primary)
                                    .frame(width: 30, alignment: .leading)
                                Text(x.2.joined(separator: "、")).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard(16)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation { open = open == r.id ? nil : r.id } }
            }
        }
    }

    private func diffText(_ r: Row) -> String {
        let sign: String = r.diff >= 0 ? "+" : "−"
        return sign + String(format: "%.1f", abs(r.diff))
    }

    private func detailText(_ r: Row) -> String {
        let a: String = String(format: "%.1f", r.avgWith)
        let b: String = String(format: "%.1f", r.avgWithout)
        let o: String = String(Int((r.overRate * 100).rounded()))
        return "吃了平均 \(a)，没吃平均 \(b)；吃了时超标 \(o)%" + (r.n < 3 ? "（次数太少，仅供参考）" : "")
    }

    private func day(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "M/d HH:mm"
        return f.string(from: d)
    }

    private func compute() {
        let owners = GlucosePeople.owners
        let tags = GlucoseTags.all
        let foods = GlucoseFoods.all
        let recs = GlucoseLocal.load().filter {
            (owners[$0.id] ?? GlucosePeople.me) == GlucosePeople.me && GlucoseKind.of(tags[$0.id] ?? GlucoseTags.auto($0)) == .after2
        }
        total = recs.count
        let taggedRecs = recs.filter { !(foods[$0.id] ?? []).isEmpty }
        tagged = taggedRecs.count
        var names = Set<String>()
        for r in taggedRecs { for f in foods[r.id] ?? [] { names.insert(f) } }
        var out: [Row] = []
        for name in names {
            let with = taggedRecs.filter { (foods[$0.id] ?? []).contains(name) }
            let without = taggedRecs.filter { !(foods[$0.id] ?? []).contains(name) }
            guard !with.isEmpty, !without.isEmpty else { continue }
            let aw = with.map(\.mmol).reduce(0, +) / Double(with.count)
            let ao = without.map(\.mmol).reduce(0, +) / Double(without.count)
            let over = Double(with.filter { $0.mmol > 7.8 }.count) / Double(with.count)
            out.append(Row(food: name, n: with.count, avgWith: aw, avgWithout: ao, overRate: over,
                           records: with.sorted { $0.date > $1.date }.map { ($0.date, $0.mmol, foods[$0.id] ?? []) }))
        }
        rows = out.sorted { ($0.n >= 3 ? 1 : 0, $0.diff) > ($1.n >= 3 ? 1 : 0, $1.diff) }
    }
}

/// 血糖页的入口
struct GlucoseFoodCard: View {
    var body: some View {
        NavigationLink {
            GlucoseFoodAnalysisView()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "fork.knife.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Color(red: 0.95, green: 0.6, blue: 0.3))
                VStack(alignment: .leading, spacing: 2) {
                    Text("三餐食材分析").font(.headline)
                    Text("吃哪些东西餐后血糖容易高").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            }
            .padding(18)
            .glassCard(24)
        }
        .buttonStyle(.plain)
    }
}
