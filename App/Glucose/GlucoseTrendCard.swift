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
struct GlucoseTrendCard: View {
    /// (时间, 数值, 标签)
    let points: [GPoint]
    /// 点「这条记录」打开详情
    var onOpen: (String) -> Void = { _ in }

    @State private var kind: GlucoseKind = .after2
    @State private var days = 30
    @State private var meal: MealFilter = .all
    @State private var selected: Date?

    private var series: [GPoint] {
        let start = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        return points.filter {
            $0.0 >= start && GlucoseKind.of($0.2) == kind && (kind == .fasting || meal.matches($0.2))
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
            }
        }
        .padding(18)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { selected = nil } }
        .glassCard(26)
        .onChange(of: kind) { _, _ in selected = nil }
        .onChange(of: days) { _, _ in selected = nil }
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
                            .foregroundStyle(p.1 > kind.safeLine ? Color(red: 1.0, green: 0.32, blue: 0.32) : .primary)
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
        let lo = max(0, min(data.map(\.1).min() ?? 4, line) - 1)
        let hi = max(data.map(\.1).max() ?? 8, line) + 1
        let danger = Color(red: 1.0, green: 0.32, blue: 0.32)
        return Chart {
            RuleMark(y: .value("安全线", line))
                .foregroundStyle(danger.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                .annotation(position: .top, alignment: .leading, spacing: 2) {
                    Text("安全线 \(String(format: "%.1f", line))")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(danger)
                }
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
                    .symbolSize(p.1 > line ? 46 : 28)
                    .foregroundStyle(p.1 > line ? danger : kind.color)
            }
            if let p = picked {
                RuleMark(x: .value("时间", p.0))
                    .foregroundStyle(.white.opacity(0.35))
                PointMark(x: .value("时间", p.0), y: .value("血糖", p.1))
                    .symbolSize(90)
                    .foregroundStyle(.white)
                    .annotation(position: .top, spacing: 6,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        HStack(spacing: 6) {
                            if let img = p.4 {
                                Image(uiImage: img).resizable().scaledToFill()
                                    .frame(width: 34, height: 34)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(String(format: "%.1f mmol/L", p.1))
                                    .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                                Text(label(p.0) + " · " + p.2)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                if let n = p.3, !n.isEmpty {
                                    Text(n).font(.system(size: 10, weight: .medium)).lineLimit(1)
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .glassCard(10)
                    }
            }
        }
        .chartYScale(domain: lo...hi)
        .tapToSelect($selected, dates: data.map(\.0))
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { v in
                AxisGridLine().foregroundStyle(.white.opacity(0.08))
                AxisValueLabel {
                    if let d = v.as(Double.self) { Text(String(format: "%.0f", d)).font(.caption2) }
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
        let line: Double
        var id: String { record.id }
    }

    let items: [Item]
    let missing: Set<String>
    let owners: [String: String]
    let onSave: (String, String?, [GlucosePhoto]) -> Void

    enum Filter: String, CaseIterable, Identifiable {
        case all = "全部超标", breakfast = "早餐", lunch = "午餐", dinner = "晚餐"
        var id: String { rawValue }
    }

    @State private var filter: Filter = .all
    @State private var editing: GlucoseRecord?
    @State private var viewing: Int?        // 正在看大图的是第几张

    private var shown: [Item] {
        let list: [Item]
        switch filter {
        case .all: list = items
        case .breakfast: list = items.filter { $0.label.contains("早餐") }
        case .lunch: list = items.filter { $0.label.contains("午餐") }
        case .dinner: list = items.filter { $0.label.contains("晚餐") }
        }
        return list.sorted { $0.record.date > $1.record.date }
    }

    var body: some View {
        let list = shown
        ScrollView {
            VStack(spacing: 14) {
                Picker("", selection: $filter) {
                    ForEach(Filter.allCases) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)

                HStack {
                    Text("\(list.count) 次超标").font(.headline)
                    Spacer()
                    if !list.isEmpty {
                        let avg = list.map(\.record.mmol).reduce(0, +) / Double(list.count)
                        Text("平均 " + String(format: "%.1f", avg) + " · 最高 " + String(format: "%.1f", list.map(\.record.mmol).max() ?? 0))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 4)

                if list.isEmpty {
                    Text("这里没有超标的记录 👍").font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(30).glassCard(20)
                }

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 14) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, it in
                        Button { viewing = i } label: { tile(it) }
                            .buttonStyle(.plain)
                    }
                }

                Text("超标线：空腹 6.1，餐后1小时 8.6，餐后2小时及以后 7.8（mmol/L）。点照片看大图，左右滑看下一张。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(16)
            .padding(.bottom, 100)
        }
        .background(AppBackground())
        .navigationTitle("超标相册")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .fullScreenCover(isPresented: Binding(get: { viewing != nil }, set: { if !$0 { viewing = nil } })) {
            GlucoseOverViewer(items: list, start: viewing ?? 0, missing: missing) { r in
                viewing = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { editing = r }
            }
        }
        .sheet(item: $editing) { r in
            GlucoseRecordSheet(record: r, tag: items.first { $0.id == r.id }?.label,
                               owner: owners[r.id] ?? GlucosePeople.me, missing: missing) { note, photos in
                onSave(r.id, note, photos)
            }
        }
    }

    private func tile(_ it: Item) -> some View {
        let r = it.record
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "M月d日 HH:mm"
        return VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let p = r.photos?.first {
                        GlucosePhotoView(photo: p, missing: p.assetID.map(missing.contains) ?? false, side: 400)
                    } else {
                        LinearGradient(colors: [Color(red: 0.35, green: 0.12, blue: 0.2), Color(red: 0.15, green: 0.08, blue: 0.18)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                            .overlay(Image(systemName: "fork.knife").font(.title).foregroundStyle(.white.opacity(0.25)))
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fill)
                .clipped()

                // 底部渐变 + 血糖值
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(String(format: "%.1f", r.mmol))
                            .font(.system(size: 26, weight: .heavy, design: .rounded).monospacedDigit())
                            .foregroundStyle(Color(red: 1, green: 0.42, blue: 0.45))
                        Text("超 " + String(format: "%.1f", r.mmol - it.line))
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    Text(it.label).font(.caption2.weight(.semibold)).foregroundStyle(.white)
                }
                .padding(8)
            }
            .aspectRatio(1, contentMode: .fit)
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

/// 超标相册看大图：上面照片，下面血糖值和备注（备注点一下展开全文），左右滑切换
struct GlucoseOverViewer: View {
    let items: [GlucoseOverGallery.Item]
    let start: Int
    let missing: Set<String>
    let onEdit: (GlucoseRecord) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var expanded = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, it in
                    page(it).tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .onChange(of: index) { _, _ in expanded = false }

            HStack(spacing: 12) {
                Text("\(index + 1) / \(items.count)").font(.subheadline.monospacedDigit()).foregroundStyle(.white.opacity(0.7))
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").font(.title).foregroundStyle(.white.opacity(0.85))
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
        .onAppear { index = start }
    }

    private func page(_ it: GlucoseOverGallery.Item) -> some View {
        let r = it.record
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "M月d日 EEE HH:mm"
        return VStack(spacing: 0) {
            Spacer(minLength: 50)
            Group {
                if let p = r.photos?.first {
                    GlucosePhotoView(photo: p, missing: p.assetID.map(missing.contains) ?? false, side: 1600, fit: true)
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
                        .foregroundStyle(Color(red: 1, green: 0.42, blue: 0.45))
                    Text("mmol/L").font(.caption).foregroundStyle(.white.opacity(0.6))
                    Text("超标线 " + String(format: "%.1f", it.line) + "，高 " + String(format: "%.1f", r.mmol - it.line))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.red.opacity(0.3)))
                    Spacer()
                    Button { onEdit(r) } label: {
                        Image(systemName: "square.and.pencil").font(.title3).foregroundStyle(.white.opacity(0.7))
                    }
                }
                Text(it.label + " · " + f.string(from: r.date)).font(.subheadline).foregroundStyle(.white.opacity(0.75))
                if let n = r.note, !n.isEmpty {
                    Text(n)
                        .font(.body)
                        .foregroundStyle(.white)
                        .lineLimit(expanded ? nil : 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() } }
                    if !expanded && n.count > 40 {
                        Text("点一下看全部备注").font(.caption2).foregroundStyle(.white.opacity(0.4))
                    }
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
