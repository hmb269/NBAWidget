import SwiftUI
import WidgetKit

/// 设置页：小组件刷新间隔（越久越省电）
struct RefreshSettingsCard: View {
    @State private var s = RefreshSettings.current
    @State private var message: String?

    var body: some View {
        CardSection(footer: message ?? "间隔越长越省电。喝水、吃药只在零点和点击时刷新；NBA 按比赛情况自动调整。iOS 还会根据你看手机的频率限制刷新次数，实际间隔可能更长。") {
            CardTitle("小组件刷新")
            RowDivider()
            row("健康", sub: "步数、睡眠、体重、HRV", value: $s.health, options: RefreshSettings.healthOptions)
            RowDivider()
            row("血糖", sub: "写入健康后、点小组件时会立即刷新", value: $s.glucose, options: RefreshSettings.glucoseOptions)
        }
        .task(id: s) {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, s.albumTitle != (RefreshSettings.savedTitle ?? RefreshSettings().albumTitle) else { return }
            do {
                try await RefreshSettings.save(s)
                WidgetCenter.shared.reloadTimelines(ofKind: "HealthAll")
                WidgetCenter.shared.reloadTimelines(ofKind: "Glucose")
                message = nil
            } catch {
                message = "保存失败：\(error.localizedDescription)"
            }
        }
    }

    private func label(_ m: Int) -> String { m < 60 ? "\(m) 分钟" : "\(m / 60) 小时" }

    private func row(_ title: String, sub: String, value: Binding<Int>, options: [Int]) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(sub).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker(title, selection: value) {
                ForEach(options, id: \.self) { Text(label($0)).tag($0) }
            }
            .pickerStyle(.menu)
            .tint(.secondary)
        }
        .padding(.vertical, 8)
    }
}
