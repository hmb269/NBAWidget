import SwiftUI

/// 设置页：血糖仪同步卡片（从罗氏智航同步 / 写入健康 / 从健康读取）
struct GlucoseSyncCard: View {
    @StateObject private var sync = AccuChekSync()
    @State private var message: String?
    @State private var working = false
    @State private var showWriteChoice = false
    @State private var people: [String] = GlucosePeople.names

    var body: some View {
        CardSection(footer: "第一次连接：先把血糖仪关机，再长按「OK」键，直到屏幕上蓝牙图标闪烁，然后点「从罗氏智航同步」。弹出配对框时输入血糖仪背面的 6 位 PIN 码。同步下来的记录先存在 App 里，到「血糖」页标好是谁测的、什么餐点后，再回来点「写入健康」选择写入谁的记录。") {
            CardTitle("血糖仪 · 罗氏智航")
            RowDivider()
            HStack {
                Button {
                    sync.start()
                } label: {
                    HStack {
                        Image(systemName: "dot.radiowaves.left.and.right")
                        Text(sync.busy ? "同步中…" : "从罗氏智航同步")
                        Spacer()
                        if sync.busy { ProgressView() }
                    }
                    .font(.body.weight(.semibold))
                    .padding(.vertical, 10)
                }
                .disabled(sync.busy)
                if sync.busy {
                    Button("取消", role: .cancel) { sync.cancel() }
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.leading, 8)
                }
            }
            RowDivider()
            Text(sync.status).font(.footnote).foregroundStyle(.secondary).padding(.vertical, 8)
            HStack(spacing: 12) {
                Button {
                    people = GlucosePeople.names
                    showWriteChoice = true
                } label: {
                    Label("写入健康", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                }
                .glassButton()
                .disabled(working)

                Button {
                    Task { await readFromHealth() }
                } label: {
                    Label("从健康读取", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                }
                .glassButton()
                .disabled(working)
            }
            .padding(.vertical, 8)
            if let message {
                Text(message).font(.footnote).foregroundStyle(.green).padding(.bottom, 8)
            }
        }
        .confirmationDialog("写入谁的血糖到健康？", isPresented: $showWriteChoice, titleVisibility: .visible) {
            Button(GlucosePeople.me) { Task { await writeToHealth(person: GlucosePeople.me) } }
            ForEach(people, id: \.self) { p in
                Button(p) { Task { await writeToHealth(person: p) } }
            }
        } message: {
            Text("只把这个人的记录写进健康（带餐点标签）；之前写进健康的其他人的记录会被移出健康，仍保留在 App 里。")
        }
        .task {
            sync.onFinished = { readings, serial in
                Task { @MainActor in
                    let incoming = GlucoseStore.records(from: readings, serial: serial)
                    let (list, added) = GlucoseLocal.merge(incoming, into: GlucoseLocal.load())
                    GlucoseLocal.save(list)
                    changed()
                    message = "读到 \(readings.count) 条，新增 \(added) 条。到「血糖」页标好测量人和餐点后，点「写入健康」"
                    pushGlucose(list: list, read: readings.count, added: added)
                }
            }
        }
    }

    /// 同步完推送企业微信：新增几条 + 最新一次
    private func pushGlucose(list: [GlucoseRecord], read: Int, added: Int) {
        let c = PushConfig.current
        guard c.glucose, c.isReady, added > 0, let r = list.max(by: { $0.date < $1.date }) else { return }
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "M月d日 HH:mm"
        let tag = GlucoseTags.all[r.id] ?? GlucoseTags.auto(r)
        var t = "🩸 罗氏智航同步：新增 \(added) 条\n最新 " + String(format: "%.1f", r.mmol) + " mmol/L"
        if let tag { t += " · \(tag)" }
        t += " · " + f.string(from: r.date)
        Task {
            do { try await WeCom.send(t, config: c) }
            catch { message = (message ?? "") + "\n企业微信推送失败：" + error.localizedDescription }
        }
    }

    private func changed() {
        NotificationCenter.default.post(name: .glucoseDataChanged, object: nil)
    }

    private func readFromHealth() async {
        working = true
        defer { working = false }
        do {
            let fromHealth = try await GlucoseStore.load()
            let (list, added) = GlucoseLocal.merge(fromHealth, into: GlucoseLocal.load())
            GlucoseLocal.save(list)
            changed()
            message = "已从健康读取 \(fromHealth.count) 条，新增 \(added) 条"
        } catch {
            message = "读取健康数据失败：\(error.localizedDescription)"
        }
    }

    private func writeToHealth(person: String) async {
        working = true
        defer { working = false }
        do {
            try await GlucoseStore.requestAccess()
            var records = GlucoseLocal.load()
            guard !records.isEmpty else { message = "还没有血糖记录"; return }
            let owners = GlucosePeople.owners
            let tags = GlucoseTags.all
            let label = { (r: GlucoseRecord) -> String? in tags[r.id] ?? GlucoseTags.auto(r) }
            let ownerOf = { (r: GlucoseRecord) in owners[r.id] ?? GlucosePeople.me }
            // 写入：这个人的、阿波能管的记录（别的 App 写的已经在健康里了，不重复写）
            let keep = records.filter { ownerOf($0) == person && ($0.mine || $0.id.hasPrefix("accuchek-")) }
            // 移出：其他人的、阿波写过的记录
            let remove = records.filter { ownerOf($0) != person && $0.mine }
            let (n, removed) = try await GlucoseStore.write(keep: keep, remove: remove, person: person, label: label)
            let keepIds = Set(keep.map(\.id)), removeIds = Set(remove.map(\.id))
            records = records.map { r in
                var r = r
                if keepIds.contains(r.id) { r.mine = true }
                if removeIds.contains(r.id) { r.mine = false }
                return r
            }
            GlucoseLocal.save(records)
            changed()
            var t = "已把\(person == GlucosePeople.me ? "你" : person)的 \(n) 条记录写入健康"
            if removed > 0 { t += "，并从健康移出其他人的 \(removed) 条" }
            let others = records.filter { ownerOf($0) != person && !$0.mine && !$0.id.hasPrefix("accuchek-") }.count
            if others > 0 { t += "。另有 \(others) 条是别的 App（如 mySugr）写的，健康不允许阿波删除，需要在健康 App 里手动删" }
            message = t
        } catch {
            message = "写入失败：\(error.localizedDescription)"
        }
    }
}

/// 设置页：三餐时间卡片
struct GlucoseMealTimesCard: View {
    // 用自己的状态，滚动时不会刷新整页
    @State private var breakfast = GlucoseTags.breakfast
    @State private var lunch = GlucoseTags.lunch
    @State private var dinner = GlucoseTags.dinner

    var body: some View {
        CardSection(footer: "血糖仪记成「餐后」的，按这里的时间判断是哪一餐，默认标成「餐后2小时」。不是 2 小时的在「血糖」页点标签手动改。") {
            CardTitle("三餐时间")
            RowDivider()
            mealPicker("早餐", key: "mealBreakfast", value: $breakfast).padding(.vertical, 6)
            RowDivider()
            mealPicker("午餐", key: "mealLunch", value: $lunch).padding(.vertical, 6)
            RowDivider()
            mealPicker("晚餐", key: "mealDinner", value: $dinner).padding(.vertical, 6)
        }
    }

    private func mealPicker(_ title: String, key: String, value: Binding<Int>) -> some View {
        let base = Calendar.current.startOfDay(for: Date())
        return DatePicker(title, selection: Binding(
            get: { base.addingTimeInterval(TimeInterval(value.wrappedValue * 60)) },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
                value.wrappedValue = m
                UserDefaults.standard.set(m, forKey: key)
                NotificationCenter.default.post(name: .glucoseDataChanged, object: nil)
            }
        ), displayedComponents: .hourAndMinute)
    }
}
