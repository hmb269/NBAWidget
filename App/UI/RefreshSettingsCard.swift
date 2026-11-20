import SwiftUI
import WidgetKit

/// 设置页：小组件刷新间隔（越久越省电）
struct RefreshSettingsCard: View {
    @State private var s = RefreshSettings.current
    @State private var message: String?

    var body: some View {
        CardSection(footer: message ?? "外观改了几秒后小组件会自动变。间隔越长越省电。喝水、吃药只在零点和点击时刷新；NBA 按比赛情况自动调整。iOS 还会根据你看手机的频率限制刷新次数，实际间隔可能更长。") {
            CardTitle("小组件刷新和外观")
            RowDivider()
            row("健康", sub: "步数、睡眠、体重、HRV", value: $s.health, options: RefreshSettings.healthOptions)
            RowDivider()
#if !LITE
            row("血糖", sub: "写入健康后、点小组件时会立即刷新", value: $s.glucose, options: RefreshSettings.glucoseOptions)
            RowDivider()
#endif
            VStack(alignment: .leading, spacing: 8) {
                Text("配色")
                Text("所有小组件一起换。「跟随系统」是桌面浅色时白底、深色时黑底").font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 10) {
                    ForEach(WidgetThemes.all) { t in
                        ThemeSwatch(t: t, selected: s.theme == t.id)
                            .onTapGesture { s.theme = t.id }
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .task(id: s) {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, s.albumTitle != (RefreshSettings.savedTitle ?? RefreshSettings().albumTitle) else { return }
            do {
                try await RefreshSettings.save(s)
                WidgetCenter.shared.reloadAllTimelines()
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

/// 配色小样：底色 + 一个字的颜色示意
struct ThemeSwatch: View {
    let t: WidgetThemeDef
    let selected: Bool

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                if t.id == 0 {
                    // 跟随系统：一半白一半黑
                    HStack(spacing: 0) {
                        Color.white
                        Color(red: 0.11, green: 0.11, blue: 0.11)
                    }
                } else {
                    t.gradient
                }
                Text("7")
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                    .foregroundStyle(t.dark == false ? Color.black.opacity(0.8) : Color.white)
                    .opacity(t.id == 0 ? 0 : 1)
                Circle().fill(Color(red: 0.4, green: 0.88, blue: 0.88)).frame(width: 6, height: 6)
                    .offset(x: 11, y: -11)
            }
            .frame(height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(selected ? Color(red: 0.4, green: 0.88, blue: 0.88) : Color.white.opacity(0.15), lineWidth: selected ? 2.5 : 0.8))
            Text(t.name).font(.system(size: 10)).foregroundStyle(selected ? .primary : .secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}
