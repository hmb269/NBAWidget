import SwiftUI

/// 注数 / 金额计算器：复式、胆拖、快乐8 选几、七星彩复式
struct LotteryCalcView: View {
    @State private var game: LotteryGame = .ssq
    @State private var dantuo = false

    // 双色球
    @State private var ssqRed = 7
    @State private var ssqBlue = 1
    @State private var ssqDan = 2
    @State private var ssqTuo = 6
    // 大乐透
    @State private var dltFront = 6
    @State private var dltBack = 2
    @State private var dltFDan = 1
    @State private var dltFTuo = 5
    @State private var dltBDan = 0
    @State private var dltBTuo = 3
    @State private var added = false
    // 快乐8
    @State private var kl8Pick = 10
    @State private var kl8Count = 11
    // 七星彩：每一位选了几个数字
    @State private var qxc = [1, 1, 1, 1, 1, 1, 1]

    @State private var multiple = 1
    @State private var periods = 1

    // 中奖计算：中了几个
    @State private var hitF = 0       // 双色球红球 / 大乐透前区 / 快乐8（复式）中了几个
    @State private var hitB = 0       // 双色球蓝球 / 大乐透后区中了几个（复式）
    @State private var hitFDan = 0    // 胆拖：胆码中了几个
    @State private var hitFTuo = 0    //       拖码中了几个
    @State private var hitBDan = 0
    @State private var hitBTuo = 0
    @State private var qxcHit = [false, false, false, false, false, false, false]  // 七星彩每一位中没中

    private let C = PrizeCalc.comb

    private var bets: Int {
        switch game {
        case .ssq:
            return dantuo ? C(ssqTuo, 6 - ssqDan) * ssqBlue : C(ssqRed, 6) * ssqBlue
        case .dlt:
            return dantuo ? C(dltFTuo, 5 - dltFDan) * C(dltBTuo, 2 - dltBDan) : C(dltFront, 5) * C(dltBack, 2)
        case .kl8:
            return C(kl8Count, kl8Pick)
        default:
            return qxc.reduce(1, *)
        }
    }
    private var price: Int { game == .dlt && added ? 3 : 2 }
    private var perDraw: Int { bets * price * multiple }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Picker("玩法", selection: $game) {
                    ForEach(LotteryGame.checkableGames) { Text($0.shortName).tag($0) }
                }
                .pickerStyle(.segmented)

                CardSection {
                    if game == .ssq || game == .dlt {
                        Picker("", selection: $dantuo) {
                            Text("复式").tag(false)
                            Text("胆拖").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .padding(.vertical, 10)
                        RowDivider()
                    }
                    inputs
                }

                CardSection {
                    stepper("倍数", $multiple, 1...99)
                    RowDivider()
                    stepper("期数", $periods, 1...30, sub: "连续买几期")
                    if game == .dlt {
                        RowDivider()
                        Toggle(isOn: $added) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("追加投注")
                                Text("每注多 1 元").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }

                result

                prizeInputs

                prizeResult
            }
            .padding(16)
            .padding(.bottom, 100)
        }
        .background(AppBackground())
        .navigationTitle("金额计算器")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .onChange(of: game) { _, _ in dantuo = false; resetHits() }
        .onChange(of: dantuo) { _, _ in resetHits() }
    }

    @ViewBuilder
    private var inputs: some View {
        switch game {
        case .ssq:
            if dantuo {
                stepper("红球胆码", $ssqDan, 1...5)
                RowDivider()
                stepper("红球拖码", $ssqTuo, max(2, 7 - ssqDan)...(33 - ssqDan), sub: "胆码 + 拖码至少 7 个")
                RowDivider()
                stepper("蓝球", $ssqBlue, 1...16)
            } else {
                stepper("红球", $ssqRed, 6...20, sub: "选几个红球（单式 6 个）")
                RowDivider()
                stepper("蓝球", $ssqBlue, 1...16)
            }
        case .dlt:
            if dantuo {
                stepper("前区胆码", $dltFDan, 1...4)
                RowDivider()
                stepper("前区拖码", $dltFTuo, max(2, 6 - dltFDan)...(35 - dltFDan), sub: "胆码 + 拖码至少 6 个")
                RowDivider()
                stepper("后区胆码", $dltBDan, 0...1)
                RowDivider()
                stepper("后区拖码", $dltBTuo, max(2, 3 - dltBDan)...(12 - dltBDan))
            } else {
                stepper("前区", $dltFront, 5...18, sub: "单式 5 个")
                RowDivider()
                stepper("后区", $dltBack, 2...12, sub: "单式 2 个")
            }
        case .kl8:
            stepper("玩法：选几", $kl8Pick, 1...10)
            RowDivider()
            stepper("选了几个号码", $kl8Count, kl8Pick...max(kl8Pick, 20), sub: "比「选几」多就是复式")
        default:
            ForEach(0..<7, id: \.self) { i in
                if i > 0 { RowDivider() }
                stepper(i < 6 ? "第\(i + 1)位" : "后区", $qxc[i], 1...(i < 6 ? 10 : 15),
                        sub: i == 0 ? "每一位选几个数字（单式都是 1）" : nil)
            }
        }
    }

    private var result: some View {
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("共").foregroundStyle(.secondary)
                Text("\(bets)").font(.system(size: 40, weight: .heavy, design: .rounded).monospacedDigit())
                Text("注").foregroundStyle(.secondary)
            }
            Divider().overlay(Color.white.opacity(0.08))
            row("每期金额", "\(perDraw) 元")
            if periods > 1 {
                row("\(periods) 期合计", "\(perDraw * periods) 元", strong: true)
            } else {
                row("合计", "\(perDraw) 元", strong: true)
            }
            Text("\(bets) 注 × \(price) 元" + (multiple > 1 ? " × \(multiple) 倍" : "") + (periods > 1 ? " × \(periods) 期" : ""))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .glassCard(24)
    }

    // MARK: 中奖计算

    private func resetHits() {
        hitF = 0; hitB = 0; hitFDan = 0; hitFTuo = 0; hitBDan = 0; hitBTuo = 0
        qxcHit = [false, false, false, false, false, false, false]
    }

    @ViewBuilder
    private var prizeInputs: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("如果中了…").font(.headline).padding(.leading, 4)
            CardSection {
                switch game {
                case .ssq:
                    if dantuo {
                        stepper("红球胆码中了几个", $hitFDan, 0...ssqDan)
                        RowDivider()
                        stepper("红球拖码中了几个", $hitFTuo, 0...min(ssqTuo, 6 - hitFDan))
                    } else {
                        stepper("红球中了几个", $hitF, 0...min(ssqRed, 6))
                    }
                    RowDivider()
                    stepper("蓝球中了几个", $hitB, 0...1)
                case .dlt:
                    if dantuo {
                        stepper("前区胆码中了几个", $hitFDan, 0...dltFDan)
                        RowDivider()
                        stepper("前区拖码中了几个", $hitFTuo, 0...min(dltFTuo, 5 - hitFDan))
                        RowDivider()
                        stepper("后区胆码中了几个", $hitBDan, 0...dltBDan)
                        RowDivider()
                        stepper("后区拖码中了几个", $hitBTuo, 0...min(dltBTuo, 2 - hitBDan))
                    } else {
                        stepper("前区中了几个", $hitF, 0...min(dltFront, 5))
                        RowDivider()
                        stepper("后区中了几个", $hitB, 0...min(dltBack, 2))
                    }
                case .kl8:
                    stepper("选的号码里中了几个", $hitF, 0...min(kl8Count, 20))
                default:
                    ForEach(0..<7, id: \.self) { i in
                        if i > 0 { RowDivider() }
                        Toggle(isOn: $qxcHit[i]) {
                            Text(i < 6 ? "第\(i + 1)位中了" : "后区中了")
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    /// 按「中了几个」算出每个奖级各中几注（已乘倍数）
    private var prizeHits: [PrizeHit] {
        var counts: [String: Int] = [:]
        switch game {
        case .ssq, .dlt:
            let (fn, bn) = game == .dlt ? (5, 2) : (6, 1)
            // 前区：胆码全进每一注，拖码里挑 (fn - 胆) 个
            let fDan = dantuo ? (game == .ssq ? ssqDan : dltFDan) : 0
            let fPool = dantuo ? (game == .ssq ? ssqTuo : dltFTuo) : (game == .ssq ? ssqRed : dltFront)
            let fDanHit = dantuo ? hitFDan : 0
            let fPoolHit = dantuo ? hitFTuo : hitF
            let bDan = (dantuo && game == .dlt) ? dltBDan : 0
            let bPool = game == .ssq ? ssqBlue : (dantuo ? dltBTuo : dltBack)
            let bDanHit = (dantuo && game == .dlt) ? hitBDan : 0
            let bPoolHit = (dantuo && game == .dlt) ? hitBTuo : hitB
            for t in 0...(fn - fDan) {
                let nf = C(fPoolHit, t) * C(fPool - fPoolHit, fn - fDan - t)
                guard nf > 0 else { continue }
                for u in 0...(bn - bDan) {
                    let nb = C(bPoolHit, u) * C(bPool - bPoolHit, bn - bDan - u)
                    guard nb > 0, let name = PrizeCalc.baseTier(game, fDanHit + t, bDanHit + u) else { continue }
                    counts[name, default: 0] += nf * nb
                }
            }
        case .kl8:
            let N = kl8Pick
            for k in 0...N {
                let n = C(hitF, k) * C(kl8Count - hitF, N - k)
                guard n > 0 else { continue }
                let name = "选\(PrizeCalc.cnNum[N])中\(k == 0 ? "零" : PrizeCalc.cnNum[k])"
                if N == 10 && k == 10 { counts[name, default: 0] += n }
                else if PrizeCalc.kl8Table[N]?[k] != nil { counts[name, default: 0] += n }
            }
        default:
            // 七星彩复式：每一位中了就有 1 个数字对、其余不对；按位展开数「前区中几位 + 后区中没中」
            var dist: [Int: Int] = [0: 1]
            for i in 0..<6 {
                var next: [Int: Int] = [:]
                for (k, n) in dist {
                    if qxcHit[i] {
                        next[k + 1, default: 0] += n
                        if qxc[i] > 1 { next[k, default: 0] += n * (qxc[i] - 1) }
                    } else {
                        next[k, default: 0] += n * qxc[i]
                    }
                }
                dist = next
            }
            for (k, n) in dist {
                let backYes = qxcHit[6] ? 1 : 0
                let backNo = qxcHit[6] ? qxc[6] - 1 : qxc[6]
                if backYes > 0, let name = PrizeCalc.qxcTier(k, true) { counts[name, default: 0] += n * backYes }
                if backNo > 0, let name = PrizeCalc.qxcTier(k, false) { counts[name, default: 0] += n * backNo }
            }
        }
        let fixed = PrizeCalc.fixedTable(game)
        let order: [String] = game == .kl8
            ? (0...kl8Pick).reversed().map { "选\(PrizeCalc.cnNum[kl8Pick])中\($0 == 0 ? "零" : PrizeCalc.cnNum[$0])" }
            : ["一等奖", "二等奖", "三等奖", "四等奖", "五等奖", "六等奖", "七等奖"]
        return order.compactMap { name -> PrizeHit? in
            guard let c = counts[name] else { return nil }
            var each: Double? = fixed[name]
            if game == .kl8 {
                let k = (0...kl8Pick).first { name.hasSuffix("中" + ($0 == 0 ? "零" : PrizeCalc.cnNum[$0])) } ?? 0
                each = (kl8Pick == 10 && k == 10) ? nil : PrizeCalc.kl8Table[kl8Pick]?[k]
            }
            return PrizeHit(name: name, count: c * multiple, each: each)
        }
    }

    private var prizeResult: some View {
        let hits = prizeHits
        let fixedSum: Double = hits.compactMap(\.total).reduce(0, +)
        let floating = hits.filter { $0.each == nil }
        let cost = Double(perDraw)
        return VStack(alignment: .leading, spacing: 10) {
            if hits.isEmpty {
                Text("这样没有中奖").font(.headline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            } else {
                ForEach(hits) { h in
                    HStack {
                        Text(h.name).font(.subheadline.weight(.semibold))
                        Text("× \(h.count) 注").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        Spacer()
                        if let t = h.total {
                            Text(LotteryFormat.yuan(String(format: "%.0f", t)))
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                        } else {
                            Text(game == .kl8 ? "浮动（最高 500 万/注）" : "浮动奖金")
                                .font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                        }
                    }
                }
                Divider().overlay(Color.white.opacity(0.08))
                row("固定奖金合计", LotteryFormat.yuan(String(format: "%.0f", fixedSum)) + (floating.isEmpty ? "" : " + 浮动奖"), strong: true)
                let net = fixedSum - cost
                row(net >= 0 ? "扣掉本期投入后赚" : "扣掉本期投入后亏",
                    LotteryFormat.yuan(String(format: "%.0f", abs(net))) + (floating.isEmpty ? "" : "（未算浮动奖）"))
            }
            Text("一、二等奖" + (game == .kl8 ? "（选十中十）" : "") + "是浮动奖，以当期开奖公告为准；"
                 + (game == .ssq ? "福运奖只有奖池超 15 亿时才设，这里没算；" : "")
                 + "奖金为税前，单注 1 万元以上要扣 20% 个税。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(24)
    }

    private func row(_ k: String, _ v: String, strong: Bool = false) -> some View {
        HStack {
            Text(k).foregroundStyle(.secondary)
            Spacer()
            Text(v).font(strong ? .title3.weight(.bold) : .body.weight(.semibold)).monospacedDigit()
                .foregroundStyle(strong ? Color(red: 1, green: 0.75, blue: 0.3) : .primary)
        }
    }

    private func stepper(_ title: String, _ v: Binding<Int>, _ range: ClosedRange<Int>, sub: String? = nil) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let sub { Text(sub).font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer()
            Text("\(v.wrappedValue)").font(.title3.weight(.bold).monospacedDigit()).frame(minWidth: 36)
            Stepper("", value: v, in: range).labelsHidden()
        }
        .padding(.vertical, 6)
        .onAppear { v.wrappedValue = min(max(v.wrappedValue, range.lowerBound), range.upperBound) }
        .onChange(of: range) { _, r in v.wrappedValue = min(max(v.wrappedValue, r.lowerBound), r.upperBound) }
    }
}
