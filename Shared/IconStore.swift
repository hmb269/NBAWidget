import UIKit

/// 可以换成自己照片的图标位置
enum IconSlot: String, CaseIterable, Identifiable {
    case sleep, weight, hrv, steps, sun

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sleep: return "睡眠"
        case .weight: return "体重"
        case .hrv: return "恢复心率变异性"
        case .steps: return "今日步数"
        case .sun: return "日出日落"
        }
    }

    var symbol: String {
        switch self {
        case .sleep: return "bed.double.fill"
        case .weight: return "figure"
        case .hrv: return "waveform.path.ecg"
        case .steps: return "figure.walk"
        case .sun: return "sun.horizon.fill"
        }
    }
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
    static func loadAllForWidget() -> [IconSlot: UIImage] {
        var out: [IconSlot: UIImage] = [:]
        for slot in IconSlot.allCases {
            if let img = image(for: slot) { out[slot] = img }
        }
        let f = DateFormatter()
        f.dateFormat = "H:mm"
        let names = IconSlot.allCases.filter { out[$0] != nil }.map(\.rawValue).joined(separator: ",")
        UIPasteboard(name: ackName, create: true)?.string = f.string(from: Date()) + "|" + names
        return out
    }

    /// App 里显示：小组件最近一次读到了哪些自定义图标
    static func widgetAck() -> (time: String, slots: [IconSlot])? {
        guard let s = UIPasteboard(name: ackName, create: false)?.string else { return nil }
        let parts = s.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let slots = parts[1].split(separator: ",").compactMap { IconSlot(rawValue: String($0)) }
        return (String(parts[0]), slots)
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
