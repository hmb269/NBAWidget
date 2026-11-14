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
            // 懒加载：屏幕外的卡片（比如很久以前的血糖记录）滑到了才画，切页面不卡
            LazyVStack(spacing: 14) {
                PageHeader(title: title, subtitle: subtitle)
                content()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 110)   // 留出底部标签栏的位置，最后一条不会被挡住
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
        ("健康", "heart.fill"), ("血糖", "drop.fill"), ("彩票", "ticket.fill"), ("NBA", "basketball.fill"), ("设置", "gearshape.fill")
    ]

    var body: some View {
        // 左右滑动翻页；底部是自己画的玻璃标签栏，点图标也能切换
        TabView(selection: $tab) {
            NavigationStack { HealthHomeView() }.tag(0)
            NavigationStack { GlucoseView() }.tag(1)
            // 只有正在看的页面才联网刷新
            NavigationStack { LotteryView(isActive: tab == 2) }.tag(2)
            NavigationStack { NBAView(isActive: tab == 3) }.tag(3)
            NavigationStack { SettingsView() }.tag(4)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .background(AppBackground())
        .ignoresSafeArea(.container, edges: .bottom)
        .safeAreaInset(edge: .bottom) { tabBar }
        .tint(Color(red: 0.40, green: 0.88, blue: 0.88))
        .preferredColorScheme(.dark)
        // 往下滑页面就收起键盘
        .scrollDismissesKeyboard(.interactively)
        // 切到别的页面时收起键盘，不然会一直挡着
        .onChange(of: tab) { _, _ in hideKeyboard() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { AutoBackup.run() }
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

/// 收起键盘（不管是哪个输入框弹出来的）
func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
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

/// 暂时关掉主页面的左右翻页（图表要左右拖动时）：
/// 放在页面背景里，往上找到主页面那个左右翻页的滚动视图，关掉它的滑动；离开页面时恢复。
/// （不能用 .scrollDisabled，它会把页面里的上下滚动也一起关掉）
struct DisableTabPaging: UIViewRepresentable {
    var active: Bool

    final class Finder: UIView {
        weak var pager: UIScrollView?
        var active = false { didSet { apply() } }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if pager == nil {
                var v = superview
                while let s = v {
                    if let sv = s as? UIScrollView, sv.isPagingEnabled { pager = sv; break }
                    v = s.superview
                }
            }
            apply()
        }
        func apply() { pager?.isScrollEnabled = !(active && window != nil) }
        deinit { let p = pager; DispatchQueue.main.async { p?.isScrollEnabled = true } }
    }
    func makeUIView(context: Context) -> Finder {
        let v = Finder()
        v.isUserInteractionEnabled = false
        return v
    }
    func updateUIView(_ uiView: Finder, context: Context) { uiView.active = active }
}

// MARK: - 健康首页

/// 首页卡片（顺序可以自己调）
enum HomeCard: String, CaseIterable, Identifiable {
    case sleep, weight, bmi, hrv, resting, steps, compare
    var id: String { rawValue }
    var wide: Bool { self == .sleep }
    var title: String {
        switch self {
        case .sleep: return "睡眠"
        case .weight: return "体重"
        case .bmi: return "BMI"
        case .hrv: return "恢复 HRV"
        case .resting: return "静息心率"
        case .steps: return "今日步数"
        case .compare: return "趋势对比"
        }
    }
    var icon: String {
        switch self {
        case .sleep: return "bed.double.fill"
        case .weight: return "figure"
        case .bmi: return "person.fill"
        case .hrv: return "waveform.path.ecg"
        case .resting: return "heart.fill"
        case .steps: return "figure.walk"
        case .compare: return "chart.xyaxis.line"
        }
    }
    static var saved: [HomeCard] {
        let s = (UserDefaults.standard.stringArray(forKey: "homeCardOrder") ?? []).compactMap(HomeCard.init(rawValue:))
        return s + allCases.filter { !s.contains($0) }
    }
    static func save(_ list: [HomeCard]) { UserDefaults.standard.set(list.map(\.rawValue), forKey: "homeCardOrder") }
}

struct HealthHomeView: View {
    @State private var health = HealthSnapshot()
    @State private var prevSleep: HealthService.SleepData?
    @State private var message: String?
    @State private var photo: UIImage?
    @State private var bmi: Double?
    @State private var resting: Double?
    @State private var cardOrder: [HomeCard] = HomeCard.saved
    @State private var arranging = false

    /// 把卡片排成一行一行
    private var homeRows: [[HomeCard]] {
        var rows: [[HomeCard]] = []
        var pending: [HomeCard] = []
        for c in cardOrder {
            if c.wide {
                if !pending.isEmpty { rows.append(pending); pending = [] }
                rows.append([c])
            } else {
                pending.append(c)
                if pending.count == 2 { rows.append(pending); pending = [] }
            }
        }
        if !pending.isEmpty { rows.append(pending) }
        return rows
    }

    @ViewBuilder
    private func homeCard(_ c: HomeCard) -> some View {
        switch c {
        case .sleep: detailLink(.sleep) { sleepCard }
        case .weight: detailLink(.weight) { weightCard }
        case .bmi:
            NavigationLink { BMIView() } label: { bmiCard.overlay(alignment: .topTrailing) { chevron } }
                .buttonStyle(.plain)
        case .hrv: detailLink(.hrv) { hrvCard }
        case .resting: restingCard
        case .steps: detailLink(.steps) { stepsCard }
        case .compare:
            NavigationLink { HealthCompareView() } label: { compareCard.overlay(alignment: .topTrailing) { chevron } }
                .buttonStyle(.plain)
        }
    }

    private var arrangeSheet: some View {
        NavigationStack {
            List {
                Section(footer: Text("按住右边的 ≡ 上下拖动。「睡眠」是大卡片，占一整行；其他小卡片两个一行。")) {
                    ForEach(cardOrder) { c in
                        Label(c.title, systemImage: c.icon)
                    }
                    .onMove { from, to in
                        cardOrder.move(fromOffsets: from, toOffset: to)
                        HomeCard.save(cardOrder)
                    }
                }
                Section {
                    Button("恢复默认顺序") {
                        cardOrder = HomeCard.allCases
                        HomeCard.save(cardOrder)
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("调整卡片顺序")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { arranging = false } } }
        }
        .presentationDetents([.medium, .large])
    }

    var body: some View {
        PageScroll(title: "阿波", subtitle: todayText) {
                // 卡片按自己排的顺序：大卡片占一整行，小卡片两个一行
                ForEach(Array(homeRows.enumerated()), id: \.offset) { _, row in
                    if row.count == 1, row[0].wide {
                        homeCard(row[0])
                    } else {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(row) { c in homeCard(c).frame(maxWidth: .infinity) }
                            if row.count == 1 { Color.clear.frame(maxWidth: .infinity) }
                        }
                    }
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

                Button {
                    arranging = true
                } label: {
                    Label("调整卡片顺序", systemImage: "arrow.up.arrow.down")
                        .font(.footnote.weight(.semibold))
                }
                .padding(.top, 2)
        }
        .sheet(isPresented: $arranging) { arrangeSheet }
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

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.bold))
            .foregroundStyle(.white.opacity(0.35))
            .padding(14)
    }

    private var bmiCard: some View {
        let c = bmi.map(BMI.category)
        return MetricCard(icon: "person.fill", colors: (Color(red: 0.35, green: 0.88, blue: 0.55), Color(red: 0.15, green: 0.65, blue: 0.45)),
                          title: "BMI", value: bmi.map { String(format: "%.1f", $0) } ?? "--", unit: c?.0 ?? "",
                          delta: nil, deltaText: nil, threshold: 0,
                          sub: bmi == nil ? "点进去填身高" : "正常 18.5～23.9")
    }

    private var restingCard: some View {
        MetricCard(icon: "heart.fill", colors: (Color(red: 1.0, green: 0.40, blue: 0.40), Color(red: 0.85, green: 0.18, blue: 0.30)),
                   title: "静息心率", value: resting.map { String(Int($0.rounded())) } ?? "--", unit: "次/分",
                   delta: nil, deltaText: nil, threshold: 0, sub: "正常 60～100")
    }

    private var compareCard: some View {
        MetricCard(icon: "chart.xyaxis.line", colors: (Color(red: 0.42, green: 0.86, blue: 1.0), Color(red: 1.0, green: 0.45, blue: 0.55)),
                   title: "趋势对比", value: "9", unit: "项",
                   delta: nil, deltaText: nil, threshold: 0, sub: "睡眠·HRV·血糖…一起看")
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
        if let w = h.weight, let cm = await BMI.height() { bmi = BMI.value(kg: w.kg, cm: cm) }
        resting = await FitnessData.latest(.restingHeartRate, unit: .count().unitDivided(by: .minute()), days: 3)?.0
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


// MARK: - 设置

struct SettingsView: View {
    @State private var sleepDebug: [String] = []
    @State private var iconTick = 0

    // 备份
    @State private var cloudBackup = false
    @State private var importing = false
    @State private var backupMessage: String?
    @State private var backupTick = 0

    var body: some View {
        PageScroll(title: "设置", subtitle: "血糖仪 · 备份 · 图标 · 小组件") {
            GlucoseSyncCard()
            GlucoseMealTimesCard()
            WaterSettingsCard()
            PillSettingsCard()
            RefreshSettingsCard()
            LotteryAISettingsCard()
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
        .cloudBackup(isPresented: $cloudBackup) { msg in
            backupMessage = msg
            backupTick += 1
        }
        .sheet(isPresented: $importing) {
            ImportPicker { url in
                importing = false
                guard let url else { return }
                do {
                    backupMessage = try GlucoseBackup.restore(Data(contentsOf: url)) + "，正在找回原图…"
                    Task {
                        let r = await GlucoseRelink.relink()
                        backupMessage = (backupMessage ?? "").replacingOccurrences(of: "，正在找回原图…", with: "") + "\n" + GlucoseRelink.message(r)
                    }
                } catch {
                    backupMessage = "导入失败：\(error.localizedDescription)"
                }
            }
            .ignoresSafeArea()
        }
    }

    private var backupCard: some View {
        let _ = backupTick
        return CardSection(footer: "本机备份在「文件」App →「我的 iPhone」→「阿波」→「阿波备份」，数据一有变化就自动更新，掉签不影响，但删 App 会一起删掉。所以每隔几天点一下「备份到 iCloud」，存到 iCloud 云盘（第二次起选「替换」）；删 App、换手机后用「导入备份文件」选它恢复。") {
            CardTitle("数据备份")
            RowDivider()
            HStack(spacing: 10) {
                Image(systemName: "iphone").frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("本机自动备份").font(.body.weight(.semibold))
                    Text("上次：" + AutoBackup.ago(AutoBackup.lastLocal)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("立即备份") {
                    backupMessage = AutoBackup.run()
                    backupTick += 1
                }
                .font(.subheadline.weight(.semibold))
            }
            .padding(.vertical, 8)
            RowDivider()
            Button {
                cloudBackup = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "icloud.and.arrow.up.fill").frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("备份到 iCloud").font(.body.weight(.semibold))
                        Text("上次：" + AutoBackup.ago(AutoBackup.lastCloud) + (AutoBackup.cloudOverdue ? " · 该备份了" : ""))
                            .font(.caption)
                            .foregroundStyle(AutoBackup.cloudOverdue ? Color.orange : Color.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            RowDivider()
            Button {
                do { backupMessage = try AutoBackup.restoreLocal() } catch { backupMessage = "恢复失败：\(error.localizedDescription)" }
            } label: {
                Label("从本机备份恢复", systemImage: "arrow.uturn.backward.circle").padding(.vertical, 10)
            }
            RowDivider()
            Button {
                importing = true
            } label: {
                Label("导入备份文件（选「阿波备份-完整.json」）", systemImage: "square.and.arrow.down").padding(.vertical, 10)
            }
            RowDivider()
            Button {
                backupMessage = "正在找回原图…"
                Task { backupMessage = GlucoseRelink.message(await GlucoseRelink.relink()) }
            } label: {
                Label("重新关联原图（换手机、照片传过来后用）", systemImage: "photo.badge.checkmark").padding(.vertical, 10)
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


