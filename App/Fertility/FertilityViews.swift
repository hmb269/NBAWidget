import SwiftUI
import Charts

// 备孕页：今天在周期哪一段、日历、体温曲线、每天记录

enum FertilityColor {
    static let period = Color(red: 1.0, green: 0.35, blue: 0.45)
    static let fertile = Color(red: 0.25, green: 0.85, blue: 0.75)
    static let ovulation = Color(red: 0.70, green: 0.50, blue: 1.0)
    static let temp = Color(red: 1.0, green: 0.62, blue: 0.30)
    static let pink = Color(red: 1.0, green: 0.55, blue: 0.70)
}

struct EditDay: Identifiable {
    let id: String
}

/// 精简版第二个标签页：备孕 / 孕期
struct FertilityHomeView: View {
    @ObservedObject private var store = FertilityStore.shared
    @AppStorage(FertilityStore.modeKey) private var mode = FertilityMode.trying.rawValue

    var body: some View {
        Group {
            if mode == FertilityMode.pregnant.rawValue {
                PregnancyView()
            } else {
                TryingView()
            }
        }
        .task { await store.syncFromHealth() }
    }
}

// MARK: - 备孕

struct TryingView: View {
    @ObservedObject private var store = FertilityStore.shared
    @State private var editing: EditDay?
    @State private var month = FertilityStore.cal.startOfDay(for: Date())
    @State private var askPregnant = false

    var body: some View {
        PageScroll(title: "备孕", subtitle: FertilityStore.md(Date()) + " · 周期、体温、排卵") {
            statusCard
            Button {
                editing = EditDay(id: FertilityStore.key(Date()))
            } label: {
                Label("记录今天", systemImage: "square.and.pencil")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .glassButton()

            alertsCard
            FertilityCalendar(month: $month) { k in editing = EditDay(id: k) }
            TemperatureCard()
            cycleHistory
            tipsCard
        }
        .sheet(item: $editing) { e in
            DayLogSheet(key: e.id, pregnant: false) { positive in
                if positive { askPregnant = true }
            }
        }
        .alert("验孕阳性，恭喜！", isPresented: $askPregnant) {
            Button("切换到孕期模式") { store.startPregnancy(lmp: nil) }
            Button("先不切换", role: .cancel) {}
        } message: {
            Text("切换后按末次月经算孕周、预产期，并显示产检时间表、体重增长、胎动和宫缩计时。以后在设置里也能切换。")
        }
    }

    // 今天的状态
    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let cd = store.cycleDay {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("周期第").font(.subheadline).foregroundStyle(.secondary)
                    Text("\(cd)").font(.system(size: 44, weight: .heavy, design: .rounded).monospacedDigit())
                    Text("天").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    phaseChip
                }
                infoRows
            } else {
                Label("还没有月经记录", systemImage: "calendar.badge.plus").font(.headline)
                Text("点「记录今天」或者日历上的日子，标上最近一次月经开始的那天（选月经量），就能算出排卵日和易孕期。手表或健康 App 里记过月经的，会自动读进来。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(26)
    }

    private var todayPhase: CyclePhase {
        store.phaseMap()[FertilityStore.key(Date())] ?? .other
    }

    private var phaseChip: some View {
        let p = todayPhase
        let text: String
        let color: Color
        switch p {
        case .period: text = "经期"; color = FertilityColor.period
        case .ovulation: text = "排卵日"; color = FertilityColor.ovulation
        case .fertile: text = "易孕期"; color = FertilityColor.fertile
        case .predictedPeriod: text = "预计经期"; color = FertilityColor.period
        case .other: text = "非易孕期"; color = .secondary
        }
        return Text(text)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(color.opacity(0.15)))
    }

    @ViewBuilder
    private var infoRows: some View {
        if let n = store.nextStart {
            let left = FertilityStore.daysBetween(Date(), n)
            infoRow("drop.fill", FertilityColor.period, "下次月经",
                    store.lateDays > 0 ? "已推迟 \(store.lateDays) 天" : FertilityStore.md(n) + (left == 0 ? "（今天）" : "（还有 \(left) 天）"))
        }
        if let o = store.ovulation {
            infoRow("sparkle", FertilityColor.ovulation, "排卵日", FertilityStore.md(o.date) + "（" + o.source + "）")
        }
        if let w = store.fertileWindow {
            infoRow("leaf.fill", FertilityColor.fertile, "易孕期", FertilityStore.shortMD(w.0) + " – " + FertilityStore.shortMD(w.1))
        }
        infoRow("heart.fill", FertilityColor.pink, "今天受孕几率", store.chanceToday)
        infoRow("arrow.triangle.2.circlepath", .secondary, "平均周期 / 经期",
                "\(store.avgCycle) 天 / \(store.avgPeriod) 天" + (store.cycleLengths.isEmpty ? "（默认值，记两次月经后自动算）" : ""))
    }

    private func infoRow(_ icon: String, _ color: Color, _ k: String, _ v: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 20)
            Text(k).foregroundStyle(.secondary)
            Spacer()
            Text(v).fontWeight(.semibold).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }

    // 提醒：推迟、高温期长、周期不规律
    @ViewBuilder
    private var alertsCard: some View {
        let msgs = alerts
        if !msgs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(msgs, id: \.self) { m in
                    Label(m, systemImage: "exclamationmark.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(20)
        }
    }

    private var alerts: [String] {
        var out: [String] = []
        if let h = store.highPhaseDays, h >= 18 {
            out.append("高温期已持续 \(h) 天（超过 18 天），很可能怀孕了，建议验孕。")
        } else if store.lateDays >= 3 {
            out.append("月经已推迟 \(store.lateDays) 天，可以用验孕棒测一下（晨尿更准）。")
        }
        let l = store.cycleLengths.suffix(6)
        if l.count >= 3, let mn = l.min(), let mx = l.max(), mx - mn > 7 {
            out.append("最近几次周期长短相差 \(mx - mn) 天，不太规律，预测的排卵日可能不准，建议配合排卵试纸和基础体温。")
        }
        if l.contains(where: { $0 < 21 || $0 > 35 }) {
            out.append("有周期短于 21 天或长于 35 天，如果经常这样，建议去妇科看看。")
        }
        return out
    }

    // 历次周期
    @ViewBuilder
    private var cycleHistory: some View {
        let starts = store.periodStarts
        if starts.count >= 1 {
            VStack(alignment: .leading, spacing: 0) {
                Text("历次周期").font(.headline).padding(.bottom, 8)
                ForEach(Array(starts.suffix(8).reversed().enumerated()), id: \.offset) { i, s in
                    if i > 0 { RowDivider() }
                    cycleRow(s, starts: starts)
                }
            }
            .padding(16)
            .glassCard(22)
        }
    }

    private func cycleRow(_ s: Date, starts: [Date]) -> some View {
        let idx = starts.firstIndex(of: s) ?? 0
        let len: Int? = idx + 1 < starts.count ? FertilityStore.daysBetween(s, starts[idx + 1]) : nil
        return HStack {
            Text(FertilityStore.md(s)).font(.subheadline)
            Spacer()
            Text("经期 \(store.periodLength(from: s)) 天").font(.caption).foregroundStyle(.secondary)
            Text(len.map { "周期 \($0) 天" } ?? "本次").font(.subheadline.weight(.semibold).monospacedDigit())
                .frame(width: 86, alignment: .trailing)
        }
        .padding(.vertical, 9)
    }

    private var tipsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("备孕小贴士", systemImage: "lightbulb.fill").font(.headline).foregroundStyle(.yellow)
            ForEach(Self.tips, id: \.self) { t in
                HStack(alignment: .top, spacing: 6) {
                    Text("•")
                    Text(t)
                }
                .font(.footnote)
            }
            Text("排卵日、易孕期都是估算，仅供参考，不能用来避孕；身体不舒服请咨询医生。")
                .font(.caption2).foregroundStyle(.tertiary).padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(22)
    }

    static let tips = [
        "孕前 3 个月起每天吃叶酸 0.4 mg，一直吃到怀孕满 3 个月（可以在设置里开「吃药小组件」提醒）。",
        "易孕期（排卵前 5 天到排卵后 1 天）隔一天同房一次，比每天更合适。",
        "基础体温：每天早上醒来、起床说话前，用基础体温计测 3～5 分钟，时间尽量固定。",
        "排卵试纸：周期第 10 天左右开始测，变强阳后一般 24～36 小时内排卵。",
        "戒烟戒酒，咖啡因每天不超过 200 mg（约一杯咖啡），规律作息，BMI 保持在 18.5～23.9 最好。",
        "规律同房、没有避孕 1 年还没怀上（35 岁以上 6 个月），建议夫妻一起去医院检查。",
    ]
}

// MARK: - 日历

struct FertilityCalendar: View {
    @ObservedObject private var store = FertilityStore.shared
    @Binding var month: Date
    var onTap: (String) -> Void

    private var monthStart: Date {
        let c = FertilityStore.cal.dateComponents([.year, .month], from: month)
        return FertilityStore.cal.date(from: c)!
    }

    private var cells: [Date?] {
        let first = monthStart
        let wd = FertilityStore.cal.component(.weekday, from: first)   // 周日 = 1
        let lead = (wd + 5) % 7                                        // 周一开头
        let n = FertilityStore.cal.range(of: .day, in: .month, for: first)?.count ?? 30
        var out: [Date?] = Array(repeating: nil, count: lead)
        for i in 0..<n { out.append(FertilityStore.addDays(first, i)) }
        return out
    }

    var body: some View {
        let phases = store.phaseMap()
        let c = FertilityStore.cal.dateComponents([.year, .month], from: monthStart)
        VStack(spacing: 10) {
            HStack {
                Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                Spacer()
                Text("\(c.year ?? 0)年\(c.month ?? 0)月").font(.headline)
                Spacer()
                Button { shift(1) } label: { Image(systemName: "chevron.right") }
            }
            .padding(.horizontal, 4)
            HStack(spacing: 0) {
                ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { w in
                    Text(w).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(Array(cells.enumerated()), id: \.offset) { _, d in
                    if let d {
                        let k = FertilityStore.key(d)
                        DayCell(date: d, phase: phases[k] ?? .other, day: store.data.days[k])
                            .onTapGesture { onTap(k) }
                    } else {
                        Color.clear.frame(height: 44)
                    }
                }
            }
            legend
        }
        .padding(14)
        .glassCard(22)
    }

    private func shift(_ n: Int) {
        withAnimation(.easeOut(duration: 0.2)) {
            month = FertilityStore.cal.date(byAdding: .month, value: n, to: monthStart) ?? month
        }
    }

    private var legend: some View {
        HStack(spacing: 10) {
            dot(FertilityColor.period, "经期")
            dot(FertilityColor.period.opacity(0.4), "预测")
            dot(FertilityColor.fertile, "易孕")
            dot(FertilityColor.ovulation, "排卵")
            Spacer()
            Text("点日子记录").font(.caption2).foregroundStyle(.tertiary)
        }
        .font(.caption2)
    }

    private func dot(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(c).frame(width: 7, height: 7)
            Text(t).foregroundStyle(.secondary)
        }
    }
}

struct DayCell: View {
    let date: Date
    let phase: CyclePhase
    let day: FertilityDay?

    private var isToday: Bool { FertilityStore.cal.isDateInToday(date) }

    var body: some View {
        let n = FertilityStore.cal.component(.day, from: date)
        VStack(spacing: 2) {
            Text("\(n)")
                .font(.system(size: 15, weight: isToday ? .heavy : .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(textColor)
            HStack(spacing: 2) {
                if day?.bbt != nil { Circle().fill(FertilityColor.temp).frame(width: 4, height: 4) }
                if (day?.lh ?? 0) >= 3 { Circle().fill(FertilityColor.ovulation).frame(width: 4, height: 4) }
                if day?.sex == true { Image(systemName: "heart.fill").font(.system(size: 6)).foregroundStyle(FertilityColor.pink) }
                if !(day?.symptoms.isEmpty ?? true) || !(day?.note.isEmpty ?? true) { Circle().fill(Color.white.opacity(0.6)).frame(width: 4, height: 4) }
            }
            .frame(height: 6)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(bg))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(strokeColor, style: strokeStyle))
        .contentShape(Rectangle())
    }

    private var strokeColor: Color {
        if isToday { return Color.white.opacity(0.8) }
        if phase == .predictedPeriod { return FertilityColor.period.opacity(0.7) }
        return Color.clear
    }

    private var strokeStyle: StrokeStyle {
        if isToday { return StrokeStyle(lineWidth: 1.5) }
        if phase == .predictedPeriod { return StrokeStyle(lineWidth: 1, dash: [3, 2]) }
        return StrokeStyle(lineWidth: 1)
    }

    private var bg: Color {
        switch phase {
        case .period: return FertilityColor.period.opacity(0.75)
        case .predictedPeriod: return FertilityColor.period.opacity(0.15)
        case .fertile: return FertilityColor.fertile.opacity(0.22)
        case .ovulation: return FertilityColor.ovulation.opacity(0.55)
        case .other: return Color.white.opacity(0.04)
        }
    }

    private var textColor: Color {
        date > Date() ? .secondary : .primary
    }
}

// MARK: - 体温

struct TemperatureCard: View {
    @ObservedObject private var store = FertilityStore.shared
    @State private var range = 0   // 0 本周期 1 近 90 天

    private var from: Date {
        if range == 0, let s = store.lastStart { return s }
        return FertilityStore.addDays(Date(), -90)
    }

    var body: some View {
        let pts = store.bbtPoints(from: from)
        let shift = FertilityStore.detectShift(pts, rise: 0.2)
        let wrist = store.wristDeviation(from: from)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("基础体温", systemImage: "thermometer.medium").font(.headline).foregroundStyle(FertilityColor.temp)
                Spacer()
                Picker("", selection: $range) {
                    Text("本周期").tag(0)
                    Text("90天").tag(1)
                }
                .pickerStyle(.segmented).frame(width: 140)
            }
            if pts.isEmpty {
                Text("还没有体温记录。每天早上醒来先测基础体温，记在「记录今天」里；用的体温计能同步到健康 App 的，会自动读进来。")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                bbtChart(pts, cover: shift?.cover, shiftDate: shift?.date)
                    .frame(height: 170)
                Text(shiftText(shift, count: pts.count)).font(.footnote.weight(.semibold))
            }
            if !wrist.isEmpty {
                RowDivider()
                Text("手表睡眠腕温（和平时比）").font(.subheadline.weight(.semibold))
                wristChart(wrist).frame(height: 120)
                Text("Apple Watch 夜里测的手腕温度变化。排卵后通常会比平时高 0.2～0.5℃，可以和基础体温对照着看。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .glassCard(22)
    }

    private func shiftText(_ s: (date: Date, cover: Double)?, count: Int) -> String {
        if let s {
            let d = FertilityStore.daysBetween(s.date, Date()) + 1
            return "体温从 " + FertilityStore.md(s.date) + " 开始升高，可能在前一天排卵；已在高温期第 \(d) 天。虚线是覆盖线 " + String(format: "%.2f℃", s.cover) + "。"
        }
        if count < 9 { return "再记几天（至少 9 天）才能判断有没有升温。" }
        return "还没看到明显升温（连续 3 天高于前 6 天，且高出 0.2℃ 以上）。"
    }

    private func bbtChart(_ pts: [(Date, Double)], cover: Double?, shiftDate: Date?) -> some View {
        let vals = pts.map(\.1)
        let lo = (vals.min() ?? 36.2) - 0.15
        let hi = (vals.max() ?? 36.8) + 0.15
        return Chart {
            if let cover {
                RuleMark(y: .value("覆盖线", cover))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            if let shiftDate {
                RuleMark(x: .value("升温", shiftDate, unit: .day))
                    .foregroundStyle(FertilityColor.ovulation.opacity(0.4))
            }
            ForEach(Array(pts.enumerated()), id: \.offset) { _, p in
                LineMark(x: .value("日期", p.0, unit: .day), y: .value("体温", p.1))
                    .foregroundStyle(FertilityColor.temp)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                PointMark(x: .value("日期", p.0, unit: .day), y: .value("体温", p.1))
                    .foregroundStyle(FertilityColor.temp)
                    .symbolSize(24)
            }
        }
        .chartYScale(domain: lo...hi)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { v in
                AxisGridLine().foregroundStyle(.white.opacity(0.06))
                AxisValueLabel {
                    if let d = v.as(Double.self) { Text(String(format: "%.1f", d)).font(.caption2) }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { v in
                AxisValueLabel {
                    if let d = v.as(Date.self) { Text(FertilityStore.shortMD(d)).font(.caption2) }
                }
            }
        }
    }

    private func wristChart(_ pts: [(Date, Double)]) -> some View {
        Chart {
            RuleMark(y: .value("基线", 0.0)).foregroundStyle(Color.white.opacity(0.3))
            ForEach(Array(pts.enumerated()), id: \.offset) { _, p in
                BarMark(x: .value("日期", p.0, unit: .day), y: .value("偏差", p.1))
                    .foregroundStyle(p.1 >= 0 ? FertilityColor.temp : Color(red: 0.4, green: 0.7, blue: 1.0))
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                AxisGridLine().foregroundStyle(.white.opacity(0.06))
                AxisValueLabel {
                    if let d = v.as(Double.self) { Text(String(format: "%+.1f", d)).font(.caption2) }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { v in
                AxisValueLabel {
                    if let d = v.as(Date.self) { Text(FertilityStore.shortMD(d)).font(.caption2) }
                }
            }
        }
    }
}

// MARK: - 每天记录

struct DayLogSheet: View {
    let key: String
    let pregnant: Bool
    var onSaved: (Bool) -> Void = { _ in }   // 参数：验孕阳性

    @Environment(\.dismiss) private var dismiss
    @State private var d: FertilityDay
    @State private var bbtText: String
    @State private var weightText: String

    init(key: String, pregnant: Bool, onSaved: @escaping (Bool) -> Void = { _ in }) {
        self.key = key
        self.pregnant = pregnant
        self.onSaved = onSaved
        let day = FertilityStore.shared.data.days[key] ?? FertilityDay(key: key)
        _d = State(initialValue: day)
        _bbtText = State(initialValue: day.bbt.map { String(format: "%.2f", $0) } ?? "")
        _weightText = State(initialValue: day.weight.map { String(format: "%.1f", $0) } ?? "")
    }

    private var title: String {
        guard let date = FertilityStore.date(key) else { return key }
        return FertilityStore.cal.isDateInToday(date) ? "今天" : FertilityStore.md(date)
    }

    var body: some View {
        NavigationStack {
            Form {
                if pregnant {
                    pregnantSections
                } else {
                    tryingSections
                }
                Section("症状") {
                    FlowLayout(spacing: 8) {
                        ForEach(pregnant ? FertilityDay.pregnantSymptoms : FertilityDay.tryingSymptoms, id: \.self) { s in
                            symptomChip(s)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section("备注") {
                    TextField("想记点什么", text: $d.note, axis: .vertical)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.bold() }
            }
        }
        .presentationDetents([.large])
    }

    @ViewBuilder
    private var tryingSections: some View {
        Section("月经") {
            Picker("流量", selection: $d.flow) {
                ForEach(0..<FertilityDay.flowNames.count, id: \.self) { Text(FertilityDay.flowNames[$0]).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        Section {
            HStack {
                Text("基础体温")
                Spacer()
                TextField("例如 36.45", text: $bbtText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 110)
                Text("℃").foregroundStyle(.secondary)
            }
        } footer: {
            Text("早上醒来、起床说话前测的体温。")
        }
        Section("排卵试纸") {
            Picker("结果", selection: $d.lh) {
                ForEach(0..<FertilityDay.lhNames.count, id: \.self) { Text(FertilityDay.lhNames[$0]).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        Section {
            Picker("宫颈黏液", selection: $d.mucus) {
                ForEach(0..<FertilityDay.mucusNames.count, id: \.self) { Text(FertilityDay.mucusNames[$0]).tag($0) }
            }
            Toggle("同房", isOn: $d.sex)
            Picker("验孕", selection: $d.test) {
                ForEach(0..<FertilityDay.testNames.count, id: \.self) { Text(FertilityDay.testNames[$0]).tag($0) }
            }
        } footer: {
            Text("蛋清样（透明、能拉丝）的黏液说明快排卵了。同房只记在 App 里，不写进健康。")
        }
    }

    @ViewBuilder
    private var pregnantSections: some View {
        Section {
            HStack {
                Text("体重")
                Spacer()
                TextField("例如 52.3", text: $weightText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 110)
                Text("kg").foregroundStyle(.secondary)
            }
            Picker("出血", selection: $d.flow) {
                ForEach(0..<FertilityDay.flowNames.count, id: \.self) { Text(FertilityDay.flowNames[$0]).tag($0) }
            }
        } footer: {
            Text("健康 App 里有体重的会自动读，这里可以补记。孕期出血（见红）要及时联系医生。")
        }
    }

    private func symptomChip(_ s: String) -> some View {
        let on = d.symptoms.contains(s)
        return Text(s)
            .font(.subheadline)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(on ? FertilityColor.pink.opacity(0.35) : Color.white.opacity(0.08)))
            .overlay(Capsule().stroke(on ? FertilityColor.pink : Color.clear, lineWidth: 1))
            .onTapGesture {
                if on { d.symptoms.removeAll { $0 == s } } else { d.symptoms.append(s) }
            }
    }

    private func save() {
        let t = Double(bbtText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
        d.bbt = t.flatMap { (34.0...42.0).contains($0) ? $0 : nil }
        let w = Double(weightText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
        d.weight = w.flatMap { (25.0...200.0).contains($0) ? $0 : nil }
        let positive = d.test == 2 && (FertilityStore.shared.data.days[key]?.test ?? 0) != 2
        FertilityStore.shared.update(d)
        dismiss()
        onSaved(positive)
    }
}
