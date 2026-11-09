import SwiftUI

// MARK: - 对奖页：选号（点球）+ 多期 + 结果

struct TicketCheckSheet: View {
    @State var scan: TicketScan
    let image: UIImage?
    /// 从收藏点进来：号码已定，只选期号对奖（不显示选号面板）
    var favMode = false
    /// 识别失败时「重新拍照」
    var onRetake: (() -> Void)? = nil
    /// 查一注号码历史上中过什么奖（不选期号，查很多期）
    var historyMode = false
    /// 从「我的彩票」打开：期号、倍数、号码都按票上的，不能改，也不会再存一张
    var ticketID: String? = nil
    private var locked: Bool { ticketID != nil }
    /// 这张照片已经存到「我的彩票」的哪一条（之后改期号只更新这一条，不会多出一张）
    @State private var savedID: String?
    @State private var historyRange = 500
    @State private var history: HistoryResult?
    @State private var historyProgress = 0
    /// 拍照进来默认只看结果；号码认错了点「手动修改」才显示选号面板
    @State private var editing = false
    @State private var multi = false
    private var readOnly: Bool { favMode || (image != nil && !editing) }
    @Environment(\.dismiss) private var dismiss

    // 选号面板
    @State private var pickFront: [Int] = []          // 七星彩：6 位，-1 = 没选
    @State private var pickBack: [Int] = []
    @State private var qxcFront: [Int] = Array(repeating: -1, count: 6)
    @State private var qxcPos = 0
    @State private var issueList: [LotteryDraw] = []
    @State private var favs: [LotteryBet] = []

    @State private var periods: [PeriodResult] = []
    @State private var pending = 0
    @State private var message: String?
    @State private var checking = false
    @State private var showRaw = false
    @State private var openIssue: String?

    struct PeriodResult: Identifiable {
        var id: String { draw.issue }
        let draw: LotteryDraw
        let results: [BetResult]
        var hits: [PrizeHit] { results.flatMap(\.hits) }
        var money: Double { hits.compactMap(\.total).reduce(0, +) }
        var floating: Bool { hits.contains { $0.each == nil } }
    }

    private var g: LotteryGame { scan.game }
    /// 拍照没认出号码：只显示失败提示，不展开选号这些
    private var failed: Bool { image != nil && scan.bets.isEmpty && !editing }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let image {
                        ticketPhoto(image)
                    }

                    if failed {
                        failedCard
                    } else {
                    if historyMode { historySettingsCard } else { settingsCard }
                    if readOnly {
                        favBetsCard
                    } else {
                        pickerCard
                        betsCard
                        favsCard
                    }

                    Button {
                        Task { await check() }
                    } label: {
                        HStack {
                            if checking { ProgressView() }
                            Text(historyMode ? (checking && historyProgress > 0 ? "已取 \(historyProgress) 期开奖…" : "查历史中奖")
                                 : scan.issueTo.isEmpty ? "对奖" : "对奖（多期）").font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                    }
                    .glassButton()
                    .disabled(checking || scan.bets.isEmpty)

                    if let message {
                        Text(message).font(.footnote).foregroundStyle(.orange)
                    }

                    if historyMode, let history { historyView(history) }
                    if !periods.isEmpty || pending > 0 { resultView }

                    // 手输的号码也可以存到「我的彩票」
                    if image == nil, !favMode, !historyMode, !locked, !periods.isEmpty || pending > 0 {
                        Button {
                            savedID = LotteryTickets.upsert(scan, photo: nil, replacing: savedID)
                            message = "已存到「我的彩票」，以后开奖会自动对"
                        } label: {
                            Label("存到我的彩票", systemImage: "ticket")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .glassButton()
                    }

                    // 对完一张接着拍下一张
                    if image != nil, !locked, let onRetake {
                        Button {
                            dismiss()
                            onRetake()
                        } label: {
                            Label("再拍一张", systemImage: "camera.fill")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .glassButton()
                    }
                    }

                    if !scan.aiNote.isEmpty {
                        Text(scan.aiNote).font(.footnote).foregroundStyle(.orange).padding(.horizontal, 6)
                    }

                    if !scan.rawText.isEmpty {
                        DisclosureGroup("识别出的原始文字" + (scan.engine.isEmpty ? "" : "（\(scan.engine)）"), isExpanded: $showRaw) {
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
            .navigationTitle(historyMode ? "历史中奖查询" : "对奖")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            }
            .onAppear {
                if image != nil, !scan.issue.isEmpty, !scan.bets.isEmpty { /* 期号校正后在 loadIssues 里对奖 */ }
                else if image != nil {
                    message = scan.bets.isEmpty ? nil : "没认出期号，填一下再点对奖。"
                }
            }
            .onChange(of: scan.game) { old, new in
                if old != new {
                    clearPicker(); scan.bets = []; periods = []; pending = 0; history = nil
                    scan.issue = ""; scan.issueTo = ""
                    Task { await loadIssues() }
                }
            }
            .task {
                multi = !scan.issueTo.isEmpty
                await loadIssues()
            }
            .onChange(of: scan.issue) { _, _ in
                // 收藏对奖：滚轮一停就自动对
                if readOnly && !issueList.isEmpty { Task { await check() } }
            }
            .onChange(of: scan.issueTo) { _, _ in
                if readOnly && multi && !issueList.isEmpty { Task { await check() } }
            }
        }
    }

    // MARK: 识别失败

    private var failedCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.orange)
            Text("没认出号码").font(.title3.weight(.bold))
            Text("把彩票放平、拍正，号码那一块别反光，再拍一次试试。")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                if let onRetake {
                    Button {
                        dismiss()
                        onRetake()
                    } label: {
                        Label("重新拍照", systemImage: "camera.fill").frame(maxWidth: .infinity)
                    }
                    .glassButton()
                }
                Button {
                    withAnimation { editing = true; message = nil }
                } label: {
                    Label("手动输入", systemImage: "hand.tap").frame(maxWidth: .infinity)
                }
                .glassButton()
            }
            .font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .glassCard(24)
    }

    // MARK: 彩票照片 + 中奖印章

    private var wonPeriods: [PeriodResult] { periods.filter { !$0.hits.isEmpty } }

    private func ticketPhoto(_ image: UIImage) -> some View {
        let won = !wonPeriods.isEmpty
        let money = periods.map(\.money).reduce(0, +)
        let floating = periods.contains(where: \.floating)
        return VStack(spacing: 10) {
            ZStack {
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                if !periods.isEmpty {
                    TicketStamp(won: won)
                        .transition(.scale(scale: 2.2).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity)
            .animation(.spring(response: 0.35, dampingFraction: 0.55), value: periods.isEmpty)

            if won {
                VStack(spacing: 4) {
                    Text(money > 0 ? "奖金约 " + LotteryFormat.yuan(String(format: "%.0f", money)) + (floating ? " + 浮动奖" : "") : "浮动奖金，以公告为准")
                        .font(.title3.weight(.bold).monospacedDigit())
                        .foregroundStyle(.orange)
                    if wonPeriods.count > 1 || periods.count > 1 {
                        Text("\(periods.count) 期里中了 \(wonPeriods.count) 期").font(.caption).foregroundStyle(.secondary)
                    }
                    if let first = wonPeriods.first, let c = Self.claimText(first.draw) {
                        Label((wonPeriods.count > 1 ? "最早一期" : "") + c.0, systemImage: "calendar.badge.clock")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(c.1 ? Color.red : Color.green)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: 玩法、期号、倍数

    private var settingsCard: some View {
        CardSection {
            if locked { lockedSettings } else {
            if readOnly {
                HStack {
                    Text(g.name).font(.headline)
                    Spacer()
                    Text(favMode ? "选期号就自动对奖" : "拍照识别 · 选期号自动对奖").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 10)
            } else {
                Picker("玩法", selection: $scan.game) {
                    ForEach(LotteryGame.checkableGames) { Text($0.shortName).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.vertical, 10)
            }
            RowDivider()
            // 期号：滚轮选（默认最近开奖的一期）；多期票打开开关，选开始期和结束期
            Toggle(isOn: $multi.animation()) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("多期票")
                    Text(multi ? "选开始期和结束期" : "只对一期").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
            .onChange(of: multi) { _, on in
                if on {
                    if scan.issueTo.isEmpty { scan.issueTo = scan.issue }
                } else {
                    scan.issueTo = ""
                }
            }
            RowDivider()
            if issueOptions.isEmpty {
                HStack(spacing: 8) {
                    Text(multi ? "从" : "期号")
                    Spacer()
                    issueField($scan.issue)
                    if multi {
                        Text("到").foregroundStyle(.secondary)
                        issueField($scan.issueTo)
                    }
                }
                .padding(.vertical, 8)
            } else if multi {
                HStack(spacing: 4) {
                    issueWheel("开始期", $scan.issue)
                    Text("到").foregroundStyle(.secondary)
                    issueWheel("结束期", $scan.issueTo)
                }
                .padding(.vertical, 4)
            } else {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("期号")
                        Text(dateOf(scan.issue)).font(.caption2).foregroundStyle(issueList.contains { $0.issue == scan.issue } ? Color.secondary : Color.orange)
                    }
                    Spacer()
                    issueWheel(nil, $scan.issue).frame(width: 180)
                }
                .padding(.vertical, 4)
            }
            RowDivider()
            if !favMode {
                Stepper("倍数 \(scan.multiple)", value: $scan.multiple, in: 1...99).padding(.vertical, 6)
            }
            if g == .dlt {
                RowDivider()
                Toggle("追加投注", isOn: $scan.added).padding(.vertical, 6)
            }
            }
        }
    }

    /// 「我的彩票」里的票：只显示，不能改
    @ViewBuilder
    private var lockedSettings: some View {
        HStack {
            Text(g.name).font(.headline)
            Spacer()
            Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
            Text("按票面").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 10)
        RowDivider()
        HStack {
            Text("期号")
            Spacer()
            Text(scan.issueTo.isEmpty || scan.issueTo == scan.issue ? "第\(scan.issue)期" : "第\(scan.issue)~\(scan.issueTo)期")
                .font(.body.weight(.semibold).monospacedDigit())
        }
        .padding(.vertical, 10)
        RowDivider()
        HStack {
            Text("倍数")
            Spacer()
            Text("\(scan.multiple) 倍" + (g == .dlt && scan.added ? " · 追加" : "")).font(.body.weight(.semibold))
        }
        .padding(.vertical, 10)
    }

    /// 滚轮里的期号：接下来没开的 5 期 + 最近开奖的 100 期（新的在上），拍照认出的期号不在里面就加进去
    private var issueOptions: [String] {
        var list = issueList.map(\.issue)
        if let latest = list.first, let n = Int(latest) {
            let future = (1...5).reversed().map { String(n + $0) }
            list = future + list
        }
        for i in [scan.issue, scan.issueTo] where !i.isEmpty && !list.contains(i) { list.insert(i, at: 0) }
        return list
    }

    private func dateOf(_ issue: String) -> String {
        if let d = issueList.first(where: { $0.issue == issue }) { return d.date }
        return issue.isEmpty ? "" : "还没开奖"
    }

    private func issueWheel(_ title: String?, _ sel: Binding<String>) -> some View {
        VStack(spacing: 0) {
            if let title { Text(title).font(.caption2).foregroundStyle(.secondary) }
            Picker(title ?? "期号", selection: sel) {
                ForEach(issueOptions, id: \.self) { i in
                    let open = issueList.contains { $0.issue == i }
                    Text(open ? i : i + " 未开").font(.callout.monospacedDigit()).tag(i)
                }
            }
            .pickerStyle(.wheel)
            .frame(height: 100)
            .clipped()
            if title != nil {
                Text(dateOf(sel.wrappedValue)).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func issueField(_ b: Binding<String>) -> some View {
        TextField([.ssq, .kl8].contains(g) ? "2026120" : "26120", text: b)
            .keyboardType(.numberPad)
            .multilineTextAlignment(.center)
            .font(.body.monospacedDigit())
            .frame(width: 100)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
    }

    /// 拍照认出的期号可能少一位（「2026288」认成「202628」）：
    /// 先按票上印的开奖日期找那一期；找不到再按「数字顺序都对得上」找最接近的期号
    @discardableResult
    private func correctIssue() -> String? {
        guard image != nil, !issueList.isEmpty else { return nil }
        let ocr = scan.issue
        var fixed: String?
        if !scan.drawDate.isEmpty, let d = issueList.first(where: { $0.date.hasPrefix(scan.drawDate) }) {
            fixed = d.issue
        } else if !ocr.isEmpty, !issueList.contains(where: { $0.issue == ocr }) {
            let isSub = { (a: String, b: String) -> Bool in   // a 是不是 b 的子序列
                var it = b.makeIterator()
                return a.allSatisfy { c in while let x = it.next() { if x == c { return true } }; return false }
            }
            fixed = issueOptions.first { $0.count != ocr.count && isSub(ocr, $0) }
        }
        guard let f = fixed, f != ocr else { return nil }
        // 多期票：结束期按同样的偏移一起改
        if !scan.issueTo.isEmpty, let a = Int(ocr), let b = Int(scan.issueTo), let nf = Int(f), a.description.count == f.count {
            scan.issueTo = String(nf + (b - a))
        }
        scan.issue = f
        return f
    }

    private func loadIssues() async {
        let game = g
        var list = LotteryAPI.cached(game)
        if list.count < 100, let fresh = try? await LotteryAPI.history(game, count: 100) { list = fresh }
        guard game == g else { return }
        issueList = list.sorted { (LotteryAPI.issueNumber($0.issue) ?? 0) > (LotteryAPI.issueNumber($1.issue) ?? 0) }
        let fixed = correctIssue()
        if scan.issue.isEmpty, let latest = issueList.first { scan.issue = latest.issue }
        if readOnly && !scan.bets.isEmpty { await check() }
        if let fixed, message == nil { message = "期号已按票上的开奖日期校正为第\(fixed)期" }
        favs = LotteryFavorites.load(game)
    }

    // MARK: 收藏对奖时：只读显示要对的号码

    private var favBetsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(favMode ? "要对的号码（\(scan.bets.count) 注）" : "识别出的号码（\(scan.bets.count) 注）",
                      systemImage: favMode ? "star.fill" : "text.viewfinder")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(favMode ? Color.yellow : Color.primary)
                Spacer()
                if !favMode && !locked {
                    Button("号码不对？手动改") { withAnimation { editing = true } }
                        .font(.caption.weight(.semibold))
                }
            }
            if scan.bets.isEmpty {
                Text("没认出号码").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(scan.bets) { b in
                HStack(spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LotteryBalls(game: g, front: b.frontStrings(g), back: b.backStrings(g), size: 26)
                    }
                    if favMode && b.added {
                        Text("追加").font(.caption2.weight(.bold)).foregroundStyle(.orange)
                    }
                    if favMode && b.multiple > 1 {
                        Text("×\(b.multiple)").font(.caption.weight(.bold).monospacedDigit()).foregroundStyle(.orange)
                    }
                    if !favMode {
                        Button { toggleFav(b) } label: { Image(systemName: isFav(b) ? "star.fill" : "star").font(.title3) }
                            .buttonStyle(.plain).foregroundStyle(isFav(b) ? Color.yellow : Color.secondary)
                    }
                }
            }
            if !favMode && !scan.bets.isEmpty {
                Text("点 ☆ 收藏这注号码，以后在「收藏」里直接对奖").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(22)
    }

    // MARK: 收藏的号码

    private var favsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("收藏的号码", systemImage: "star.fill").font(.subheadline.weight(.semibold)).foregroundStyle(.yellow)
                Spacer()
                if !favs.isEmpty {
                    Button {
                        Task { await checkFavorites() }
                    } label: {
                        Label(historyMode ? "全部查" : "全部对奖", systemImage: "checkmark.seal").font(.caption.weight(.semibold))
                    }
                    .glassButton()
                }
            }
            if favs.isEmpty {
                Text("在「我的号码」里点 ☆ 收藏常买的号码，以后点一下就能对奖。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(favs) { b in
                HStack(spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LotteryBalls(game: g, front: b.frontStrings(g), back: b.backStrings(g), size: 26)
                    }
                    Button {
                        Task { await checkOne(b) }
                    } label: {
                        Text(historyMode ? "查历史" : "对奖").font(.caption.weight(.semibold))
                    }
                    .glassButton()
                    Button {
                        withAnimation { favs.removeAll { $0.id == b.id } }
                        LotteryFavorites.save(favs, for: g)
                    } label: { Image(systemName: "star.slash").font(.callout) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(22)
    }

    private func isFav(_ b: LotteryBet) -> Bool { favs.contains { $0.front == b.front && $0.back == b.back } }

    private func toggleFav(_ b: LotteryBet) {
        withAnimation {
            if isFav(b) { favs.removeAll { $0.front == b.front && $0.back == b.back } }
            else { favs.append(LotteryBet(front: b.front, back: b.back, multiple: max(1, b.multiple * scan.multiple), pick: b.pick, added: b.added || (g == .dlt && scan.added))) }
        }
        LotteryFavorites.save(favs, for: g)
    }

    /// 点收藏里的「对奖」：只用这一注
    private func checkOne(_ b: LotteryBet) async {
        scan.bets = [LotteryBet(front: b.front, back: b.back, multiple: b.multiple, pick: b.pick, added: b.added)]
        await check()
    }

    private func checkFavorites() async {
        scan.bets = favs.map { LotteryBet(front: $0.front, back: $0.back, multiple: $0.multiple, pick: $0.pick, added: $0.added) }
        await check()
    }

    // MARK: 点球选号

    private var pickerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("点选号码").font(.subheadline.weight(.semibold))
                Spacer()
                Text(pickHint).font(.caption).foregroundStyle(pickValid ? Color.green : Color.secondary)
            }
            // 号码多的时候在这块里上下滑动
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 10) {
                    switch g {
                    case .qxc:
                        // 七星彩：先选第几位，再点数字，点完自动跳到下一位
                        HStack(spacing: 6) {
                            ForEach(0..<6, id: \.self) { pos in
                                Button {
                                    qxcPos = pos
                                } label: {
                                    VStack(spacing: 2) {
                                        Text("第\(pos + 1)位").font(.system(size: 10, weight: .medium))
                                        Text(qxcFront[pos] >= 0 ? "\(qxcFront[pos])" : "–")
                                            .font(.system(size: 18, weight: .bold, design: .rounded))
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(qxcPos == pos ? g.frontColor.opacity(0.35) : Color.white.opacity(0.06)))
                                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(qxcPos == pos ? g.frontColor : .clear, lineWidth: 1.5))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        grid(0...9, cols: 5, color: g.frontColor, square: true, selected: qxcFront[qxcPos] >= 0 ? [qxcFront[qxcPos]] : []) { d in
                            qxcFront[qxcPos] = qxcFront[qxcPos] == d ? -1 : d
                            if qxcFront[qxcPos] >= 0, let next = (0..<6).first(where: { qxcFront[$0] < 0 }) { qxcPos = next }
                        }
                        Text("后区").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 2)
                        grid(0...14, cols: 5, color: g.backColor, square: true, selected: pickBack) { toggle(&pickBack, $0, max: 1) }
                    case .kl8:
                        grid(1...80, cols: 8, color: g.frontColor, selected: pickFront) { toggle(&pickFront, $0, max: 10) }
                    default:
                        Text(g == .dlt ? "前区" : "红球").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        grid(1...(g == .dlt ? 35 : 33), cols: 7, color: g.frontColor, selected: pickFront) { toggle(&pickFront, $0, max: 20) }
                        Text(g == .dlt ? "后区" : "蓝球").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 2)
                        grid(1...(g == .dlt ? 12 : 16), cols: 7, color: g.backColor, selected: pickBack) { toggle(&pickBack, $0, max: 16) }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: g == .qxc ? 330 : 340)
        }
        .padding(16)
        .glassCard(22)
    }

    private func grid(_ range: ClosedRange<Int>, cols: Int, color: Color, square: Bool = false,
                      selected: [Int], tap: @escaping (Int) -> Void) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: cols), spacing: 8) {
            ForEach(Array(range), id: \.self) { n in
                pickBall(text: square ? "\(n)" : String(format: "%02d", n), on: selected.contains(n), color: color, square: square) { tap(n) }
            }
        }
    }

    private func pickBall(text: String, on: Bool, color: Color, square: Bool = false, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            ZStack {
                if square {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(on ? color : Color.white.opacity(0.06))
                    if !on { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(color.opacity(0.5), lineWidth: 1.2) }
                } else {
                    Circle().fill(on ? color : Color.white.opacity(0.06))
                    if !on { Circle().stroke(color.opacity(0.5), lineWidth: 1.2) }
                }
                Text(text)
                    .font(.system(size: 17, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(on ? Color.white : color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(2)
            }
            .aspectRatio(1, contentMode: .fit)
            .scaleEffect(on ? 1.06 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: on)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ list: inout [Int], _ n: Int, max: Int) {
        if let i = list.firstIndex(of: n) { list.remove(at: i) }
        else if list.count < max { list.append(n) }
        else if max == 1 { list = [n] }
    }

    private var pickValid: Bool {
        switch g {
        case .qxc: return !qxcFront.contains(-1) && pickBack.count == 1
        case .kl8: return (1...10).contains(pickFront.count)
        case .dlt: return pickFront.count >= 5 && pickBack.count >= 2
        default: return pickFront.count >= 6 && pickBack.count >= 1
        }
    }

    private var pickHint: String {
        switch g {
        case .qxc:
            let n = qxcFront.filter { $0 >= 0 }.count
            return "前区 \(n)/6 位 · 后区 \(pickBack.count)/1"
        case .kl8:
            return pickFront.isEmpty ? "选 1~10 个" : "选\(["", "一", "二", "三", "四", "五", "六", "七", "八", "九", "十"][pickFront.count])"
        case .dlt:
            let n = PrizeCalc.comb(pickFront.count, 5) * PrizeCalc.comb(pickBack.count, 2)
            return "前区 \(pickFront.count) · 后区 \(pickBack.count)" + (n > 1 ? " · 复式 \(n) 注" : "")
        default:
            let n = PrizeCalc.comb(pickFront.count, 6) * PrizeCalc.comb(pickBack.count, 1)
            return "红 \(pickFront.count) · 蓝 \(pickBack.count)" + (n > 1 ? " · 复式 \(n) 注" : "")
        }
    }

    private func clearPicker() {
        pickFront = []; pickBack = []; qxcFront = Array(repeating: -1, count: 6); qxcPos = 0
    }

    private func addPicked() {
        let bet = draftBet
        withAnimation { scan.bets.append(bet) }
        clearPicker()
    }

    /// 点已有的一注：放回选号面板里修改
    private func edit(_ bet: LotteryBet) {
        if g == .qxc { qxcFront = bet.front; pickBack = bet.back; qxcPos = 0 }
        else { pickFront = bet.front; pickBack = bet.back }
        withAnimation { scan.bets.removeAll { $0.id == bet.id } }
    }

    // MARK: 已选的注

    private var hasDraft: Bool {
        g == .qxc ? (qxcFront.contains { $0 >= 0 } || !pickBack.isEmpty) : (!pickFront.isEmpty || !pickBack.isEmpty)
    }

    private var draftBet: LotteryBet {
        g == .qxc ? LotteryBet(front: qxcFront, back: pickBack) : LotteryBet(front: pickFront.sorted(), back: pickBack.sorted())
    }

    private var betsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("我的号码（\(scan.bets.count) 注）").font(.subheadline.weight(.semibold))
                Spacer()
                if !scan.bets.isEmpty {
                    Button("全部删除") { withAnimation { scan.bets = []; periods = [] } }
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            // 正在选的这一注：点一个球就出现在这里，选够了点「确认」
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("正在选").font(.caption.weight(.semibold)).foregroundStyle(g.frontColor)
                    Spacer()
                    Text(pickValid ? "选好了，点确认加入" : pickHint).font(.caption2).foregroundStyle(.secondary)
                }
                if hasDraft {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LotteryBalls(game: g, front: draftStrings.0, back: draftStrings.1, size: 28)
                    }
                } else {
                    Text("在上面点球，选中的号码会出现在这里").font(.caption).foregroundStyle(.tertiary)
                        .frame(height: 28)
                }
                HStack(spacing: 10) {
                    Button {
                        withAnimation { clearPicker() }
                    } label: {
                        Label("清空", systemImage: "arrow.counterclockwise").frame(maxWidth: .infinity)
                    }
                    .glassButton()
                    .disabled(!hasDraft)
                    Button {
                        addPicked()
                    } label: {
                        Label("确认这一注", systemImage: "checkmark.circle.fill").frame(maxWidth: .infinity)
                    }
                    .glassButton()
                    .tint(.green)
                    .disabled(!pickValid)
                }
                .font(.subheadline.weight(.semibold))
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(pickValid ? Color.green.opacity(0.6) : Color.white.opacity(0.1), style: StrokeStyle(lineWidth: 1, dash: pickValid ? [] : [4, 3])))

            ForEach(Array(scan.bets.enumerated()), id: \.element.id) { i, b in
                HStack(spacing: 8) {
                    Text("\(i + 1)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(width: 16)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LotteryBalls(game: g, front: b.frontStrings(g), back: b.backStrings(g), size: 26)
                    }
                    Button { toggleFav(b) } label: { Image(systemName: isFav(b) ? "star.fill" : "star").font(.title3) }
                        .buttonStyle(.plain).foregroundStyle(isFav(b) ? Color.yellow : Color.secondary)
                    Button { edit(b) } label: { Image(systemName: "pencil.circle").font(.title3) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                    Button { withAnimation { scan.bets.removeAll { $0.id == b.id } } } label: { Image(systemName: "xmark.circle.fill").font(.title3) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(22)
    }

    /// 正在选的号码（七星彩没选的位显示「–」）
    private var draftStrings: ([String], [String]) {
        if g == .qxc { return (qxcFront.map { $0 >= 0 ? "\($0)" : "–" }, pickBack.map(String.init)) }
        return (pickFront.sorted().map { String(format: "%02d", $0) }, pickBack.sorted().map { String(format: "%02d", $0) })
    }

    // MARK: 结果

    private var resultView: some View {
        let won = periods.filter { !$0.hits.isEmpty }
        let money = periods.map(\.money).reduce(0, +)
        return VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 6) {
                Image(systemName: won.isEmpty ? "face.dashed" : "party.popper.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(won.isEmpty ? Color.secondary : Color.orange)
                Text(won.isEmpty ? (periods.isEmpty ? "还没开奖" : "这次没中") : (periods.count > 1 ? "\(periods.count) 期里中了 \(won.count) 期" : "中奖了！"))
                    .font(.title2.weight(.bold))
                if money > 0 {
                    Text("合计约 " + LotteryFormat.yuan(String(format: "%.0f", money)))
                        .font(.title3.weight(.bold).monospacedDigit()).foregroundStyle(.orange)
                }
                if periods.contains(where: \.floating) {
                    Text("含浮动奖（一、二等奖等），金额以开奖公告为准").font(.caption).foregroundStyle(.secondary)
                }
                if let first = periods.filter({ !$0.hits.isEmpty }).map(\.draw).first, let c = Self.claimText(first) {
                    Label((periods.filter { !$0.hits.isEmpty }.count > 1 ? "最早一期" : "") + c.0, systemImage: "calendar.badge.clock")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(c.1 ? Color.red : Color.green)
                    Text("开奖之日起 60 天内兑奖，最后一天遇法定节假日顺延，以彩票站为准").font(.caption2).foregroundStyle(.tertiary)
                }
                if pending > 0 {
                    Text("还有 \(pending) 期没开奖").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(18)
            .glassCard(22)

            ForEach(periods) { p in
                periodRow(p)
            }
        }
    }

    private func periodRow(_ p: PeriodResult) -> some View {
        let open = openIssue == p.draw.issue || periods.count == 1
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("第\(p.draw.issue)期").font(.subheadline.weight(.semibold).monospacedDigit())
                Text(p.draw.date).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if p.hits.isEmpty {
                    Text("未中奖").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(p.money > 0 ? LotteryFormat.yuan(String(format: "%.0f", p.money)) + (p.floating ? "+" : "") : "浮动奖")
                        .font(.subheadline.weight(.bold).monospacedDigit()).foregroundStyle(.orange)
                }
            }
            LotteryBalls(game: g, front: p.draw.front, back: p.draw.back, size: g == .kl8 ? 24 : 26)
            if !p.hits.isEmpty {
                Text(summary(p.hits)).font(.caption).foregroundStyle(.orange)
                if let c = Self.claimText(p.draw) {
                    Label(c.0, systemImage: "calendar.badge.clock")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(c.1 ? Color.red : Color.green)
                }
            }
            if open {
                ForEach(Array(p.results.enumerated()), id: \.element.id) { i, r in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("第\(i + 1)注" + (g == .kl8 ? "（选\(r.bet.pick ?? r.bet.front.count)\(r.bet.pick != nil ? "复式" : "")）" : "") + (r.combos > 1 ? "（复式 \(r.combos) 注）" : ""))
                                .font(.caption.weight(.semibold))
                            Spacer()
                            Text(hitSummary(r)).font(.caption).foregroundStyle(.secondary)
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            LotteryBalls(game: g, front: r.bet.frontStrings(g), back: r.bet.backStrings(g),
                                         size: 24, hitFront: r.frontHitIdx, hitBack: r.backHitIdx)
                        }
                        ForEach(r.hits) { h in
                            HStack {
                                Text("\(h.name) × \(h.count)").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                                Spacer()
                                Text(h.total.map { LotteryFormat.yuan(String(format: $0 < 100 && $0 != $0.rounded() ? "%.1f" : "%.0f", $0)) }
                                     ?? (g == .kl8 ? "浮动（最高500万）" : "浮动奖金"))
                                    .font(.caption.monospacedDigit())
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            } else {
                Text("点开看每一注").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(18)
        .contentShape(Rectangle())
        .onTapGesture {
            guard periods.count > 1 else { return }
            withAnimation(.easeOut(duration: 0.2)) { openIssue = openIssue == p.draw.issue ? nil : p.draw.issue }
        }
    }

    // MARK: 历史中奖查询

    struct HistoryResult {
        let scanned: Int
        let firstDate: String
        let lastDate: String
        let wins: [PeriodResult]
        let costPerDraw: Double
        var fixedMoney: Double { wins.map(\.money).reduce(0, +) }
        var floating: Int { wins.filter(\.floating).count }
        /// 各奖级中了几次（注数）
        var byPrize: [(String, Int)] {
            var m: [String: Int] = [:]
            for w in wins { for h in w.hits { m[h.name, default: 0] += h.count } }
            return m.sorted { $0.value < $1.value }
        }
    }

    private var historySettingsCard: some View {
        CardSection {
            Picker("玩法", selection: $scan.game) {
                ForEach(LotteryGame.checkableGames) { Text($0.shortName).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.vertical, 10)
            RowDivider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("查多少期")
                    Text("第一次查「全部」要多等一会儿，之后只补新开的").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: $historyRange) {
                    Text("近 100 期").tag(100)
                    Text("近 500 期").tag(500)
                    Text("近 1000 期").tag(1000)
                    Text("全部").tag(0)
                }
                .pickerStyle(.menu).tint(.secondary)
            }
            .padding(.vertical, 8)
            if g == .dlt {
                RowDivider()
                Toggle("追加投注", isOn: $scan.added).padding(.vertical, 6)
            }
        }
    }

    private func queryHistory() async {
        message = nil
        history = nil
        guard !scan.bets.isEmpty else { message = "先在上面点选号码，添加至少一注。"; return }
        checking = true
        historyProgress = 0
        defer { checking = false }
        do {
            let list = try await LotteryAPI.longHistory(g, limit: historyRange) { n in
                Task { @MainActor in historyProgress = n }
            }
            guard !list.isEmpty else { message = "没取到开奖数据，稍后再试。"; return }
            let res = list.map { d in
                PeriodResult(draw: d, results: scan.bets.map { PrizeCalc.check(withAdded($0), draw: d, game: g, multiple: max(1, $0.multiple)) })
            }
            let per = (res.first?.results ?? []).enumerated().reduce(0.0) { sum, e in
                let b = withAdded(scan.bets[e.offset])
                return sum + Double(e.element.combos) * (g == .dlt && b.added ? 3 : 2) * Double(max(1, b.multiple))
            }
            let wins = res.filter { !$0.hits.isEmpty }.sorted {
                if $0.floating != $1.floating { return $0.floating }
                if $0.money != $1.money { return $0.money > $1.money }
                return (LotteryAPI.issueNumber($0.draw.issue) ?? 0) > (LotteryAPI.issueNumber($1.draw.issue) ?? 0)
            }
            withAnimation {
                history = HistoryResult(scanned: list.count, firstDate: String(list.last?.date.prefix(10) ?? ""),
                                        lastDate: String(list.first?.date.prefix(10) ?? ""), wins: wins, costPerDraw: per)
            }
        } catch {
            message = "获取历史开奖失败：\(error.localizedDescription)"
        }
    }

    private func historyView(_ h: HistoryResult) -> some View {
        let cost = h.costPerDraw * Double(h.scanned)
        let net = h.fixedMoney - cost
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("查了 \(h.scanned) 期").font(.headline)
                Text(h.firstDate + " ~ " + h.lastDate).font(.caption).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("中奖 \(h.wins.count) 期").font(.title3.weight(.bold))
                    Text("合计 " + LotteryFormat.money(h.fixedMoney)).font(.title3.weight(.bold))
                        .foregroundStyle(Color(red: 1, green: 0.75, blue: 0.3))
                }
                if h.floating > 0 {
                    Text("另有 \(h.floating) 期中了浮动大奖（一、二等奖），奖金见下面").font(.footnote.weight(.semibold)).foregroundStyle(.orange)
                }
                Text(costText(h, cost: cost, net: net))
                    .font(.caption).foregroundStyle(.secondary)
                if !h.byPrize.isEmpty {
                    Text(h.byPrize.map { "\($0.0) × \($0.1)" }.joined(separator: "   "))
                        .font(.caption.weight(.semibold))
                }
                Text("固定奖金按现在的规则算，早年规则不同的期可能有出入；浮动奖金是那一期官方公布的。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(22)

            if h.wins.isEmpty {
                Text("这些期里一次都没中过。").font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(24).glassCard(20)
            }
            ForEach(h.wins.prefix(300)) { p in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("第\(p.draw.issue)期").font(.subheadline.weight(.bold))
                        Text(String(p.draw.date.prefix(10))).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(p.floating && p.money == 0 ? "浮动奖" : LotteryFormat.money(p.money))
                            .font(.subheadline.weight(.bold)).foregroundStyle(Color(red: 1, green: 0.75, blue: 0.3))
                    }
                    LotteryBalls(game: g, front: p.draw.front, back: p.draw.back, size: g == .kl8 ? 22 : 24,
                                 hitFront: drawHits(p, back: false), hitBack: drawHits(p, back: true))
                    Text(hitsText(p))
                    .font(.caption).foregroundStyle(.secondary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard(18)
            }
            if h.wins.count > 300 {
                Text("只列出前 300 期").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func hitsText(_ p: PeriodResult) -> String {
        p.hits.map { (h: PrizeHit) -> String in
            var t: String = h.name + " × \(h.count)"
            if let e = h.each { t += "（" + LotteryFormat.money(e) + "）" }
            else if let f = floatingAmount(p.draw, h.name) { t += "（" + f + "/注）" }
            return t
        }.joined(separator: "、")
    }

    private func costText(_ h: HistoryResult, cost: Double, net: Double) -> String {
        let per: String = LotteryFormat.money(h.costPerDraw)
        let total: String = LotteryFormat.money(cost)
        let diff: String = (net >= 0 ? "净赚 " : "净亏 ") + LotteryFormat.money(abs(net))
        let tail: String = h.floating > 0 ? "（不含浮动大奖）" : ""
        return "如果每期都买（每期 \(per)），一共要花 \(total)，\(diff)\(tail)"
    }

    /// 开奖号码里哪些位置被这几注号码中了
    private func drawHits(_ p: PeriodResult, back: Bool) -> Set<Int> {
        if g == .qxc {
            return back ? (p.results.contains { !$0.backHitIdx.isEmpty } ? [0] : [])
                        : p.results.reduce(Set<Int>()) { $0.union($1.frontHitIdx) }
        }
        let mine = Set(scan.bets.flatMap { back ? $0.back : $0.front })
        let nums = back ? p.draw.back : p.draw.front
        return Set(nums.indices.filter { Int(nums[$0]).map(mine.contains) ?? false })
    }

    /// 浮动奖那一期官方公布的单注奖金
    private func floatingAmount(_ d: LotteryDraw, _ name: String) -> String? {
        guard let p = d.prizes.first(where: { $0.name == name || $0.name.hasPrefix(name) }), !p.amount.isEmpty else { return nil }
        return LotteryFormat.yuan(p.amount)
    }

    /// 票上勾了追加，就每注都算追加
    private func withAdded(_ b: LotteryBet) -> LotteryBet {
        var b = b
        if g == .dlt && scan.added { b.added = true }
        return b
    }

    /// 兑奖期限：开奖之日起 60 天（最后一天遇法定节假日顺延，以彩票站为准）
    static func claimDeadline(_ d: LotteryDraw) -> Date? {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        guard let day = f.date(from: String(d.date.prefix(10))) else { return nil }
        return Calendar.current.date(byAdding: .day, value: 60, to: day)
    }

    static func claimText(_ d: LotteryDraw) -> (String, Bool)? {
        guard let end = claimDeadline(d) else { return nil }
        let cal = Calendar.current
        let left = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: end).day ?? 0
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "yyyy年M月d日"
        if left < 0 { return ("已过兑奖期（截止 \(f.string(from: end))）", true) }
        return ("兑奖截止 \(f.string(from: end))，还剩 \(left) 天", left <= 7)
    }

    private func summary(_ hits: [PrizeHit]) -> String {
        var merged: [(String, Int)] = []
        for h in hits {
            if let i = merged.firstIndex(where: { $0.0 == h.name }) { merged[i].1 += h.count } else { merged.append((h.name, h.count)) }
        }
        return merged.map { "\($0.0) × \($0.1)" }.joined(separator: "、")
    }

    private func hitSummary(_ r: BetResult) -> String {
        switch g {
        case .kl8: return "中 \(r.frontHits) 个"
        case .qxc: return "前区对上 \(r.frontHits) 位 · 后区\(r.backHits > 0 ? "中" : "没中")"
        default: return "前区中 \(r.frontHits) · 后区中 \(r.backHits)"
        }
    }

    // MARK: 对奖

    private func check() async {
        if historyMode { await queryHistory(); return }
        message = nil
        periods = []
        pending = 0
        openIssue = nil
        let from = scan.issue.trimmingCharacters(in: .whitespaces)
        let to = scan.issueTo.trimmingCharacters(in: .whitespaces)
        guard from.count >= 5 else { message = "请填期号（双色球、快乐8 是 7 位，如 2026120；大乐透、七星彩 5 位，如 26120）"; return }
        guard !scan.bets.isEmpty else { message = "先在上面点选号码，添加至少一注。"; return }
        checking = true
        defer { checking = false }
        do {
            let r = try await LotteryAPI.draws(g, from: from, to: to.isEmpty ? nil : to, periods: nil)
            periods = r.draws.sorted { (LotteryAPI.issueNumber($0.issue) ?? 0) < (LotteryAPI.issueNumber($1.issue) ?? 0) }.map { d in
                PeriodResult(draw: d, results: scan.bets.map { PrizeCalc.check(withAdded($0), draw: d, game: g, multiple: scan.multiple * max(1, $0.multiple)) })
            }
            pending = r.pending
            // 拍照对奖的票自动存到「我的彩票」（多期票以后不用再扫）
            if image != nil && !locked { savedID = LotteryTickets.upsert(scan, photo: image, replacing: savedID) }
            // 中了的自动记到「中奖」栏
            for p in periods where !p.hits.isEmpty {
                LotteryWins.record(game: g, draw: p.draw, results: p.results, factor: scan.multiple, photo: image)
            }
            if periods.isEmpty && pending == 0 {
                message = "没找到第\(from)\(to.isEmpty ? "" : "~\(to)")期的开奖结果：期号可能填错了，或者太久以前（只能查最近 100 期）。"
            }
        } catch {
            message = "获取开奖结果失败：\(error.localizedDescription)"
        }
    }
}

/// 收藏的号码：每种玩法分开存
enum LotteryFavorites {
    private struct Item: Codable { var front: [Int]; var back: [Int]; var multiple: Int?; var pick: Int?; var added: Bool? }

    static func load(_ g: LotteryGame) -> [LotteryBet] {
        guard let data = UserDefaults.standard.data(forKey: "lotteryFavs_" + g.rawValue),
              let items = try? JSONDecoder().decode([Item].self, from: data) else { return [] }
        return items.map { LotteryBet(front: $0.front, back: $0.back, multiple: $0.multiple ?? 1, pick: $0.pick, added: $0.added ?? false) }
    }

    static func save(_ list: [LotteryBet], for g: LotteryGame) {
        let items = list.map { Item(front: $0.front, back: $0.back, multiple: $0.multiple, pick: $0.pick, added: $0.added) }
        if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: "lotteryFavs_" + g.rawValue) }
        AutoBackup.schedule()   // 收藏也进备份
        NotificationCenter.default.post(name: .lotteryFavsChanged, object: nil)
    }

    /// 备份用：玩法 → [[前区],[后区]]
    static func exportAll() -> [String: [[[Int]]]] {
        var out: [String: [[[Int]]]] = [:]
        for g in LotteryGame.checkableGames {
            let list = load(g)
            // [前区, 后区, [倍数], [选几(0=无)], [追加 1/0]]
            if !list.isEmpty { out[g.rawValue] = list.map { [$0.front, $0.back, [$0.multiple], [$0.pick ?? 0], [$0.added ? 1 : 0]] } }
        }
        return out
    }

    /// 从备份恢复：合并，已有的不重复。返回新增几注
    static func importAll(_ m: [String: [[[Int]]]]) -> Int {
        var added = 0
        for (key, bets) in m {
            guard let g = LotteryGame(rawValue: key) else { continue }
            var list = load(g)
            for b in bets where b.count >= 2 && !list.contains(where: { $0.front == b[0] && $0.back == b[1] }) {
                list.append(LotteryBet(front: b[0], back: b[1], multiple: b.count > 2 ? (b[2].first ?? 1) : 1, pick: b.count > 3 ? b[3].first.flatMap { $0 > 0 ? $0 : nil } : nil,
                                       added: b.count > 4 ? b[4].first == 1 : false)); added += 1
            }
            save(list, for: g)
        }
        return added
    }
}

extension Notification.Name {
    static let lotteryFavsChanged = Notification.Name("lotteryFavsChanged")
}

/// 盖在彩票照片上的印章：中奖啦（红） / 未中奖（灰）
struct TicketStamp: View {
    let won: Bool
    var body: some View {
        let c = won ? Color(red: 0.92, green: 0.15, blue: 0.18) : Color.gray
        ZStack {
            Circle().stroke(c, lineWidth: 4)
            Circle().stroke(c, lineWidth: 1.5).padding(7)
            VStack(spacing: 2) {
                Text(won ? "★ ★ ★" : "—").font(.system(size: 10, weight: .bold))
                Text(won ? "中奖啦" : "未中奖").font(.system(size: 26, weight: .heavy))
                Text(won ? "WINNER" : "NO PRIZE").font(.system(size: 9, weight: .bold)).tracking(2)
            }
            .foregroundStyle(c)
        }
        .frame(width: 124, height: 124)
        .background(Circle().fill(Color.white.opacity(won ? 0.12 : 0.05)))
        .rotationEffect(.degrees(-18))
        .opacity(0.9)
        .shadow(color: c.opacity(0.4), radius: 6)
    }
}
