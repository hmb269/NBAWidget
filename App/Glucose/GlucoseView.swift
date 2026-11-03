import SwiftUI
import HealthKit

// 血糖记录的流程：
// 1. 从罗氏智航同步 → 先存在 App 里（不直接写健康）
// 2. 每条可以标「谁测的」和餐点（如「午餐后2小时」）
// 3. 写入健康 → 选一个人，只把这个人的记录写进健康；之前写进健康的其他人的记录会被移出
// 4. 从健康读取 → 把健康里已有的血糖（包括别的 App 写的）合并进来

// MARK: - 一条血糖记录（存在 App 里）

struct GlucoseRecord: Identifiable, Codable, Equatable {
    let id: String          // 血糖仪导入的用「accuchek-序列号-序号-时间」，健康读进来的用样本 UUID
    let date: Date
    let mmol: Double
    var meterMeal: String?  // 血糖仪自带的餐点标记（或健康里存的标签）
    var source: String
    var mine: Bool          // 是不是阿波自己写进健康的（只有这种能改、能删）
}

/// 本地存储：Application Support/glucose.json
enum GlucoseLocal {
    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("glucose.json")
    }

    static func load() -> [GlucoseRecord] {
        guard let d = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([GlucoseRecord].self, from: d)) ?? []
    }

    static func save(_ list: [GlucoseRecord]) {
        if let d = try? JSONEncoder().encode(list) { try? d.write(to: url, options: .atomic) }
    }

    /// 合并：已有的记录保留，新的加进来；同一条（id 相同）以新的数值为准，但标签、归属不动
    static func merge(_ incoming: [GlucoseRecord], into list: [GlucoseRecord]) -> ([GlucoseRecord], Int) {
        var byId = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        var added = 0
        for r in incoming {
            if var old = byId[r.id] {
                if old.meterMeal == nil { old.meterMeal = r.meterMeal }
                old.mine = old.mine || r.mine
                byId[r.id] = old
            } else {
                byId[r.id] = r
                added += 1
            }
        }
        return (byId.values.sorted { $0.date > $1.date }, added)
    }
}

// MARK: - 测量人

enum GlucosePeople {
    static let me = "我"
    private static let namesKey = "glucosePeople"
    private static let ownerKey = "glucoseOwner"

    static var names: [String] { UserDefaults.standard.stringArray(forKey: namesKey) ?? [] }
    static func add(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n != me, !names.contains(n) else { return }
        UserDefaults.standard.set(names + [n], forKey: namesKey)
    }

    static var owners: [String: String] { (UserDefaults.standard.dictionary(forKey: ownerKey) as? [String: String]) ?? [:] }
    static func owner(of id: String) -> String { owners[id] ?? me }
    static func set(_ person: String, for id: String) {
        var d = owners
        d[id] = person == me ? nil : person
        UserDefaults.standard.set(d, forKey: ownerKey)
    }
}

// MARK: - 健康 App

enum GlucoseStore {
    static let type = HKQuantityType(.bloodGlucose)
    static let unit = HKUnit.moleUnit(with: .milli, molarMass: HKUnitMolarMassBloodGlucose).unitDivided(by: .liter())
    private static let mealKey = "餐点"
    private static let oldMealKey = "阿波餐点"   // 早期版本用的字段名，读取时兼容
    private static let personKey = "测量人"

    static func requestAccess() async throws {
        try await HealthService.store.requestAuthorization(toShare: [type], read: [type])
    }

    static func mealName(_ code: UInt8?) -> String? {
        switch code {
        case 1: return "餐前"
        case 2: return "餐后"
        case 3: return "空腹"
        case 4: return "随机"
        case 5: return "睡前"
        default: return nil
        }
    }

    /// 血糖仪读到的记录 → App 里的记录
    static func records(from readings: [MeterReading], serial: String) -> [GlucoseRecord] {
        readings.map {
            GlucoseRecord(id: "accuchek-\(serial)-\($0.seq)-\(Int($0.date.timeIntervalSince1970))",
                          date: $0.date, mmol: $0.mmol, meterMeal: mealName($0.meal), source: "罗氏智航", mine: true)
        }
    }

    /// 写入健康：把 keep 里的记录写进去（带餐点标签），把 remove 里阿波写过的记录从健康删掉。
    /// 用同一个同步标识、更高的版本号保存，健康会替换旧的，不会重复。返回（写入数，删除数）
    static func write(keep: [GlucoseRecord], remove: [GlucoseRecord], person: String,
                      label: (GlucoseRecord) -> String?) async throws -> (Int, Int) {
        let version = Int(Date().timeIntervalSince1970)
        let samples = keep.map { r -> HKQuantitySample in
            var meta: [String: Any] = [
                HKMetadataKeySyncIdentifier: r.id,
                HKMetadataKeySyncVersion: version,
                HKMetadataKeyWasUserEntered: false
            ]
            if person != GlucosePeople.me { meta[personKey] = person }
            if let tag = label(r) {
                meta[mealKey] = tag
                if tag.contains("后") {
                    meta[HKMetadataKeyBloodGlucoseMealTime] = HKBloodGlucoseMealTime.postprandial.rawValue
                } else if tag == "空腹" || (tag.contains("前") && tag != "睡前") {
                    meta[HKMetadataKeyBloodGlucoseMealTime] = HKBloodGlucoseMealTime.preprandial.rawValue
                }
            }
            return HKQuantitySample(type: type, quantity: HKQuantity(unit: unit, doubleValue: r.mmol),
                                    start: r.date, end: r.date, metadata: meta)
        }
        if !samples.isEmpty { try await HealthService.store.save(samples) }

        var removed = 0
        let ids = remove.map(\.id)
        if !ids.isEmpty {
            let predicate = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier, allowedValues: ids)
            let found: [HKSample] = try await withCheckedThrowingContinuation { cont in
                let q = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, r, e in
                    if let e { cont.resume(throwing: e) } else { cont.resume(returning: r ?? []) }
                }
                HealthService.store.execute(q)
            }
            let ours = found.filter { $0.sourceRevision.source.bundleIdentifier == Bundle.main.bundleIdentifier }
            if !ours.isEmpty {
                try await HealthService.store.delete(ours)
                removed = ours.count
            }
        }
        return (samples.count, removed)
    }

    /// 读健康里的血糖
    static func load(days: Int = 365) async throws -> [GlucoseRecord] {
        let start = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let samples: [HKQuantitySample] = try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, r, e in
                if let e { cont.resume(throwing: e) } else { cont.resume(returning: (r as? [HKQuantitySample]) ?? []) }
            }
            HealthService.store.execute(q)
        }
        return samples.map { s in
            let meta = s.metadata ?? [:]
            var meal = (meta[mealKey] as? String) ?? (meta[oldMealKey] as? String)
            if meal == nil, let raw = meta[HKMetadataKeyBloodGlucoseMealTime] as? NSNumber {
                meal = raw.intValue == HKBloodGlucoseMealTime.preprandial.rawValue ? "餐前" : "餐后"
            }
            let mine = s.sourceRevision.source.bundleIdentifier == Bundle.main.bundleIdentifier
            return GlucoseRecord(id: (meta[HKMetadataKeySyncIdentifier] as? String) ?? s.uuid.uuidString,
                                 date: s.startDate, mmol: s.quantity.doubleValue(for: unit),
                                 meterMeal: meal, source: s.sourceRevision.source.name, mine: mine)
        }
    }
}

// MARK: - 餐点标签

enum GlucoseTags {
    static let options = ["空腹", "早餐后", "午餐前", "午餐后", "晚餐前", "晚餐后", "睡前", "随机"]
    private static let key = "glucoseTags"
    static var all: [String: String] { (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:] }
    /// 三餐时间（从当天 0 点起的分钟数），在血糖页里可以改
    static var breakfast: Int { minutes("mealBreakfast", 7 * 60 + 30) }
    static var lunch: Int { minutes("mealLunch", 12 * 60) }
    static var dinner: Int { minutes("mealDinner", 18 * 60 + 30) }
    private static func minutes(_ k: String, _ def: Int) -> Int {
        UserDefaults.standard.object(forKey: k) == nil ? def : UserDefaults.standard.integer(forKey: k)
    }

    /// 血糖仪只记了「餐后 / 餐前」时，按测量时间换成具体餐次；餐后默认 2 小时
    static func auto(_ r: GlucoseRecord) -> String? {
        let c = Calendar.current.dateComponents([.hour, .minute], from: r.date)
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        switch r.meterMeal {
        case "餐后":
            let name: String
            if m >= breakfast - 60 && m < lunch { name = "早餐后" }
            else if m >= lunch && m < dinner { name = "午餐后" }
            else { name = "晚餐后" }
            return name + "2小时"
        case "餐前":
            if m < 10 * 60 && m >= 4 * 60 { return "空腹" }
            if m >= 10 * 60 && m < 15 * 60 { return "午餐前" }
            if m >= 15 * 60 && m < 21 * 60 { return "晚餐前" }
            return "睡前"
        default:
            return r.meterMeal
        }
    }

    static func set(_ tag: String?, for id: String) {
        var d = all
        d[id] = tag
        UserDefaults.standard.set(d, forKey: key)
    }
}

// MARK: - 血糖页面

struct GlucoseView: View {
    @StateObject private var sync = AccuChekSync()
    @State private var records: [GlucoseRecord] = GlucoseLocal.load()
    @State private var tags: [String: String] = GlucoseTags.all
    @State private var owners: [String: String] = GlucosePeople.owners
    @State private var people: [String] = GlucosePeople.names
    @State private var message: String?
    @State private var working = false

    // 三餐时间：用自己的状态，滚动时不会刷新整页（之前每滚一下弹窗就被关掉）
    @State private var breakfast = GlucoseTags.breakfast
    @State private var lunch = GlucoseTags.lunch
    @State private var dinner = GlucoseTags.dinner

    @State private var showAddPerson = false
    @State private var newPerson = ""
    @State private var pendingOwnerId: String?
    @State private var showWriteChoice = false
    @State private var filter: String = "全部"

    var body: some View {
        List {
            Section {
                Button {
                    sync.start()
                } label: {
                    HStack {
                        Image(systemName: "dot.radiowaves.left.and.right")
                        Text(sync.busy ? "同步中…" : "从罗氏智航同步")
                        Spacer()
                        if sync.busy { ProgressView() }
                    }
                }
                .disabled(sync.busy)
                Text(sync.status).font(.footnote).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button {
                        showWriteChoice = true
                    } label: {
                        Label("写入健康", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(working || records.isEmpty)

                    Button {
                        Task { await readFromHealth() }
                    } label: {
                        Label("从健康读取", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(working)
                }
                if let message {
                    Text(message).font(.footnote).foregroundStyle(.green)
                }
            } footer: {
                Text("第一次连接：先把血糖仪关机，再长按「OK」键，直到屏幕上蓝牙图标闪烁，然后点「从罗氏智航同步」。弹出配对框时输入血糖仪背面的 6 位 PIN 码。\n同步下来的记录先存在 App 里，标好是谁测的、什么餐点后，点「写入健康」选择写入谁的记录。")
            }

            Section {
                mealPicker("早餐", key: "mealBreakfast", value: $breakfast)
                mealPicker("午餐", key: "mealLunch", value: $lunch)
                mealPicker("晚餐", key: "mealDinner", value: $dinner)
            } header: {
                Text("三餐时间")
            } footer: {
                Text("血糖仪记成「餐后」的，按这里的时间判断是哪一餐，默认标成「餐后2小时」。不是 2 小时的点标签手动改。")
            }

            if !people.isEmpty {
                Section {
                    Picker("显示", selection: $filter) {
                        Text("全部").tag("全部")
                        Text(GlucosePeople.me).tag(GlucosePeople.me)
                        ForEach(people, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }

            if shown.isEmpty {
                Section { Text("还没有血糖记录").foregroundStyle(.secondary) }
            }

            ForEach(groupedDays, id: \.0) { day, items in
                Section(header: Text(dayTitle(day))) {
                    ForEach(items) { r in row(r) }
                }
            }
        }
        .navigationTitle("血糖")
        .refreshable { await readFromHealth() }
        .confirmationDialog("写入谁的血糖到健康？", isPresented: $showWriteChoice, titleVisibility: .visible) {
            Button(GlucosePeople.me) { Task { await writeToHealth(person: GlucosePeople.me) } }
            ForEach(people, id: \.self) { p in
                Button(p) { Task { await writeToHealth(person: p) } }
            }
        } message: {
            Text("只把这个人的记录写进健康（带餐点标签）；之前写进健康的其他人的记录会被移出健康，仍保留在 App 里。")
        }
        .alert("添加测量人", isPresented: $showAddPerson) {
            TextField("名字，比如：老婆、爸爸", text: $newPerson)
            Button("添加") {
                GlucosePeople.add(newPerson)
                people = GlucosePeople.names
                if let id = pendingOwnerId, people.contains(newPerson.trimmingCharacters(in: .whitespaces)) {
                    setOwner(newPerson.trimmingCharacters(in: .whitespaces), for: id)
                }
                newPerson = ""
                pendingOwnerId = nil
            }
            Button("取消", role: .cancel) { newPerson = ""; pendingOwnerId = nil }
        }
        .task {
            sync.onFinished = { readings, serial in
                Task { @MainActor in
                    let incoming = GlucoseStore.records(from: readings, serial: serial)
                    let (list, added) = GlucoseLocal.merge(incoming, into: records)
                    records = list
                    GlucoseLocal.save(list)
                    message = "读到 \(readings.count) 条，新增 \(added) 条。标好测量人和餐点后，点「写入健康」"
                }
            }
            try? await GlucoseStore.requestAccess()
            // 第一次用新版：把健康里已有的血糖导进来
            if records.isEmpty { await readFromHealth() }
        }
    }

    // MARK: 一行

    private func row(_ r: GlucoseRecord) -> some View {
        let owner = owners[r.id] ?? GlucosePeople.me
        let isMe = owner == GlucosePeople.me
        return HStack(alignment: .firstTextBaseline) {
            Text(timeText(r.date))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
            Text(String(format: "%.1f", r.mmol))
                .font(.system(size: 24, weight: .bold, design: .rounded).monospacedDigit())
            Text("mmol/L").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Menu {
                Section("谁测的") {
                    ownerButton(GlucosePeople.me, r, current: owner)
                    ForEach(people, id: \.self) { ownerButton($0, r, current: owner) }
                    Button {
                        pendingOwnerId = r.id
                        showAddPerson = true
                    } label: { Label("添加测量人…", systemImage: "person.badge.plus") }
                }
                Section("餐点") {
                    ForEach(GlucoseTags.options, id: \.self) { t in
                        if t.hasSuffix("餐后") {
                            Menu(t) {
                                ForEach(1...4, id: \.self) { h in
                                    Button("\(t)\(h)小时") { setTag("\(t)\(h)小时", for: r) }
                                }
                                Button("不指定时间") { setTag(t, for: r) }
                            }
                        } else {
                            Button(t) { setTag(t, for: r) }
                        }
                    }
                    if tags[r.id] != nil {
                        Button("恢复血糖仪的标记", role: .destructive) { setTag(nil, for: r) }
                    }
                }
            } label: {
                let tag = tags[r.id] ?? GlucoseTags.auto(r) ?? "标记餐点"
                Text(isMe ? tag : "\(owner) · \(tag)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(isMe ? Color.accentColor : Color.orange)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill((isMe ? Color.accentColor : Color.orange).opacity(0.12)))
            }
        }
    }

    private func ownerButton(_ p: String, _ r: GlucoseRecord, current: String) -> some View {
        Button {
            setOwner(p, for: r.id)
        } label: {
            if p == current { Label(p, systemImage: "checkmark") } else { Text(p) }
        }
    }

    // MARK: 操作

    private func setOwner(_ p: String, for id: String) {
        GlucosePeople.set(p, for: id)
        owners = GlucosePeople.owners
    }

    private func setTag(_ t: String?, for r: GlucoseRecord) {
        GlucoseTags.set(t, for: r.id)
        tags = GlucoseTags.all
    }

    private func label(_ r: GlucoseRecord) -> String? { tags[r.id] ?? GlucoseTags.auto(r) }

    private func writeToHealth(person: String) async {
        working = true
        defer { working = false }
        do {
            try await GlucoseStore.requestAccess()
            let ownerOf = { (r: GlucoseRecord) in owners[r.id] ?? GlucosePeople.me }
            // 写入：这个人的、阿波能管的记录（别的 App 写的已经在健康里了，不重复写）
            let keep = records.filter { ownerOf($0) == person && ($0.mine || $0.id.hasPrefix("accuchek-")) }
            // 移出：其他人的、阿波写过的记录
            let remove = records.filter { ownerOf($0) != person && $0.mine }
            let (n, removed) = try await GlucoseStore.write(keep: keep, remove: remove, person: person, label: label)
            // 写完以后这些记录都算阿波写的
            let keepIds = Set(keep.map(\.id)), removeIds = Set(remove.map(\.id))
            records = records.map { r in
                var r = r
                if keepIds.contains(r.id) { r.mine = true }
                if removeIds.contains(r.id) { r.mine = false }
                return r
            }
            GlucoseLocal.save(records)
            var t = "已把\(person == GlucosePeople.me ? "你" : person)的 \(n) 条记录写入健康"
            if removed > 0 { t += "，并从健康移出其他人的 \(removed) 条" }
            let others = records.filter { ownerOf($0) != person && !$0.mine && !$0.id.hasPrefix("accuchek-") }.count
            if others > 0 { t += "。另有 \(others) 条是别的 App（如 mySugr）写的，健康不允许阿波删除，需要在健康 App 里手动删" }
            message = t
        } catch {
            message = "写入失败：\(error.localizedDescription)"
        }
    }

    private func readFromHealth() async {
        working = true
        defer { working = false }
        do {
            let fromHealth = try await GlucoseStore.load()
            let (list, added) = GlucoseLocal.merge(fromHealth, into: records)
            records = list
            GlucoseLocal.save(list)
            message = "已从健康读取 \(fromHealth.count) 条，新增 \(added) 条"
        } catch {
            message = "读取健康数据失败：\(error.localizedDescription)"
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
            }
        ), displayedComponents: .hourAndMinute)
    }

    // MARK: 列表

    private var shown: [GlucoseRecord] {
        guard filter != "全部" else { return records }
        return records.filter { (owners[$0.id] ?? GlucosePeople.me) == filter }
    }

    private var groupedDays: [(Date, [GlucoseRecord])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: shown) { cal.startOfDay(for: $0.date) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0]!.sorted { $0.date > $1.date }) }
    }

    private func dayTitle(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "今天" }
        if cal.isDateInYesterday(d) { return "昨天" }
        let f = DateFormatter()
        f.dateFormat = "M月d日 EEE"
        f.locale = Locale(identifier: "zh_CN")
        return f.string(from: d)
    }

    private func timeText(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}
