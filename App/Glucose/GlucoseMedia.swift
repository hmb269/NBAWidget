import SwiftUI
import Photos
import PhotosUI
import UniformTypeIdentifiers

// 血糖记录的照片和备注，以及数据备份。
//
// 照片的存法（六层保护）：
// 1. 原图留在系统「照片」里，App 只记相册编号；同时加进「阿波血糖」相簿（只是分类，不多占空间）
// 2. App 每次打开检查一遍：相册里找不到的照片会提醒（30 天内可以在「最近删除」恢复）
// 3. App 自己再存一张压缩小图（约 50KB），原图被删也还能看
// 4. 备份文件里带上小图
// 5. 写入健康时，备注和照片编号也写进健康
// 6. 自动备份到「文件」App 里选的文件夹（删 App、掉签都不影响）

extension Notification.Name {
    /// 导入备份后通知血糖页重新读数据
    static let glucoseDataChanged = Notification.Name("glucoseDataChanged")
}

/// 一张照片：小图文件名 + 相册编号
struct GlucosePhoto: Codable, Hashable, Identifiable {
    var id: String          // App 里小图的文件名
    var assetID: String?    // 系统相册里的编号（换手机会变）
    // 换手机后找回原图用的「指纹」（见 GlucoseRelink）
    var cloudID: String? = nil   // iCloud 照片编号
    var taken: Date? = nil       // 拍摄时间
    var pw: Int? = nil           // 原图宽
    var ph: Int? = nil           // 原图高
}

enum GlucoseMedia {
    static let albumTitle = "阿波血糖"
    private static let cache = NSCache<NSString, UIImage>()

    // MARK: 小图

    static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("glucose_thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func thumbURL(_ id: String) -> URL { dir.appendingPathComponent(id + ".jpg") }

    static func thumb(_ p: GlucosePhoto) -> UIImage? {
        if let c = cache.object(forKey: p.id as NSString) { return c }
        guard let d = try? Data(contentsOf: thumbURL(p.id)), let img = UIImage(data: d) else { return nil }
        cache.setObject(img, forKey: p.id as NSString)
        return img
    }

    /// 压缩成长边 640 像素的小图（约 30~60KB）
    static func thumbData(_ img: UIImage) -> Data? {
        let maxSide: CGFloat = 640
        let s = min(1, maxSide / max(img.size.width, img.size.height))
        let size = CGSize(width: max(1, img.size.width * s), height: max(1, img.size.height * s))
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        let out = UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            img.draw(in: CGRect(origin: .zero, size: size))
        }
        return out.jpegData(compressionQuality: 0.6)
    }

    /// 存一张小图，返回照片记录
    static func store(_ img: UIImage, assetID: String?) -> GlucosePhoto? {
        guard let d = thumbData(img) else { return nil }
        let p = GlucosePhoto(id: UUID().uuidString, assetID: assetID)
        do { try d.write(to: thumbURL(p.id), options: .atomic) } catch { return nil }
        return p
    }

    static func deleteThumb(_ p: GlucosePhoto) {
        try? FileManager.default.removeItem(at: thumbURL(p.id))
        cache.removeObject(forKey: p.id as NSString)
    }

    // MARK: 系统相册

    private static var canUseLibrary: Bool {
        let s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return s == .authorized || s == .limited
    }

    static func requestAccess() async {
        _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    private static func album() -> PHAssetCollection? {
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "title == %@", albumTitle)
        return PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: opts).firstObject
    }

    /// 把照片加进「阿波血糖」相簿（只是分类，不复制）
    static func addToAlbum(_ ids: [String]) async {
        guard !ids.isEmpty, canUseLibrary else { return }
        if album() == nil {
            let title = albumTitle
            try? await PHPhotoLibrary.shared().performChanges {
                _ = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            }
        }
        guard let col = album() else { return }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        guard assets.count > 0 else { return }
        try? await PHPhotoLibrary.shared().performChanges {
            PHAssetCollectionChangeRequest(for: col)?.addAssets(assets)
        }
    }

    private final class IDBox: @unchecked Sendable { var id: String? }

    /// 拍的照片存进系统相册，返回相册编号
    static func saveToLibrary(_ img: UIImage) async -> String? {
        await requestAccess()
        guard canUseLibrary else { return nil }
        let box = IDBox()
        try? await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCreationRequest.creationRequestForAsset(from: img)
            box.id = req.placeholderForCreatedAsset?.localIdentifier
        }
        return box.id
    }

    /// 从相册取原图（找不到返回 nil）
    static func fullImage(_ id: String, side: CGFloat) async -> UIImage? {
        guard canUseLibrary,
              let a = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
        let o = PHImageRequestOptions()
        o.deliveryMode = .highQualityFormat
        o.isNetworkAccessAllowed = true
        return await withCheckedContinuation { cont in
            let done = IDBox()
            PHImageManager.default().requestImage(for: a, targetSize: CGSize(width: side, height: side),
                                                  contentMode: .aspectFit, options: o) { img, _ in
                guard done.id == nil else { return }
                done.id = "done"
                cont.resume(returning: img)
            }
        }
    }

    /// 相册里已经找不到的照片编号（被删或在「最近删除」里）。没有完全访问权限时不检查，避免误报
    static func missing(_ ids: [String]) -> Set<String> {
        guard !ids.isEmpty, PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return [] }
        let found = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var have = Set<String>()
        found.enumerateObjects { a, _, _ in have.insert(a.localIdentifier) }
        return Set(ids).subtracting(have)
    }
}

// MARK: - 照片显示

/// 先显示小图，再从相册换成原图；原图找不到时右上角标个感叹号
struct GlucosePhotoView: View {
    let photo: GlucosePhoto
    var missing = false
    var side: CGFloat = 400
    var fit = false          // 看大图时完整显示，不裁剪

    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image {
                    if fit { Image(uiImage: image).resizable().scaledToFit() }
                    else { Image(uiImage: image).resizable().scaledToFill() }
                } else {
                    Rectangle().fill(Color.white.opacity(0.08))
                        .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                }
            }
            if missing {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .padding(3)
                    .background(Circle().fill(.black.opacity(0.5)))
                    .padding(3)
            }
        }
        .clipped()
        .task(id: photo) {
            image = GlucoseMedia.thumb(photo)
            if let id = photo.assetID, !missing, let full = await GlucoseMedia.fullImage(id, side: side) {
                image = full
            }
        }
    }
}

/// 系统相机
struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let c = UIImagePickerController()
        c.sourceType = .camera
        c.delegate = context.coordinator
        return c
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ p: CameraPicker) { parent = p }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage { parent.onImage(img) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

/// 看大图
struct GlucosePhotoViewer: View {
    let photo: GlucosePhoto
    let missing: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            GlucosePhotoView(photo: photo, missing: missing, side: 2000)
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.headline).padding(12)
                    }
                    .glassButton()
                }
                Spacer()
                if missing {
                    Text("原图在相册里找不到了（可能被删除），显示的是 App 保存的小图。30 天内可以在「照片 → 最近删除」恢复。")
                        .font(.footnote)
                        .padding(12)
                        .glassCard(14)
                }
            }
            .padding()
        }
    }
}

// MARK: - 一条记录的详情：照片 + 备注

struct GlucoseRecordSheet: View {
    let record: GlucoseRecord
    let tag: String?
    let owner: String
    let missing: Set<String>
    let onSave: (String?, [GlucosePhoto]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var note: String
    @State private var photos: [GlucosePhoto]
    @State private var removed: [GlucosePhoto] = []
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var adding = false
    @State private var viewing: GlucosePhoto?

    init(record: GlucoseRecord, tag: String?, owner: String, missing: Set<String>,
         onSave: @escaping (String?, [GlucosePhoto]) -> Void) {
        self.record = record
        self.tag = tag
        self.owner = owner
        self.missing = missing
        self.onSave = onSave
        _note = State(initialValue: record.note ?? "")
        _photos = State(initialValue: record.photos ?? [])
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    header
                    photoCard
                    noteCard
                }
                .padding(16)
            }
            .background(AppBackground())
            .navigationTitle("照片和备注")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        // 新加的照片没保存就丢掉小图
                        for p in photos where !(record.photos ?? []).contains(p) { GlucoseMedia.deleteThumb(p) }
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        removed.forEach(GlucoseMedia.deleteThumb)
                        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(n.isEmpty ? nil : n, photos)
                        dismiss()
                    }
                    .bold()
                    .disabled(adding)
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { img in
                    Task {
                        adding = true
                        let id = await GlucoseMedia.saveToLibrary(img)
                        if let p = GlucoseMedia.store(img, assetID: id) { photos.append(p) }
                        if let id { await GlucoseMedia.addToAlbum([id]) }
                        adding = false
                    }
                }
                .ignoresSafeArea()
            }
            .fullScreenCover(item: $viewing) { p in
                GlucosePhotoViewer(photo: p, missing: p.assetID.map(missing.contains) ?? false)
            }
            .onChange(of: pickerItems) { _, items in
                guard !items.isEmpty else { return }
                Task { await addPicked(items) }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(String(format: "%.1f", record.mmol))
                .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
            Text("mmol/L").font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(tag ?? "未标记").font(.subheadline.weight(.semibold))
                Text(timeText + (owner == GlucosePeople.me ? "" : " · \(owner)"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .glassCard(24)
    }

    private var photoCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("照片").font(.headline)
                Spacer()
                if adding { ProgressView() }
            }
            if !photos.isEmpty {
                let cols = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
                LazyVGrid(columns: cols, spacing: 8) {
                    ForEach(photos) { p in
                        // 先占一个正方形格子，照片放在里面裁剪，不会溢出盖住别的内容
                        Color.clear
                            .aspectRatio(1, contentMode: .fit)
                            .overlay {
                                GlucosePhotoView(photo: p, missing: p.assetID.map(missing.contains) ?? false)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .onTapGesture { viewing = p }
                            .contextMenu {
                                Button("从这条记录移除", systemImage: "trash", role: .destructive) {
                                    photos.removeAll { $0 == p }
                                    if !(record.photos ?? []).contains(p) { GlucoseMedia.deleteThumb(p) } else { removed.append(p) }
                                }
                            }
                    }
                }
                Text("长按照片可以移除（只是从这条记录移除，不会删相册里的原图）")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button {
                        showCamera = true
                    } label: {
                        Label("拍照", systemImage: "camera.fill").frame(maxWidth: .infinity)
                    }
                    .glassButton()
                }
                PhotosPicker(selection: $pickerItems, maxSelectionCount: 6, matching: .images, photoLibrary: .shared()) {
                    Label("从相册选", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity)
                }
                .glassButton()
            }
            .disabled(adding)
        }
        .padding(18)
        .glassCard(24)
    }

    private var noteCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("备注").font(.headline)
            TextField("比如：吃了米粉、饭后散步30分钟", text: $note, axis: .vertical)
                .lineLimit(2...6)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.06)))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(["饭后散步", "运动了", "吃了甜食", "吃得多", "吃得少", "熬夜了"], id: \.self) { q in
                        Button(q) {
                            // 已经写过的不重复加
                            guard !note.contains(q) else { return }
                            note = note.isEmpty ? q : note + "，" + q
                        }
                        .font(.footnote.weight(.semibold))
                        .fixedSize()
                        .buttonStyle(.plain)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(note.contains(q) ? Color.accentColor.opacity(0.3) : Color.white.opacity(0.08)))
                    }
                }
            }
        }
        .padding(18)
        .glassCard(24)
    }

    private var timeText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 EEE HH:mm"
        return f.string(from: record.date)
    }

    private func addPicked(_ items: [PhotosPickerItem]) async {
        adding = true
        await GlucoseMedia.requestAccess()
        var ids: [String] = []
        for it in items {
            guard let data = try? await it.loadTransferable(type: Data.self), let img = UIImage(data: data) else { continue }
            if let p = GlucoseMedia.store(img, assetID: it.itemIdentifier) {
                photos.append(p)
                if let a = it.itemIdentifier { ids.append(a) }
            }
        }
        await GlucoseMedia.addToAlbum(ids)
        pickerItems = []
        adding = false
    }
}

// MARK: - 备份

struct GlucoseBackupFile: Codable {
    var version: Int
    var exportedAt: Date
    var records: [GlucoseRecord]
    var tags: [String: String]
    var owners: [String: String]
    var people: [String]
    var meals: [String: Int]
    var thumbs: [String: Data]
    var lotteryFavs: [String: [[[Int]]]]? = nil   // 彩票收藏：玩法 → [[前区],[后区]]
    var lotteryWins: Data? = nil                  // 彩票中奖记录
}

enum GlucoseBackup {
    private static let mealKeys = ["mealBreakfast", "mealLunch", "mealDinner"]

    static var fileName: String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmm"
        return "阿波备份-" + f.string(from: Date())
    }

    /// 打包：所有血糖记录（含别人的）、标签、测量人、三餐时间、小图
    static func make(includeThumbs: Bool = true) -> Data? {
        let records = GlucoseLocal.load()
        var thumbs: [String: Data] = [:]
        for p in records.flatMap({ $0.photos ?? [] }) where includeThumbs {
            if let d = try? Data(contentsOf: GlucoseMedia.thumbURL(p.id)) { thumbs[p.id] = d }
        }
        let d = UserDefaults.standard
        var meals: [String: Int] = [:]
        for k in mealKeys where d.object(forKey: k) != nil { meals[k] = d.integer(forKey: k) }
        let file = GlucoseBackupFile(version: 1, exportedAt: Date(), records: records,
                                     tags: GlucoseTags.all, owners: GlucosePeople.owners, people: GlucosePeople.names,
                                     meals: meals, thumbs: thumbs, lotteryFavs: LotteryFavorites.exportAll(), lotteryWins: LotteryWins.exportData())
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        return try? enc.encode(file)
    }

    /// 导入：合并进现有数据（已有的不覆盖，只补缺的）
    static func restore(_ data: Data) throws -> String {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let f = try dec.decode(GlucoseBackupFile.self, from: data)

        var newThumbs = 0
        for (id, d) in f.thumbs where !FileManager.default.fileExists(atPath: GlucoseMedia.thumbURL(id).path) {
            try? d.write(to: GlucoseMedia.thumbURL(id), options: .atomic)
            newThumbs += 1
        }

        var byId = Dictionary(uniqueKeysWithValues: GlucoseLocal.load().map { ($0.id, $0) })
        var added = 0
        for r in f.records {
            if var old = byId[r.id] {
                if old.meterMeal == nil { old.meterMeal = r.meterMeal }
                if old.note == nil { old.note = r.note }
                if (old.photos ?? []).isEmpty { old.photos = r.photos }
                byId[r.id] = old
            } else {
                byId[r.id] = r
                added += 1
            }
        }
        GlucoseLocal.save(byId.values.sorted { $0.date > $1.date })

        let d = UserDefaults.standard
        var tags = GlucoseTags.all
        for (k, v) in f.tags where tags[k] == nil { tags[k] = v }
        d.set(tags, forKey: "glucoseTags")
        var owners = GlucosePeople.owners
        for (k, v) in f.owners where owners[k] == nil { owners[k] = v }
        d.set(owners, forKey: "glucoseOwner")
        var people = GlucosePeople.names
        for p in f.people where !people.contains(p) { people.append(p) }
        d.set(people, forKey: "glucosePeople")
        for (k, v) in f.meals where d.object(forKey: k) == nil { d.set(v, forKey: k) }

        let favs = f.lotteryFavs.map(LotteryFavorites.importAll) ?? 0
        let wins = f.lotteryWins.map(LotteryWins.importData) ?? 0

        NotificationCenter.default.post(name: .glucoseDataChanged, object: nil)
        return "导入完成：新增 \(added) 条记录，恢复 \(newThumbs) 张小图" + (favs > 0 ? "，\(favs) 注彩票收藏" : "") + (wins > 0 ? "，\(wins) 条中奖记录" : "")
    }
}

/// 导出用的文件
struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// 备份（重签的 App 每次重启后都没有权限再写外部文件夹，所以这样分）：
/// - 本机：写在 App 自己的「阿波备份」文件夹（文件 App → 我的 iPhone → 阿波），全自动、增量
///     阿波备份.json / 阿波备份-上一版.json / 阿波照片/xxx.jpg
/// - iCloud：一键生成完整备份文件（含照片小图），用系统「存储到」放进 iCloud；超过 7 天提醒
enum AutoBackup {
    static let recordsName = "阿波备份.json"
    static let prevName = "阿波备份-上一版.json"
    static let photosDir = "阿波照片"
    static let cloudFileName = "阿波备份-完整.json"
    static let remindDays = 7
    private static let lastLocalKey = "autoBackupLastLocal"
    private static let lastCloudKey = "backupLastCloud"
    private static var work: DispatchWorkItem?

    /// App 文稿目录里的「阿波备份」（开了文件共享，文件 App 里能看到）
    static var localFolder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let d = docs.appendingPathComponent("阿波备份", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static var lastLocal: Date? { UserDefaults.standard.object(forKey: lastLocalKey) as? Date }
    static var lastCloud: Date? { UserDefaults.standard.object(forKey: lastCloudKey) as? Date }
    static func markCloudDone() { UserDefaults.standard.set(Date(), forKey: lastCloudKey) }

    /// 有记录、且超过 7 天没备份到 iCloud
    static var cloudOverdue: Bool {
        guard !GlucoseLocal.load().isEmpty else { return false }
        guard let d = lastCloud else { return true }
        return Date().timeIntervalSince(d) > Double(remindDays) * 86400
    }

    static func ago(_ d: Date?) -> String {
        guard let d else { return "从未" }
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: d),
                                                   to: Calendar.current.startOfDay(for: Date())).day ?? 0
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        if days == 0 { return "今天 " + f.string(from: d) }
        if days == 1 { return "昨天 " + f.string(from: d) }
        return "\(days) 天前"
    }

    /// 本机备份（增量），返回结果说明
    @discardableResult
    static func run() -> String {
        guard let data = GlucoseBackup.make(includeThumbs: false) else { return "生成备份失败" }
        let folder = localFolder
        let fm = FileManager.default
        let latest = folder.appendingPathComponent(recordsName)
        let prev = folder.appendingPathComponent(prevName)
        do {
            if fm.fileExists(atPath: latest.path) {
                try? fm.removeItem(at: prev)
                try? fm.copyItem(at: latest, to: prev)
            }
            try data.write(to: latest, options: .atomic)
        } catch {
            return "本机备份失败：\(error.localizedDescription)"
        }
        let dir = folder.appendingPathComponent(photosDir, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let existing = Set((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
        var copied = 0
        for p in GlucoseLocal.load().flatMap({ $0.photos ?? [] }) where !existing.contains(p.id + ".jpg") {
            let src = GlucoseMedia.thumbURL(p.id)
            guard fm.fileExists(atPath: src.path) else { continue }
            if (try? fm.copyItem(at: src, to: dir.appendingPathComponent(p.id + ".jpg"))) != nil { copied += 1 }
        }
        UserDefaults.standard.set(Date(), forKey: lastLocalKey)
        return "本机已备份" + (copied > 0 ? "，新增 \(copied) 张照片" : "")
    }

    /// 数据有变化时调用：3 秒内多次变化只备份一次
    static func schedule() {
        work?.cancel()
        let w = DispatchWorkItem { run() }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: w)
    }

    /// 从本机备份恢复（App 数据出问题时用）
    static func restoreLocal() throws -> String {
        let folder = localFolder
        let fm = FileManager.default
        var restored = 0
        let dir = folder.appendingPathComponent(photosDir, isDirectory: true)
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(".jpg") {
            let dest = GlucoseMedia.thumbURL(String(name.dropLast(4)))
            guard !fm.fileExists(atPath: dest.path) else { continue }
            if (try? fm.copyItem(at: dir.appendingPathComponent(name), to: dest)) != nil { restored += 1 }
        }
        let data = try Data(contentsOf: folder.appendingPathComponent(recordsName))
        return try GlucoseBackup.restore(data) + (restored > 0 ? "，恢复 \(restored) 张照片" : "")
    }

    /// 生成要存到 iCloud 的完整备份文件（含照片小图）
    static func makeCloudFile() -> URL? {
        guard let data = GlucoseBackup.make(includeThumbs: true) else { return nil }
        let u = FileManager.default.temporaryDirectory.appendingPathComponent(cloudFileName)
        try? FileManager.default.removeItem(at: u)
        do { try data.write(to: u, options: .atomic) } catch { return nil }
        return u
    }
}

/// 系统的「存储到…」：把一个文件拷到用户选的位置（iCloud 云盘 / 我的 iPhone）
struct ExportPicker: UIViewControllerRepresentable {
    let url: URL
    let onDone: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let c = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        c.delegate = context.coordinator
        return c
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: ExportPicker
        init(_ p: ExportPicker) { parent = p }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.onDone(!urls.isEmpty)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { parent.onDone(false) }
    }
}

/// 选一个备份文件导入（拷贝方式，不需要长期权限）
struct ImportPicker: UIViewControllerRepresentable {
    let onPick: (URL?) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let c = UIDocumentPickerViewController(forOpeningContentTypes: [.json], asCopy: true)
        c.delegate = context.coordinator
        return c
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: ImportPicker
        init(_ p: ImportPicker) { parent = p }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.onPick(urls.first)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { parent.onPick(nil) }
    }
}

/// 「备份到 iCloud」：生成文件 → 系统存储界面 → 成功后记下时间
struct CloudBackupModifier: ViewModifier {
    @Binding var isPresented: Bool
    let onResult: (String) -> Void
    @State private var file: URL?

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented) { _, on in
                guard on else { return }
                file = AutoBackup.makeCloudFile()
                if file == nil { isPresented = false; onResult("生成备份文件失败") }
            }
            .sheet(isPresented: Binding(get: { isPresented && file != nil }, set: { if !$0 { isPresented = false } })) {
                if let f = file {
                    ExportPicker(url: f) { ok in
                        isPresented = false
                        if ok {
                            AutoBackup.markCloudDone()
                            onResult("已存储「\(AutoBackup.cloudFileName)」。以后存到同一个位置时选「替换」")
                        }
                    }
                    .ignoresSafeArea()
                }
            }
    }
}

extension View {
    func cloudBackup(isPresented: Binding<Bool>, onResult: @escaping (String) -> Void) -> some View {
        modifier(CloudBackupModifier(isPresented: isPresented, onResult: onResult))
    }
}
