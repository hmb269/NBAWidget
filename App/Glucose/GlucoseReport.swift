import SwiftUI
import Charts

// 血糖报告：生成 PDF（A4），复查时给医生看。
// 内容：统计汇总、血糖曲线、体重/BMI、超标和偏低的记录、全部记录（带饭后活动）、餐食照片

struct ReportRow: Identifiable {
    let id: String
    let date: Date
    let mmol: Double
    let label: String
    let note: String
    let line: Double?
    let post: PostMealActivity?
    let photo: UIImage?
    var over: Bool { line.map { mmol > $0 } ?? false }
    var low: Bool { mmol < GlucoseLow.line }
}

struct ReportData {
    var from: Date
    var to: Date
    var rows: [ReportRow]           // 从早到晚
    var weightStart: Double?
    var weightEnd: Double?
    var heightCm: Double?
}

enum GlucoseReport {
    static let page = CGSize(width: 595, height: 842)   // A4（点）

    /// 收集数据（只要自己的记录）
    static func collect(days: Int) async -> ReportData {
        let cal = Calendar.current
        let to = Date()
        let from = cal.date(byAdding: .day, value: -(days - 1), to: cal.startOfDay(for: to))!
        let owners = GlucosePeople.owners
        let tags = GlucoseTags.all
        var rows: [ReportRow] = []
        for r in GlucoseLocal.load().sorted(by: { $0.date < $1.date })
        where r.date >= from && (owners[r.id] ?? GlucosePeople.me) == GlucosePeople.me {
            let label = tags[r.id] ?? GlucoseTags.auto(r) ?? "未标记"
            let post = PostMeal.isAfterMeal(label) ? await PostMeal.activity(before: r.date) : nil
            let foods = GlucoseFoods.get(r.id)
            let note = (foods.isEmpty ? "" : "【" + foods.joined(separator: "、") + "】") + (r.note ?? "")
            rows.append(ReportRow(id: r.id, date: r.date, mmol: r.mmol, label: label, note: note,
                                  line: glucoseSafeLine(label), post: post,
                                  photo: r.photos?.first.flatMap(GlucoseMedia.thumb)))
        }
        let w = ((try? await HealthService.weightHistory(days: days)) ?? []).sorted { $0.date < $1.date }
        return ReportData(from: from, to: to, rows: rows, weightStart: w.first?.kg, weightEnd: w.last?.kg,
                          heightCm: await BMI.height())
    }

    /// 生成 PDF 文件，返回文件地址
    @MainActor
    static func makePDF(_ d: ReportData) -> URL? {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("血糖报告-\(f.string(from: d.to)).pdf")
        var box = CGRect(origin: .zero, size: page)
        guard let pdf = CGContext(url as CFURL, mediaBox: &box, nil) else { return nil }

        var pages: [AnyView] = [AnyView(ReportSummaryPage(d: d))]
        // 超标和偏低的记录
        let marked = d.rows.filter { $0.over || $0.low }
        let perPage = 30
        // 全部记录（新的在前）
        let all = Array(d.rows.reversed())
        var chunks: [(String, [ReportRow])] = []
        if !marked.isEmpty {
            for i in stride(from: 0, to: marked.count, by: perPage) {
                let rev: [ReportRow] = Array(marked.reversed())
                chunks.append(("超标和偏低的记录", Array(rev[i..<min(i + perPage, rev.count)])))
            }
        }
        for i in stride(from: 0, to: all.count, by: perPage) {
            chunks.append(("全部记录", Array(all[i..<min(i + perPage, all.count)])))
        }
        for c in chunks { pages.append(AnyView(ReportTablePage(title: c.0, rows: c.1))) }
        // 照片：超标、偏低优先，最多 12 张
        let withPhoto = d.rows.filter { $0.photo != nil }
        let bad: [ReportRow] = Array(withPhoto.filter { $0.over || $0.low }.reversed())
        let good: [ReportRow] = Array(withPhoto.filter { !$0.over && !$0.low }.reversed())
        let pick: [ReportRow] = Array((bad + good).prefix(12))
        if !pick.isEmpty { pages.append(AnyView(ReportPhotoPage(rows: pick))) }

        for (i, p) in pages.enumerated() {
            let view = p
                .frame(width: page.width, height: page.height)
                .overlay(alignment: .bottom) {
                    Text("第 \(i + 1) / \(pages.count) 页 · 阿波 App 生成").font(.system(size: 8)).foregroundStyle(.gray).padding(.bottom, 14)
                }
                .background(Color.white)
                .environment(\.colorScheme, .light)
            let r = ImageRenderer(content: view)
            r.render { _, draw in
                pdf.beginPDFPage(nil)
                draw(pdf)
                pdf.endPDFPage()
            }
        }
        pdf.closePDF()
        return url
    }

    static func stats(_ rows: [ReportRow]) -> (Int, Double, Double, Double, Int, Int)? {
        guard !rows.isEmpty else { return nil }
        let v = rows.map(\.mmol)
        return (rows.count, v.reduce(0, +) / Double(v.count), v.max()!, v.min()!, rows.filter(\.over).count, rows.filter(\.low).count)
    }
}

// MARK: - 第一页：汇总

extension View {
    static func fmt(_ f: String) -> DateFormatter {
        let d = DateFormatter()
        d.dateFormat = f
        return d
    }
}

private struct ReportSummaryPage: View {
    let d: ReportData

    private func kindRows(_ k: GlucoseKind?) -> [ReportRow] {
        d.rows.filter { GlucoseKind.of($0.label) == k }
    }

    var body: some View {
        let df = Self.fmt("yyyy年M月d日")
        VStack(alignment: .leading, spacing: 12) {
            Text("血糖记录报告").font(.system(size: 22, weight: .bold))
            Text("时间：\(df.string(from: d.from)) – \(df.string(from: d.to))    共 \(d.rows.count) 次测量")
                .font(.system(size: 10)).foregroundStyle(.gray)
            Text("姓名：__________    数据来源：罗氏智航血糖仪（自测）").font(.system(size: 10)).foregroundStyle(.gray)

            // 统计表
            VStack(spacing: 0) {
                row(["", "次数", "平均", "最高", "最低", "超标", "偏低(<3.9)"], head: true)
                ForEach(Self.kinds, id: \.1) { item in
                    if let s = GlucoseReport.stats(kindRows(item.0)) {
                        row(statCells(item.1, s), head: false)
                    }
                }
                if let s = GlucoseReport.stats(d.rows) {
                    row(statCells("全部", s), head: true)
                }
            }
            .overlay(Rectangle().stroke(Color.gray.opacity(0.5), lineWidth: 0.5))
            Text("单位 mmol/L。超标线：空腹 6.1，餐后1小时 8.6，餐后2小时 7.8；低于 3.9 记为偏低。")
                .font(.system(size: 8)).foregroundStyle(.gray)

            Text("血糖曲线").font(.system(size: 13, weight: .bold)).padding(.top, 4)
            Chart {
                RuleMark(y: .value("7.8", 7.8)).foregroundStyle(.red.opacity(0.6)).lineStyle(StrokeStyle(lineWidth: 0.8, dash: [4, 3]))
                    .annotation(position: .top, alignment: .leading, spacing: 1) {
                        Text("7.8 餐后2小时上限").font(.system(size: 7, weight: .semibold)).foregroundStyle(.red)
                    }
                RuleMark(y: .value("3.9", 3.9)).foregroundStyle(.blue.opacity(0.6)).lineStyle(StrokeStyle(lineWidth: 0.8, dash: [4, 3]))
                    .annotation(position: .bottom, alignment: .leading, spacing: 1) {
                        Text("3.9 低血糖").font(.system(size: 7, weight: .semibold)).foregroundStyle(.blue)
                    }
                // 每种时段连成一条曲线，再画点；超标、偏低的点大一点
                ForEach(d.rows) { r in
                    LineMark(x: .value("时间", r.date), y: .value("血糖", r.mmol),
                             series: .value("类型", GlucoseKind.of(r.label)?.rawValue ?? "其他"))
                        .foregroundStyle(by: .value("类型", GlucoseKind.of(r.label)?.rawValue ?? "其他"))
                        .lineStyle(StrokeStyle(lineWidth: 1.2))
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("时间", r.date), y: .value("血糖", r.mmol))
                        .foregroundStyle(by: .value("类型", GlucoseKind.of(r.label)?.rawValue ?? "其他"))
                        .symbolSize(r.over || r.low ? 40 : 14)
                }
            }
            .chartForegroundStyleScale(["空腹": Color.orange, "餐后1h": Color.purple, "餐后2h": Color.red, "其他": Color.gray])
            .chartLegend(position: .top, alignment: .leading)
            .chartYAxis {
                AxisMarks(position: .trailing, values: [0, 2, 3.9, 6, 7.8, 10, 12]) { v in
                    AxisGridLine().foregroundStyle(Color.gray.opacity(0.15))
                    AxisValueLabel {
                        if let d = v.as(Double.self) {
                            Text(d == 3.9 || d == 7.8 ? String(format: "%.1f", d) : String(Int(d)))
                                .font(.system(size: 8, weight: d == 3.9 || d == 7.8 ? .bold : .regular))
                                .foregroundStyle(d == 7.8 ? Color.red : d == 3.9 ? Color.blue : Color.gray)
                        }
                    }
                }
            }
            .frame(height: 230)
            Text("红色虚线 7.8（餐后2小时上限），蓝色虚线 3.9（低血糖）。").font(.system(size: 8)).foregroundStyle(.gray)

            // 体重
            if let a = d.weightStart, let b = d.weightEnd {
                Text("体重").font(.system(size: 13, weight: .bold)).padding(.top, 4)
                Text(weightText(a, b)).font(.system(size: 10))
            }
            Spacer()
        }
        .padding(36)
        .foregroundStyle(.black)
    }

    private func f1(_ v: Double) -> String { String(format: "%.1f", v) }

    static let kinds: [(GlucoseKind?, String)] = [(.fasting, "空腹"), (.after1, "餐后1小时"), (.after2, "餐后2小时"), (nil, "其他时间")]

    private func statCells(_ name: String, _ s: (Int, Double, Double, Double, Int, Int)) -> [String] {
        [name, String(s.0), f1(s.1), f1(s.2), f1(s.3), String(s.4), String(s.5)]
    }

    private func weightText(_ a: Double, _ b: Double) -> String {
        let sign: String = b >= a ? "+" : "−"
        var t: String = f1(a) + " → " + f1(b) + " 公斤（" + sign + f1(abs(b - a)) + "）"
        if let h = d.heightCm {
            let v: Double = BMI.value(kg: b, cm: h)
            t += "，BMI " + f1(v) + "（" + BMI.category(v).0 + "），身高 " + String(Int(h)) + " 厘米"
        }
        return t
    }

    private func row(_ c: [String], head: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(c.enumerated()), id: \.offset) { i, t in
                Text(t).font(.system(size: 10, weight: head ? .bold : .regular))
                    .frame(maxWidth: .infinity, alignment: i == 0 ? .leading : .center)
                    .padding(.vertical, 5).padding(.horizontal, 6)
            }
        }
        .background(head ? Color.gray.opacity(0.12) : Color.clear)
    }
}

// MARK: - 记录表

private struct ReportTablePage: View {
    let title: String
    let rows: [ReportRow]

    var body: some View {
        let df = Self.fmt("M/d HH:mm")
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 15, weight: .bold))
            VStack(spacing: 0) {
                line(["时间", "血糖", "时段", "饭后2小时活动", "备注"], head: true, color: .black)
                ForEach(rows) { r in
                    line([df.string(from: r.date), String(format: "%.1f", r.mmol), r.label, act(r), r.note],
                         head: false, color: r.over ? .red : r.low ? .blue : .black)
                }
            }
            .overlay(Rectangle().stroke(Color.gray.opacity(0.5), lineWidth: 0.5))
            Text("红色 = 超标，蓝色 = 偏低（<3.9）。饭后2小时活动 = 测血糖前 2 小时手表记录的步数 / 活动卡路里 / 锻炼分钟。")
                .font(.system(size: 8)).foregroundStyle(.gray)
            Spacer()
        }
        .padding(36)
        .foregroundStyle(.black)
    }

    private func act(_ r: ReportRow) -> String {
        guard let p = r.post else { return "" }
        let s = p.steps.map { "\(Int($0))步" } ?? "-"
        let k = p.kcal.map { "\(Int($0))卡" } ?? "-"
        let e = p.exercise.map { "\(Int($0))分" } ?? "-"
        return "\(s) / \(k) / \(e)"
    }

    private func line(_ c: [String], head: Bool, color: Color) -> some View {
        let widths: [CGFloat] = [62, 34, 70, 112, 245]
        return HStack(spacing: 0) {
            ForEach(Array(c.enumerated()), id: \.offset) { i, t in
                Text(t).font(.system(size: 8.5, weight: head || i == 1 ? .bold : .regular))
                    .foregroundStyle(i == 1 ? color : .black)
                    .lineLimit(2)
                    .frame(width: widths[i], alignment: .leading)
                    .padding(.vertical, 3).padding(.horizontal, 2)
            }
        }
        .background(head ? Color.gray.opacity(0.12) : Color.clear)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.gray.opacity(0.2)).frame(height: 0.5) }
    }
}

// MARK: - 餐食照片

private struct ReportPhotoPage: View {
    let rows: [ReportRow]

    var body: some View {
        let df = Self.fmt("M/d HH:mm")
        VStack(alignment: .leading, spacing: 10) {
            Text("餐食照片（超标、偏低的优先）").font(.system(size: 15, weight: .bold))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(rows) { r in
                    VStack(alignment: .leading, spacing: 3) {
                        if let img = r.photo {
                            Image(uiImage: img).resizable().scaledToFill()
                                .frame(height: 120).frame(maxWidth: .infinity).clipped()
                        }
                        Text(String(format: "%.1f", r.mmol) + "  " + r.label)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(r.over ? .red : r.low ? .blue : .black)
                        Text(df.string(from: r.date) + (r.note.isEmpty ? "" : " · " + r.note))
                            .font(.system(size: 7.5)).foregroundStyle(.gray).lineLimit(2)
                    }
                }
            }
            Spacer()
        }
        .padding(36)
        .foregroundStyle(.black)
    }
}

// MARK: - 血糖页的入口卡片

struct GlucoseReportCard: View {
    @State private var days = 90
    @State private var working = false
    @State private var file: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("血糖报告", systemImage: "doc.richtext").font(.headline)
                    .foregroundStyle(Color(red: 0.45, green: 0.8, blue: 1))
                Spacer()
                Picker("", selection: $days) {
                    Text("近30天").tag(30)
                    Text("近90天").tag(90)
                    Text("近半年").tag(180)
                }
                .pickerStyle(.menu).tint(.secondary)
            }
            Text("生成 PDF 给医生看：统计、曲线、超标和偏低记录、饭后活动、餐食照片、体重变化。")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button {
                    Task {
                        working = true
                        let d = await GlucoseReport.collect(days: days)
                        file = GlucoseReport.makePDF(d)
                        working = false
                    }
                } label: {
                    HStack {
                        if working { ProgressView() }
                        Text(working ? "正在生成…" : "生成报告")
                    }
                    .frame(maxWidth: .infinity)
                }
                .glassButton()
                .disabled(working)
                if let file {
                    ShareLink(item: file) {
                        Label("分享 / 保存", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                    }
                    .glassButton()
                }
            }
            .font(.subheadline.weight(.semibold))
        }
        .padding(18)
        .glassCard(24)
        .onChange(of: days) { _, _ in file = nil }
    }
}
