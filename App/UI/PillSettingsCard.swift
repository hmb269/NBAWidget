import SwiftUI
import WidgetKit

/// 设置页：吃药小组件（药名、每几天一次、和健康「用药」关联）
struct PillSettingsCard: View {
    @State private var s = PillSettings.current
    @State private var healthNames: [String] = []
    @State private var message: String?
    @State private var loading = false
    @State private var alertText: String?

    var body: some View {
        CardSection(footer: message ?? "健康 App 的「用药」苹果只允许读、不允许其他 App 写：在健康或手表上点了「已服用」，小组件会自动显示已吃；在小组件上点的只记在阿波里。药名要和健康里的药名（或昵称）一致才能关联。") {
            CardTitle("吃药小组件")
            RowDivider()

            HStack(spacing: 16) {
                PillCapsule(state: .due, kind: s.shape).frame(width: 54, height: 44)
                PillCapsule(state: .taken, kind: s.shape).frame(width: 54, height: 44)
                PillCapsule(state: .rest, kind: s.shape).frame(width: 54, height: 44)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .animation(.easeOut(duration: 0.2), value: s.shape)

            RowDivider()
            Picker("形状", selection: $s.shape) {
                ForEach(PillShapeKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.vertical, 10)

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
        .alert("健康「用药」", isPresented: Binding(get: { alertText != nil }, set: { if !$0 { alertText = nil } })) {
            Button("好") { alertText = nil }
        } message: {
            Text(alertText ?? "")
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
        guard #available(iOS 26.0, *) else { alertText = "读取健康「用药」需要 iOS 26 或更新。"; return }
        do {
            try await MedsHealth.requestAccess()
        } catch {
            alertText = "授权失败：\(error.localizedDescription)"
            return
        }
        healthNames = await MedsHealth.medicationNames()
        WidgetCenter.shared.reloadTimelines(ofKind: "Pill")
        if healthNames.isEmpty {
            alertText = """
            没有读到任何药。可能是：
            1. 健康 App 里还没添加药：打开健康 →「浏览」→「用药」→ 添加药物，把维生素D加进去，设成隔天。
            2. 授权页没弹出或没勾选：打开系统「设置 → 健康 → 数据访问与设备 → 阿波 →『用药』」，打开维生素D。
            弄好后回来再点一次。
            """
        } else {
            let hit = healthNames.contains { $0.contains(s.name) || s.name.contains($0) }
            alertText = "读到 \(healthNames.count) 种药：" + healthNames.joined(separator: "、") +
                (hit ? "\n已经和「\(s.name)」关联上了。" : "\n点「从健康里选」选一个，药名一致才能关联。")
        }
    }
}
