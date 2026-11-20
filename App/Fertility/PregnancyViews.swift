import SwiftUI
import Charts
import HealthKit

// 孕期：孕周、预产期、宝宝大小、产检时间表、体重增长、胎动、宫缩、身体监测

enum PregnancyInfo {
    /// 每周宝宝大概多大（20 周前是头到臀，之后是头到脚），仅供参考
    static let baby: [Int: (String, String)] = [
        4: ("罂粟籽", "约 1 mm"), 5: ("芝麻", "约 2 mm"), 6: ("小扁豆", "约 5 mm"), 7: ("蓝莓", "约 1.3 cm"),
        8: ("树莓", "约 1.6 cm"), 9: ("樱桃", "约 2.3 cm"), 10: ("草莓", "约 3 cm"), 11: ("无花果", "约 4 cm"),
        12: ("青柠", "约 5.4 cm · 14 g"), 13: ("豌豆荚", "约 7 cm · 23 g"), 14: ("柠檬", "约 8.7 cm · 43 g"),
        15: ("苹果", "约 10 cm · 70 g"), 16: ("牛油果", "约 11.6 cm · 100 g"), 17: ("洋葱", "约 13 cm · 140 g"),
        18: ("红薯", "约 14 cm · 190 g"), 19: ("芒果", "约 15 cm · 240 g"), 20: ("香蕉", "约 25 cm · 300 g"),
        21: ("胡萝卜", "约 27 cm · 360 g"), 22: ("木瓜", "约 28 cm · 430 g"), 23: ("葡萄柚", "约 29 cm · 500 g"),
        24: ("玉米", "约 30 cm · 600 g"), 25: ("花椰菜", "约 35 cm · 660 g"), 26: ("生菜", "约 36 cm · 760 g"),
        27: ("西兰花", "约 37 cm · 875 g"), 28: ("茄子", "约 38 cm · 1 kg"), 29: ("小南瓜", "约 39 cm · 1.15 kg"),
        30: ("卷心菜", "约 40 cm · 1.3 kg"), 31: ("椰子", "约 41 cm · 1.5 kg"), 32: ("大白菜", "约 42 cm · 1.7 kg"),
        33: ("菠萝", "约 44 cm · 1.9 kg"), 34: ("哈密瓜", "约 45 cm · 2.1 kg"), 35: ("蜜瓜", "约 46 cm · 2.4 kg"),
        36: ("木瓜（大）", "约 47 cm · 2.6 kg"), 37: ("冬瓜", "约 49 cm · 2.9 kg"), 38: ("南瓜", "约 50 cm · 3.1 kg"),
        39: ("小西瓜", "约 51 cm · 3.3 kg"), 40: ("西瓜", "约 51 cm · 3.5 kg"),
    ]

    struct Checkup: Identifiable {
        let id: String
        let from: Int     // 孕周
        let to: Int
        let title: String
        let detail: String
    }

    /// 产检时间表（参考《孕前和孕期保健指南》，具体以医院安排为准）
    static let checkups: [Checkup] = [
        Checkup(id: "c1", from: 6, to: 13, title: "建档 · 第一次产检", detail: "B 超确认宫内孕和胎心，血常规、尿常规、血型、肝肾功能、甲功、乙肝/梅毒/艾滋筛查等"),
        Checkup(id: "c2", from: 11, to: 13, title: "NT 检查", detail: "11～13⁺⁶ 周，B 超看颈项透明层厚度，初步筛查染色体异常"),
        Checkup(id: "c3", from: 15, to: 20, title: "唐氏筛查 / 无创 DNA", detail: "唐筛 15～20⁺⁶ 周抽血；无创 DNA 一般 12～22⁺⁶ 周，高龄或高风险可能要做羊水穿刺"),
        Checkup(id: "c4", from: 20, to: 24, title: "大排畸（系统 B 超）", detail: "20～24 周，系统检查宝宝的结构发育"),
        Checkup(id: "c5", from: 24, to: 28, title: "糖耐量 OGTT", detail: "24～28 周，空腹抽血后喝糖水，1 小时、2 小时再抽血，筛查妊娠期糖尿病"),
        Checkup(id: "c6", from: 28, to: 32, title: "孕晚期产检 · 小排畸", detail: "28 周起每 2 周一次产检；30～32 周 B 超看生长发育、胎位"),
        Checkup(id: "c7", from: 32, to: 36, title: "每 2 周产检 · 胎心监护", detail: "34 周左右开始做胎心监护，查 B 族链球菌（35～37 周）"),
        Checkup(id: "c8", from: 37, to: 41, title: "每周产检", detail: "胎心监护、B 超评估羊水和胎儿大小，准备待产包；超过 41 周要听医生安排"),
    ]

    /// 孕期体重增长推荐（WS/T 801—2022《妊娠期妇女体重增长推荐值标准》）
    struct GainRule {
        let label: String
        let total: ClosedRange<Double>
        let weekly: ClosedRange<Double>   // 孕中晚期每周
    }

    static func rule(bmi: Double) -> GainRule {
        if bmi < 18.5 { return GainRule(label: "偏瘦", total: 11...16, weekly: 0.37...0.56) }
        if bmi < 24 { return GainRule(label: "正常", total: 8...14, weekly: 0.26...0.48) }
        if bmi < 28 { return GainRule(label: "超重", total: 7...11, weekly: 0.22...0.37) }
        return GainRule(label: "肥胖", total: 5...9, weekly: 0.15...0.30)
    }

    /// 到某个孕周（可以带小数）推荐长了多少：孕早期（≤13 周）0～2 kg，之后按每周推荐
    static func gainRange(week: Double, rule: GainRule) -> ClosedRange<Double> {
        if week <= 13 { return 0...(2 * week / 13) }
        let w = week - 13
        return (w * rule.weekly.lowerBound)...(2 + w * rule.weekly.upperBound)
    }
}

struct PregnancyView: View {
    @ObservedObject private var store = FertilityStore.shared
    @State private var editing: EditDay?
    @State private var lmpPick = FertilityStore.addDays(Date(), -42)

    var body: some View {
        PageScroll(title: "孕期", subtitle: subtitle) {
            if let g = store.gestation, g.days <= 300 {
                headerCard(g)
                Button {
                    editing = EditDay(id: FertilityStore.key(Date()))
                } label: {
                    Label("记录今天（体重、症状）", systemImage: "square.and.pencil")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .glassButton()
                warningCard
                CheckupCard(week: g.week)
                PregnancyWeightCard()
                HStack(spacing: 14) {
                    NavigationLink { KickCounterView() } label: { toolCard("胎动计数", "hand.tap.fill", kickSummary, FertilityColor.pink) }
                        .buttonStyle(.plain)
                    NavigationLink { ContractionTimerView() } label: { toolCard("宫缩计时", "timer", contractionSummary, FertilityColor.ovulation) }
                        .buttonStyle(.plain)
                }
                PregnancyMonitorCard()
                symptomHistory
            } else {
                setupCard
            }
        }
        .sheet(item: $editing) { e in DayLogSheet(key: e.id, pregnant: true) }
    }

    private var subtitle: String {
        guard let g = store.gestation else { return "设置末次月经后开始" }
        return "孕 \(g.week) 周 \(g.day) 天"
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("末次月经第一天", systemImage: "calendar").font(.headline)
            Text("用来算孕周和预产期（预产期 = 末次月经 + 280 天）。如果医生按 B 超调整过孕周，就把日期往前或往后挪到一致。")
                .font(.footnote).foregroundStyle(.secondary)
            DatePicker("日期", selection: $lmpPick, in: FertilityStore.addDays(Date(), -300)...Date(), displayedComponents: .date)
                .datePickerStyle(.compact)
                .environment(\.locale, Locale(identifier: "zh_CN"))
            Button {
                store.data.settings.lmp = FertilityStore.cal.startOfDay(for: lmpPick)
                store.save()
                store.objectWillChange.send()
            } label: {
                Text("开始").frame(maxWidth: .infinity).padding(.vertical, 4)
            }
            .glassButton()
            Button("回到备孕模式") { store.mode = .trying }
                .font(.footnote)
        }
        .padding(18)
        .glassCard(24)
        .onAppear { if let s = store.lastStart { lmpPick = s } }
    }

    private func headerCard(_ g: (week: Int, day: Int, days: Int)) -> some View {
        let due = store.dueDate ?? Date()
        let left = FertilityStore.daysBetween(Date(), due)
        let tri = g.week < 14 ? "孕早期" : (g.week < 28 ? "孕中期" : "孕晚期")
        let baby = PregnancyInfo.baby[min(max(g.week, 4), 40)]
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("孕").font(.subheadline).foregroundStyle(.secondary)
                Text("\(g.week)").font(.system(size: 46, weight: .heavy, design: .rounded).monospacedDigit())
                Text("周").font(.subheadline).foregroundStyle(.secondary)
                Text("\(g.day)").font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                Text("天").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text(tri).font(.subheadline.weight(.bold)).foregroundStyle(FertilityColor.pink)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(FertilityColor.pink.opacity(0.15)))
            }
            ProgressView(value: min(Double(g.days), 280), total: 280)
                .tint(FertilityColor.pink)
            HStack {
                Text("预产期 " + FertilityStore.md(due)).font(.subheadline.weight(.semibold))
                Spacer()
                Text(left >= 0 ? "还有 \(left) 天" : "已过预产期 \(-left) 天").font(.subheadline).foregroundStyle(.secondary)
            }
            if let b = baby, g.week >= 4 {
                HStack(spacing: 10) {
                    Image(systemName: "leaf.circle.fill").font(.title2).foregroundStyle(FertilityColor.fertile)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("宝宝大概有一个" + b.0 + "那么大").font(.subheadline.weight(.semibold))
                        Text(b.1 + "（仅供参考）").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(18)
        .glassCard(26)
    }

    private var warningCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("出现这些情况马上去医院", systemImage: "cross.case.fill").font(.subheadline.weight(.bold)).foregroundStyle(.red)
            Text("阴道流血 · 破水（流液）· 剧烈或持续腹痛 · 胎动明显减少或消失（28 周后）· 严重头痛、眼花、手脚脸突然肿 · 持续呕吐吃不下东西 · 发烧 38℃ 以上")
                .font(.footnote)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(20)
    }

    private func toolCard(_ title: String, _ icon: String, _ sub: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon).font(.title2).foregroundStyle(color)
            Text(title).font(.headline)
            Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .glassCard(22)
    }

    private var kickSummary: String {
        let today = store.data.kicks.filter { FertilityStore.cal.isDateInToday($0.start) }
        if today.isEmpty { return "28 周起每天早中晚各数 1 小时" }
        return "今天数了 \(today.count) 次，共 \(today.map { $0.kicks.count }.reduce(0, +)) 下胎动"
    }

    private var contractionSummary: String {
        let recent = store.data.contractions.filter { Date().timeIntervalSince($0.start) < 3600 }
        if recent.isEmpty { return "记录每次宫缩的时长和间隔" }
        return "最近 1 小时 \(recent.count) 次"
    }

    // 最近记的症状
    @ViewBuilder
    private var symptomHistory: some View {
        let days = store.data.days.values
            .filter { !$0.symptoms.isEmpty || !$0.note.isEmpty || $0.weight != nil }
            .sorted { $0.key > $1.key }
            .prefix(10)
        if !days.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("最近记录").font(.headline).padding(.bottom, 8)
                ForEach(Array(days.enumerated()), id: \.offset) { i, d in
                    if i > 0 { RowDivider() }
                    Button { editing = EditDay(id: d.key) } label: { symptomRow(d) }
                        .buttonStyle(.plain)
                }
            }
            .padding(16)
            .glassCard(22)
        }
    }

    private func symptomRow(_ d: FertilityDay) -> some View {
        let date = FertilityStore.date(d.key) ?? Date()
        var parts: [String] = []
        if let w = d.weight { parts.append(String(format: "%.1f kg", w)) }
        if !d.symptoms.isEmpty { parts.append(d.symptoms.joined(separator: "、")) }
        if !d.note.isEmpty { parts.append(d.note) }
        return HStack(alignment: .top) {
            Text(FertilityStore.md(date)).font(.subheadline).foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
            Text(parts.joined(separator: " · ")).font(.subheadline).lineLimit(2)
            Spacer()
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}

// MARK: - 产检时间表

struct CheckupCard: View {
    let week: Int
    @ObservedObject private var store = FertilityStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("产检时间表", systemImage: "stethoscope").font(.headline).padding(.bottom, 8)
            ForEach(Array(PregnancyInfo.checkups.enumerated()), id: \.element.id) { i, c in
                if i > 0 { RowDivider() }
                row(c)
            }
            Text("参考国内常规安排，具体时间以医院为准。点左边圆圈标记已做。")
                .font(.caption2).foregroundStyle(.tertiary).padding(.top, 8)
        }
        .padding(16)
        .glassCard(22)
    }

    private func row(_ c: PregnancyInfo.Checkup) -> some View {
        let done = store.data.settings.checkupsDone.contains(c.id)
        let now = (c.from...c.to).contains(week)
        let past = week > c.to
        return HStack(alignment: .top, spacing: 10) {
            Button {
                if done { store.data.settings.checkupsDone.removeAll { $0 == c.id } } else { store.data.settings.checkupsDone.append(c.id) }
                store.save()
                store.objectWillChange.send()
            } label: {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(done ? FertilityColor.fertile : (now ? FertilityColor.pink : Color.secondary))
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(c.title).font(.subheadline.weight(.semibold))
                    if now && !done {
                        Text("现在").font(.caption2.weight(.bold)).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(FertilityColor.pink))
                    }
                }
                Text("\(c.from)～\(c.to) 周 · " + c.detail).font(.caption).foregroundStyle(.secondary)
            }
            .opacity(past && !done ? 0.55 : 1)
        }
        .padding(.vertical, 9)
    }
}

// MARK: - 体重增长

struct PregnancyWeightCard: View {
    @ObservedObject private var store = FertilityStore.shared
    @State private var weights: [(Date, Double)] = []
    @State private var height: Double?
    @State private var preText = ""

    private var pre: Double? {
        if let p = store.data.settings.prePregWeight { return p }
        guard let l = store.lmp else { return nil }
        // 末次月经前后 60 天内最接近的一次
        return weights.min { abs($0.0.timeIntervalSince(l)) < abs($1.0.timeIntervalSince(l)) }
            .flatMap { abs($0.0.timeIntervalSince(l)) < 60 * 86400 ? $0.1 : nil }
    }

    /// 健康里的 + 自己记的，按天合并
    private var allWeights: [(Date, Double)] {
        var m: [String: (Date, Double)] = [:]
        for w in weights { m[FertilityStore.key(w.0)] = w }
        for v in store.data.days.values {
            if let w = v.weight, let d = FertilityStore.date(v.key) { m[v.key] = (d, w) }
        }
        return m.values.sorted { $0.0 < $1.0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("体重增长", systemImage: "scalemass.fill").font(.headline).foregroundStyle(Color(red: 0.8, green: 0.55, blue: 1.0))
            if let p = pre, let l = store.lmp {
                content(pre: p, lmp: l)
            } else {
                Text("填上孕前体重，就能对照国家标准看体重长得合不合适。").font(.footnote).foregroundStyle(.secondary)
                HStack {
                    TextField("孕前体重", text: $preText).keyboardType(.decimalPad)
                    Text("kg").foregroundStyle(.secondary)
                    Button("保存") {
                        if let v = Double(preText), (30...150).contains(v) {
                            store.data.settings.prePregWeight = v
                            store.save()
                            store.objectWillChange.send()
                        }
                    }
                }
            }
        }
        .padding(16)
        .glassCard(22)
        .task {
            if let l = store.lmp { weights = await FertilityHealth.weights(from: FertilityStore.addDays(l, -60)) }
            height = await BMI.height()
        }
    }

    @ViewBuilder
    private func content(pre: Double, lmp: Date) -> some View {
        let bmi: Double? = height.map { BMI.value(kg: pre, cm: $0) }
        let rule = PregnancyInfo.rule(bmi: bmi ?? 21)
        let pts: [(Double, Double)] = allWeights.compactMap { w -> (Double, Double)? in
            let wk = Double(FertilityStore.daysBetween(lmp, w.0)) / 7
            return wk >= 0 ? (wk, w.1 - pre) : nil
        }
        let nowWeek = Double(FertilityStore.daysBetween(lmp, Date())) / 7
        let range = PregnancyInfo.gainRange(week: nowWeek, rule: rule)
        let last = pts.last
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(last.map { String(format: "%+.1f", $0.1) } ?? "--")
                    .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                Text("kg").foregroundStyle(.secondary)
                Spacer()
                if let l = last { statusChip(l.1, range: PregnancyInfo.gainRange(week: l.0, rule: rule)) }
            }
            Text("孕前 " + String(format: "%.1f", pre) + " kg" + (bmi.map { "，BMI " + String(format: "%.1f", $0) + "（" + rule.label + "）" } ?? "（没有身高，按正常体重算）")
                 + "；整个孕期建议长 \(Int(rule.total.lowerBound))～\(Int(rule.total.upperBound)) kg，现在这个孕周建议长 "
                 + String(format: "%.1f～%.1f", range.lowerBound, range.upperBound) + " kg。")
                .font(.caption).foregroundStyle(.secondary)
            if !pts.isEmpty { chart(pts, rule: rule, nowWeek: nowWeek).frame(height: 170) }
        }
    }

    private func statusChip(_ gain: Double, range: ClosedRange<Double>) -> some View {
        let text: String
        let color: Color
        if gain < range.lowerBound - 0.3 { text = "偏少"; color = Color(red: 0.4, green: 0.7, blue: 1.0) }
        else if gain > range.upperBound + 0.3 { text = "偏多"; color = .orange }
        else { text = "合适"; color = FertilityColor.fertile }
        return Text(text).font(.subheadline.weight(.bold)).foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.15)))
    }

    private func chart(_ pts: [(Double, Double)], rule: PregnancyInfo.GainRule, nowWeek: Double) -> some View {
        let maxW = min(40, max(nowWeek + 4, 16))
        let band: [(Double, Double, Double)] = stride(from: 0.0, through: maxW, by: 1.0).map { w in
            let r = PregnancyInfo.gainRange(week: w, rule: rule)
            return (w, r.lowerBound, r.upperBound)
        }
        return Chart {
            ForEach(Array(band.enumerated()), id: \.offset) { _, b in
                AreaMark(x: .value("孕周", b.0), yStart: .value("下限", b.1), yEnd: .value("上限", b.2))
                    .foregroundStyle(FertilityColor.fertile.opacity(0.18))
            }
            ForEach(Array(pts.enumerated()), id: \.offset) { _, p in
                LineMark(x: .value("孕周", p.0), y: .value("增长", p.1))
                    .foregroundStyle(Color(red: 0.8, green: 0.55, blue: 1.0))
                PointMark(x: .value("孕周", p.0), y: .value("增长", p.1))
                    .foregroundStyle(Color(red: 0.8, green: 0.55, blue: 1.0))
                    .symbolSize(18)
            }
        }
        .chartXScale(domain: 0...maxW)
        .chartXAxis {
            AxisMarks(values: .stride(by: 4)) { v in
                AxisGridLine().foregroundStyle(.white.opacity(0.05))
                AxisValueLabel {
                    if let d = v.as(Double.self) { Text("\(Int(d))周").font(.caption2) }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { v in
                AxisGridLine().foregroundStyle(.white.opacity(0.06))
                AxisValueLabel {
                    if let d = v.as(Double.self) { Text(String(format: "%+.0f", d)).font(.caption2) }
                }
            }
        }
    }
}

// MARK: - 身体监测

struct PregnancyMonitorCard: View {
    @State private var resting: [DayValue] = []
    @State private var bp: [(Double, Double, Date)] = []
    @State private var sleepAvg: Double?
    @ObservedObject private var store = FertilityStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("身体监测", systemImage: "waveform.path.ecg").font(.headline).foregroundStyle(Color(red: 1.0, green: 0.45, blue: 0.55))
            bpRow
            RowDivider()
            restingRow
            RowDivider()
            wristRow
            RowDivider()
            sleepRow
        }
        .padding(16)
        .glassCard(22)
        .task {
            resting = (try? await HealthService.daily(.restingHR, days: 30)) ?? []
            bp = await FertilityHealth.bloodPressure(days: 30)
            let nights = await HealthService.nightlySleep(days: 7)
            if !nights.isEmpty { sleepAvg = nights.map { $0.1.asleep }.reduce(0, +) / Double(nights.count) / 3600 }
        }
    }

    private func line(_ icon: String, _ title: String, _ value: String, _ note: String, warn: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).frame(width: 22).foregroundStyle(warn ? .orange : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title).font(.subheadline)
                    Spacer()
                    Text(value).font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(warn ? .orange : .primary)
                }
                Text(note).font(.caption2).foregroundStyle(warn ? .orange : .secondary)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var bpRow: some View {
        if let l = bp.last {
            let high = l.0 >= 140 || l.1 >= 90
            line("heart.text.square", "血压", "\(Int(l.0))/\(Int(l.1))",
                 high ? "达到 140/90，孕期高血压要重视，尽快联系医生" : "最近一次 " + FertilityStore.md(l.2) + "，孕期正常应低于 140/90",
                 warn: high)
        } else {
            line("heart.text.square", "血压", "--", "健康 App 里没有血压。家里有血压计的，记进健康后这里会显示（孕期应低于 140/90）")
        }
    }

    @ViewBuilder
    private var restingRow: some View {
        let last7 = resting.suffix(7).map(\.value)
        let first7 = resting.prefix(7).map(\.value)
        if !last7.isEmpty {
            let a = last7.reduce(0, +) / Double(last7.count)
            let b = first7.isEmpty ? a : first7.reduce(0, +) / Double(first7.count)
            line("heart.fill", "静息心率（近 7 天）", "\(Int(a.rounded())) 次/分",
                 String(format: "比一个月前 %+.0f。", a - b) + "孕期静息心率比孕前高 10～20 次/分是正常的" + (a > 110 ? "；超过 110 请咨询医生" : ""),
                 warn: a > 110)
        } else {
            line("heart.fill", "静息心率", "--", "戴 Apple Watch 会自动记录")
        }
    }

    @ViewBuilder
    private var wristRow: some View {
        let dev = store.wristDeviation(from: FertilityStore.addDays(Date(), -7))
        if let l = dev.last {
            line("thermometer.medium", "手表腕温（昨晚）", String(format: "%+.2f℃", l.1),
                 l.1 >= 1.0 ? "比平时高很多，量一下体温，发烧 38℃ 以上要看医生" : "和平时比的变化；孕期略高一点是正常的",
                 warn: l.1 >= 1.0)
        } else {
            line("thermometer.medium", "手表腕温", "--", "戴 Apple Watch 睡觉，打开「腕温」后会记录")
        }
    }

    @ViewBuilder
    private var sleepRow: some View {
        if let s = sleepAvg {
            line("bed.double.fill", "睡眠（近 7 晚平均）", HealthFormat.duration(s * 3600),
                 s < 7 ? "孕期建议每晚睡够 7～9 小时，孕中晚期左侧卧更舒服" : "睡得不错，孕中晚期左侧卧更舒服")
        } else {
            line("bed.double.fill", "睡眠", "--", "戴手表睡觉会自动记录")
        }
    }
}

// MARK: - 胎动计数

struct KickCounterView: View {
    @ObservedObject private var store = FertilityStore.shared
    @State private var now = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var active: KickSession? {
        guard let s = store.data.kicks.last, s.end == nil else { return nil }
        return s
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let s = active {
                    activeView(s)
                } else {
                    Button {
                        store.data.kicks.append(KickSession(start: Date()))
                        store.save()
                        store.objectWillChange.send()
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "play.circle.fill").font(.system(size: 54))
                            Text("开始数胎动（1 小时）").font(.headline)
                        }
                        .frame(maxWidth: .infinity).padding(30)
                    }
                    .buttonStyle(.plain)
                    .glassCard(26)
                }
                todaySummary
                history
                Text("28 周起，每天早、中、晚各找 1 小时安静地数胎动。宝宝连续动算 1 次（App 会把 5 分钟内的连续胎动算成 1 次）。每小时 3 次以上算正常；如果 2 小时少于 6 次，或比平时少一半以上，要马上去医院。")
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(16).glassCard(20)
            }
            .padding(16)
            .padding(.bottom, 100)
        }
        .background(AppBackground())
        .navigationTitle("胎动计数")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .onReceive(timer) { t in
            now = t
            if let s = active, t.timeIntervalSince(s.start) >= 3600 { finish() }
        }
    }

    private func activeView(_ s: KickSession) -> some View {
        let left = max(0, 3600 - now.timeIntervalSince(s.start))
        return VStack(spacing: 14) {
            Text(String(format: "剩余 %02d:%02d", Int(left) / 60, Int(left) % 60))
                .font(.title3.monospacedDigit()).foregroundStyle(.secondary)
            Button {
                tap()
            } label: {
                VStack(spacing: 6) {
                    Text("\(s.kicks.count)").font(.system(size: 64, weight: .heavy, design: .rounded).monospacedDigit())
                    Text("动了就点一下").font(.subheadline)
                    Text("一共点了 \(s.taps) 下").font(.caption).foregroundStyle(.secondary)
                }
                .frame(width: 220, height: 220)
                .background(Circle().fill(FertilityColor.pink.opacity(0.25)))
                .overlay(Circle().stroke(FertilityColor.pink, lineWidth: 2))
            }
            .buttonStyle(.plain)
            Button("提前结束") { finish() }
                .glassButton()
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .glassCard(26)
    }

    private func tap() {
        guard var s = active, let i = store.data.kicks.indices.last else { return }
        let t = Date()
        s.taps += 1
        if let last = s.kicks.last, store.data.settings.kickMerge, t.timeIntervalSince(last) < 300 {
            // 5 分钟内连续动，算同一次
        } else {
            s.kicks.append(t)
        }
        store.data.kicks[i] = s
        store.save()
        store.objectWillChange.send()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func finish() {
        guard var s = active, let i = store.data.kicks.indices.last else { return }
        s.end = min(Date(), s.start.addingTimeInterval(3600))
        store.data.kicks[i] = s
        store.save()
        store.objectWillChange.send()
    }

    private var todaySummary: some View {
        let today = store.data.kicks.filter { FertilityStore.cal.isDateInToday($0.start) && $0.end != nil }
        let total = today.map { $0.kicks.count }.reduce(0, +)
        return VStack(alignment: .leading, spacing: 6) {
            Text("今天").font(.headline)
            Text("数了 \(today.count) 次，共 \(total) 下胎动" + (today.count >= 3 ? "，估算 12 小时约 \(total * 4) 下（30 下以上正常）" : ""))
                .font(.subheadline)
            if let low = today.first(where: { $0.kicks.count < 3 }) {
                Text("有一次（" + FertilityStore.shortMD(low.start) + " " + Self.hm(low.start) + "）1 小时少于 3 下，换个时间再数一次；还是少就去医院。")
                    .font(.footnote.weight(.semibold)).foregroundStyle(.orange)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(20)
    }

    private var history: some View {
        let done = store.data.kicks.filter { $0.end != nil }.suffix(20).reversed()
        return VStack(alignment: .leading, spacing: 0) {
            if !done.isEmpty {
                Text("记录").font(.headline).padding(.bottom, 6)
                ForEach(Array(done.enumerated()), id: \.element.id) { i, s in
                    if i > 0 { RowDivider() }
                    HStack {
                        Text(FertilityStore.shortMD(s.start) + " " + Self.hm(s.start)).font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(s.kicks.count) 下").font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(s.kicks.count < 3 ? .orange : .primary)
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .padding(done.isEmpty ? 0 : 16)
        .glassCard(20)
        .opacity(done.isEmpty ? 0 : 1)
    }

    static func hm(_ d: Date) -> String {
        let c = FertilityStore.cal.dateComponents([.hour, .minute], from: d)
        return String(format: "%02ld:%02ld", c.hour ?? 0, c.minute ?? 0)
    }
}

// MARK: - 宫缩计时

struct ContractionTimerView: View {
    @ObservedObject private var store = FertilityStore.shared
    @State private var now = Date()
    @State private var confirmClear = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var active: Contraction? {
        guard let c = store.data.contractions.last, c.end == nil else { return nil }
        return c
    }

    private var recent: [Contraction] {
        store.data.contractions.filter { $0.end != nil && now.timeIntervalSince($0.start) < 2 * 3600 }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                bigButton
                adviceCard
                list
                Text("宫缩计时：开始疼时点「开始」，不疼了点「结束」。间隔是从上一次开始到这次开始。")
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(16).glassCard(20)
                if !store.data.contractions.isEmpty {
                    Button("清空记录", role: .destructive) { confirmClear = true }
                        .font(.footnote)
                }
            }
            .padding(16)
            .padding(.bottom, 100)
        }
        .background(AppBackground())
        .navigationTitle("宫缩计时")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .onReceive(timer) { now = $0 }
        .confirmationDialog("清空所有宫缩记录？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) {
                store.data.contractions = []
                store.save()
                store.objectWillChange.send()
            }
        }
    }

    private var bigButton: some View {
        let running = active != nil
        return Button {
            if let c = active, let i = store.data.contractions.indices.last {
                var e = c
                e.end = Date()
                store.data.contractions[i] = e
            } else {
                store.data.contractions.append(Contraction(start: Date()))
            }
            store.save()
            store.objectWillChange.send()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } label: {
            VStack(spacing: 6) {
                if let c = active {
                    Text(Self.mmss(now.timeIntervalSince(c.start))).font(.system(size: 52, weight: .heavy, design: .rounded).monospacedDigit())
                    Text("疼完了点这里结束").font(.subheadline)
                } else {
                    Image(systemName: "play.fill").font(.system(size: 44))
                    Text("宫缩开始").font(.headline)
                    if let l = store.data.contractions.last {
                        Text("距上次开始 " + Self.mmss(now.timeIntervalSince(l.start))).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 220, height: 220)
            .background(Circle().fill((running ? Color.orange : FertilityColor.ovulation).opacity(0.25)))
            .overlay(Circle().stroke(running ? Color.orange : FertilityColor.ovulation, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .padding(20)
        .glassCard(26)
    }

    private var adviceCard: some View {
        let r = recent
        let intervals: [TimeInterval] = r.count >= 2 ? (1..<r.count).map { r[$0].start.timeIntervalSince(r[$0 - 1].start) } : []
        let avgInt: Double? = intervals.isEmpty ? nil : intervals.reduce(0, +) / Double(intervals.count)
        let durs = r.compactMap(\.duration)
        let avgDur: Double? = durs.isEmpty ? nil : durs.reduce(0, +) / Double(durs.count)
        let regular = (avgInt ?? 9999) <= 330 && (avgDur ?? 0) >= 45 && r.count >= 6
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                stat("最近 2 小时", "\(r.count) 次")
                stat("平均间隔", avgInt.map { Self.mmss($0) } ?? "--")
                stat("平均时长", avgDur.map { Self.mmss($0) } ?? "--")
            }
            Text(regular ? "宫缩已经比较规律（约 5 分钟一次、每次约 1 分钟），该去医院了！破水或出血不用等，立刻去。"
                 : "初产妇一般等到宫缩每 5 分钟一次、每次持续约 1 分钟、持续 1 小时再去医院；破水、见红较多、胎动减少要马上去。")
                .font(.footnote.weight(regular ? .bold : .regular))
                .foregroundStyle(regular ? .orange : .secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(20)
    }

    private func stat(_ k: String, _ v: String) -> some View {
        VStack(spacing: 2) {
            Text(v).font(.headline.monospacedDigit())
            Text(k).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var list: some View {
        let all = store.data.contractions.filter { $0.end != nil }.suffix(30)
        let arr = Array(all)
        return VStack(alignment: .leading, spacing: 0) {
            if !arr.isEmpty {
                HStack {
                    Text("开始").frame(width: 70, alignment: .leading)
                    Spacer()
                    Text("时长").frame(width: 60)
                    Text("间隔").frame(width: 60)
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, 4)
                ForEach(Array(arr.enumerated().reversed()), id: \.element.id) { i, c in
                    RowDivider()
                    HStack {
                        Text(KickCounterView.hm(c.start)).frame(width: 70, alignment: .leading)
                        Spacer()
                        Text(c.duration.map { Self.mmss($0) } ?? "--").frame(width: 60)
                        Text(i > 0 ? Self.mmss(c.start.timeIntervalSince(arr[i - 1].start)) : "--").frame(width: 60)
                    }
                    .font(.subheadline.monospacedDigit())
                    .padding(.vertical, 7)
                }
            }
        }
        .padding(arr.isEmpty ? 0 : 16)
        .glassCard(20)
        .opacity(arr.isEmpty ? 0 : 1)
    }

    static func mmss(_ t: TimeInterval) -> String {
        let s = Int(max(0, t))
        if s >= 3600 { return String(format: "%ld:%02ld:%02ld", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%02ld:%02ld", s / 60, s % 60)
    }
}

// MARK: - 设置卡片

struct FertilitySettingsCard: View {
    @ObservedObject private var store = FertilityStore.shared
    @AppStorage(FertilityStore.modeKey) private var mode = FertilityMode.trying.rawValue
    @State private var message: String?
    @State private var lmp = Date()

    var body: some View {
        CardSection(footer: message ?? "月经、基础体温、排卵试纸、宫颈黏液会同时写进健康 App（同房只记在 App 里）。手表或其他 App 记的月经、体温也会自动读进来。") {
            CardTitle("备孕 / 孕期")
            RowDivider()
            Picker("模式", selection: $mode) {
                ForEach(FertilityMode.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .padding(.vertical, 8)
            .onChange(of: mode) { _, m in
                if m == FertilityMode.pregnant.rawValue && store.data.settings.lmp == nil {
                    store.data.settings.lmp = store.lastStart
                    store.save()
                }
                store.objectWillChange.send()
            }
            RowDivider()
            if mode == FertilityMode.pregnant.rawValue {
                DatePicker("末次月经第一天", selection: $lmp, in: FertilityStore.addDays(Date(), -300)...Date(), displayedComponents: .date)
                    .environment(\.locale, Locale(identifier: "zh_CN"))
                    .padding(.vertical, 6)
                    .onAppear { lmp = store.data.settings.lmp ?? Date() }
                    .onChange(of: lmp) { _, v in
                        store.data.settings.lmp = FertilityStore.cal.startOfDay(for: v)
                        store.save()
                        store.objectWillChange.send()
                    }
                RowDivider()
                Toggle("胎动 5 分钟内连续算 1 次", isOn: Binding(get: { store.data.settings.kickMerge }, set: {
                    store.data.settings.kickMerge = $0; store.save(); store.objectWillChange.send()
                }))
                .padding(.vertical, 6)
            } else {
                Toggle("按记录自动算周期", isOn: Binding(get: { store.data.settings.autoCycle }, set: {
                    store.data.settings.autoCycle = $0; store.save(); store.objectWillChange.send()
                }))
                .padding(.vertical, 6)
                RowDivider()
                Stepper("周期长度  \(store.data.settings.cycleLen) 天", value: Binding(get: { store.data.settings.cycleLen }, set: {
                    store.data.settings.cycleLen = $0; store.save(); store.objectWillChange.send()
                }), in: 20...45)
                .padding(.vertical, 6)
                RowDivider()
                Stepper("经期长度  \(store.data.settings.periodLen) 天", value: Binding(get: { store.data.settings.periodLen }, set: {
                    store.data.settings.periodLen = $0; store.save(); store.objectWillChange.send()
                }), in: 2...10)
                .padding(.vertical, 6)
            }
            RowDivider()
            Toggle("记录同时写进健康 App", isOn: Binding(get: { store.data.settings.syncHealth }, set: {
                store.data.settings.syncHealth = $0; store.save(); store.objectWillChange.send()
            }))
            .padding(.vertical, 6)
            RowDivider()
            Button {
                Task {
                    await store.syncFromHealth()
                    message = store.healthMessage ?? "已从健康 App 读取月经、体温记录"
                }
            } label: {
                Label("授权 / 从健康读取", systemImage: "arrow.clockwise")
            }
            .padding(.vertical, 8)
        }
    }
}
