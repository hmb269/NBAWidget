import Foundation

/// 小组件刷新时检查：到点了就推企业微信（吃药、喝水、每日汇总），每天每种只推一次
enum WidgetPush {
    static func run() async {
        PushConfig.refreshFromAlbum()
        let c = PushConfig.current
        guard c.isReady else { return }

        if c.pill, WeCom.isTime(c.pillTime), !WeCom.sentToday("pill") {
            PillSettings.refreshFromAlbum()
            let s = PillSettings.current
            let health = await MedsHealth.takenDates(matching: s.name)
            let st = PillStatus(local: PillLog.local, health: health, settings: s)
            if st.kind == .due {
                var t = "💊 今天要吃\(s.name)"
                if let g = st.gapDays, g > s.every { t += "（已经隔了 \(g) 天）" }
                t += "\n吃了在小组件上点一下药丸"
                await WeCom.pushOnce("pill", text: t, config: c)
            }
        }

        if c.water, WeCom.isTime(c.waterTime), !WeCom.sentToday("water") {
            WaterSettings.refreshFromAlbum()
            let n = WaterLog.count
            if n < WaterLog.enough {
                let t = "💧 今天才喝了 \(n) 杯（\(WaterLog.totalML) ml），还差 \(WaterLog.enough - n) 杯达标"
                await WeCom.pushOnce("water", text: t, config: c)
            }
        }

        if c.daily, WeCom.isTime(c.dailyTime), !WeCom.sentToday("daily") {
            let t = await WeCom.dailySummary()
            await WeCom.pushOnce("daily", text: t, config: c)
        }
    }

    /// 今天还没到点的提醒里最早的一个（让小组件到时候刷新一次）
    static func nextCheck(now: Date = Date()) -> Date? {
        let c = PushConfig.current
        guard c.isReady else { return nil }
        var times: [(Bool, Int, String)] = [(c.pill, c.pillTime, "pill"), (c.water, c.waterTime, "water"), (c.daily, c.dailyTime, "daily")]
        times = times.filter { $0.0 && !WeCom.sentToday($0.2) }
        let dates = times.map { WeCom.date(today: $0.1).addingTimeInterval(30) }.filter { $0 > now }
        return dates.min()
    }

    /// 时间线下次刷新：原定时间、下一个提醒点、开了推送时最多 30 分钟看一次
    static func refreshDate(_ planned: Date, now: Date = Date()) -> Date {
        var d = planned
        if let n = nextCheck(now: now) { d = min(d, n) }
        if PushConfig.current.isReady { d = min(d, now.addingTimeInterval(30 * 60)) }
        return d
    }
}
