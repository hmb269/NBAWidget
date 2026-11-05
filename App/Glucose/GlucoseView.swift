import SwiftUI
import HealthKit
import WidgetKit

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
    var note: String? = nil           // 备注，比如「饭后散步」
    var photos: [GlucosePhoto]? = nil // 照片（相册编号 + 小图）
}

/// 本地存储：Application Support/glucose.json
enum GlucoseLocal {
    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("glucose.json")
    }

    /// 读过一次就留在内存里（切换页面时不用每次都读文件、解析 JSON，避免卡顿）
    private static var memo: [GlucoseRecord]?

    static func load() -> [GlucoseRecord] {
        if let memo { return memo }
        guard let d = try? Data(contentsOf: url) else { memo = []; return [] }
        let list = (try? JSONDecoder().decode([GlucoseRecord].self, from: d)) ?? []
        memo = list
        return list
    }

    static func save(_ list: [GlucoseRecord]) {
        memo = list
        if let d = try? JSONEncoder().encode(list) { try? d.write(to: url, options: .atomic) }
        AutoBackup.schedule()
    }

    /// 合并：已有的记录保留，新的加进来；同一条（id 相同）以新的数值为准，但标签、归属不动
    static func merge(_ incoming: [GlucoseRecord], into list: [GlucoseRecord]) -> ([GlucoseRecord], Int) {
        var byId = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        var added = 0
        for r in incoming {
            if var old = byId[r.id] {
                if old.meterMeal == nil { old.meterMeal = r.meterMeal }
                if old.note == nil { old.note = r.note }
                if (old.photos ?? []).isEmpty, let p = r.photos, !p.isEmpty { old.photos = p }
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
        AutoBackup.schedule()
    }

    static var owners: [String: String] { (UserDefaults.standard.dictionary(forKey: ownerKey) as? [String: String]) ?? [:] }
    static func owner(of id: String) -> String { owners[id] ?? me }
    static func set(_ person: String, for id: String) {
        var d = owners
        d[id] = person == me ? nil : person
        UserDefaults.standard.set(d, forKey: ownerKey)
        AutoBackup.schedule()
    }
}

// MARK: - 健康 App

enum GlucoseStore {
    static let type = HKQuantityType(.bloodGlucose)
    static let unit = HKUnit.moleUnit(with: .milli, molarMass: HKUnitMolarMassBloodGlucose).unitDivided(by: .liter())
    private static let mealKey = "餐点"
    private static let oldMealKey = "阿波餐点"   // 早期版本用的字段名，读取时兼容
    private static let personKey = "测量人"
    private static let noteKey = "备注"
    private static let photoKey = "照片编号"

    static func requestAccess() async throws {
        // 顺便申请「饮水」写入权限：喝水小组件打勾时写进健康
        let water = HKQuantityType(.dietaryWater)
        try await HealthService.store.requestAuthorization(toShare: [type, water], read: [type])
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
            if let n = r.note, !n.isEmpty { meta[noteKey] = n }
            let ids = (r.photos ?? []).compactMap(\.assetID)
            if !ids.isEmpty { meta[photoKey] = ids.joined(separator: "|") }
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
        // 写完马上刷新血糖小组件（平时 1 小时才自动刷新一次）
        WidgetCenter.shared.reloadTimelines(ofKind: "Glucose")
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
            // 照片只记了相册编号；小图文件名用编号算出来（重装后没有小图，就直接显示相册原图）
            let photos = (meta[photoKey] as? String).map { str in
                str.split(separator: "|").map { id in
                    GlucosePhoto(id: "h-" + String(id).replacingOccurrences(of: "/", with: "_"), assetID: String(id))
                }
            }
            return GlucoseRecord(id: (meta[HKMetadataKeySyncIdentifier] as? String) ?? s.uuid.uuidString,
                                 date: s.startDate, mmol: s.quantity.doubleValue(for: unit),
                                 meterMeal: meal, source: s.sourceRevision.source.name, mine: mine,
                                 note: meta[noteKey] as? String, photos: photos)
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
        AutoBackup.schedule()
    }
}

// MARK: - 血糖页面

struct GlucoseView: View {
    private static var checkedMissing = false
    @State private var records: [GlucoseRecord] = GlucoseLocal.load()
    @State private var tags: [String: String] = GlucoseTags.all
    @State private var owners: [String: String] = GlucosePeople.owners
    @State private var people: [String] = GlucosePeople.names
    @State private var message: String?
    @State private var working = false

    @State private var showAddPerson = false
    @State private var newPerson = ""
    @State private var pendingOwnerId: String?
    @State private var filter: String = "全部"
    @State private var pickedDay: Date?
    @State private var showCalendar = false
    @State private var editing: GlucoseRecord?
    @State private var cloudBackup = false
    @State private var backupTick = 0
    @State private var missingIDs: Set<String> = []

    var body: some View {
        PageScroll(title: "血糖", subtitle: "\(records.count) 条记录 · 罗氏智航") {
            if AutoBackup.cloudOverdue, backupTick >= 0 {
                CardSection {
                    HStack(spacing: 10) {
                        Image(systemName: "icloud.and.arrow.up.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("该备份到 iCloud 了").font(.subheadline.weight(.semibold))
                            Text("上次：" + AutoBackup.ago(AutoBackup.lastCloud) + "，删 App 或换手机时靠它恢复")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("备份") { cloudBackup = true }
                            .font(.subheadline.weight(.semibold))
                            .glassButton()
                    }
                    .padding(.vertical, 10)
                }
            }

            GlucoseTrendCard(points: shown.map {
                ($0.date, $0.mmol, label($0) ?? "", $0.note, $0.photos?.first.flatMap(GlucoseMedia.thumb), $0.id)
            }, onOpen: { id in
                editing = records.first { $0.id == id }
            })

            overAlbumCard

            if !people.isEmpty {
                Picker("显示", selection: $filter) {
                    Text("全部").tag("全部")
                    Text(GlucosePeople.me).tag(GlucosePeople.me)
                    ForEach(people, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            if !missingIDs.isEmpty {
                CardSection {
                    Label("有 \(missingIDs.count) 张饮食照片在相册里找不到了，可能被误删。30 天内可以在「照片 → 相簿 → 最近删除」里恢复，恢复后会自动重新显示。记录里仍保留了小图（带 ⚠︎ 的就是）。",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .padding(.vertical, 10)
                }
            }

            // 记录列表上方：按日期查找
            HStack(spacing: 10) {
                Text(pickedDay.map { "\(dayTitle($0))的记录" } ?? "全部记录")
                    .font(.headline)
                Spacer()
                if pickedDay != nil {
                    Button("全部") { withAnimation { pickedDay = nil } }
                        .font(.subheadline.weight(.semibold))
                        .glassButton()
                }
                Button {
                    showCalendar = true
                } label: {
                    Label("选日期", systemImage: "calendar")
                        .font(.subheadline.weight(.semibold))
                }
                .glassButton()
            }
            .padding(.horizontal, 4)
            .padding(.top, 4)

            if listed.isEmpty {
                CardSection {
                    Text(pickedDay == nil ? "还没有血糖记录" : "这一天没有记录")
                        .foregroundStyle(.secondary).padding(.vertical, 10)
                }
            }

            ForEach(groupedDays, id: \.0) { day, items in
                CardSection(title: dayTitle(day)) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, r in
                        if i > 0 { RowDivider() }
                        row(r).padding(.vertical, 8)
                    }
                }
            }
        }
        .refreshable { await readFromHealth() }
        .cloudBackup(isPresented: $cloudBackup) { msg in
            message = msg
            backupTick += 1
        }
        .sheet(item: $editing) { r in
            GlucoseRecordSheet(record: r, tag: label(r), owner: owners[r.id] ?? GlucosePeople.me,
                               missing: missingIDs) { note, photos in
                updateMedia(r.id, note: note, photos: photos)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .glucoseDataChanged)) { _ in
            records = GlucoseLocal.load()
            tags = GlucoseTags.all
            owners = GlucosePeople.owners
            people = GlucosePeople.names
            refreshMissing()
        }
        .sheet(isPresented: $showCalendar) {
            GlucoseCalendarSheet(
                days: Set(shown.map { Calendar.current.startOfDay(for: $0.date) }),
                selected: pickedDay
            ) { d in
                pickedDay = d
                showCalendar = false
            }
            .presentationDetents([.medium, .large])
            .presentationBackground(.ultraThinMaterial)
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
            try? await GlucoseStore.requestAccess()
            // 第一次用新版：把健康里已有的血糖导进来
            if records.isEmpty { await readFromHealth() }
            // 检查相册里照片还在不在：每次打开 App 查一次就够了，不用每次切到血糖页都查
            if !Self.checkedMissing { Self.checkedMissing = true; refreshMissing() }
        }
    }

    // MARK: 血糖相册入口

    private var albumItems: [GlucoseOverGallery.Item] {
        shown.map { r in
            let l = label(r)
            return GlucoseOverGallery.Item(record: r, label: l ?? "", line: glucoseSafeLine(l))
        }
    }

    private var overAlbumCard: some View {
        let items = albumItems.sorted { $0.record.date > $1.record.date }
        let overCount = items.filter(\.over).count
        let photoItems = items.filter { !($0.record.photos ?? []).isEmpty }
        return NavigationLink {
            GlucoseOverGallery(items: items, missing: missingIDs, owners: owners) { id, note, photos in
                updateMedia(id, note: note, photos: photos)
            }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Label("血糖相册", systemImage: "photo.stack").font(.headline)
                        .foregroundStyle(Color(red: 1, green: 0.42, blue: 0.45))
                    Text("\(photoItems.count) 张照片 · 超标 \(overCount) 次")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: -10) {
                    ForEach(photoItems.compactMap { $0.record.photos?.first }.prefix(4), id: \.id) { p in
                        GlucosePhotoView(photo: p, missing: false, side: 120)
                            .frame(width: 38, height: 38)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.black.opacity(0.4), lineWidth: 1))
                    }
                }
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(16)
            .glassCard(22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 一行

    private func row(_ r: GlucoseRecord) -> some View {
        let owner = owners[r.id] ?? GlucosePeople.me
        let isMe = owner == GlucosePeople.me
        let photos = r.photos ?? []
        // 固定布局：时间 | 数值 + 备注 | 照片（固定一格，每行对齐）| 餐点标签
        return HStack(alignment: .center, spacing: 8) {
            Button {
                editing = r
            } label: {
                HStack(alignment: .center, spacing: 8) {
                    Text(timeText(r.date))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 46, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(String(format: "%.1f", r.mmol))
                                .font(.system(size: 24, weight: .bold, design: .rounded).monospacedDigit())
                                .fixedSize()
                            Text("mmol/L").font(.caption2).foregroundStyle(.secondary).fixedSize()
                        }
                        if let n = r.note, !n.isEmpty {
                            Text(n).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // 照片格：有照片显示缩略图，没有显示相机图标，宽度固定
                    ZStack {
                        if let p = photos.first {
                            GlucosePhotoView(photo: p, missing: p.assetID.map(missingIDs.contains) ?? false, side: 120)
                                .frame(width: 40, height: 40)
                                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                .overlay(alignment: .bottomTrailing) {
                                    if photos.count > 1 {
                                        Text("\(photos.count)")
                                            .font(.system(size: 9, weight: .bold))
                                            .padding(.horizontal, 4)
                                            .background(Capsule().fill(.black.opacity(0.65)))
                                            .offset(x: 3, y: 3)
                                    }
                                }
                        } else {
                            Image(systemName: "camera")
                                .font(.footnote)
                                .foregroundStyle(.white.opacity(0.25))
                        }
                    }
                    .frame(width: 40, height: 40)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Menu {
                Button("照片和备注…", systemImage: "camera") { editing = r }
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
                    .fixedSize()
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

    /// 保存照片和备注；如果这条已经在健康里，顺便更新健康里的备注
    private func updateMedia(_ id: String, note: String?, photos: [GlucosePhoto]) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        records[i].note = note
        records[i].photos = photos.isEmpty ? nil : photos
        GlucoseLocal.save(records)
        refreshMissing()
        let r = records[i]
        if r.mine {
            let person = owners[r.id] ?? GlucosePeople.me
            Task { _ = try? await GlucoseStore.write(keep: [r], remove: [], person: person, label: label) }
        }
    }

    /// 检查哪些照片在相册里找不到了
    private func refreshMissing() {
        let ids = records.flatMap { $0.photos ?? [] }.compactMap(\.assetID)
        missingIDs = GlucoseMedia.missing(ids)
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

    // MARK: 列表

    private var shown: [GlucoseRecord] {
        guard filter != "全部" else { return records }
        return records.filter { (owners[$0.id] ?? GlucosePeople.me) == filter }
    }

    /// 列表里显示的：按测量人筛选后，再按选中的日期筛选
    private var listed: [GlucoseRecord] {
        guard let d = pickedDay else { return shown }
        return shown.filter { Calendar.current.isDate($0.date, inSameDayAs: d) }
    }

    private var groupedDays: [(Date, [GlucoseRecord])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: listed) { cal.startOfDay(for: $0.date) }
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

/// 选日期：月历，有记录的日子下面带一个小红点
struct GlucoseCalendarSheet: View {
    let days: Set<Date>
    let selected: Date?
    let onPick: (Date) -> Void

    @State private var month: Date = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date()))!
    private let cal = Calendar.current
    private let red = Color(red: 1.0, green: 0.40, blue: 0.55)

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Button { shift(-1) } label: { Image(systemName: "chevron.left").font(.headline) }
                Spacer()
                Text(monthTitle).font(.headline)
                Spacer()
                Button { shift(1) } label: { Image(systemName: "chevron.right").font(.headline) }
                    .disabled(cal.isDate(month, equalTo: Date(), toGranularity: .month))
            }
            .padding(.horizontal, 8)

            let cols = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
            LazyVGrid(columns: cols, spacing: 10) {
                ForEach(["日", "一", "二", "三", "四", "五", "六"], id: \.self) {
                    Text($0).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(cells.enumerated()), id: \.offset) { _, d in
                    if let d { dayCell(d) } else { Color.clear.frame(height: 40) }
                }
            }

            Text("有红点的日子有血糖记录")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(20)
        .onAppear {
            if let s = selected {
                month = cal.date(from: cal.dateComponents([.year, .month], from: s))!
            } else if let latest = days.max() {
                month = cal.date(from: cal.dateComponents([.year, .month], from: latest))!
            }
        }
    }

    private func dayCell(_ d: Date) -> some View {
        let has = days.contains(cal.startOfDay(for: d))
        let isSel = selected.map { cal.isDate($0, inSameDayAs: d) } ?? false
        let future = d > Date()
        return Button {
            onPick(cal.startOfDay(for: d))
        } label: {
            VStack(spacing: 3) {
                Text("\(cal.component(.day, from: d))")
                    .font(.system(size: 16, weight: has ? .bold : .regular, design: .rounded))
                    .foregroundStyle(future ? Color.secondary.opacity(0.4) : (has ? Color.primary : Color.secondary))
                Circle().fill(has ? red : .clear).frame(width: 5, height: 5)
            }
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSel ? red.opacity(0.35) : (cal.isDateInToday(d) ? Color.white.opacity(0.08) : .clear))
            )
        }
        .buttonStyle(.plain)
        .disabled(future)
    }

    /// 这个月的格子（前面补空位对齐星期）
    private var cells: [Date?] {
        let range = cal.range(of: .day, in: .month, for: month)!
        let firstWeekday = cal.component(.weekday, from: month) - 1
        var out: [Date?] = Array(repeating: nil, count: firstWeekday)
        for day in range {
            out.append(cal.date(byAdding: .day, value: day - 1, to: month))
        }
        return out
    }

    private var monthTitle: String {
        let c = cal.dateComponents([.year, .month], from: month)
        return "\(c.year ?? 0)年\(c.month ?? 0)月"
    }

    private func shift(_ n: Int) {
        if let m = cal.date(byAdding: .month, value: n, to: month) { month = m }
    }
}
