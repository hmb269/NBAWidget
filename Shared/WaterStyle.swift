import SwiftUI
import Photos

// 喝水小组件的外观和设置（App 和小组件共用）。
// 重签名后 App 和小组件不能共享存储，所以 App 把设置写成一个相簿的名字，
// 小组件读这个相簿名，例如「阿波设置·喝水·350ml·4杯·玻璃杯」（相簿是空的，不占空间）。

let waterBlue = Color(red: 0.30, green: 0.68, blue: 1.0)
let waterCyan = Color(red: 0.35, green: 0.90, blue: 0.95)
let waterGreen = Color(red: 0.30, green: 0.85, blue: 0.55)

enum CupKind: String, CaseIterable, Identifiable {
    case glass = "玻璃杯"
    case tumbler = "直筒杯"
    case mug = "马克杯"
    case bottle = "水瓶"
    var id: String { rawValue }

    /// 宽高比
    var aspect: CGFloat {
        switch self {
        case .glass: return 0.72
        case .tumbler: return 0.64
        case .mug: return 0.95
        case .bottle: return 0.5
        }
    }
    /// 水面高度（从顶部往下的比例）
    var waterTop: CGFloat { self == .bottle ? 0.34 : 0.18 }
}

struct WaterSettings: Equatable {
    var ml: Int = 350
    var cups: Int = 4
    var kind: CupKind = .glass

    /// 少一杯算达标（2 杯的话要喝满）
    var enough: Int { cups >= 3 ? cups - 1 : cups }

    static let mlRange = 100...1000
    static let cupsRange = 2...6
    static let prefix = "阿波设置·喝水·"

    var albumTitle: String { Self.prefix + "\(ml)ml·\(cups)杯·\(kind.rawValue)" }

    init(ml: Int = 350, cups: Int = 4, kind: CupKind = .glass) {
        self.ml = ml; self.cups = cups; self.kind = kind
    }

    init?(albumTitle t: String) {
        guard t.hasPrefix(Self.prefix) else { return nil }
        let parts = t.dropFirst(Self.prefix.count).split(separator: "·").map(String.init)
        guard parts.count == 3,
              let ml = Int(parts[0].replacingOccurrences(of: "ml", with: "")),
              let cups = Int(parts[1].replacingOccurrences(of: "杯", with: "")),
              let kind = CupKind(rawValue: parts[2]) else { return nil }
        self.ml = min(max(ml, Self.mlRange.lowerBound), Self.mlRange.upperBound)
        self.cups = min(max(cups, Self.cupsRange.lowerBound), Self.cupsRange.upperBound)
        self.kind = kind
    }

    // MARK: 本地缓存（App、小组件各存一份）

    private static let key = "waterSettingsTitle"

    static var current: WaterSettings {
        UserDefaults.standard.string(forKey: key).flatMap(WaterSettings.init(albumTitle:)) ?? WaterSettings()
    }

    /// App 里已经同步到相簿的设置
    static var savedTitle: String? { UserDefaults.standard.string(forKey: "waterSettingsSaved") }

    private static func cache(_ s: WaterSettings) {
        UserDefaults.standard.set(s.albumTitle, forKey: key)
    }

    // MARK: 相簿

    private static func album() -> PHAssetCollection? {
        let st = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard st == .authorized || st == .limited else { return nil }
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "title BEGINSWITH %@", prefix)
        return PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: opts).firstObject
    }

    /// 小组件里调用：从相簿名读最新设置
    static func refreshFromAlbum() {
        if let t = album()?.localizedTitle, let s = WaterSettings(albumTitle: t) { cache(s) }
    }

    /// App 里调用：保存设置（改相簿名；没有就建一个空相簿）
    static func save(_ s: WaterSettings) async throws {
        cache(s)
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw NSError(domain: "阿波", code: 1, userInfo: [NSLocalizedDescriptionKey: "没有相册权限，小组件读不到设置"])
        }
        let title = s.albumTitle
        if let col = album() {
            if col.localizedTitle != title {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCollectionChangeRequest(for: col)?.title = title
            }
            }
        } else {
            try await PHPhotoLibrary.shared().performChanges {
                _ = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            }
        }
        UserDefaults.standard.set(title, forKey: "waterSettingsSaved")
    }
}

// MARK: - 杯子

/// 一个杯子：喝了就装满水、带水波、勾和时间
struct CupView: View {
    var kind: CupKind = .glass
    let filled: Bool
    let isNext: Bool
    var arming = false       // 等待第二次点击撤销
    var time: String? = nil  // 喝这杯的时间，写在杯子里
    var big = false

    var body: some View {
        let cup = CupBody(kind: kind)
        let stroke = arming ? Color.orange : filled ? waterCyan.opacity(0.9) : (isNext ? waterBlue.opacity(0.7) : Color.white.opacity(0.22))
        let style = StrokeStyle(lineWidth: 1.6, dash: filled || isNext || arming ? [] : [3, 3])
        ZStack {
            cup.fill(Color.white.opacity(filled ? 0.04 : 0.06))
            if filled {
                WaveShape(top: kind.waterTop)
                    .fill(LinearGradient(colors: [waterCyan.opacity(0.95), waterBlue], startPoint: .top, endPoint: .bottom))
                    .clipShape(cup)
                    .opacity(arming ? 0.35 : 1)
                Group {
                    if arming || time == nil {
                        Image(systemName: arming ? "arrow.uturn.backward" : "checkmark")
                            .font(.system(size: big ? 16 : 13, weight: .heavy))
                    } else if let time {
                        // 时间就是「已喝」的标记：放得下就一行「13:53」，放不下就上下两行「13 / 53」
                        let parts = time.split(separator: ":").map(String.init)
                        let size: CGFloat = big ? 16 : 14
                        ViewThatFits(in: .horizontal) {
                            Text(time)
                                .font(.system(size: size, weight: .heavy, design: .rounded).monospacedDigit())
                                .fixedSize()
                            VStack(spacing: -2) {
                                ForEach(parts.indices, id: \.self) { Text(parts[$0]) }
                            }
                            .font(.system(size: size, weight: .heavy, design: .rounded).monospacedDigit())
                            .fixedSize()
                            VStack(spacing: -2) {
                                ForEach(parts.indices, id: \.self) { Text(parts[$0]) }
                            }
                            .font(.system(size: size - 3, weight: .heavy, design: .rounded).monospacedDigit())
                            .fixedSize()
                        }
                    }
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.3), radius: 2)
                .padding(.horizontal, 2)
                .centered(in: kind, dy: kind == .bottle ? 8 : (kind == .mug ? 4 : 3))
            } else if isNext {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(waterBlue.opacity(0.9))
                    .centered(in: kind, dy: kind == .bottle ? 6 : 0)
            }
            cup.stroke(stroke, style: style)
            if kind == .mug {
                MugHandle().stroke(stroke, style: StrokeStyle(lineWidth: big ? 3 : 2, lineCap: .round, dash: style.dash))
            }
        }
        .aspectRatio(kind.aspect, contentMode: .fit)
    }
}

extension View {
    /// 放在杯身中间（马克杯的杯身偏左，要避开把手）
    func centered(in kind: CupKind, dy: CGFloat) -> some View {
        GeometryReader { g in
            self.frame(width: g.size.width * (kind == .mug ? 0.76 : 1) - 4)
                .position(x: g.size.width * (kind == .mug ? 0.38 : 0.5), y: g.size.height / 2 + dy)
        }
    }
}

/// 杯身外形
struct CupBody: Shape {
    var kind: CupKind

    func path(in r: CGRect) -> Path {
        switch kind {
        case .glass:
            // 上宽下窄的梯形，底部圆角
            let inset = r.width * 0.13, radius = r.width * 0.12
            var p = Path()
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX - inset, y: r.maxY - radius))
            p.addQuadCurve(to: CGPoint(x: r.maxX - inset - radius, y: r.maxY), control: CGPoint(x: r.maxX - inset, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX + inset + radius, y: r.maxY))
            p.addQuadCurve(to: CGPoint(x: r.minX + inset, y: r.maxY - radius), control: CGPoint(x: r.minX + inset, y: r.maxY))
            p.closeSubpath()
            return p
        case .tumbler:
            // 直筒：上下一样宽，底部大圆角
            return UnevenRoundedRectangle(topLeadingRadius: 2, bottomLeadingRadius: r.width * 0.22,
                                          bottomTrailingRadius: r.width * 0.22, topTrailingRadius: 2,
                                          style: .continuous).path(in: r)
        case .mug:
            // 杯身占左边 76%，右边留给把手
            let body = CGRect(x: r.minX, y: r.minY + r.height * 0.08, width: r.width * 0.76, height: r.height * 0.92)
            return UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: body.width * 0.2,
                                          bottomTrailingRadius: body.width * 0.2, topTrailingRadius: 3,
                                          style: .continuous).path(in: body)
        case .bottle:
            // 瓶盖口 + 瓶肩 + 圆角瓶身
            let neckW = r.width * 0.42, neckH = r.height * 0.12, shoulder = r.height * 0.24
            let cx = r.midX, radius = r.width * 0.22
            var p = Path()
            p.move(to: CGPoint(x: cx - neckW / 2, y: r.minY))
            p.addLine(to: CGPoint(x: cx + neckW / 2, y: r.minY))
            p.addLine(to: CGPoint(x: cx + neckW / 2, y: r.minY + neckH))
            p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + shoulder), control: CGPoint(x: r.maxX, y: r.minY + neckH))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - radius))
            p.addQuadCurve(to: CGPoint(x: r.maxX - radius, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX + radius, y: r.maxY))
            p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - radius), control: CGPoint(x: r.minX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.minY + shoulder))
            p.addQuadCurve(to: CGPoint(x: cx - neckW / 2, y: r.minY + neckH), control: CGPoint(x: r.minX, y: r.minY + neckH))
            p.closeSubpath()
            return p
        }
    }
}

/// 马克杯把手
struct MugHandle: Shape {
    func path(in r: CGRect) -> Path {
        let x0 = r.minX + r.width * 0.76
        let top = r.minY + r.height * 0.3, bottom = r.minY + r.height * 0.72
        var p = Path()
        p.move(to: CGPoint(x: x0, y: top))
        p.addCurve(to: CGPoint(x: x0, y: bottom),
                   control1: CGPoint(x: r.maxX + r.width * 0.02, y: top - r.height * 0.02),
                   control2: CGPoint(x: r.maxX + r.width * 0.02, y: bottom + r.height * 0.02))
        return p
    }
}

/// 水面：从杯底到 top 的位置，顶上一道水波
struct WaveShape: Shape {
    var top: CGFloat = 0.18
    func path(in r: CGRect) -> Path {
        let y0 = r.minY + r.height * top
        let amp = r.height * 0.035
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: y0))
        let steps = 24
        for s in 0...steps {
            let x = r.minX + r.width * CGFloat(s) / CGFloat(steps)
            let y = y0 + sin(CGFloat(s) / CGFloat(steps) * .pi * 2) * amp
            p.addLine(to: CGPoint(x: x, y: y))
        }
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}
