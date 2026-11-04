import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

// MARK: - 彩票页

struct LotteryView: View {
    @State private var welfare = true
    @State private var data: [LotteryGame: [LotteryDraw]] = Dictionary(uniqueKeysWithValues: LotteryGame.allCases.map { ($0, LotteryAPI.cached($0)) })
    @State private var errors: [LotteryGame: String] = [:]
    @State private var loading = false

    @State private var showCamera = false
    @State private var photoItem: PhotosPickerItem?
    @State private var scanning = false
    @State private var scan: TicketScan?
    @State private var scanImage: UIImage?

    @State private var order: [String] = UserDefaults.standard.stringArray(forKey: "lotteryOrder") ?? LotteryGame.allCases.map(\.rawValue)
    @State private var dragging: LotteryGame?

    /// 按自己排的顺序（长按拖动调整）
    private var games: [LotteryGame] {
        let base = welfare ? LotteryGame.welfare : LotteryGame.sports
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

            Picker("", selection: $welfare) {
                Text("福彩").tag(true)
                Text("体彩").tag(false)
            }
            .pickerStyle(.segmented)

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

            Text("长按卡片可以拖动调整顺序")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)

            Text("数据来自中国福利彩票、中国体育彩票官网，仅供参考，兑奖以彩票站和官方公告为准。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
        }
        .refreshable { await load() }
        .task { await load() }
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
                    scan = TicketScan(game: welfare ? .ssq : .dlt)
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

    private func load() async {
        loading = true
        defer { loading = false }
        await withTaskGroup(of: (LotteryGame, Result<[LotteryDraw], Error>).self) { group in
            for g in LotteryGame.allCases {
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
                Text(game.schedule)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
                    .foregroundStyle(.secondary)
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
                            Text(LotteryFormat.money(d.pool))
                                .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
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
                Text(d.date).font(.caption2).foregroundStyle(.tertiary)
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
    }
}

// MARK: - 开奖历史

struct LotteryHistoryView: View {
    let game: LotteryGame
    @State var draws: [LotteryDraw]
    @State private var open: String?
    @State private var error: String?

    var body: some View {
        PageScroll(title: game.name, subtitle: "近 \(draws.count) 期开奖 · \(game.schedule)开奖") {
            if let error { Text(error).font(.footnote).foregroundStyle(.orange) }
            ForEach(draws) { d in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("第\(d.issue)期").font(.subheadline.weight(.semibold).monospacedDigit())
                        Spacer()
                        Text(d.date).font(.caption).foregroundStyle(.secondary)
                    }
                    LotteryBalls(game: game, front: d.front, back: d.back, size: game == .kl8 ? 24 : 28)
                    if game.hasPool {
                        HStack {
                            Text("奖池 " + LotteryFormat.money(d.pool)).font(.caption.weight(.semibold)).foregroundStyle(.orange)
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

// MARK: - 对奖

struct TicketCheckSheet: View {
    @State var scan: TicketScan
    let image: UIImage?
    @Environment(\.dismiss) private var dismiss

    @State private var betsText = ""
    @State private var draw: LotteryDraw?
    @State private var results: [BetResult] = []
    @State private var message: String?
    @State private var checking = false
    @State private var showRaw = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFit()
                            .frame(maxHeight: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .frame(maxWidth: .infinity)
                    }

                    CardSection(footer: (image == nil ? "" : "识别不一定准，核对一下，有错直接改。") + formatHint) {
                        Picker("玩法", selection: $scan.game) {
                            ForEach(LotteryGame.checkableGames) { Text($0.shortName).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .padding(.vertical, 10)
                        RowDivider()
                        HStack {
                            Text("期号")
                            TextField([.ssq, .kl8].contains(scan.game) ? "如 2026128" : "如 26128", text: $scan.issue)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .font(.body.monospacedDigit())
                        }
                        .padding(.vertical, 10)
                        RowDivider()
                        Stepper("倍数 \(scan.multiple)", value: $scan.multiple, in: 1...99).padding(.vertical, 6)
                        if scan.game == .dlt {
                            RowDivider()
                            Toggle("追加投注", isOn: $scan.added).padding(.vertical, 6)
                        }
                        RowDivider()
                        Text("号码").font(.footnote.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 8)
                        TextEditor(text: $betsText)
                            .font(.body.monospacedDigit())
                            .frame(minHeight: 110)
                            .scrollContentBackground(.hidden)
                            .padding(.bottom, 8)
                    }

                    Button {
                        Task { await check() }
                    } label: {
                        HStack {
                            if checking { ProgressView() }
                            Text("对奖").font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                    }
                    .glassButton()
                    .disabled(checking)

                    if let message {
                        Text(message).font(.footnote).foregroundStyle(.orange)
                    }

                    if let draw { resultView(draw) }

                    if !scan.rawText.isEmpty {
                        DisclosureGroup("识别出的原始文字", isExpanded: $showRaw) {
                            Text(scan.rawText).font(.caption.monospaced()).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.footnote)
                        .padding(.horizontal, 6)
                    }
                }
                .padding(16)
            }
            .navigationTitle("对奖")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            }
            .onAppear {
                betsText = scan.bets.map { $0.text(scan.game) }.joined(separator: "\n")
                if image != nil, !scan.issue.isEmpty, !scan.bets.isEmpty { Task { await check() } }
                else if image != nil { message = scan.bets.isEmpty ? "没认出号码，拍正一点、光线亮一点再试，或者直接手动输入。" : "没认出期号，填一下再点对奖。" }
            }
        }
    }

    private func resultView(_ d: LotteryDraw) -> some View {
        let totalHits = results.flatMap(\.hits)
        let money = totalHits.compactMap(\.total).reduce(0, +)
        let won = !totalHits.isEmpty
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("第\(d.issue)期 开奖号码").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(d.date).font(.caption).foregroundStyle(.secondary)
                }
                LotteryBalls(game: scan.game, front: d.front, back: d.back, size: 30)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading).glassCard(20)

            // 总结
            VStack(spacing: 6) {
                Image(systemName: won ? "party.popper.fill" : "face.dashed")
                    .font(.system(size: 34))
                    .foregroundStyle(won ? Color.orange : Color.secondary)
                Text(won ? "中奖了！" : "这次没中")
                    .font(.title2.weight(.bold))
                if won {
                    Text(totalHits.map { "\($0.name) × \($0.count)" }.joined(separator: "、"))
                        .font(.subheadline).multilineTextAlignment(.center)
                    if money > 0 {
                        Text("约 " + LotteryFormat.yuan(String(format: "%.0f", money)))
                            .font(.title3.weight(.bold).monospacedDigit()).foregroundStyle(.orange)
                    }
                    if scan.added, totalHits.contains(where: { $0.name == "一等奖" || $0.name == "二等奖" }) {
                        Text("追加投注：一、二等奖另加基本奖金的 80%").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(18)
            .glassCard(22)

            ForEach(Array(results.enumerated()), id: \.element.id) { i, r in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("第\(i + 1)注" + (scan.game == .kl8 ? "（选\(r.bet.front.count)）" : "") + (r.combos > 1 ? "（复式 \(r.combos) 注）" : "")).font(.caption.weight(.semibold))
                        Spacer()
                        Text(hitSummary(r)).font(.caption).foregroundStyle(.secondary)
                    }
                    LotteryBalls(game: scan.game,
                                 front: r.bet.frontStrings(scan.game),
                                 back: r.bet.backStrings(scan.game),
                                 size: scan.game == .kl8 ? 26 : 28, hitFront: r.frontHitIdx, hitBack: r.backHitIdx)
                    if r.hits.isEmpty {
                        Text("未中奖").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(r.hits) { h in
                            HStack {
                                Text("\(h.name) × \(h.count)").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                                Spacer()
                                Text(h.total.map { LotteryFormat.yuan(String(format: $0 < 100 && $0 != $0.rounded() ? "%.1f" : "%.0f", $0)) } ?? (scan.game == .kl8 ? "浮动（最高500万）" : "浮动奖金"))
                                    .font(.caption.monospacedDigit())
                            }
                        }
                    }
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading).glassCard(18)
            }
        }
    }

    private var formatHint: String {
        switch scan.game {
        case .ssq: return "每行一注：6 个以上红球 + 1 个以上蓝球，如「01 05 12 18 22 30 + 07」，复式多写几个号码。"
        case .dlt: return "每行一注：5 个以上前区 + 2 个以上后区，如「05 12 18 25 33 + 03 11」，复式多写几个号码。"
        case .kl8: return "每行一注：选几就写几个号码（1~80），如选五「03 18 27 44 69」。"
        case .qxc: return "每行一注：前区 6 位数字 + 后区 1 个号码（0~14），如「3 7 0 5 9 1 + 12」。"
        default: return ""
        }
    }

    private func hitSummary(_ r: BetResult) -> String {
        switch scan.game {
        case .kl8: return "中 \(r.frontHits) 个"
        case .qxc: return "前区对上 \(r.frontHits) 位 · 后区\(r.backHits > 0 ? "中" : "没中")"
        default: return "前区中 \(r.frontHits) · 后区中 \(r.backHits)"
        }
    }

    private func check() async {
        message = nil
        draw = nil
        results = []
        let bets = betsText.split(whereSeparator: \.isNewline).compactMap { LotteryBet.parse(String($0), game: scan.game) }
        let issue = scan.issue.trimmingCharacters(in: .whitespaces)
        guard issue.count >= 5 else { message = "请填期号（双色球、快乐8 是 7 位，如 2026128；大乐透、七星彩 5 位，如 26128）"; return }
        guard !bets.isEmpty else { message = "号码格式不对。" + formatHint; return }
        checking = true
        defer { checking = false }
        do {
            guard let d = try await LotteryAPI.draw(scan.game, issue: issue) else {
                message = "没找到第\(issue)期的开奖结果：可能还没开奖（\(scan.game.name)\(scan.game.schedule)晚上开奖），或者期号认错了。"
                return
            }
            draw = d
            results = bets.map { PrizeCalc.check($0, draw: d, game: scan.game, multiple: scan.multiple) }
        } catch {
            message = "获取开奖结果失败：\(error.localizedDescription)"
        }
    }
}
