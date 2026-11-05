import UIKit
import Photos

// 换手机后重新找回原图。
//
// 系统给照片的编号（localIdentifier）换了手机会变，所以每张照片另外记三样「指纹」：
// 1. iCloud 编号：两台手机都开了「iCloud 照片」时，系统能直接换算成新手机上的编号（最准）
// 2. 拍摄时间（精确到秒）+ 照片尺寸
// 3. 小图的样子（缩成 16×16 灰度图比较）
// 找原图的顺序：iCloud 编号 → 拍摄时间相同的照片 → 「阿波血糖」相簿里的照片，
// 后两种都要再用小图比一下长得像才算找到，宁可找不到也不连错。

enum GlucoseRelink {
    private static var canRead: Bool { PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized }

    // MARK: 旧手机：给每张照片记下指纹

    /// 给还没记指纹的照片补上（原图在相册里的才能补）。有变化就保存，自动备份会带上
    static func fillInfo() async {
        guard canRead else { return }
        var list = GlucoseLocal.load()
        var need: [String] = []
        for r in list { for p in r.photos ?? [] where p.taken == nil || p.cloudID == nil { if let a = p.assetID { need.append(a) } } }
        guard !need.isEmpty else { return }

        var assets: [String: PHAsset] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: need, options: nil).enumerateObjects { a, _, _ in assets[a.localIdentifier] = a }
        guard !assets.isEmpty else { return }
        var clouds: [String: String] = [:]
        for (local, res) in PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: Array(assets.keys)) {
            if case .success(let c) = res { clouds[local] = c.stringValue }
        }

        var changed = false
        for i in list.indices {
            guard var photos = list[i].photos else { continue }
            for j in photos.indices {
                guard let id = photos[j].assetID, let a = assets[id] else { continue }
                if photos[j].taken == nil, let d = a.creationDate {
                    photos[j].taken = d; photos[j].pw = a.pixelWidth; photos[j].ph = a.pixelHeight; changed = true
                }
                if photos[j].cloudID == nil, let c = clouds[id] { photos[j].cloudID = c; changed = true }
            }
            list[i].photos = photos
        }
        if changed { GlucoseLocal.save(list) }
    }

    // MARK: 新手机：重新找回原图

    /// 返回（找回几张，原来找不到的一共几张）
    static func relink() async -> (fixed: Int, lost: Int) {
        await GlucoseMedia.requestAccess()
        guard canRead else { return (0, -1) }
        var list = GlucoseLocal.load()

        // 现在找不到原图的照片
        let all = list.flatMap { $0.photos ?? [] }.compactMap(\.assetID)
        let missing = GlucoseMedia.missing(all)
        let lostPhotos = list.flatMap { $0.photos ?? [] }.filter { p in p.assetID.map(missing.contains) ?? true }
        guard !lostPhotos.isEmpty else { return (0, 0) }

        // 1) iCloud 编号直接换算
        var cloudMap: [String: String] = [:]
        let cloudIDs = lostPhotos.compactMap(\.cloudID).map { PHCloudIdentifier(stringValue: $0) }
        if !cloudIDs.isEmpty {
            for (c, res) in PHPhotoLibrary.shared().localIdentifierMappings(for: cloudIDs) {
                if case .success(let local) = res { cloudMap[c.stringValue] = local }
            }
        }

        // 「阿波血糖」相簿里的照片（备用候选）
        var albumAssets: [PHAsset] = []
        let o = PHFetchOptions(); o.predicate = NSPredicate(format: "title == %@", GlucoseMedia.albumTitle)
        if let col = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: o).firstObject {
            PHAsset.fetchAssets(in: col, options: nil).enumerateObjects { a, _, _ in albumAssets.append(a) }
        }
        var printCache: [String: [Float]] = [:]
        func assetPrint(_ a: PHAsset) -> [Float]? {
            if let c = printCache[a.localIdentifier] { return c }
            guard let img = smallImage(a), let f = fingerprint(img) else { return nil }
            printCache[a.localIdentifier] = f
            return f
        }

        var newID: [String: String] = [:]    // 照片 id → 新编号
        var used = Set<String>()
        for p in lostPhotos {
            // 1) iCloud 编号
            if let c = p.cloudID, let local = cloudMap[c],
               PHAsset.fetchAssets(withLocalIdentifiers: [local], options: nil).count > 0 {
                newID[p.id] = local; used.insert(local); continue
            }
            guard let thumb = GlucoseMedia.thumb(p), let mine = fingerprint(thumb) else { continue }

            // 2) 拍摄时间相同（±1 秒）的照片
            var candidates: [PHAsset] = []
            if let t = p.taken {
                let fo = PHFetchOptions()
                fo.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate <= %@",
                                           t.addingTimeInterval(-1) as NSDate, t.addingTimeInterval(1) as NSDate)
                PHAsset.fetchAssets(with: .image, options: fo).enumerateObjects { a, _, _ in candidates.append(a) }
                if let w = p.pw, let h = p.ph {
                    let same = candidates.filter { ($0.pixelWidth == w && $0.pixelHeight == h) || ($0.pixelWidth == h && $0.pixelHeight == w) }
                    if !same.isEmpty { candidates = same }
                }
            }
            // 3) 相簿里的照片
            if candidates.isEmpty { candidates = albumAssets }

            // 比小图，挑最像的；必须足够像，并且明显比第二像的更像
            var scored: [(PHAsset, Float)] = []
            for a in candidates where !used.contains(a.localIdentifier) {
                if let f = assetPrint(a) { scored.append((a, diff(mine, f))) }
            }
            scored.sort { $0.1 < $1.1 }
            guard let best = scored.first else { continue }
            let byTime = p.taken != nil && candidates.count <= 3
            let limit: Float = byTime ? 0.12 : 0.045
            let second = scored.count > 1 ? scored[1].1 : 1
            if best.1 < limit && (byTime || second - best.1 > 0.02) {
                newID[p.id] = best.0.localIdentifier; used.insert(best.0.localIdentifier)
            }
        }

        guard !newID.isEmpty else { return (0, lostPhotos.count) }
        for i in list.indices {
            guard var photos = list[i].photos else { continue }
            for j in photos.indices { if let n = newID[photos[j].id] { photos[j].assetID = n } }
            list[i].photos = photos
        }
        GlucoseLocal.save(list)
        await GlucoseMedia.addToAlbum(Array(newID.values))
        await fillInfo()
        await MainActor.run { NotificationCenter.default.post(name: .glucoseDataChanged, object: nil) }
        return (newID.count, lostPhotos.count)
    }

    static func message(_ r: (fixed: Int, lost: Int)) -> String {
        if r.lost < 0 { return "需要「照片」的完全访问权限才能找原图（设置 → 隐私 → 照片 → 阿波 → 完全访问）" }
        if r.lost == 0 { return "所有照片的原图都在，不用重新关联" }
        if r.fixed == r.lost { return "已找回全部 \(r.fixed) 张原图" }
        return "找回 \(r.fixed) 张原图，还有 \(r.lost - r.fixed) 张没找到（可能还没同步完或被删了，稍后可以再点一次）"
    }

    // MARK: 小图比较

    private static func smallImage(_ a: PHAsset) -> UIImage? {
        let o = PHImageRequestOptions()
        o.isSynchronous = true
        o.deliveryMode = .highQualityFormat
        o.resizeMode = .fast
        o.isNetworkAccessAllowed = true
        var out: UIImage?
        PHImageManager.default().requestImage(for: a, targetSize: CGSize(width: 160, height: 160),
                                              contentMode: .aspectFit, options: o) { img, _ in out = img }
        return out
    }

    /// 缩成 16×16 灰度，减去平均亮度（不怕亮度、压缩差别）
    private static func fingerprint(_ img: UIImage) -> [Float]? {
        let n = 16
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
        let small = UIGraphicsImageRenderer(size: CGSize(width: n, height: n), format: fmt).image { _ in
            img.draw(in: CGRect(x: 0, y: 0, width: n, height: n))
        }
        guard let cg = small.cgImage else { return nil }
        var px = [UInt8](repeating: 0, count: n * n)
        guard let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        let v = px.map { Float($0) / 255 }
        let mean = v.reduce(0, +) / Float(v.count)
        return v.map { $0 - mean }
    }

    private static func diff(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 1 }
        var s: Float = 0
        for i in a.indices { s += abs(a[i] - b[i]) }
        return s / Float(a.count)
    }
}
