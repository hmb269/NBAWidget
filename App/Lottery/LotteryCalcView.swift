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
            }
            .padding(16)
            .padding(.bottom, 100)
        }
        .background(AppBackground())
        .navigationTitle("金额计算器")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .onChange(of: game) { _, _ in dantuo = false }
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
