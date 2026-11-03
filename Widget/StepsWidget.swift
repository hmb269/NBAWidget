import WidgetKit
import SwiftUI

/// 今日步数：小组件扩展自己查 HealthKit（不依赖 App Group）
struct StepsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "HealthSteps", provider: StepsProvider()) { entry in
            StepsWidgetView(entry: entry)
        }
        .configurationDisplayName("今日步数")
        .description("今天走了多少步（iPhone + 手表合并）。先在 App 里授权健康数据")
        .supportedFamilies([.systemSmall])
    }
}

struct StepsEntry: TimelineEntry {
    let date: Date
    let result: HealthService.StepResult
}

struct StepsProvider: TimelineProvider {
    func placeholder(in context: Context) -> StepsEntry {
        StepsEntry(date: Date(), result: .init(steps: 6543, updated: Date(), note: nil))
    }

    func getSnapshot(in context: Context, completion: @escaping (StepsEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
            return
        }
        Task { completion(StepsEntry(date: Date(), result: await HealthService.loadSteps())) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StepsEntry>) -> Void) {
        Task {
            let entry = StepsEntry(date: Date(), result: await HealthService.loadSteps())
            // 系统会限制刷新次数，这里请求 15 分钟一次
            let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date())!
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }
}

struct StepsWidgetView: View {
    let entry: StepsEntry
    private let green = Color(red: 0.2, green: 0.85, blue: 0.4)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("今日步数", systemImage: "figure.walk")
                .font(.caption.weight(.semibold))
                .foregroundStyle(green)
            Spacer(minLength: 0)
            if let s = entry.result.steps {
                Text(s.formatted())
                    .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .foregroundStyle(.white)
            } else {
                Text("--")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer(minLength: 0)
            Text(footer)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(Color.black, for: .widget)
    }

    private var footer: String {
        var parts: [String] = []
        if let t = entry.result.updated {
            parts.append(t.formatted(date: .omitted, time: .shortened) + " 更新")
        }
        if let n = entry.result.note { parts.append(n) }
        return parts.isEmpty ? " " : parts.joined(separator: " · ")
    }
}
