import SwiftUI
import WidgetKit

/// 设置页：吃药小组件（药名、每几天一次、和健康「用药」关联）
struct PillSettingsCard: View {
    @State private var s = PillSettings.current
    @State private var healthNames: [String] = []
    @State private var message: String?
    @State private var loading = false

    var body: some View {
        CardSection(footer: message ?? "健康 App 的「用药」苹果只允许读、不允许其他 App 写：在健康或手表上点了「已服用」，小组件会自动显示已吃；在小组件上点的只记在阿波里。药名要和健康里的药名（或昵称）一致才能关联。") {
            CardTitle("吃药小组件")
            RowDivider()

            HStack(spacing: 16) {
                PillCapsule(state: .due).frame(width: 54)
                PillCapsule(state: .taken).frame(width: 54)
                PillCapsule(state: .rest).frame(width: 54)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)

            RowDivider()
            HStack {
                Text("药名")
                TextField("维生素D", text: $s.name)
                    .multilineTextAlignment(.trailing)
                    .submitLabel(.done)
            }
            .padding(.vertical, 10)

            RowDivider()
            Stepper(value: $s.every, in: PillSettings.everyRange) {
                HStack {
                    Text("多久吃一次")
                    Spacer()
                    Text(s.everyText).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)

            RowDivider()
            HStack {
                Text("关联健康「用药」")
                Spacer()
                if loading {
                    ProgressView()
                } else if healthNames.isEmpty {
                    Button("授权并读取") { Task { await loadHealth() } }
                        .font(.subheadline.weight(.semibold))
                        .glassButton()
                } else {
                    Menu {
                        ForEach(healthNames, id: \.self) { n in
                            Button(n) { s.name = n }
                        }
                    } label: {
                        Label("从健康里选", systemImage: "pills")
                            .font(.subheadline.weight(.semibold))
                    }
                    .glassButton()
                }
            }
            .padding(.vertical, 8)
        }
        .task(id: s) {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, s.albumTitle != (PillSettings.savedTitle ?? PillSettings().albumTitle) else { return }
            do {
                try await PillSettings.save(s)
                WidgetCenter.shared.reloadTimelines(ofKind: "Pill")
                message = nil
            } catch {
                message = "保存失败：\(error.localizedDescription)"
            }
        }
    }

    private func loadHealth() async {
        loading = true
        defer { loading = false }
        guard #available(iOS 26.0, *) else { message = "读取健康「用药」需要 iOS 26"; return }
        do {
            try await MedsHealth.requestAccess()
            healthNames = await MedsHealth.medicationNames()
            message = healthNames.isEmpty ? "健康里没有读到药。先在健康 App →「用药」里添加维生素D，并在授权页勾选它。" : nil
            WidgetCenter.shared.reloadTimelines(ofKind: "Pill")
        } catch {
            message = "授权失败：\(error.localizedDescription)"
        }
    }
}
