import UIKit
import Photos

/// 可以换成自己照片的图标位置
enum IconSlot: String, CaseIterable, Identifiable {
    case sleep
    case weight, hrv, steps, sun
    case restingHR, heartRate, activeEnergy, exercise, stand, distance, flights
    case oxygen, respiratory, vo2max, bodyFat

    var id: String { rawValue }
    var metric: MetricKind? { MetricKind(rawValue: rawValue) }
    var title: String { self == .sleep ? "睡眠（圆环中间）" : (metric?.title ?? rawValue) }
    var symbol: String { self == .sleep ? "bed.double.fill" : (metric?.symbol ?? "circle") }

    init(_ kind: MetricKind) { self = IconSlot(rawValue: kind.rawValue)! }

    /// App 里默认展开的几项
    static let common: [IconSlot] = [.sleep, .weight, .hrv, .steps, .sun]
}

/// 自定义图标：App 里选照片保存，小组件读取。
/// 重签后 App Group 不一定能用，所以同时写一份到「命名剪贴板」（同一签名下 App 和小组件共用），
/// 小组件读到后再自己缓存一份。
enum IconStore {
    private static let groupID = "group.com.hmb269.nbawidget"
    private static let pngType = "public.png"
    private static let ackName = UIPasteboard.Name("com.hmb269.nbawidget.icon.ack")

    private static func boardName(_ slot: IconSlot) -> UIPasteboard.Name {
        UIPasteboard.Name("com.hmb269.nbawidget.icon.\(slot.rawValue)")
    }

    private static var groupDir: URL? {
        guard let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else { return nil }
        let dir = base.appendingPathComponent("icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func cacheKey(_ slot: IconSlot) -> String { "icon_cache_\(slot.rawValue)" }

    // MARK: App 端

    /// 裁成正方形、缩到 180 像素后保存
    static func save(_ image: UIImage, for slot: IconSlot) {
        guard let data = square(image, side: 180).pngData() else { return }
        if let dir = groupDir { try? data.write(to: dir.appendingPathComponent(slot.rawValue + ".png")) }
        UIPasteboard(name: boardName(slot), create: true)?.setData(data, forPasteboardType: pngType)
        UserDefaults.standard.set(data, forKey: cacheKey(slot))
    }

    static func reset(_ slot: IconSlot) {
        if let dir = groupDir { try? FileManager.default.removeItem(at: dir.appendingPathComponent(slot.rawValue + ".png")) }
        UIPasteboard(name: boardName(slot), create: true)?.string = "none"
        UserDefaults.standard.removeObject(forKey: cacheKey(slot))
    }

    // MARK: 读取（App 和小组件都用）

    static func image(for slot: IconSlot) -> UIImage? {
        // 0. 系统相簿「阿波小组件·xx」（重签后最可靠的通道）
        if let img = albumImage(slot) { return img }
        // 1. App Group 能用时以它为准
        if let dir = groupDir {
            let url = dir.appendingPathComponent(slot.rawValue + ".png")
            if let d = try? Data(contentsOf: url), let img = UIImage(data: d) { return img }
        }
        // 2. 命名剪贴板
        if let board = UIPasteboard(name: boardName(slot), create: false) {
            if let d = board.data(forPasteboardType: pngType), let img = UIImage(data: d) {
                UserDefaults.standard.set(d, forKey: cacheKey(slot))
                return img
            }
            if board.string == "none" {
                UserDefaults.standard.removeObject(forKey: cacheKey(slot))
                return nil
            }
        }
        // 3. 自己的缓存
        if let d = UserDefaults.standard.data(forKey: cacheKey(slot)) { return UIImage(data: d) }
        return nil
    }

    /// 小组件刷新时调用：把读到了哪些自定义图标写回去，App 里据此显示同步状态
    static func loadAllForWidget(_ slots: [IconSlot] = IconSlot.allCases) -> [IconSlot: UIImage] {
        var out: [IconSlot: UIImage] = [:]
        for slot in slots {
            if let img = image(for: slot) { out[slot] = img }
        }
        let f = DateFormatter()
        f.dateFormat = "H:mm"
        let names = IconSlot.allCases.filter { out[$0] != nil }.map(\.rawValue).joined(separator: ",")
        UIPasteboard(name: ackName, create: true)?.string = f.string(from: Date()) + "|" + names + "|" + photoStatusText
        return out
    }

    /// App 里显示：小组件最近一次读到了哪些自定义图标
    static func widgetAck() -> (time: String, slots: [IconSlot], photo: String)? {
        guard let s = UIPasteboard(name: ackName, create: false)?.string else { return nil }
        let parts = s.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        let slots = parts[1].split(separator: ",").compactMap { IconSlot(rawValue: String($0)) }
        return (String(parts[0]), slots, parts.count > 2 ? String(parts[2]) : "")
    }

    // MARK: 相簿中转

    static func albumTitle(_ slot: IconSlot) -> String { "阿波小组件·" + slot.title }

    static var photoStatusText: String {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized: return "完全访问"
        case .limited: return "部分访问"
        case .denied: return "已拒绝"
        case .restricted: return "受限"
        default: return "未授权"
        }
    }

    private static func album(_ slot: IconSlot) -> PHAssetCollection? {
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "title == %@", albumTitle(slot))
        return PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: opts).firstObject
    }

    /// 相簿里最后一张照片，裁成方形缩略图
    static func albumImage(_ slot: IconSlot) -> UIImage? {
        let st = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard st == .authorized || st == .limited, let col = album(slot) else { return nil }
        guard let asset = PHAsset.fetchAssets(in: col, options: nil).lastObject else { return nil }
        let ro = PHImageRequestOptions()
        ro.isSynchronous = true
        ro.deliveryMode = .highQualityFormat
        ro.resizeMode = .exact
        ro.isNetworkAccessAllowed = true
        var out: UIImage?
        PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 240, height: 240),
                                              contentMode: .aspectFill, options: ro) { img, _ in out = img }
        return out
    }

    /// App 里调用：把选中的照片放进对应相簿（只放这一张）。
    /// 能拿到相册里的原照片就直接引用，不会多出一张；拿不到就把图片存成新照片放进去。
    static func putInAlbum(_ slot: IconSlot, assetID: String?, image: UIImage) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { throw NSError(domain: "阿波", code: 1, userInfo: [NSLocalizedDescriptionKey: "没有相册权限"]) }

        if album(slot) == nil {
            let title = albumTitle(slot)
            try await PHPhotoLibrary.shared().performChanges {
                _ = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            }
        }
        guard let col = album(slot) else { throw NSError(domain: "阿波", code: 2, userInfo: [NSLocalizedDescriptionKey: "建相簿失败"]) }
        let existing = PHAsset.fetchAssets(in: col, options: nil)
        let picked = assetID.flatMap { PHAsset.fetchAssets(withLocalIdentifiers: [$0], options: nil).firstObject }
        let data = square(image, side: 600).jpegData(compressionQuality: 0.9)

        try await PHPhotoLibrary.shared().performChanges {
            guard let req = PHAssetCollectionChangeRequest(for: col) else { return }
            if existing.count > 0 { req.removeAssets(existing) }
            if let picked {
                req.addAssets([picked] as NSArray)
            } else if let data {
                let create = PHAssetCreationRequest.forAsset()
                create.addResource(with: .photo, data: data, options: nil)
                if let ph = create.placeholderForCreatedAsset { req.addAssets([ph] as NSArray) }
            }
        }
    }

    /// 清空相簿（照片本身还留在图库里）
    static func clearAlbum(_ slot: IconSlot) async {
        guard let col = album(slot) else { return }
        let existing = PHAsset.fetchAssets(in: col, options: nil)
        guard existing.count > 0 else { return }
        try? await PHPhotoLibrary.shared().performChanges {
            PHAssetCollectionChangeRequest(for: col)?.removeAssets(existing)
        }
    }

    private static func square(_ image: UIImage, side: CGFloat) -> UIImage {
        let w = image.size.width, h = image.size.height
        let s = min(w, h)
        let crop = CGRect(x: (w - s) / 2, y: (h - s) / 2, width: s, height: s)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            // 按正方形区域画进去：先放大让短边铺满，再居中
            let scale = side / s
            image.draw(in: CGRect(x: -crop.minX * scale, y: -crop.minY * scale, width: w * scale, height: h * scale))
        }
    }
}
