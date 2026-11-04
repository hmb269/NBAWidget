import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

// MARK: - 彩票页

struct LotteryView: View {
    @State private var segment = 0          // 0 福彩 1 体彩 2 收藏
    @Environment(\.scenePhase) private var scenePhase
    @State private var data: [LotteryGame: [LotteryDraw]] = Dictionary(uniqueKeysWithValues: LotteryGame.allCases.map { ($0, LotteryAPI.cached($0)) })
    @State private var errors: [LotteryGame: String] = [:]
    @State private var loading = false

    @State private var showCamera = false
    @State private var photoItem: PhotosPickerItem?
    @State private var scanning = false
    @State private var scan: TicketScan?
    @State private var scanImage: UIImage?
    @State private var favCheck: TicketScan?

    @State private var order: [String] = UserDefaults.standard.stringArray(forKey: "lotteryOrder") ?? LotteryGame.allCases.map(\.rawValue)
    @State private var dragging: LotteryGame?

    /// 按自己排的顺序（长按拖动调整）
    private var games: [LotteryGame] {
        let base = segment == 0 ? LotteryGame.welfare : LotteryGame.sports
        return base.sorted { (order.firstIndex(of: $0.rawValue) ?? 99) < (order.firstIndex(of: $1.rawValue) ?? 99) }
    }

    private var todayText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 EEEE"
        return f.string(from: Date())
    }

    var body: some View {
        PageScroll(title: "彩票", subtitle: todayText) {
            checkCard

            Picker("", selection: $segment) {
                Text("福彩").tag(0)
                Text("体彩").tag(1)
                Text("★ 收藏").tag(2)
            }
            .pickerStyle(.segmented)

            if segment == 2 {
                LotteryFavoritesPane(onAdd: { g in
                    scanImage = nil
                    scan = TicketScan(game: g)
                }, onCheck: { g, bets in
                    favCheck = TicketScan(game: g, bets: bets.map { LotteryBet(front: $0.front, back: $0.back, multiple: $0.multiple, pick: $0.pick, added: $0.added) })
                })
            } else {

            ForEach(games) { g in
                NavigationLink {
                    LotteryHistoryView(game: g, draws: data[g] ?? [])
                } label: {
                    LotteryGameCard(game: g, draw: data[g]?.first, error: errors[g])
                }
                .buttonStyle(.plain)
                // 长按拖动排序
                .onDrag {
                    dragging = g
                    return NSItemProvider(object: g.rawValue as NSString)
                }
                .onDrop(of: [.text], delegate: LotteryReorder(target: g, order: $order, dragging: $dragging))
            }

            Text("长按卡片可以拖动调整顺序 · 下拉刷新 · 开奖后会自动刷新")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
            }

            Text("数据来自中国福利彩票、中国体育彩票官网，仅供参考，兑奖以彩票站和官方公告为准。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
        }
        .refreshable { await load() }
        .task {
            await load()
            // 开奖后自动刷新：到了开奖时间、但还没拿到今天这期，就每分钟查一次（最多查 3 小时）
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                let waiting = LotteryGame.allCases.filter { awaiting($0) }
                if !waiting.isEmpty { await load(waiting) }
            }
        }
        .onChange(of: scenePhase) { _, p in
            if p == .active { Task { await load() } }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { img in Task { await read(img) } }
                .ignoresSafeArea()
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let d = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: d) { await read(img) }
                photoItem = nil
            }
        }
        .sheet(isPresented: Binding(get: { scan != nil }, set: { if !$0 { scan = nil } })) {
            if let s = scan {
                TicketCheckSheet(scan: s, image: scanImage)
                    .presentationBackground(.ultraThinMaterial)
            }
        }
        .sheet(isPresented: Binding(get: { favCheck != nil }, set: { if !$0 { favCheck = nil } })) {
            if let s = favCheck {
                TicketCheckSheet(scan: s, image: nil, favMode: true)
                    .presentationBackground(.ultraThinMaterial)
            }
        }
    }

    private var checkCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(LinearGradient(colors: [Color(red: 1, green: 0.35, blue: 0.35), Color(red: 1, green: 0.6, blue: 0.2)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: scanning ? "text.viewfinder" : "camera.viewfinder")
                        .font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                }
                .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text("拍照对奖").font(.title3.weight(.bold))
                    Text(scanning ? "正在识别彩票…" : "拍一下彩票，自动识别期号和号码（双色球、大乐透、快乐8、七星彩）")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if scanning { ProgressView() }
            }
            HStack(spacing: 10) {
                Button {
                    showCamera = true
                } label: {
                    Label("拍照", systemImage: "camera.fill").frame(maxWidth: .infinity)
                }
                .glassButton()
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("相册", systemImage: "photo").frame(maxWidth: .infinity)
                }
                .glassButton()
                Button {
                    scanImage = nil
                    scan = TicketScan(game: segment == 1 ? .dlt : .ssq)
                } label: {
                    Label("手输", systemImage: "keyboard").frame(maxWidth: .infinity)
                }
                .glassButton()
            }
            .font(.subheadline.weight(.semibold))
            .disabled(scanning)
        }
        .padding(18)
        .glassCard(26)
    }

    private func read(_ img: UIImage) async {
        scanning = true
        let s = await TicketReader.scan(img)
        try? await Task.sleep(for: .milliseconds(500))   // 等相机页面关掉再弹出结果
        scanning = false
        scanImage = img
        scan = s
    }

    /// 今天开奖、已过开奖时间、还没拿到今天这期
    private func awaiting(_ g: LotteryGame) -> Bool {
        let now = Date()
        guard g.isDrawDay(now) else { return false }
        let t = g.drawDate(on: now)
        guard now >= t, now < t.addingTimeInterval(3 * 3600) else { return false }
        guard let d = data[g]?.first, d.isToday else { return true }
        // 号码出来了但奖池、奖级还没公布：继续等
        return g.hasPool && ((d.pool ?? 0) <= 0 || d.prizes.isEmpty)
    }

    private func load(_ only: [LotteryGame] = LotteryGame.allCases) async {
        loading = true
        defer { loading = false }
        await withTaskGroup(of: (LotteryGame, Result<[LotteryDraw], Error>).self) { group in
            for g in only {
                group.addTask {
                    do { return (g, .success(try await LotteryAPI.history(g))) } catch { return (g, .failure(error)) }
                }
            }
            for await (g, r) in group {
                switch r {
                case .success(let list): data[g] = list; errors[g] = nil
                case .failure(let e): errors[g] = (data[g]?.isEmpty ?? true) ? e.localizedDescription : "更新失败，显示的是上次的数据"
                }
            }
        }
    }
}

// MARK: - 拖动排序

struct LotteryReorder: DropDelegate {
    let target: LotteryGame
    @Binding var order: [String]
    @Binding var dragging: LotteryGame?

    func dropEntered(info: DropInfo) {
        guard let d = dragging, d != target,
              let from = order.firstIndex(of: d.rawValue), let to = order.firstIndex(of: target.rawValue) else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            order.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
        UserDefaults.standard.set(order, forKey: "lotteryOrder")
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

// MARK: - 号码球

struct LotteryBalls: View {
    let game: LotteryGame
    let front: [String]
    let back: [String]
    var size: CGFloat = 30
    var hitFront: Set<Int>? = nil   // 中了的位置（下标）；nil = 不标中没中
    var hitBack: Set<Int>? = nil

    var body: some View {
        let square = [.d3, .pl3, .pl5, .qxc].contains(game)
        if game == .kl8 && front.count > 10 {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 10), spacing: 5) {
                ForEach(Array(front.enumerated()), id: \.offset) { i, n in
                    ball(n, color: game.frontColor, s: size * 0.82, hit: hitFront.map { $0.contains(i) })
                }
            }
        } else {
            HStack(spacing: 5) {
                ForEach(Array(front.enumerated()), id: \.offset) { i, n in
                    ball(n, color: game.frontColor, s: size, hit: hitFront.map { $0.contains(i) }, square: square)
                }
                if !back.isEmpty {
                    Spacer().frame(width: 2)
                    ForEach(Array(back.enumerated()), id: \.offset) { i, n in
                        ball(n, color: game.backColor, s: size, hit: hitBack.map { $0.contains(i) }, square: square)
                    }
                }
            }
        }
    }

    private func ball(_ n: String, color: Color, s: CGFloat, hit: Bool?, square: Bool = false) -> some View {
        let on = hit ?? true
        return Text(n)
            .font(.system(size: s * 0.46, weight: .bold, design: .rounded).monospacedDigit())
            .foregroundStyle(on ? Color.white : Color.white.opacity(0.55))
            .frame(width: s, height: s)
            .background {
                if square {
                    RoundedRectangle(cornerRadius: s * 0.25, style: .continuous)
                        .fill(on ? AnyShapeStyle(LinearGradient(colors: [color.opacity(0.95), color.opacity(0.7)], startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(Color.white.opacity(0.08)))
                } else {
                    Circle()
                        .fill(on ? AnyShapeStyle(RadialGradient(colors: [color.opacity(1), color.opacity(0.7)], center: UnitPoint(x: 0.35, y: 0.3), startRadius: 1, endRadius: s * 0.7)) : AnyShapeStyle(Color.white.opacity(0.08)))
                }
            }
            .overlay {
                if hit == false {
                    if square {
                        RoundedRectangle(cornerRadius: s * 0.25, style: .continuous).stroke(color.opacity(0.5), lineWidth: 1)
                    } else {
                        Circle().stroke(color.opacity(0.5), lineWidth: 1)
                    }
                }
            }
    }
}

// MARK: - 每个玩法一张卡

struct LotteryGameCard: View {
    let game: LotteryGame
    let draw: LotteryDraw?
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(game.name).font(.headline)
                Spacer()
                if let d = draw {
                    Text("第\(d.issue)期").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }

            if let d = draw {
                LotteryBalls(game: game, front: d.front, back: d.back, size: game == .kl8 ? 26 : 32)

                HStack(alignment: .bottom) {
                    if game.hasPool {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("奖池").font(.caption2).foregroundStyle(.secondary)
                            Text(d.pool.map { $0 > 0 } == true ? LotteryFormat.money(d.pool) : (d.isToday ? "开奖后公布" : "未公布"))
                                .font(.system(size: d.pool.map { $0 > 0 } == true ? 22 : 15, weight: .bold, design: .rounded).monospacedDigit())
                                .foregroundStyle(LinearGradient(colors: [Color(red: 1, green: 0.85, blue: 0.4), Color(red: 1, green: 0.6, blue: 0.25)],
                                                                startPoint: .top, endPoint: .bottom))
                        }
                    }
                    Spacer()
                    if let p = d.prizes.first, game != .kl8 {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text("\(p.name) \(p.count.isEmpty ? "—" : p.count) 注").font(.caption2).foregroundStyle(.secondary)
                            Text(LotteryFormat.yuan(p.amount)).font(.subheadline.weight(.semibold).monospacedDigit())
                        }
                    }
                }
                LotteryDrawStatus(game: game, draw: d)
            } else if let error {
                Text(error).font(.footnote).foregroundStyle(.orange)
            } else {
                HStack { ProgressView(); Text("加载中…").font(.footnote).foregroundStyle(.secondary) }
            }
            if let error, draw != nil {
                Text(error).font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(22)
        // 整张卡片都能点、都能长按拖动（不只是有文字的地方）
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .contentShape(.dragPreview, RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// 卡片底部：这期几点开的 + 下次开奖 / 正在等公布
struct LotteryDrawStatus: View {
    let game: LotteryGame
    let draw: LotteryDraw

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            let now = ctx.date
            let next = game.nextDraw(after: now)
            let todayDraw = game.drawDate(on: now)
            let inWindow = game.isDrawDay(now) && now >= todayDraw && now < todayDraw.addingTimeInterval(3 * 3600)
            let waiting = inWindow && !draw.isToday
            let detailsPending = inWindow && draw.isToday && game.hasPool && ((draw.pool ?? 0) <= 0 || draw.prizes.isEmpty)
            HStack(spacing: 6) {
                Text("\(draw.date) \(game.timeText) 开奖").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                if waiting {
                    ProgressView().controlSize(.mini)
                    Text("今晚已开奖，等官方公布…").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                } else if detailsPending {
                    ProgressView().controlSize(.mini)
                    Text("号码已出，奖池奖金公布中…").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                } else {
                    Text("下次 " + nextText(next, now: now)).font(.caption2.weight(.semibold))
                        .foregroundStyle(Calendar.current.isDate(next, inSameDayAs: now) ? Color.orange : Color.secondary)
                }
            }
        }
    }

    private func nextText(_ d: Date, now: Date) -> String {
        let cal = Calendar.current
        let t = game.timeText
        if cal.isDate(d, inSameDayAs: now) {
            let mins = Int(d.timeIntervalSince(now) / 60)
            if mins < 60 { return "今天 \(t)（还有 \(mins) 分钟）" }
            return "今天 \(t)"
        }
        if cal.isDateInTomorrow(d) { return "明天 \(t)" }
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "EEE"
        return f.string(from: d) + " " + t
    }
}

// MARK: - 开奖历史

struct LotteryHistoryView: View {
    let game: LotteryGame
    @State var draws: [LotteryDraw]
    @State private var open: String?
    @State private var error: String?

    var body: some View {
        PageScroll(title: game.name, subtitle: "近 \(draws.count) 期 · \(game.schedule) 开奖") {
            if let error { Text(error).font(.footnote).foregroundStyle(.orange) }
            ForEach(draws) { d in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("第\(d.issue)期").font(.subheadline.weight(.semibold).monospacedDigit())
                        Spacer()
                        Text(d.date + " " + game.timeText).font(.caption).foregroundStyle(.secondary)
                    }
                    LotteryBalls(game: game, front: d.front, back: d.back, size: game == .kl8 ? 24 : 28)
                    if game.hasPool {
                        HStack {
                            Text("奖池 " + ((d.pool ?? 0) > 0 ? LotteryFormat.money(d.pool) : "未公布")).font(.caption.weight(.semibold)).foregroundStyle(.orange)
                            Spacer()
                            if let s = d.sales { Text("销量 " + LotteryFormat.money(s)).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    if open == d.issue, !d.prizes.isEmpty {
                        VStack(spacing: 6) {
                            if let w = d.winners {
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: "mappin.and.ellipse").font(.caption).foregroundStyle(.orange)
                                    Text("一等奖中奖地：" + w).font(.caption).foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(.bottom, 4)
                            } else if !game.isWelfare {
                                Text("体彩官网的开奖接口不提供中奖地").font(.caption2).foregroundStyle(.tertiary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            ForEach(d.prizes, id: \.self) { p in
                                HStack {
                                    Text(p.name).font(.caption)
                                    Spacer()
                                    Text("\(p.count.isEmpty ? "—" : p.count) 注").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    Text(LotteryFormat.yuan(p.amount)).font(.caption.weight(.semibold).monospacedDigit())
                                        .frame(width: 110, alignment: .trailing)
                                }
                            }
                        }
                        .padding(.top, 4)
                    } else if !d.prizes.isEmpty {
                        Text("点开看各奖级").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard(20)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { open = open == d.issue ? nil : d.issue } }
            }
        }
        .toolbar(.visible, for: .navigationBar)
        .refreshable {
            do { draws = try await LotteryAPI.history(game, count: 50); error = nil }
            catch { self.error = error.localizedDescription }
        }
        .task {
            if draws.count < 50, let list = try? await LotteryAPI.history(game, count: 50) { draws = list }
        }
    }
}

