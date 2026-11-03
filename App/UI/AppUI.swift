import SwiftUI
import UniformTypeIdentifiers
import WidgetKit

// MARK: - 玻璃风格公共部件

/// 深色底 + 几团柔和的彩色光晕，玻璃卡片放在上面能透出颜色
struct AppBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.04, green: 0.06, blue: 0.14), Color(red: 0.01, green: 0.01, blue: 0.05)],
                           startPoint: .top, endPoint: .bottom)
            Circle().fill(Color(red: 0.15, green: 0.75, blue: 0.75).opacity(0.45))
                .frame(width: 340).blur(radius: 90).offset(x: -140, y: -320)
            Circle().fill(Color(red: 0.35, green: 0.35, blue: 0.95).opacity(0.45))
                .frame(width: 380).blur(radius: 110).offset(x: 160, y: -60)
            Circle().fill(Color(red: 0.95, green: 0.35, blue: 0.50).opacity(0.28))
                .frame(width: 320).blur(radius: 110).offset(x: -110, y: 330)
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// 玻璃卡片：iOS 26 起用系统的液态玻璃，旧系统用毛玻璃
    @ViewBuilder
    func glassCard(_ radius: CGFloat = 24) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            self
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(.white.opacity(0.14), lineWidth: 0.8))
        }
    }

    /// 玻璃按钮
    @ViewBuilder
    func glassButton() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }

    /// 列表页统一外观：隐藏默认底色，换成光晕背景
    func glassList() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(AppBackground())
    }
}

/// 每页顶部统一的标题（大标题 + 一行小字），四个页面左右滑动时上下对齐
struct PageHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 34, weight: .bold))
            Text(subtitle).font(.subheadline.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.top, 10)
    }
}

/// 每页统一的容器：同样的边距、同样的起始位置、隐藏系统导航栏
struct PageScroll<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                PageHeader(title: title, subtitle: subtitle)
                content()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .background(AppBackground())
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// 一组玻璃卡片：上面一行小标题，下面一行说明
struct CardSection<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 6)
            }
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard(22)
            if let footer {
                Text(footer).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 6)
            }
        }
    }
}

/// 卡片里面第一行的小标题
struct CardTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.vertical, 10)
    }
}

/// 卡片里两行之间的分隔线
struct RowDivider: View {
    var body: some View { Divider().overlay(Color.white.opacity(0.06)) }
}

/// 列表行的玻璃底
struct GlassRow: View {
    var body: some View {
        Rectangle().fill(.ultraThinMaterial)
    }
}

enum AppColor {
    static let up = Color(red: 0.25, green: 0.88, blue: 0.45)
    static let down = Color(red: 1.0, green: 0.32, blue: 0.32)
    static let deep = Color(red: 0.30, green: 0.36, blue: 0.95)
    static let core = Color(red: 0.25, green: 0.60, blue: 1.0)
    static let rem = Color(red: 0.42, green: 0.86, blue: 1.0)
    static let awake = Color(red: 1.0, green: 0.52, blue: 0.42)
    static let sleep = Color(red: 0.42, green: 0.86, blue: 1.0)
}

// MARK: - 根视图：四个标签页

struct RootView: View {
    @State private var tab = 0
    @Environment(\.scenePhase) private var scenePhase

    private let tabs: [(String, String)] = [
        ("健康", "heart.fill"), ("血糖", "drop.fill"), ("NBA", "basketball.fill"), ("设置", "gearshape.fill")
    ]

    var body: some View {
        // 左右滑动翻页；底部是自己画的玻璃标签栏，点图标也能切换
        TabView(selection: $tab) {
            NavigationStack { HealthHomeView() }.tag(0)
            NavigationStack { GlucoseView() }.tag(1)
            NavigationStack { NBAView() }.tag(2)
            NavigationStack { SettingsView() }.tag(3)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .background(AppBackground())
        .ignoresSafeArea(.container, edges: .bottom)
        .safeAreaInset(edge: .bottom) { tabBar }
        .tint(Color(red: 0.40, green: 0.88, blue: 0.88))
        .preferredColorScheme(.dark)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, AutoBackup.isSet { AutoBackup.run() }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.offset) { i, t in
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { tab = i }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: t.1).font(.system(size: 19, weight: .semibold))
                        Text(t.0).font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(tab == i ? Color(red: 0.40, green: 0.88, blue: 0.88) : Color.white.opacity(0.85))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background {
                        if tab == i {
                            Capsule().fill(Color.white.opacity(0.12))
                                .matchedGeometryEffect(id: "tab", in: tabSpace)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .glassCapsule()
        .padding(.horizontal, 20)
        .padding(.bottom, 2)
    }

    @Namespace private var tabSpace
}

extension View {
    /// 胶囊形玻璃（底部标签栏用）
    @ViewBuilder
    func glassCapsule() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: Capsule())
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 0.8))
        }
    }
}

// MARK: - 健康首页

struct HealthHomeView: View {
    @State private var health = HealthSnapshot()
    @State private var prevSleep: HealthService.SleepData?
    @State private var message: String?
    @State private var photo: UIImage?

    var body: some View {
        PageScroll(title: "阿波", subtitle: todayText) {
                detailLink(.sleep) { sleepCard }

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible())], spacing: 14) {
                    detailLink(.weight) { weightCard }
                    detailLink(.hrv) { hrvCard }
                    detailLink(.steps) { stepsCard }
                    sunCard
                }

                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .glassCard(18)
                }

                Button {
                    Task { await authorizeAndLoad() }
                } label: {
                    Label("授权 / 刷新健康数据", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
                .glassButton()
                .padding(.top, 4)
        }
        .refreshable { await load() }
        .task { await authorizeAndLoad() }
    }

    /// 点卡片进详情页（最近 7 / 30 天）
    private func detailLink<C: View>(_ kind: HealthDetailKind, @ViewBuilder _ content: () -> C) -> some View {
        NavigationLink {
            HealthDetailView(kind: kind)
        } label: {
            content()
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.35))
                        .padding(14)
                }
        }
        .buttonStyle(.plain)
    }

    // 睡眠大卡片
    private var sleepCard: some View {
        let s = health.sleep
        let delta: TimeInterval? = {
            guard let a = s?.asleep, let b = prevSleep?.asleep else { return nil }
            return a - b
        }()
        let color: Color = {
            guard let d = delta, abs(d) >= 60 else { return .primary }
            return d > 0 ? AppColor.up : AppColor.down
        }()
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                StageRing(sleep: s, photo: photo, size: 92)
                VStack(alignment: .leading, spacing: 4) {
                    Label("睡眠", systemImage: "bed.double.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppColor.sleep)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(s.map { HealthFormat.duration($0.asleep) } ?? "--")
                            .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(color)
                        if let d = delta, abs(d) >= 60 {
                            Image(systemName: d > 0 ? "arrow.up" : "arrow.down")
                                .font(.headline.weight(.heavy))
                                .foregroundStyle(color)
                        }
                    }
                    if let b = s?.bedtime, let w = s?.wake {
                        Text(HealthFormat.time(b) + " – " + HealthFormat.time(w))
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            if let s {
                HStack(spacing: 8) {
                    stageChip("深睡", s.deep, AppColor.deep)
                    stageChip("核心", s.core, AppColor.core)
                    stageChip("眼动", s.rem, AppColor.rem)
                    stageChip("清醒", s.awake, AppColor.awake)
                }
            }
        }
        .padding(18)
        .glassCard(28)
    }

    private func stageChip(_ name: String, _ t: TimeInterval, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Circle().fill(c).frame(width: 7, height: 7)
                Text(name).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            }
            Text(HealthFormat.clock(t))
                .font(.system(size: 16, weight: .semibold, design: .rounded).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(c.opacity(0.12)))
    }

    // 四张小卡片
    private var weightCard: some View {
        let w = health.weight
        let d = w.flatMap { w in w.previousKg.map { w.kg - $0 } }
        return MetricCard(icon: "figure", colors: (Color(red: 0.80, green: 0.55, blue: 1.0), Color(red: 0.55, green: 0.32, blue: 0.95)),
                          title: "体重", value: w.map { HealthFormat.kg($0.kg) } ?? "--", unit: "公斤",
                          delta: d, deltaText: d.map { String(format: "%.2f", abs($0)) }, threshold: 0.005,
                          sub: "比前一次")
    }

    private var hrvCard: some View {
        let h = health.hrv
        let d = h.flatMap { h in h.previous.map { h.ms - $0 } }
        return MetricCard(icon: "waveform.path.ecg", colors: (Color(red: 1.0, green: 0.45, blue: 0.55), Color(red: 0.95, green: 0.22, blue: 0.42)),
                          title: "恢复HRV", value: h.map { String(Int($0.ms.rounded())) } ?? "--", unit: "毫秒",
                          delta: d, deltaText: d.map { String(Int(abs($0).rounded())) }, threshold: 0.5,
                          sub: h?.previous.map { "前晚 \(Int($0.rounded()))" } ?? "昨晚平均")
    }

    private var stepsCard: some View {
        MetricCard(icon: "figure.walk", colors: (Color(red: 1.0, green: 0.72, blue: 0.25), Color(red: 1.0, green: 0.45, blue: 0.18)),
                   title: "今日步数", value: health.steps.map { $0.formatted() } ?? "--", unit: "步",
                   delta: nil, deltaText: nil, threshold: 0, sub: "iPhone + 手表")
    }

    private var sunCard: some View {
        let t = SunTimes.times()
        return MetricCard(icon: "sun.horizon.fill", colors: (Color(red: 1.0, green: 0.86, blue: 0.30), Color(red: 1.0, green: 0.55, blue: 0.15)),
                          title: "日出", value: t.map { HealthFormat.time($0.sunrise) } ?? "--", unit: "",
                          delta: nil, deltaText: nil, threshold: 0,
                          sub: t.map { "日落 " + HealthFormat.time($0.sunset) } ?? " ")
    }

    private var todayText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 EEEE"
        return f.string(from: Date())
    }

    // 读取

    private func authorizeAndLoad() async {
        message = await HealthService.requestAccess()
        await load()
    }

    private func load() async {
        var h = HealthSnapshot()
        var errors: [String] = []
        do { h.sleep = try await HealthService.lastNightSleep() } catch { errors.append("睡眠：" + HealthService.describe(error)) }
        prevSleep = try? await HealthService.lastNightSleep(nightsAgo: 1)
        do { h.weight = try await HealthService.latestWeight() } catch { errors.append("体重：" + HealthService.describe(error)) }
        do { h.hrv = try await HealthService.recentHRV(sleep: h.sleep, prevSleep: prevSleep) } catch { errors.append("HRV：" + HealthService.describe(error)) }
        do { h.steps = try await HealthService.todaySteps() } catch { errors.append("步数：" + HealthService.describe(error)) }
        health = h
        photo = IconStore.image(for: .sleep)
        if message == nil, !errors.isEmpty { message = errors.joined(separator: "\n") }
        WidgetCenter.shared.reloadAllTimelines()
    }
}

/// 首页的小卡片
struct MetricCard: View {
    let icon: String
    let colors: (Color, Color)
    let title: String
    let value: String
    let unit: String
    let delta: Double?
    let deltaText: String?
    let threshold: Double
    let sub: String

    private var trendColor: Color? {
        guard let d = delta, abs(d) >= threshold else { return nil }
        return d > 0 ? AppColor.up : AppColor.down
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(LinearGradient(colors: [colors.0, colors.1], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: icon).font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                }
                .frame(width: 30, height: 30)
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(trendColor ?? colors.0)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(trendColor ?? .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if !unit.isEmpty && value != "--" {
                    Text(unit).font(.caption.weight(.semibold)).foregroundStyle((trendColor ?? colors.0).opacity(0.85))
                }
            }
            HStack(spacing: 4) {
                if let d = delta, let t = deltaText, abs(d) >= threshold {
                    Label(t, systemImage: d > 0 ? "arrow.up" : "arrow.down")
                        .labelStyle(.titleAndIcon)
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(d > 0 ? AppColor.up : AppColor.down)
                }
                Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard(24)
    }
}

/// App 里用的睡眠圆环：按深睡 / 核心 / 快速眼动比例分段，中间放头像或小时数
struct StageRing: View {
    let sleep: HealthService.SleepData?
    let photo: UIImage?
    let size: CGFloat

    var body: some View {
        let lw = size * 0.13
        let parts: [(Double, Color)] = {
            guard let s = sleep else { return [] }
            let list = [(s.deep, AppColor.deep), (s.core, AppColor.core), (s.rem, AppColor.rem), (s.other, AppColor.core)]
                .filter { $0.0 > 0 }
            let total = list.reduce(0) { $0 + $1.0 }
            return total > 0 ? list.map { ($0.0 / total, $0.1) } : []
        }()
        let gap = parts.count > 1 ? 0.025 : 0
        ZStack {
            Circle().stroke(Color.white.opacity(0.12), lineWidth: lw)
            ForEach(Array(parts.enumerated()), id: \.offset) { i, p in
                let start = parts.prefix(i).reduce(0) { $0 + $1.0 }
                Circle()
                    .trim(from: start + gap / 2, to: max(start + gap / 2, start + p.0 - gap / 2))
                    .stroke(p.1, style: StrokeStyle(lineWidth: lw, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: p.1.opacity(0.6), radius: 6)
            }
            if let photo {
                Image(uiImage: photo).resizable().scaledToFill()
                    .frame(width: size - lw * 1.6, height: size - lw * 1.6)
                    .clipShape(Circle())
            } else if let s = sleep {
                Text(String(format: "%.1f", s.asleep / 3600))
                    .font(.system(size: size * 0.24, weight: .bold, design: .rounded).monospacedDigit())
            }
        }
        .frame(width: size, height: size)
        .padding(lw / 2)
    }
}

// MARK: - NBA


struct NBAView: View {
    @State private var today: [Game] = []
    @State private var tomorrow: [Game] = []
    @State private var loading = false
    @State private var errorText: String?
    private let favorites = myTeams

    var body: some View {
        PageScroll(title: "NBA", subtitle: "北京时间 · 湖人、76人排在最前") {
            if let errorText {
                Text(errorText).font(.footnote).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12).glassCard(16)
            }
            // 今天、明天左右并排，装在一张玻璃卡片里
            HStack(alignment: .top, spacing: 8) {
                dayColumn(title: "今天", offset: 0, games: today)
                Rectangle().fill(Color.white.opacity(0.10)).frame(width: 0.6)
                dayColumn(title: "明天", offset: 1, games: tomorrow)
            }
            .padding(12)
            .glassCard(24)
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private func sorted(_ g: [Game]) -> [Game] {
        g.filter { $0.involves(favorites) } + g.filter { !$0.involves(favorites) }
    }

    private func dayColumn(title: String, offset: Int, games: [Game]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(title).font(.system(size: 15, weight: .bold))
                Text(NBAService.dateLabel(NBAService.targetDate(offset: offset), withWeekday: true))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .padding(.bottom, 6)

            if loading && games.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, 8)
            } else if games.isEmpty {
                Text("没有比赛").font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 6)
            } else {
                ForEach(Array(sorted(games).enumerated()), id: \.element.id) { i, g in
                    if i > 0 { Divider().overlay(Color.white.opacity(0.06)) }
                    CompactGameRow(game: g, favorites: favorites)
                }
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            async let a = NBAService.fetch(offset: 0)
            async let b = NBAService.fetch(offset: 1)
            today = try await a
            tomorrow = try await b
            errorText = nil
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            errorText = "加载失败：\(error.localizedDescription)"
        }
    }
}

/// 一场比赛一行：客队 · 比分/时间 · 主队（窄列用的小字号）
struct CompactGameRow: View {
    let game: Game
    let favorites: Set<String>
    private let red = Color(red: 1.0, green: 0.30, blue: 0.35)

    var body: some View {
        HStack(spacing: 3) {
            team(game.away, game.awayCode, won: game.state == "post" && game.awayScore > game.homeScore)
                .frame(maxWidth: .infinity, alignment: .trailing)
            VStack(spacing: 0) {
                Text(game.middleText)
                    .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(game.state == "in" ? red : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if game.state == "in" {
                    Text(game.liveText)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(red)
                        .lineLimit(1)
                }
            }
            .frame(width: 58)
            team(game.home, game.homeCode, won: game.state == "post" && game.homeScore > game.awayScore)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 5)
    }

    private func team(_ name: String, _ code: String, won: Bool) -> some View {
        let fav = favorites.contains(code)
        return Text(name)
            .font(.system(size: 12, weight: fav ? .heavy : (won ? .semibold : .regular)))
            .foregroundStyle(fav ? red : (game.state == "post" && !won ? Color.secondary : Color.primary))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
    }
}

// MARK: - 设置

struct SettingsView: View {
    @State private var sleepDebug: [String] = []
    @State private var iconTick = 0

    // 备份
    @State private var exporting = false
    @State private var exportDoc: BackupDocument?
    @State private var importing = false
    @State private var pickFolder = false
    @State private var folderPurpose: FolderPurpose = .cloud
    @State private var setupTarget: AutoBackup.Target?
    @State private var exportFolder: URL?
    enum FolderPurpose { case cloud, local, restore }
    @State private var backupMessage: String?
    @State private var backupTick = 0

    var body: some View {
        PageScroll(title: "设置", subtitle: "备份 · 图标 · 小组件") {
            backupCard

            CardSection(footer: iconStatus) {
                CardTitle("自定义图标")
                ForEach(Array(IconSlot.allCases.enumerated()), id: \.element.id) { i, slot in
                    RowDivider()
                    IconRow(slot: slot) { iconTick += 1 }
                        .padding(.vertical, 8)
                }
            }

            CardSection {
                CardTitle("小组件")
                RowDivider()
                Text("长按桌面空白处 → 编辑 → 添加小组件 → 搜索「阿波」，可以选 NBA、健康和血糖。\n所有小组件点空白处都只刷新，不会打开 App。\n湖人、76人的比赛排在最上面，队名显示为红色。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 10)
            }

            CardSection {
                CardTitle("睡眠明细（排查用）")
                RowDivider()
                if sleepDebug.isEmpty {
                    Button("读取昨晚睡眠明细") { Task { await loadSleepDebug() } }
                        .padding(.vertical, 10)
                } else {
                    ForEach(sleepDebug, id: \.self) { line in
                        Text(line).font(.caption.monospacedDigit()).textSelection(.enabled)
                            .padding(.vertical, 4)
                    }
                    Button("重新读取") { Task { await loadSleepDebug() } }
                        .padding(.vertical, 10)
                }
            }
        }
        .fileExporter(isPresented: $exporting, document: exportDoc, contentType: .json,
                      defaultFilename: GlucoseBackup.fileName) { result in
            switch result {
            case .success: backupMessage = "已导出备份文件"
            case .failure(let e): backupMessage = "导出失败：\(e.localizedDescription)"
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                let ok = url.startAccessingSecurityScopedResource()
                defer { if ok { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    backupMessage = try GlucoseBackup.restore(data)
                } catch {
                    backupMessage = "导入失败：\(error.localizedDescription)"
                }
            case .failure(let e):
                backupMessage = "导入失败：\(e.localizedDescription)"
            }
        }
        .confirmationDialog(setupTarget.map { "设置\($0.title)" } ?? "", isPresented: Binding(
            get: { setupTarget != nil }, set: { if !$0 { setupTarget = nil } }), titleVisibility: .visible) {
            if let t = setupTarget {
                Button("新建备份文件夹（推荐）") {
                    folderPurpose = t == .cloud ? .cloud : .local
                    if let dir = AutoBackup.prepareFolder() {
                        exportFolder = dir
                    } else {
                        backupMessage = "准备备份文件夹失败"
                    }
                }
                Button("选择已有的文件夹") {
                    folderPurpose = t == .cloud ? .cloud : .local
                    pickFolder = true
                }
                if AutoBackup.isSet(t) {
                    Button("停用\(t.title)", role: .destructive) {
                        AutoBackup.clear(t)
                        backupTick += 1
                    }
                }
            }
        } message: {
            Text(setupTarget == .cloud
                 ? "新建：接下来在「移动到」里选「iCloud 云盘」，点右上角「移动」。"
                 : "新建：接下来在「移动到」里选「我的 iPhone」，点右上角「移动」。")
        }
        .sheet(isPresented: Binding(get: { exportFolder != nil }, set: { if !$0 { exportFolder = nil } })) {
            if let dir = exportFolder {
                // 系统的「移动到…」：把建好的「阿波备份」文件夹放到用户选的位置，返回新位置
                FolderExporter(url: dir) { url in
                    exportFolder = nil
                    handleFolder(url)
                } onCancel: {
                    exportFolder = nil
                }
                .ignoresSafeArea()
            }
        }
        .sheet(isPresented: $pickFolder) {
            // 用系统原生的文件夹选择器（和上面的 fileImporter 分开，避免两个选择器冲突收不到结果）
            FolderPicker { url in
                pickFolder = false
                handleFolder(url)
            } onCancel: {
                pickFolder = false
            }
            .ignoresSafeArea()
        }
    }

    private func handleFolder(_ url: URL) {
        do {
            switch folderPurpose {
            case .cloud:
                try AutoBackup.setFolder(url, for: .cloud)
                backupMessage = AutoBackup.run()
            case .local:
                try AutoBackup.setFolder(url, for: .local)
                backupMessage = AutoBackup.run()
            case .restore:
                backupMessage = try AutoBackup.restore(from: url)
            }
        } catch {
            backupMessage = "失败：\(error.localizedDescription)"
        }
        backupTick += 1
    }

    private var backupCard: some View {
        let _ = backupTick
        return CardSection(footer: "两个位置都设上最稳：iCloud 防手机丢了坏了，本机防没网或 iCloud 满了。数据一有变化、App 退到后台都会自动备份；照片只备份新增的。删 App、掉签、换手机后，用「从备份文件夹恢复」选同一个文件夹即可。") {
            CardTitle("数据备份")
            ForEach(AutoBackup.Target.allCases, id: \.self) { t in
                RowDivider()
                Button {
                    setupTarget = t
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: t == .cloud ? "icloud.fill" : "iphone")
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.title).font(.body.weight(.semibold))
                            Text(AutoBackup.statusText(t)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        Image(systemName: AutoBackup.isSet(t) ? "checkmark.circle.fill" : "chevron.right")
                            .foregroundStyle(AutoBackup.isSet(t) ? Color.green : Color.secondary)
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if AutoBackup.isSet {
                RowDivider()
                Button {
                    backupMessage = AutoBackup.run()
                    backupTick += 1
                } label: {
                    Label("立即备份", systemImage: "arrow.triangle.2.circlepath").padding(.vertical, 10)
                }
            }
            RowDivider()
            Button {
                folderPurpose = .restore
                pickFolder = true
            } label: {
                Label("从备份文件夹恢复", systemImage: "arrow.uturn.backward.circle").padding(.vertical, 10)
            }
            RowDivider()
            Button {
                exportDoc = GlucoseBackup.make().map(BackupDocument.init(data:))
                exporting = exportDoc != nil
                if exportDoc == nil { backupMessage = "生成备份失败" }
            } label: {
                Label("导出单个备份文件（含照片，可发微信）", systemImage: "square.and.arrow.up").padding(.vertical, 10)
            }
            RowDivider()
            Button {
                importing = true
            } label: {
                Label("导入备份文件（.json）", systemImage: "square.and.arrow.down").padding(.vertical, 10)
            }
            if let backupMessage {
                RowDivider()
                Text(backupMessage).font(.footnote).foregroundStyle(.green).padding(.vertical, 8)
            }
        }
    }

    private var iconStatus: String {
        let _ = iconTick
        var t = "点「换照片」从相册选一张，会自动裁成圆形。照片会放进系统相簿「阿波小组件·xx」，小组件从那里读。第一次会请求相册权限，请选「允许完全访问」。"
        t += "\nApp 相册权限：" + IconStore.photoStatusText
        if let ack = IconStore.widgetAck() {
            let names = ack.slots.map(\.title).joined(separator: "、")
            t += "\n小组件 \(ack.time) 读到的自定义图标：" + (names.isEmpty ? "无" : names)
        }
        return t
    }

    private func loadSleepDebug() async {
        do { sleepDebug = try await HealthService.sleepDebug() }
        catch { sleepDebug = ["读取失败：" + HealthService.describe(error)] }
    }
}


/// 系统的文件夹选择器：进入要用的文件夹，点「打开」
struct FolderPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let c = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        c.allowsMultipleSelection = false
        c.delegate = context.coordinator
        return c
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: FolderPicker
        init(_ p: FolderPicker) { parent = p }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let u = urls.first { parent.onPick(u) } else { parent.onCancel() }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCancel()
        }
    }
}


/// 系统的「移动到…」：把一个文件夹移到用户选的位置，返回移动后的地址（App 之后可以继续写这个文件夹）
struct FolderExporter: UIViewControllerRepresentable {
    let url: URL
    let onDone: (URL) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let c = UIDocumentPickerViewController(forExporting: [url], asCopy: false)
        c.delegate = context.coordinator
        return c
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: FolderExporter
        init(_ p: FolderExporter) { parent = p }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let u = urls.first { parent.onDone(u) } else { parent.onCancel() }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCancel()
        }
    }
}
