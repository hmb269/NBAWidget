import SwiftUI
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
    var body: some View {
        TabView {
            NavigationStack { HealthHomeView() }
                .tabItem { Label("健康", systemImage: "heart.fill") }
            NavigationStack { GlucoseView() }
                .tabItem { Label("血糖", systemImage: "drop.fill") }
            NavigationStack { NBAView() }
                .tabItem { Label("NBA", systemImage: "basketball.fill") }
            NavigationStack { SettingsView() }
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
        }
        .tint(Color(red: 0.40, green: 0.88, blue: 0.88))
        .preferredColorScheme(.dark)
    }
}

// MARK: - 健康首页

struct HealthHomeView: View {
    @State private var health = HealthSnapshot()
    @State private var prevSleep: HealthService.SleepData?
    @State private var message: String?
    @State private var photo: UIImage?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                HStack {
                    Text(todayText).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 4)

                sleepCard

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible())], spacing: 14) {
                    weightCard
                    hrvCard
                    stepsCard
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
            .padding(16)
        }
        .background(AppBackground())
        .navigationTitle("阿波")
        .refreshable { await load() }
        .task { await authorizeAndLoad() }
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
    @State private var day = 0
    @State private var games: [Game] = []
    @State private var loading = false
    @State private var errorText: String?
    private let favorites = myTeams

    private var sortedGames: [Game] {
        games.filter { $0.involves(favorites) } + games.filter { !$0.involves(favorites) }
    }

    var body: some View {
        List {
            Section {
                Picker("日期", selection: $day) {
                    Text("今天").tag(0)
                    Text("明天").tag(1)
                }
                .pickerStyle(.segmented)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            Section(header: Text(NBAService.dateLabel(NBAService.targetDate(offset: day), withWeekday: true) + "（北京时间）")) {
                if loading && games.isEmpty {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if let errorText {
                    Text(errorText).foregroundStyle(.secondary)
                } else if games.isEmpty {
                    Text(day == 0 ? "今天没有比赛" : "明天没有比赛").foregroundStyle(.secondary)
                } else {
                    ForEach(sortedGames) { g in
                        AppGameRow(game: g, favorites: favorites)
                    }
                }
            }
            .listRowBackground(GlassRow())
        }
        .glassList()
        .navigationTitle("NBA 赛程")
        .refreshable { await load() }
        .task(id: day) { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            games = try await NBAService.fetch(offset: day)
            errorText = nil
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            errorText = "加载失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 设置

struct SettingsView: View {
    @State private var sleepDebug: [String] = []
    @State private var iconTick = 0

    var body: some View {
        List {
            Section(header: Text("自定义图标"), footer: Text(iconStatus).font(.footnote)) {
                ForEach(IconSlot.allCases) { slot in
                    IconRow(slot: slot) { iconTick += 1 }
                }
            }
            .listRowBackground(GlassRow())

            Section(header: Text("小组件")) {
                Text("长按桌面空白处 → 编辑 → 添加小组件 → 搜索「阿波」，可以选「今日 NBA」「明日 NBA」和「健康」（小 / 中 / 大）。\n健康小组件点一下刷新；NBA 小组件多页时点一下翻页，只有一页时刷新。\n湖人、76人的比赛排在最上面，队名显示为红色。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(GlassRow())

            Section(header: Text("睡眠明细（排查用）")) {
                if sleepDebug.isEmpty {
                    Button("读取昨晚睡眠明细") { Task { await loadSleepDebug() } }
                } else {
                    ForEach(sleepDebug, id: \.self) { line in
                        Text(line).font(.caption.monospacedDigit()).textSelection(.enabled)
                    }
                    Button("重新读取") { Task { await loadSleepDebug() } }
                }
            }
            .listRowBackground(GlassRow())
        }
        .glassList()
        .navigationTitle("设置")
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
