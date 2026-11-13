import SwiftUI
import Charts

/// 血糖分类：从餐点标签里看出是空腹、餐后 1 小时还是餐后 2 小时
enum GlucoseKind: String, CaseIterable, Identifiable {
    case fasting = "空腹"
    case after1 = "餐后1h"
    case after2 = "餐后2h"

    var id: String { rawValue }

    static func of(_ tag: String?) -> GlucoseKind? {
        guard let t = tag else { return nil }
        if t == "空腹" { return .fasting }
        if t.hasSuffix("后1小时") { return .after1 }
        if t.hasSuffix("后2小时") { return .after2 }
        return nil
    }

    /// 安全线：空腹 6.1（WHO/中国指南正常上限）、餐后2小时 7.8（WHO 正常糖耐量上限）、
    /// 餐后1小时 8.6（IDF 2024 立场声明）。是「正常与否」的界值，不是个人治疗目标
    var safeLine: Double {
        switch self {
        case .fasting: return 6.1
        case .after1: return 8.6
        case .after2: return 7.8
        }
    }

    var color: Color {
        switch self {
        case .fasting: return Color(red: 0.40, green: 0.80, blue: 1.0)
        case .after1: return Color(red: 1.0, green: 0.70, blue: 0.30)
        case .after2: return Color(red: 1.0, green: 0.40, blue: 0.55)
        }
    }
}

/// 趋势图上的一个点：时间、数值、餐点、备注、照片小图
typealias GPoint = (Date, Double, String, String?, UIImage?, String)   // 最后一个是记录 id

/// 只看某一餐
enum MealFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case lunchDinner = "午餐+晚餐"
    case breakfast = "早餐"
    case lunch = "午餐"
    case dinner = "晚餐"

    var id: String { rawValue }

    func matches(_ tag: String) -> Bool {
        switch self {
        case .all: return true
        case .lunchDinner: return tag.hasPrefix("午餐") || tag.hasPrefix("晚餐")
        case .breakfast: return tag.hasPrefix("早餐")
        case .lunch: return tag.hasPrefix("午餐")
        case .dinner: return tag.hasPrefix("晚餐")
        }
    }
}

/// 血糖页最上面的趋势卡片：选空腹 / 餐后1h / 餐后2h 和时间范围，按住曲线看每个点
/// 低血糖：低于 3.9 mmol/L（糖尿病指南的低血糖警戒值）
enum GlucoseLow {
    static let line = 3.9
    static let color = Color(red: 0.35, green: 0.65, blue: 1.0)
}

struct GlucoseTrendCard: View {
    /// (时间, 数值, 标签)
    let points: [GPoint]
    /// 点「这条记录」打开详情
    var onOpen: (String) -> Void = { _ in }
    /// 其他测量人（不含「我」）；记录 id → 测量人
    var people: [String] = []
    var ownerOf: (String) -> String = { _ in GlucosePeople.me }

    @State private var person = GlucosePeople.me   // 默认看自己的趋势
    @State private var kind: GlucoseKind = .after2
    @State private var days = 30
    @State private var meal: MealFilter = .all
    @State private var selected: Date?

    private var series: [GPoint] {
        let start = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        return points.filter {
            $0.0 >= start && GlucoseKind.of($0.2) == kind && (kind == .fasting || meal.matches($0.2))
                && ownerOf($0.5) == person
        }.sorted { $0.0 < $1.0 }
    }

    private var picked: GPoint? {
        guard let s = selected else { return nil }
        return series.min { abs($0.0.timeIntervalSince(s)) < abs($1.0.timeIntervalSince(s)) }
    }

    var body: some View {
        let data = series
        let values = data.map(\.1)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("血糖趋势", systemImage: "drop.fill")
                    .font(.headline)
                    .foregroundStyle(kind.color)
                Spacer()
                if !people.isEmpty {
                    Picker("测量人", selection: $person) {
                        Text(GlucosePeople.me).tag(GlucosePeople.me)
                        ForEach(people, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .tint(.secondary)
                }
                Picker("范围", selection: $days) {
                    Text("7天").tag(7)
                    Text("30天").tag(30)
                    Text("90天").tag(90)
                }
                .pickerStyle(.menu)
                .tint(.secondary)
            }

            Picker("类型", selection: $kind) {
                ForEach(GlucoseKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            if kind != .fasting {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(MealFilter.allCases) { m in
                            Button {
                                meal = m
                            } label: {
                                Text(m.rawValue)
                                    .font(.footnote.weight(.semibold))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .foregroundStyle(meal == m ? Color.white : Color.secondary)
                                    .background(Capsule().fill(meal == m ? kind.color.opacity(0.85) : Color.white.opacity(0.08)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            if data.count >= 1 {
                // 图例放在图外面，不和曲线打架
                HStack(spacing: 5) {
                    Spacer()
                    Path { p in p.move(to: CGPoint(x: 0, y: 1)); p.addLine(to: CGPoint(x: 16, y: 1)) }
                        .stroke(Color(red: 1.0, green: 0.32, blue: 0.32), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .frame(width: 16, height: 2)
                    Text("安全线 " + String(format: "%.1f", kind.safeLine))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(red: 1.0, green: 0.32, blue: 0.32))
                    Path { p in p.move(to: CGPoint(x: 0, y: 1)); p.addLine(to: CGPoint(x: 16, y: 1)) }
                        .stroke(GlucoseLow.color, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .frame(width: 16, height: 2)
                        .padding(.leading, 6)
                    Text("低血糖 3.9")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(GlucoseLow.color)
                }
                .padding(.bottom, -6)
                chart(data)
                    .frame(height: 180)
            } else {
                Text("这段时间没有「\(kind.rawValue)」的记录。\n在下面的记录里把餐点标成「\(kind == .fasting ? "空腹" : kind == .after1 ? "午餐后1小时" : "午餐后2小时")」这类，就会出现在这里。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }

            if let p = picked {
                pickedRow(p)
            }

            HStack(spacing: 0) {
                stat("最新", data.last.map { String(format: "%.1f", $0.1) }, jump: data.last?.0)
                stat("平均", values.isEmpty ? nil : String(format: "%.1f", values.reduce(0, +) / Double(values.count)))
                stat("最高", values.max().map { String(format: "%.1f", $0) }, jump: data.max { $0.1 < $1.1 }?.0)
                stat("最低", values.min().map { String(format: "%.1f", $0) }, jump: data.min { $0.1 < $1.1 }?.0)
                stat("超线", values.isEmpty ? nil : "\(values.filter { $0 > kind.safeLine }.count)/\(values.count)")
                stat("偏低", values.isEmpty ? nil : "\(values.filter { $0 < GlucoseLow.line }.count)", jump: data.first { $0.1 < GlucoseLow.line }?.0)
            }
        }
        .padding(18)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { selected = nil } }
        .glassCard(26)
        .onChange(of: kind) { _, _ in selected = nil }
        .onChange(of: days) { _, _ in selected = nil }
        .onChange(of: person) { _, _ in selected = nil }
        .onChange(of: meal) { _, _ in selected = nil }
    }

    /// 选中的点：照片 + 数值 + 时间 + 备注，点一下打开这条记录的「照片和备注」
    private func pickedRow(_ p: GPoint) -> some View {
        Button {
            onOpen(p.5)
        } label: {
            HStack(spacing: 10) {
                Group {
                    if let img = p.4 {
                        Image(uiImage: img).resizable().scaledToFill()
                    } else {
                        Image(systemName: "camera").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.white.opacity(0.08))
                    }
                }
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(String(format: "%.1f", p.1))
                            .font(.system(size: 18, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(p.1 > kind.safeLine ? Color(red: 1.0, green: 0.32, blue: 0.32) : p.1 < GlucoseLow.line ? GlucoseLow.color : .primary)
                        Text(label(p.0) + " · " + p.2).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(p.3.flatMap { $0.isEmpty ? nil : $0 } ?? (p.4 == nil ? "点这里加照片和备注" : "点这里查看照片和备注"))
                        .font(.caption)
                        .foregroundStyle(p.3 == nil ? Color.secondary : Color.primary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func chart(_ data: [GPoint]) -> some View {
        let line = kind.safeLine
        let lo = max(0, min(data.map(\.1).min() ?? 4, GlucoseLow.line) - 1)
        let hi = max(data.map(\.1).max() ?? 8, line) + 1
        let danger = Color(red: 1.0, green: 0.32, blue: 0.32)
        return Chart {
            RuleMark(y: .value("安全线", line))
                .foregroundStyle(danger.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
            // 低血糖线 3.9
            RuleMark(y: .value("低血糖", GlucoseLow.line))
                .foregroundStyle(GlucoseLow.color.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
            ForEach(Array(data.enumerated()), id: \.offset) { _, p in
                AreaMark(x: .value("时间", p.0), yStart: .value("下限", lo), yEnd: .value("血糖", p.1))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(LinearGradient(colors: [kind.color.opacity(0.35), kind.color.opacity(0.0)],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("时间", p.0), y: .value("血糖", p.1))
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .foregroundStyle(kind.color)
                PointMark(x: .value("时间", p.0), y: .value("血糖", p.1))
                    .symbolSize(p.1 > line || p.1 < GlucoseLow.line ? 46 : 28)
                    .foregroundStyle(p.1 > line ? danger : p.1 < GlucoseLow.line ? GlucoseLow.color : kind.color)
            }
            if let p = picked {
                RuleMark(x: .value("时间", p.0))
                    .foregroundStyle(.white.opacity(0.35))
                PointMark(x: .value("时间", p.0), y: .value("血糖", p.1))
                    .symbolSize(90)
                    .foregroundStyle(.white)
                    .annotation(position: .top, spacing: 6,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        // 只显示数值，详情在图下面
                        Text(String(format: "%.1f", p.1))
                            .font(.system(size: 14, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(p.1 > line ? danger : p.1 < GlucoseLow.line ? GlucoseLow.color : Color.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .glassCard(10)
                    }
            }
        }
        .chartYScale(domain: lo...hi)
        .tapToSelect($selected, dates: data.map(\.0))
        .chartYAxis {
            // 普通刻度（太靠近安全线的不显示，免得和 7.8 挤在一起）
            AxisMarks(position: .trailing, values: yTicks(lo, hi, avoid: line)) { v in
                AxisGridLine().foregroundStyle(.white.opacity(0.08))
                AxisValueLabel {
                    if let d = v.as(Double.self) { Text(String(format: "%.0f", d)).font(.caption2) }
                }
            }
            // 安全线的数值标在右边坐标轴上
            AxisMarks(position: .trailing, values: [line]) { _ in
                AxisValueLabel {
                    Text(String(format: "%.1f", line))
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(danger.opacity(0.85)))
                }
            }
            AxisMarks(position: .trailing, values: [GlucoseLow.line]) { _ in
                AxisValueLabel {
                    Text("3.9")
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(GlucoseLow.color.opacity(0.85)))
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { v in
                AxisValueLabel {
                    if let d = v.as(Date.self) { Text(shortDay(d)).font(.caption2) }
                }
            }
        }
    }

    /// 右边坐标轴的刻度：每 2 一格（范围小就每 1 一格），离安全线太近的去掉
    private func yTicks(_ lo: Double, _ hi: Double, avoid: Double) -> [Double] {
        let step: Double = hi - lo > 6 ? 2 : 1
        var v = (lo / step).rounded(.up) * step
        var out: [Double] = []
        while v <= hi { if abs(v - avoid) > step * 0.45 && abs(v - GlucoseLow.line) > step * 0.45 { out.append(v) }; v += step }
        return out
    }

    /// 统计数字；带 jump 的点一下会在图上选中那个点
    private func stat(_ title: String, _ value: String?, jump: Date? = nil) -> some View {
        Button {
            if let jump { withAnimation(.easeOut(duration: 0.2)) { selected = jump } }
        } label: {
            VStack(spacing: 3) {
                Text(value ?? "--")
                    .font(.system(size: 17, weight: .bold, design: .rounded).monospacedDigit())
                HStack(spacing: 2) {
                    Text(title)
                    if jump != nil { Image(systemName: "scope").font(.system(size: 8)) }
                }
                .font(.caption2)
                .foregroundStyle(jump != nil ? kind.color : .secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(jump == nil)
    }

    private func label(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm"
        return f.string(from: d)
    }

    private func shortDay(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "M/d"
        return f.string(from: d)
    }
}

// MARK: - 超标相册

/// 这条血糖的超标线（空腹 6.1、餐后1小时 8.6、餐后2小时及以后 7.8）；其他标签不判断
func glucoseSafeLine(_ label: String?) -> Double? {
    guard let t = label else { return nil }
    if t == "空腹" { return 6.1 }
    if t.contains("后1小时") { return 8.6 }
    if t.contains("餐后") { return 7.8 }
    return nil
}

struct GlucoseOverGallery: View {
    struct Item: Identifiable {
        let record: GlucoseRecord
        let label: String
        let line: Double?          // 超标线（没有判断标准的标签为 nil）
        var id: String { record.id }
        var over: Bool { line.map { record.mmol > $0 } ?? false }
    }

    let items: [Item]
    let missing: Set<String>
    let owners: [String: String]
    let onSave: (String, String?, [GlucosePhoto]) -> Void

    enum OverSub: String, CaseIterable, Identifiable {
        case all = "全部", fasting = "空腹", breakfast = "早餐", lunch = "午餐", dinner = "晚餐"
        var id: String { rawValue }
        func match(_ label: String) -> Bool {
            self == .all || label.contains(rawValue)
        }
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all = "全部", over = "超标", breakfast = "早餐", lunch = "午餐", dinner = "晚餐"
        var id: String { rawValue }
    }

    @State private var filter: Filter = .all
    @State private var overSub: OverSub = .all    // 超标里再按餐点分
    @State private var atTop = true                // 滚到下面时显示「回到顶部」
    @State private var editing: GlucoseRecord?
    @State private var viewing: Int?        // 正在看大图的是第几张
    @State private var lastSeen: String?    // 大图最后停在哪张，返回时滚到那里

    private var shown: [Item] {
        let list: [Item]
        switch filter {
        // 超标：所有超标的（没拍照的也算）；其他：有照片的
        case .over: list = items.filter { $0.over && overSub.match($0.label) }
        case .all: list = items.filter { !($0.record.photos ?? []).isEmpty }
        case .breakfast: list = items.filter { $0.label.contains("早餐") && !($0.record.photos ?? []).isEmpty }
        case .lunch: list = items.filter { $0.label.contains("午餐") && !($0.record.photos ?? []).isEmpty }
        case .dinner: list = items.filter { $0.label.contains("晚餐") && !($0.record.photos ?? []).isEmpty }
        }
        return list.sorted { $0.record.date > $1.record.date }
    }

    var body: some View {
        let list = shown
        ScrollViewReader { proxy in
        ScrollView {
            VStack(spacing: 14) {
                Picker("", selection: $filter) {
                    ForEach(Filter.allCases) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .id("top")
                .background(GeometryReader { g in
                    Color.clear.preference(key: GalleryTopKey.self, value: g.frame(in: .named("gallery")).minY)
                })

                if filter == .over {
                    // 超标里再细分
                    HStack(spacing: 8) {
                        ForEach(OverSub.allCases) { s in
                            let n = items.filter { $0.over && s.match($0.label) }.count
                            Button { withAnimation(.snappy) { overSub = s } } label: {
                                Text(s.rawValue + (n > 0 ? " \(n)" : ""))
                                    .font(.footnote.weight(overSub == s ? .bold : .regular))
                                    .foregroundStyle(overSub == s ? Color.white : Color.secondary)
                                    .padding(.horizontal, 11).padding(.vertical, 6)
                                    .background(Capsule().fill(overSub == s ? Color(red: 1, green: 0.42, blue: 0.45).opacity(0.55) : Color.white.opacity(0.08)))
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer(minLength: 0)
                    }
                }

                HStack {
                    Text(filter == .over ? "\(list.count) 次超标" : "\(list.count) 张 · 超标 \(list.filter(\.over).count) 次").font(.headline)
                    Spacer()
                    if !list.isEmpty {
                        let avg = list.map(\.record.mmol).reduce(0, +) / Double(list.count)
                        Text("平均 " + String(format: "%.1f", avg) + " · 最高 " + String(format: "%.1f", list.map(\.record.mmol).max() ?? 0))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 4)

                if list.isEmpty {
                    Text(filter == .over ? "这里没有超标的记录 👍" : "这里还没有带照片的记录").font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(30).glassCard(20)
                }

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 14) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, it in
                        Button { viewing = i } label: { tile(it) }
                            .buttonStyle(.plain)
                            .id(it.id)
                    }
                }

                Text("超标线：空腹 6.1，餐后1小时 8.6，餐后2小时及以后 7.8（mmol/L）。点照片看大图，左右滑看下一张，双指或双击放大。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(16)
            .padding(.bottom, 100)
        }
        .coordinateSpace(name: "gallery")
        .onPreferenceChange(GalleryTopKey.self) { y in
            if #available(iOS 18, *) { return }      // iOS 18 起用下面更可靠的方法
            setTop(y > -300)
        }
        .modifier(ScrollTopWatcher { setTop($0) })
        // 回到顶部
        .overlay(alignment: .bottomTrailing) {
            if !atTop {
                Button {
                    withAnimation { proxy.scrollTo("top", anchor: .top) }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 46, height: 46)
                        .background(Circle().fill(.ultraThinMaterial))
                        .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
                }
                .padding(.trailing, 20)
                .padding(.bottom, 108)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .fullScreenCover(isPresented: Binding(get: { viewing != nil }, set: { if !$0 { viewing = nil } }),
                         onDismiss: {
            // 返回时滚到大图里最后看的那张
            if let id = lastSeen { withAnimation { proxy.scrollTo(id, anchor: .center) } }
        }) {
            GlucoseOverViewer(items: list, start: viewing ?? 0, missing: missing,
                              onPage: { i in if list.indices.contains(i) { lastSeen = list[i].id } }) { r in
                viewing = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { editing = r }
            }
        }
        }
        .background(AppBackground())
        .navigationTitle("血糖相册")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .sheet(item: $editing) { r in
            GlucoseRecordSheet(record: r, tag: items.first { $0.id == r.id }?.label,
                               owner: owners[r.id] ?? GlucosePeople.me, missing: missing) { note, photos in
                onSave(r.id, note, photos)
            }
        }
    }

    private func setTop(_ top: Bool) {
        if top != atTop { withAnimation(.easeInOut(duration: 0.2)) { atTop = top } }
    }

    private func tile(_ it: Item) -> some View {
        let r = it.record
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "M月d日 HH:mm"
        return VStack(alignment: .leading, spacing: 6) {
            // 固定正方形：照片铺满裁剪，血糖值压在照片底部
            Color.clear
                .aspectRatio(3.0 / 4.0, contentMode: .fit)   // 竖图比例，照片基本完整
                .overlay {
                    if let p = r.photos?.first {
                        GlucosePhotoView(photo: p, missing: p.assetID.map(missing.contains) ?? false, side: 400)
                    } else {
                        LinearGradient(colors: [Color(red: 0.35, green: 0.12, blue: 0.2), Color(red: 0.15, green: 0.08, blue: 0.18)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                            .overlay(Image(systemName: "fork.knife").font(.title).foregroundStyle(.white.opacity(0.25)))
                    }
                }
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 70)
                }
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(String(format: "%.1f", r.mmol))
                                .font(.system(size: 28, weight: .heavy, design: .rounded).monospacedDigit())
                                .foregroundStyle(it.over ? Color(red: 1, green: 0.45, blue: 0.48) : Color(red: 0.45, green: 0.95, blue: 0.65))
                            if it.over, let line = it.line {
                                Text("高 " + String(format: "%.1f", r.mmol - line))
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.9))
                            }
                        }
                        Text(it.label).font(.caption2.weight(.semibold)).foregroundStyle(.white)
                    }
                    .shadow(color: .black.opacity(0.6), radius: 3)
                    .padding(9)
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            Text(f.string(from: r.date)).font(.caption2).foregroundStyle(.secondary)
            Text(r.note?.isEmpty == false ? r.note! : "没有备注")
                .font(.caption)
                .foregroundStyle(r.note?.isEmpty == false ? Color.primary : Color.secondary.opacity(0.6))
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
        }
    }
}

/// 监听滚动位置：滚下去超过 300 点就算「不在顶部」
private struct ScrollTopWatcher: ViewModifier {
    let onChange: (Bool) -> Void
    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.onScrollGeometryChange(for: Bool.self) { g in
                g.contentOffset.y + g.contentInsets.top < 300
            } action: { _, top in onChange(top) }
        } else {
            content
        }
    }
}

private struct GalleryTopKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// 可以双指放大、双击放大、放大后拖动看细节的照片；没放大时单击触发 onTap（返回）
struct ZoomablePhoto: View {
    let photo: GlucosePhoto
    let missing: Bool
    @Binding var zoomed: Bool
    var onTap: () -> Void

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { g in
            let size = g.size
            // 图片本身只做变换；手势挂在外面不变形的框上，手指位置才准
            ZStack {
                GlucosePhotoView(photo: photo, missing: missing, side: 2400, fit: true)
                    .frame(width: size.width, height: size.height)
                    .scaleEffect(scale)
                    .offset(offset)
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .gesture(
                MagnifyGesture()
                    .onChanged { v in
                        let s1 = min(5, max(1, lastScale * v.magnification))
                        // 以双指中间为中心放大：手指下的那块保持不动
                        offset = zoomOffset(at: v.startLocation, from: lastScale, to: s1, base: lastOffset, size: size)
                        scale = s1
                    }
                    .onEnded { _ in
                        if scale < 1.05 { withAnimation(.spring(duration: 0.3)) { reset() } } else {
                            lastScale = scale; zoomed = true
                            withAnimation(.spring(duration: 0.25)) { offset = clamp(offset, size) }
                            lastOffset = clamp(offset, size)
                        }
                    }
            )
            // 放大后单指拖动看细节（优先于左右翻页和往下拉返回）
            .highPriorityGesture(
                DragGesture()
                    .onChanged { v in
                        offset = CGSize(width: lastOffset.width + v.translation.width,
                                        height: lastOffset.height + v.translation.height)
                    }
                    .onEnded { _ in
                        withAnimation(.spring(duration: 0.25)) { offset = clamp(offset, size) }
                        lastOffset = clamp(offset, size)
                    },
                including: scale > 1 ? .all : .subviews
            )
            // 双击：在点的位置放大 / 缩回
            .gesture(
                SpatialTapGesture(count: 2).onEnded { v in
                    withAnimation(.spring(duration: 0.3)) {
                        if scale > 1 { reset() } else {
                            let o = zoomOffset(at: v.location, from: 1, to: 2.5, base: .zero, size: size)
                            scale = 2.5; lastScale = 2.5; zoomed = true
                            offset = clamp(o, size); lastOffset = offset
                        }
                    }
                }
                .exclusively(before: TapGesture().onEnded {
                    if scale > 1 { withAnimation(.spring(duration: 0.3)) { reset() } } else { onTap() }
                })
            )
        }
        .clipped()
    }

    /// 从 s0 缩放到 s1 时，让屏幕上点 p 下面的内容不动，算出新的偏移
    private func zoomOffset(at p: CGPoint, from s0: CGFloat, to s1: CGFloat, base o0: CGSize, size: CGSize) -> CGSize {
        let dx = p.x - size.width / 2, dy = p.y - size.height / 2
        let k = s1 / s0
        return CGSize(width: dx - k * (dx - o0.width), height: dy - k * (dy - o0.height))
    }

    private func reset() {
        scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero; zoomed = false
    }

    private func clamp(_ o: CGSize, _ size: CGSize) -> CGSize {
        let mx = (scale - 1) * size.width / 2, my = (scale - 1) * size.height / 2
        return CGSize(width: min(mx, max(-mx, o.width)), height: min(my, max(-my, o.height)))
    }
}

/// 血糖相册看大图：上面照片，下面血糖值和备注（备注点一下展开全文），左右滑切换
struct GlucoseOverViewer: View {
    let items: [GlucoseOverGallery.Item]
    let start: Int
    let missing: Set<String>
    var onPage: (Int) -> Void = { _ in }
    let onEdit: (GlucoseRecord) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var dragY: CGFloat = 0     // 往下拉的距离，松手超过一定距离就返回
    @State private var zoomed = false         // 照片放大时不翻页、不下拉返回

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(1 - min(Double(dragY) / 500, 0.6)).ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, it in
                    page(it).tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .scrollDisabled(zoomed)      // 放大时拖动是看细节，不翻页
            .offset(y: dragY)
            .scaleEffect(1 - min(dragY / 2000, 0.15))
            // 往下拉返回（只认竖直方向，左右滑还是翻页）
            .simultaneousGesture(
                DragGesture(minimumDistance: 15)
                    .onChanged { v in
                        guard !zoomed else { return }
                        let dy = v.translation.height
                        if dy > 0 && dy > abs(v.translation.width) * 1.2 { dragY = dy }
                    }
                    .onEnded { v in
                        guard !zoomed else { dragY = 0; return }
                        if dragY > 110 || (dragY > 30 && v.predictedEndTranslation.height > 300) {
                            dismiss()
                        } else {
                            withAnimation(.spring(duration: 0.3)) { dragY = 0 }
                        }
                    }
            )

            HStack(spacing: 12) {
                Text("\(index + 1) / \(items.count)").font(.subheadline.monospacedDigit()).foregroundStyle(.white.opacity(0.7))
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").font(.title).foregroundStyle(.white.opacity(0.85))
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
        .onAppear { index = start; onPage(start) }
        .onChange(of: index) { _, i in onPage(i); zoomed = false }
    }

    private func page(_ it: GlucoseOverGallery.Item) -> some View {
        let r = it.record
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "M月d日 EEE HH:mm"
        return VStack(spacing: 0) {
            Spacer(minLength: 50)
            Group {
                if let p = r.photos?.first {
                    // 双指/双击放大；没放大时点一下返回
                    ZoomablePhoto(photo: p, missing: p.assetID.map(missing.contains) ?? false,
                                  zoomed: $zoomed) { dismiss() }
                        .zIndex(1)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "fork.knife").font(.system(size: 40))
                        Text("这条没有拍照").font(.footnote)
                    }
                    .foregroundStyle(.white.opacity(0.3))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 照片下面：血糖值 + 餐点时间 + 备注
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(String(format: "%.1f", r.mmol))
                        .font(.system(size: 40, weight: .heavy, design: .rounded).monospacedDigit())
                        .foregroundStyle(it.over ? Color(red: 1, green: 0.42, blue: 0.45) : Color(red: 0.45, green: 0.95, blue: 0.65))
                    Text("mmol/L").font(.caption).foregroundStyle(.white.opacity(0.6))
                    if let line = it.line {
                        Text(it.over ? "超标线 " + String(format: "%.1f", line) + "，高 " + String(format: "%.1f", r.mmol - line)
                                     : "正常（< " + String(format: "%.1f", line) + "）")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.8))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(it.over ? Color.red.opacity(0.3) : Color.green.opacity(0.25)))
                    }
                    Spacer()
                    Button { onEdit(r) } label: {
                        Image(systemName: "square.and.pencil").font(.title3).foregroundStyle(.white.opacity(0.7))
                    }
                }
                Text(it.label + " · " + f.string(from: r.date)).font(.subheadline).foregroundStyle(.white.opacity(0.75))
                if let n = r.note, !n.isEmpty {
                    // 备注全部显示，太长就在这块里上下滑
                    ScrollView {
                        Text(n)
                            .font(.body)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)
                    .fixedSize(horizontal: false, vertical: n.count < 80)
                } else {
                    Text("没有备注").font(.subheadline).foregroundStyle(.white.opacity(0.35))
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [.clear, .white.opacity(0.06)], startPoint: .top, endPoint: .bottom))
        }
    }
}
