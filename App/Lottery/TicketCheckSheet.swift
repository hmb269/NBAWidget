import SwiftUI

// MARK: - 对奖页：选号（点球）+ 多期 + 结果

struct TicketCheckSheet: View {
    @State var scan: TicketScan
    let image: UIImage?
    @Environment(\.dismiss) private var dismiss

    // 选号面板
    @State private var pickFront: [Int] = []          // 七星彩：6 位，-1 = 没选
    @State private var pickBack: [Int] = []
    @State private var qxcFront: [Int] = Array(repeating: -1, count: 6)
    @State private var qxcPos = 0

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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFit()
                            .frame(maxHeight: 160)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .frame(maxWidth: .infinity)
                    }

                    settingsCard
                    pickerCard
                    betsCard

                    Button {
                        Task { await check() }
                    } label: {
                        HStack {
                            if checking { ProgressView() }
                            Text(scan.issueTo.isEmpty ? "对奖" : "对奖（多期）").font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                    }
                    .glassButton()
                    .disabled(checking || scan.bets.isEmpty)

                    if let message {
                        Text(message).font(.footnote).foregroundStyle(.orange)
                    }

                    if !periods.isEmpty || pending > 0 { resultView }

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
                if image != nil, !scan.issue.isEmpty, !scan.bets.isEmpty { Task { await check() } }
                else if image != nil {
                    message = scan.bets.isEmpty ? "没认出号码，拍正一点、光线亮一点再试，或者在下面点选号码。" : "没认出期号，填一下再点对奖。"
                }
            }
            .onChange(of: scan.game) { old, new in
                if old != new { clearPicker(); scan.bets = []; periods = []; pending = 0 }
            }
        }
    }

    // MARK: 玩法、期号、倍数

    private var settingsCard: some View {
        CardSection {
            Picker("玩法", selection: $scan.game) {
                ForEach(LotteryGame.checkableGames) { Text($0.shortName).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.vertical, 10)
            RowDivider()
            HStack(spacing: 8) {
                Text("期号")
                Spacer()
                TextField([.ssq, .kl8].contains(g) ? "2026120" : "26120", text: $scan.issue)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .font(.body.monospacedDigit())
                    .frame(width: 96)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
                Text("到").foregroundStyle(.secondary)
                TextField("单期不填", text: $scan.issueTo)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .font(.body.monospacedDigit())
                    .frame(width: 96)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
            }
            .padding(.vertical, 8)
            RowDivider()
            Stepper("倍数 \(scan.multiple)", value: $scan.multiple, in: 1...99).padding(.vertical, 6)
            if g == .dlt {
                RowDivider()
                Toggle("追加投注", isOn: $scan.added).padding(.vertical, 6)
            }
        }
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
                if scan.added, periods.flatMap(\.hits).contains(where: { $0.name == "一等奖" || $0.name == "二等奖" }) {
                    Text("追加投注：一、二等奖另加基本奖金的 80%").font(.caption).foregroundStyle(.secondary)
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
            }
            if open {
                ForEach(Array(p.results.enumerated()), id: \.element.id) { i, r in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("第\(i + 1)注" + (g == .kl8 ? "（选\(r.bet.front.count)）" : "") + (r.combos > 1 ? "（复式 \(r.combos) 注）" : ""))
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
                PeriodResult(draw: d, results: scan.bets.map { PrizeCalc.check($0, draw: d, game: g, multiple: scan.multiple) })
            }
            pending = r.pending
            if periods.isEmpty && pending == 0 {
                message = "没找到第\(from)\(to.isEmpty ? "" : "~\(to)")期的开奖结果：期号可能填错了，或者太久以前（只能查最近 100 期）。"
            }
        } catch {
            message = "获取开奖结果失败：\(error.localizedDescription)"
        }
    }
}
