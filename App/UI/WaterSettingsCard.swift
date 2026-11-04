import SwiftUI
import WidgetKit

/// 设置页：喝水小组件（杯子形状、每杯毫升、每天杯数）
struct WaterSettingsCard: View {
    @State private var s = WaterSettings.current
    @State private var message: String?

    var body: some View {
        CardSection(footer: message ?? "改完后小组件会自动更新。设置通过相册里一个空相簿「\(WaterSettings.prefix)…」传给小组件，请不要删除它。") {
            CardTitle("喝水小组件")
            RowDivider()

            // 预览：喝了两杯的样子
            HStack(spacing: 12) {
                ForEach(0..<min(s.cups, 6), id: \.self) { i in
                    CupView(kind: s.kind, filled: i < 2, isNext: i == 2,
                            time: i == 0 ? "09:30" : i == 1 ? "14:05" : nil, big: true)
                        .frame(height: 70)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 12)
            .animation(.easeOut(duration: 0.2), value: s)

            RowDivider()
            Picker("杯子形状", selection: $s.kind) {
                ForEach(CupKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.vertical, 10)

            RowDivider()
            Stepper(value: $s.ml, in: WaterSettings.mlRange, step: 50) {
                HStack {
                    Text("每杯")
                    Spacer()
                    Text("\(s.ml) ml").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)

            RowDivider()
            Stepper(value: $s.cups, in: WaterSettings.cupsRange) {
                HStack {
                    Text("每天")
                    Spacer()
                    Text("\(s.cups) 杯 · 共 \(s.ml * s.cups) ml").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)

            RowDivider()
            Text("喝到 \(s.enough) 杯算达标，\(s.cups) 杯算喝满。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
        }
        .task(id: s) {
            // 停 0.6 秒再保存，连续点加减号时不会反复改相簿
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, s.albumTitle != (WaterSettings.savedTitle ?? WaterSettings().albumTitle) else { return }
            do {
                try await WaterSettings.save(s)
                WidgetCenter.shared.reloadTimelines(ofKind: "Water")
                message = nil
            } catch {
                message = "保存失败：\(error.localizedDescription)"
            }
        }
    }
}
