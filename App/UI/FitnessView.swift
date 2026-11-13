import SwiftUI
import Charts
import HealthKit

// 健身：三个圆环、锻炼记录、静息心率；BMI（中国成人标准）

// MARK: - 数据

struct RingsData {
    var move: Double = 0, moveGoal: Double = 0          // 千卡
    var exercise: Double = 0, exerciseGoal: Double = 30 // 分钟
    var stand: Double = 0, standGoal: Double = 12       // 小时
}

struct WorkoutItem: Identifiable {
    let id: UUID
    let type: String
    let icon: String
    let start: Date
    let duration: TimeInterval
    let kcal: Double?
    let km: Double?
    let avgHR: Double?
    let maxHR: Double?
}

enum FitnessData {
    private static var store: HKHealthStore { HealthService.store }

    /// 今天的三个圆环
    static func rings(on day: Date = Date()) async -> RingsData? {
        var cal = Calendar.current
        cal.timeZone = .current
        var comps = cal.dateComponents([.era, .year, .month, .day], from: day)
        comps.calendar = cal
        let predicate = HKQuery.predicateForActivitySummary(with: comps)
        return await withCheckedContinuation { cont in
            let q = HKActivitySummaryQuery(predicate: predicate) { _, list, _ in
                guard let a = list?.first else { cont.resume(returning: nil); return }
                var r = RingsData()
                r.move = a.activeEnergyBurned.doubleValue(for: .kilocalorie())
                r.moveGoal = a.activeEnergyBurnedGoal.doubleValue(for: .kilocalorie())
                r.exercise = a.appleExerciseTime.doubleValue(for: .minute())
                r.exerciseGoal = max(1, a.exerciseTimeGoal?.doubleValue(for: .minute()) ?? a.appleExerciseTimeGoal.doubleValue(for: .minute()))
                r.stand = a.appleStandHours.doubleValue(for: .count())
                r.standGoal = max(1, a.standHoursGoal?.doubleValue(for: .count()) ?? a.appleStandHoursGoal.doubleValue(for: .count()))
                cont.resume(returning: r)
            }
            store.execute(q)
        }
    }

    /// 最近的体能训练（新的在前）
    static func workouts(days: Int = 30, limit: Int = 50) async -> [WorkoutItem] {
        let start = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let list: [HKWorkout] = await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: .workoutType(), predicate: predicate, limit: limit, sortDescriptors: [sort]) { _, r, _ in
                cont.resume(returning: (r as? [HKWorkout]) ?? [])
            }
            store.execute(q)
        }
        let bpm = HKUnit.count().unitDivided(by: .minute())
        return list.map { w in
            let (name, icon) = typeName(w.workoutActivityType)
            let kcal = w.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie())
            let dist = [HKQuantityType(.distanceWalkingRunning), HKQuantityType(.distanceCycling), HKQuantityType(.distanceSwimming)]
                .compactMap { w.statistics(for: $0)?.sumQuantity()?.doubleValue(for: .meter()) }.first
            let hr = w.statistics(for: HKQuantityType(.heartRate))
            return WorkoutItem(id: w.uuid, type: name, icon: icon, start: w.startDate, duration: w.duration,
                               kcal: kcal, km: dist.map { $0 / 1000 },
                               avgHR: hr?.averageQuantity()?.doubleValue(for: bpm), maxHR: hr?.maximumQuantity()?.doubleValue(for: bpm))
        }
    }

    /// 最近一次的数值（静息心率、身高、最大摄氧量）
    static func latest(_ id: HKQuantityTypeIdentifier, unit: HKUnit, days: Int = 3650) async -> (Double, Date)? {
        let start = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        return await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: HKQuantityType(id), predicate: predicate, limit: 1, sortDescriptors: [sort]) { _, r, _ in
                guard let s = r?.first as? HKQuantitySample else { cont.resume(returning: nil); return }
                cont.resume(returning: (s.quantity.doubleValue(for: unit), s.endDate))
            }
            store.execute(q)
        }
    }

    static func typeName(_ t: HKWorkoutActivityType) -> (String, String) {
        switch t {
        case .walking: return ("步行", "figure.walk")
        case .running: return ("跑步", "figure.run")
        case .cycling: return ("骑车", "figure.outdoor.cycle")
        case .swimming: return ("游泳", "figure.pool.swim")
        case .hiking: return ("徒步", "figure.hiking")
        case .yoga: return ("瑜伽", "figure.yoga")
        case .traditionalStrengthTraining, .functionalStrengthTraining: return ("力量训练", "figure.strengthtraining.traditional")
        case .highIntensityIntervalTraining: return ("高强度间歇", "figure.highintensity.intervaltraining")
        case .elliptical: return ("椭圆机", "figure.elliptical")
        case .rowing: return ("划船", "figure.rower")
        case .stairClimbing, .stairs: return ("爬楼梯", "figure.stairs")
        case .badminton: return ("羽毛球", "figure.badminton")
        case .basketball: return ("篮球", "figure.basketball")
        case .tableTennis: return ("乒乓球", "figure.table.tennis")
        case .soccer: return ("足球", "figure.soccer")
        case .tennis: return ("网球", "figure.tennis")
        case .dance, .socialDance, .cardioDance: return ("跳舞", "figure.dance")
        case .coreTraining: return ("核心训练", "figure.core.training")
        case .flexibility, .cooldown: return ("拉伸", "figure.flexibility")
        case .mindAndBody, .taiChi: return ("身心训练", "figure.mind.and.body")
        case .jumpRope: return ("跳绳", "figure.jumprope")
        case .mixedCardio: return ("混合有氧", "figure.mixed.cardio")
        default: return ("其他运动", "figure.mixed.cardio")
        }
    }
}

// MARK: - BMI

enum BMI {
    /// 身高（厘米）：优先用健康里的，没有就用自己填的
    static var manualHeight: Double {
        get { UserDefaults.standard.double(forKey: "heightCm") }
        set { UserDefaults.standard.set(newValue, forKey: "heightCm") }
    }

    static func height() async -> Double? {
        if manualHeight > 0 { return manualHeight }
        if let (m, _) = await FitnessData.latest(.height, unit: .meterUnit(with: .centi)) { return m }
        return nil
    }

    static func value(kg: Double, cm: Double) -> Double { kg / pow(cm / 100, 2) }

    /// 中国成人标准：< 18.5 偏瘦，18.5–23.9 正常，24–27.9 超重，≥ 28 肥胖
    static func category(_ b: Double) -> (String, Color) {
        switch b {
        case ..<18.5: return ("偏瘦", Color(red: 0.40, green: 0.75, blue: 1.0))
        case ..<24: return ("正常", Color(red: 0.30, green: 0.88, blue: 0.50))
        case ..<28: return ("超重", Color(red: 1.0, green: 0.70, blue: 0.25))
        default: return ("肥胖", Color(red: 1.0, green: 0.35, blue: 0.35))
        }
    }

    static let rangeText = "健康范围 18.5～23.9（中国成人标准）"

    /// 正常范围对应的体重
    static func healthyKg(cm: Double) -> ClosedRange<Double> {
        let m2 = pow(cm / 100, 2)
        return (18.5 * m2)...(23.9 * m2)
    }
}

// MARK: - 圆环

struct ActivityRings: View {
    let r: RingsData
    var size: CGFloat = 92
    var line: CGFloat { size * 0.12 }

    static let moveColor = Color(red: 0.98, green: 0.07, blue: 0.31)
    static let exerciseColor = Color(red: 0.62, green: 1.0, blue: 0.0)
    static let standColor = Color(red: 0.0, green: 0.92, blue: 0.95)

    var body: some View {
        ZStack {
            ring(r.move / max(1, r.moveGoal), Self.moveColor, inset: 0)
            ring(r.exercise / max(1, r.exerciseGoal), Self.exerciseColor, inset: line * 1.15)
            ring(r.stand / max(1, r.standGoal), Self.standColor, inset: line * 2.3)
        }
        .frame(width: size, height: size)
    }

    private func ring(_ p: Double, _ c: Color, inset: CGFloat) -> some View {
        ZStack {
            Circle().stroke(c.opacity(0.2), lineWidth: line)
            Circle().trim(from: 0, to: min(1, max(0, p)))
                .stroke(c, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if p > 1 {   // 超过一圈：再叠一段
                Circle().trim(from: 0, to: min(1, p - 1))
                    .stroke(c, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: .black.opacity(0.4), radius: 2)
            }
        }
        .padding(inset + line / 2)
    }
}

// MARK: - 首页「健身」卡片

struct FitnessCard: View {
    @State private var rings: RingsData?
    @State private var last: WorkoutItem?

    var body: some View {
        NavigationLink {
            FitnessView()
        } label: {
            HStack(spacing: 16) {
                ActivityRings(r: rings ?? RingsData(), size: 86)
                VStack(alignment: .leading, spacing: 5) {
                    Label("健身", systemImage: "flame.fill").font(.subheadline.weight(.semibold))
                        .foregroundStyle(ActivityRings.moveColor)
                    ringLine("活动", ringText(0), ActivityRings.moveColor)
                    ringLine("锻炼", ringText(1), ActivityRings.exerciseColor)
                    ringLine("站立", ringText(2), ActivityRings.standColor)
                    if let w = last {
                        Text(lastText(w)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.35))
            }
            .padding(18)
            .glassCard(26)
        }
        .buttonStyle(.plain)
        .task {
            rings = await FitnessData.rings()
            last = await FitnessData.workouts(days: 14, limit: 1).first
        }
    }

    private func ringText(_ i: Int) -> String? {
        guard let r = rings else { return nil }
        switch i {
        case 0: return "\(Int(r.move))/\(Int(r.moveGoal)) 千卡"
        case 1: return "\(Int(r.exercise))/\(Int(r.exerciseGoal)) 分钟"
        default: return "\(Int(r.stand))/\(Int(r.standGoal)) 小时"
        }
    }

    private func lastText(_ w: WorkoutItem) -> String {
        let d: String = HealthFormat.duration(w.duration)
        let k: String = w.kcal.map { " · \(Int($0)) 千卡" } ?? ""
        return "最近：\(w.type) · \(d)\(k)"
    }

    private func ringLine(_ t: String, _ v: String?, _ c: Color) -> some View {
        HStack(spacing: 6) {
            Text(t).font(.caption).foregroundStyle(.secondary)
            Text(v ?? "--").font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit()).foregroundStyle(c)
        }
    }
}

// MARK: - 健身详情

struct FitnessView: View {
    @State private var rings: RingsData?
    @State private var workouts: [WorkoutItem] = []
    @State private var kcal: [DayValue] = []
    @State private var resting: (Double, Date)?
    @State private var vo2: (Double, Date)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 18) {
                    ActivityRings(r: rings ?? RingsData(), size: 130)
                    VStack(alignment: .leading, spacing: 10) {
                        big("活动", 0, ActivityRings.moveColor)
                        big("锻炼", 1, ActivityRings.exerciseColor)
                        big("站立", 2, ActivityRings.standColor)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard(26)

                HStack(spacing: 14) {
                    smallCard("静息心率", resting.map { "\(Int($0.0.rounded()))" } ?? "--", "次/分", "heart.fill", Color(red: 1, green: 0.35, blue: 0.45))
                    smallCard("最大摄氧量", vo2.map { String(format: "%.1f", $0.0) } ?? "--", "", "lungs.fill", Color(red: 0.35, green: 0.85, blue: 1))
                }

                // 最近 14 天活动卡路里
                VStack(alignment: .leading, spacing: 8) {
                    Text("最近 14 天活动卡路里").font(.subheadline.weight(.semibold))
                    Chart(kcal) { d in
                        BarMark(x: .value("日期", d.date, unit: .day), y: .value("千卡", d.value))
                            .foregroundStyle(ActivityRings.moveColor.gradient)
                            .cornerRadius(4)
                        if let g = rings?.moveGoal, g > 0 {
                            RuleMark(y: .value("目标", g)).foregroundStyle(.white.opacity(0.35))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: 3)) { _ in
                            AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
                        }
                    }
                    .frame(height: 150)
                }
                .padding(16)
                .glassCard(22)

                Text("体能训练（最近 30 天）").font(.headline).padding(.top, 4)
                if workouts.isEmpty {
                    Text("最近 30 天没有体能训练记录").font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(24).glassCard(20)
                }
                ForEach(workouts) { w in workoutRow(w) }
            }
            .padding(16)
            .padding(.bottom, 100)
        }
        .background(AppBackground())
        .navigationTitle("健身")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task {
            rings = await FitnessData.rings()
            async let w = FitnessData.workouts()
            async let k = (try? HealthService.daily(.activeEnergy, days: 14)) ?? []
            async let r = FitnessData.latest(.restingHeartRate, unit: .count().unitDivided(by: .minute()), days: 30)
            async let v = FitnessData.latest(.vo2Max, unit: HKUnit(from: "ml/kg*min"), days: 365)
            workouts = await w
            kcal = await k
            resting = await r
            vo2 = await v
        }
    }

    private func big(_ t: String, _ i: Int, _ c: Color) -> some View {
        let r = rings
        let v: String? = r.map { i == 0 ? "\(Int($0.move))" : i == 1 ? "\(Int($0.exercise))" : "\(Int($0.stand))" }
        let g: Int = i == 0 ? Int(r?.moveGoal ?? 0) : i == 1 ? Int(r?.exerciseGoal ?? 30) : Int(r?.standGoal ?? 12)
        let goal: String = "/\(g) " + (i == 0 ? "千卡" : i == 1 ? "分钟" : "小时")
        return VStack(alignment: .leading, spacing: 0) {
            Text(t).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(v ?? "--").font(.system(size: 24, weight: .bold, design: .rounded).monospacedDigit()).foregroundStyle(c)
                Text(goal).font(.caption).foregroundStyle(c.opacity(0.8))
            }
        }
    }

    private func smallCard(_ t: String, _ v: String, _ unit: String, _ icon: String, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(t, systemImage: icon).font(.caption.weight(.semibold)).foregroundStyle(c)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(v).font(.system(size: 26, weight: .bold, design: .rounded).monospacedDigit())
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(20)
    }

    private func workoutRow(_ w: WorkoutItem) -> some View {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "M月d日 EEE HH:mm"
        return HStack(spacing: 12) {
            Image(systemName: w.icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(ActivityRings.exerciseColor)
                .frame(width: 44, height: 44)
                .background(Circle().fill(ActivityRings.exerciseColor.opacity(0.15)))
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(w.type).font(.subheadline.weight(.bold))
                    Spacer()
                    Text(f.string(from: w.start)).font(.caption2).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    tag(HealthFormat.duration(w.duration), "clock")
                    if let k = w.kcal { tag(String(Int(k)) + " 千卡", "flame") }
                    if let d = w.km, d > 0.05 { tag(String(format: "%.2f 公里", d), "location") }
                    if let h = w.avgHR { tag(String(Int(h)) + " 次/分", "heart") }
                }
            }
        }
        .padding(12)
        .glassCard(18)
    }

    private func tag(_ t: String, _ icon: String) -> some View {
        Label(t, systemImage: icon).font(.caption2.monospacedDigit()).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
    }
}

// MARK: - BMI 详情

struct BMIView: View {
    @State private var height: Double?
    @State private var points: [DayValue] = []
    @State private var heightText = ""
    @State private var days = 90
    @State private var selected: Date?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let h = height, let last = points.last {
                    let (name, color) = BMI.category(last.value)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(String(format: "%.1f", last.value)).font(.system(size: 44, weight: .heavy, design: .rounded))
                            Text(name).font(.title3.weight(.bold)).foregroundStyle(color)
                        }
                        scale(last.value)
                        Text(BMI.rangeText).font(.caption).foregroundStyle(.secondary)
                        let r = BMI.healthyKg(cm: h)
                        Text(String(format: "身高 %.0f 厘米，正常体重 %.1f～%.1f 公斤", h, r.lowerBound, r.upperBound))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassCard(24)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("BMI 变化").font(.subheadline.weight(.semibold))
                            Spacer()
                            Picker("", selection: $days) {
                                Text("30天").tag(30); Text("90天").tag(90); Text("1年").tag(365)
                            }.pickerStyle(.menu).tint(.secondary)
                        }
                        let vals = points.map(\.value)
                        let lo = min(vals.min() ?? 18, 17.5), hi = max(vals.max() ?? 24, 24.5)
                        Chart {
                            RectangleMark(yStart: .value("下限", 18.5), yEnd: .value("上限", 23.9))
                                .foregroundStyle(Color.green.opacity(0.12))
                            RuleMark(y: .value("下限", 18.5)).foregroundStyle(.green.opacity(0.5)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            RuleMark(y: .value("上限", 24)).foregroundStyle(.orange.opacity(0.5)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            ForEach(points) { p in
                                LineMark(x: .value("日期", p.date, unit: .day), y: .value("BMI", p.value))
                                    .interpolationMethod(.monotone)
                                    .foregroundStyle(Color(red: 0.8, green: 0.55, blue: 1))
                                PointMark(x: .value("日期", p.date, unit: .day), y: .value("BMI", p.value))
                                    .foregroundStyle(BMI.category(p.value).1)
                                    .symbolSize(20)
                            }
                            // 点某一天：标出当天的 BMI 和体重档位
                            if let sd = selected, let p = points.first(where: { Calendar.current.isDate($0.date, inSameDayAs: sd) }) {
                                RuleMark(x: .value("选中", p.date, unit: .day)).foregroundStyle(.white.opacity(0.35))
                                PointMark(x: .value("日期", p.date, unit: .day), y: .value("BMI", p.value))
                                    .foregroundStyle(.white).symbolSize(70)
                                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                                        VStack(spacing: 0) {
                                            Text(String(format: "%.1f", p.value)).font(.system(size: 13, weight: .bold, design: .rounded))
                                            Text(selectedDay(p.date)).font(.system(size: 9))
                                        }
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 7).padding(.vertical, 3)
                                        .background(RoundedRectangle(cornerRadius: 7).fill(BMI.category(p.value).1.opacity(0.85)))
                                    }
                            }
                        }
                        .chartYScale(domain: (lo - 0.5)...(hi + 0.5))
                        .frame(height: 200)
                        .tapToSelect($selected, dates: points.map(\.date), byDay: true)
                        Text("绿色区域是健康范围").font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .glassCard(22)
                } else if height == nil {
                    Text("健康 App 里没有身高，在下面填一下就能算 BMI。").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Text("还没有体重记录").font(.subheadline).foregroundStyle(.secondary)
                }

                CardSection(footer: "身高优先用这里填的；不填就用健康 App 里的身高。") {
                    HStack {
                        Text("身高")
                        TextField("厘米", text: $heightText).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                        Text("厘米").foregroundStyle(.secondary)
                        Button("保存") {
                            BMI.manualHeight = Double(heightText) ?? 0
                            Task { await load() }
                        }
                    }
                    .padding(.vertical, 10)
                }

                Text("BMI = 体重(公斤) ÷ 身高(米)²。中国成人标准：低于 18.5 偏瘦，18.5～23.9 正常，24～27.9 超重，28 及以上肥胖。BMI 不区分肌肉和脂肪，仅供参考。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(16)
            .padding(.bottom, 100)
        }
        .background(AppBackground())
        .navigationTitle("BMI")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task(id: days) { await load() }
    }

    private func selectedDay(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "M/d"
        return f.string(from: d)
    }

    /// 横向刻度条：偏瘦 / 正常 / 超重 / 肥胖，标出当前位置
    private func scale(_ v: Double) -> some View {
        let lo = 15.0, hi = 32.0
        let segs: [(Double, Double, Color)] = [(lo, 18.5, BMI.category(17).1), (18.5, 24, BMI.category(20).1),
                                               (24, 28, BMI.category(25).1), (28, hi, BMI.category(30).1)]
        return GeometryReader { g in
            let w = g.size.width
            ZStack(alignment: .leading) {
                HStack(spacing: 2) {
                    ForEach(Array(segs.enumerated()), id: \.offset) { _, s in
                        Capsule().fill(s.2.opacity(0.75)).frame(width: max(0, (s.1 - s.0) / (hi - lo) * w - 2), height: 8)
                    }
                }
                Circle().fill(.white).frame(width: 14, height: 14)
                    .shadow(radius: 2)
                    .offset(x: CGFloat((min(hi, max(lo, v)) - lo) / (hi - lo)) * w - 7)
            }
        }
        .frame(height: 16)
    }

    private func load() async {
        let h = await BMI.height()
        height = h
        if heightText.isEmpty, let h { heightText = String(format: "%.0f", h) }
        guard let h else { points = []; return }
        let pts = (try? await HealthService.weightHistory(days: days)) ?? []
        let cal = Calendar.current
        var byDay: [Date: Double] = [:]
        for p in pts.sorted(by: { $0.date < $1.date }) { byDay[cal.startOfDay(for: p.date)] = p.kg }
        var list = byDay.map { DayValue(date: $0.key, value: BMI.value(kg: $0.value, cm: h)) }.sorted { $0.date < $1.date }
        if list.isEmpty, let w = try? await HealthService.latestWeight() {
            list = [DayValue(date: w.date, value: BMI.value(kg: w.kg, cm: h))]
        }
        points = list
    }
}
