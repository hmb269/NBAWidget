import SwiftUI
import Charts

// 饭后运动和餐后血糖：每一顿（每条餐后 2 小时记录）单独看，
// 测血糖前 2 小时走了多少步 / 消耗多少活动卡路里 / 锻炼几分钟，和这次的餐后血糖对照

struct PostMealAnalysisView: View {
    enum Kind: String, CaseIterable, Identifiable {
        case steps = "步数", kcal = "活动卡路里", exercise = "锻炼分钟"
        var id: String { rawValue }
        var unit: String { self == .steps ? "步" : self == .kcal ? "千卡" : "分钟" }
        var edges: [Double] {
            switch self {
            case .steps: return [300, 1000, 2000]
            case .kcal: return [20, 50, 100]
            case .exercise: return [1, 10, 20]
            }
        }
        func value(_ a: PostMealActivity) -> Double? {
            switch self {
            case .steps: return a.steps
            case .kcal: return a.kcal
            case .exercise: return a.exercise ?? 0
            }
        }
        func label(_ i: Int) -> String {
            let e = edges
            func f(_ v: Double) -> String { String(Int(v)) }
            if i == 0 { return self == .exercise ? "没锻炼" : "\(f(e[0]))\(unit)以下" }
            if i == e.count { return "\(f(e[e.count - 1]))\(unit)以上" }
            return "\(f(e[i - 1]))～\(f(e[i]))\(unit)"
        }
    }

    struct Meal: Identifiable {
        let id: String
        let date: Date
        let mmol: Double
        let label: String
        let act: PostMealActivity
        let foods: [String]
    }

    @State private var kind: Kind = .steps
    @State private var meals: [Meal] = []
    @State private var loading = true
    @State private var showList = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Picker("", selection: $kind) {
                    ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                if loading {
                    ProgressView().frame(maxWidth: .infinity).padding(40)
                } else if meals.count < 5 {
                    Text("餐后 2 小时的记录还不到 5 条（现在 \(meals.count) 条），多测几顿再来看。")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading).glassCard(20)
                } else {
                    conclusionCard
                    binsCard
                    scatterCard
                    listCard
                }

                Text("每一顿单独算：以测血糖的时间往前 2 小时，统计手机和手表记录的步数、活动卡路里、锻炼分钟。只用你自己「餐后2小时」的记录。吃的东西、吃多少也会影响血糖，次数越多越可信。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(16)
            .padding(.bottom, 100)
        }
        .background(AppBackground())
        .navigationTitle("饭后运动和血糖")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task { await load() }
    }

    // MARK: 结论

    private var pairs: [(Double, Double)] { meals.compactMap { m in kind.value(m.act).map { ($0, m.mmol) } } }

    private var conclusionCard: some View {
        let p = pairs
        let r = p.count >= 3 ? Relation.spearman(p) : 0
        let pv = p.count >= 4 ? Relation.pValue(r, p.count) : 1
        let sorted = p.sorted { $0.0 < $1.0 }
        let k = max(1, p.count / 3)
        let lo = Array(sorted.prefix(k)), hi = Array(sorted.suffix(k))
        func avg(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.reduce(0, +) / Double(a.count) }
        let hiX = avg(hi.map(\.0)), hiY = avg(hi.map(\.1)), loX = avg(lo.map(\.0)), loY = avg(lo.map(\.1))
        let strength: String = p.count < 10 ? "次数还少，仅供参考" : pv > 0.1 ? "可能是巧合" : abs(r) >= 0.5 ? "关系明显" : abs(r) >= 0.3 ? "有一定关系" : "基本看不出关系"
        return VStack(alignment: .leading, spacing: 8) {
            Label("结论", systemImage: "sparkles").font(.headline).foregroundStyle(Color(red: 1, green: 0.8, blue: 0.4))
            Text(sentence(hiX, hiY, loX, loY)).font(.subheadline.weight(.semibold))
            Text("\(strength)（相关 \(String(format: "%.2f", r))，\(p.count) 顿）")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).glassCard(22)
    }

    private func sentence(_ hiX: Double, _ hiY: Double, _ loX: Double, _ loY: Double) -> String {
        let more: String = "饭后\(kind.rawValue)多的那几顿（平均 \(Int(hiX)) \(kind.unit)），餐后2h平均 " + String(format: "%.1f", hiY)
        let less: String = "；少的那几顿（平均 \(Int(loX)) \(kind.unit)），平均 " + String(format: "%.1f", loY)
        let d = hiY - loY
        let tail: String = abs(d) < 0.2 ? "，差不多。" : (d < 0 ? "，动得多的低 " : "，动得多的反而高 ") + String(format: "%.1f", abs(d)) + "。"
        return more + less + tail
    }

    // MARK: 分档

    private var binsCard: some View {
        let e = kind.edges
        let rows: [(String, [Meal])] = (0...e.count).map { i in
            let lo = i == 0 ? -Double.infinity : e[i - 1]
            let hi = i == e.count ? Double.infinity : e[i]
            return (kind.label(i), meals.filter { m in kind.value(m.act).map { $0 >= lo && $0 < hi } ?? false })
        }
        let avgs: [Double?] = rows.map { $0.1.isEmpty ? nil : $0.1.map(\.mmol).reduce(0, +) / Double($0.1.count) }
        let best = rows.indices.filter { rows[$0].1.count >= 3 && avgs[$0] != nil }.min { avgs[$0]! < avgs[$1]! }
        return VStack(alignment: .leading, spacing: 8) {
            Label("饭后动多少，餐后血糖最低", systemImage: "target").font(.headline)
                .foregroundStyle(Color(red: 0.5, green: 0.95, blue: 0.6))
            HStack {
                Text("饭后" + kind.rawValue).frame(maxWidth: .infinity, alignment: .leading)
                Text("顿数").frame(width: 40)
                Text("平均").frame(width: 44)
                Text("超标").frame(width: 44)
            }
            .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(rows.indices, id: \.self) { i in
                let list = rows[i].1
                HStack {
                    HStack(spacing: 3) {
                        if i == best { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.yellow) }
                        Text(rows[i].0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(list.count)").frame(width: 40)
                    Text(avgs[i].map { String(format: "%.1f", $0) } ?? "—").frame(width: 44)
                        .foregroundStyle((avgs[i] ?? 0) > 7.8 ? Color.red : Color.primary)
                    Text(list.isEmpty ? "—" : "\(Int(Double(list.filter { $0.mmol > 7.8 }.count) / Double(list.count) * 100))%").frame(width: 44)
                }
                .font(.system(size: 13, weight: i == best ? .bold : .regular).monospacedDigit())
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(i == best ? Color.green.opacity(0.12) : Color.clear))
            }
            Text("⭐ 是餐后血糖平均最低的一档（至少 3 顿才参与）。").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).glassCard(22)
    }

    // MARK: 散点图

    private var scatterCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("每一顿").font(.headline)
            Chart {
                RuleMark(y: .value("7.8", 7.8)).foregroundStyle(.red.opacity(0.5)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                RuleMark(y: .value("3.9", 3.9)).foregroundStyle(.blue.opacity(0.5)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                ForEach(meals) { m in
                    if let x = kind.value(m.act) {
                        PointMark(x: .value(kind.rawValue, x), y: .value("餐后血糖", m.mmol))
                            .foregroundStyle(m.mmol > 7.8 ? Color.red : m.mmol < 3.9 ? Color.blue : Color(red: 0.35, green: 0.9, blue: 0.65))
                            .symbolSize(45)
                    }
                }
            }
            .chartXAxisLabel("饭后 2 小时内" + kind.rawValue + "（" + kind.unit + "）")
            .chartYAxisLabel("餐后2h 血糖")
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(height: 220)
            Text("每个点是一顿。点越往右下 = 动得多、血糖低。红线 7.8，蓝线 3.9。").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(16).glassCard(22)
    }

    // MARK: 明细

    private var listCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation { showList.toggle() }
            } label: {
                HStack {
                    Text("每一顿的明细（\(meals.count)）").font(.headline)
                    Spacer()
                    Image(systemName: showList ? "chevron.up" : "chevron.down")
                }
            }
            .buttonStyle(.plain)
            if showList {
                ForEach(meals.sorted { $0.date > $1.date }) { m in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(day(m.date) + " " + m.label).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(String(format: "%.1f", m.mmol)).font(.subheadline.weight(.bold).monospacedDigit())
                                .foregroundStyle(m.mmol > 7.8 ? Color.red : m.mmol < 3.9 ? Color.blue : Color.primary)
                        }
                        Text(m.act.text + (m.foods.isEmpty ? "" : " · " + m.foods.joined(separator: "、")))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    Divider().overlay(Color.white.opacity(0.06))
                }
            }
        }
        .padding(16).glassCard(22)
    }

    private func day(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "M/d HH:mm"
        return f.string(from: d)
    }

    private func load() async {
        let owners = GlucosePeople.owners
        let tags = GlucoseTags.all
        let foods = GlucoseFoods.all
        var out: [Meal] = []
        for r in GlucoseLocal.load() where (owners[r.id] ?? GlucosePeople.me) == GlucosePeople.me {
            let label = tags[r.id] ?? GlucoseTags.auto(r)
            guard GlucoseKind.of(label) == .after2 else { continue }
            let a = await PostMeal.activity(before: r.date)
            out.append(Meal(id: r.id, date: r.date, mmol: r.mmol, label: label ?? "", act: a, foods: foods[r.id] ?? []))
        }
        meals = out
        loading = false
    }
}

/// 血糖页的入口
struct PostMealAnalysisCard: View {
    var body: some View {
        NavigationLink {
            PostMealAnalysisView()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "figure.walk.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Color(red: 1.0, green: 0.85, blue: 0.35))
                VStack(alignment: .leading, spacing: 2) {
                    Text("饭后运动和血糖").font(.headline)
                    Text("饭后动多少，餐后2小时血糖最低").font(.caption).foregroundStyle(.secondary)
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
