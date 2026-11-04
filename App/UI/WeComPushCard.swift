import SwiftUI
import WidgetKit

/// 设置页：企业微信推送（自建应用）
struct WeComPushCard: View {
    @State private var c = PushConfig.current
    @State private var saved = PushConfig.current
    @State private var message: String?
    @State private var ok = true
    @State private var busy = false

    var body: some View {
        CardSection(footer: "定时提醒由小组件刷新时检查并发送，会有几分钟到半小时的误差，需要把喝水、吃药或健康小组件放在桌面上。手机直连企业微信会受「企业可信IP」限制，报 60020 就是这个原因。") {
            CardTitle("企业微信推送")
            RowDivider()
            field("企业ID", "corpid", text: $c.corpID)
            RowDivider()
            HStack {
                Text("Secret").frame(width: 76, alignment: .leading)
                SecureField("应用的 Secret", text: $c.secret)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .padding(.vertical, 10)
            RowDivider()
            field("AgentId", "1000002", text: $c.agentID, number: true)
            RowDivider()
            field("接收人", "@all 或 成员账号，多个用 | 分隔", text: $c.toUser)

            RowDivider()
            Text("推送什么").font(.footnote.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 10)
            toggleTime("💊 吃药提醒", "该吃的那天到点还没吃就推", on: $c.pill, minutes: $c.pillTime)
            RowDivider()
            toggleTime("💧 喝水提醒", "到点还没喝够达标杯数就推", on: $c.water, minutes: $c.waterTime)
            RowDivider()
            Toggle(isOn: $c.glucose) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("🩸 血糖同步")
                    Text("从罗氏智航同步到新记录时推").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 8)
            RowDivider()
            toggleTime("📋 每日健康汇总", "睡眠、体重、恢复HRV、步数", on: $c.daily, minutes: $c.dailyTime)

            RowDivider()
            HStack(spacing: 12) {
                Button {
                    Task { await save() }
                } label: {
                    Label(c == saved ? "已保存" : "保存", systemImage: "checkmark").frame(maxWidth: .infinity)
                }
                .glassButton()
                .disabled(busy || c == saved)

                Button {
                    Task { await test() }
                } label: {
                    HStack {
                        if busy { ProgressView() }
                        Label("发送测试", systemImage: "paperplane").labelStyle(.titleAndIcon)
                    }
                    .frame(maxWidth: .infinity)
                }
                .glassButton()
                .disabled(busy || !c.isReady)
            }
            .padding(.vertical, 10)
            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(ok ? Color.green : Color.orange)
                    .textSelection(.enabled)
                    .padding(.bottom, 10)
            }
        }
    }

    private func field(_ title: String, _ hint: String, text: Binding<String>, number: Bool = false) -> some View {
        HStack {
            Text(title).frame(width: 76, alignment: .leading)
            TextField(hint, text: text)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(number ? .numberPad : .asciiCapable)
        }
        .padding(.vertical, 10)
    }

    private func toggleTime(_ title: String, _ sub: String, on: Binding<Bool>, minutes: Binding<Int>) -> some View {
        let base = Calendar.current.startOfDay(for: Date())
        return HStack {
            Toggle(isOn: on) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(sub).font(.caption).foregroundStyle(.secondary)
                }
            }
            if on.wrappedValue {
                DatePicker("", selection: Binding(
                    get: { base.addingTimeInterval(TimeInterval(minutes.wrappedValue * 60)) },
                    set: { d in
                        let k = Calendar.current.dateComponents([.hour, .minute], from: d)
                        minutes.wrappedValue = (k.hour ?? 0) * 60 + (k.minute ?? 0)
                    }
                ), displayedComponents: .hourAndMinute)
                .labelsHidden()
                .fixedSize()
            }
        }
        .padding(.vertical, 8)
    }

    private func trimmed() {
        c.corpID = c.corpID.trimmingCharacters(in: .whitespacesAndNewlines)
        c.secret = c.secret.trimmingCharacters(in: .whitespacesAndNewlines)
        c.agentID = c.agentID.trimmingCharacters(in: .whitespacesAndNewlines)
        c.toUser = c.toUser.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() async {
        trimmed()
        busy = true
        defer { busy = false }
        do {
            try await PushConfig.save(c)
            saved = c
            WidgetCenter.shared.reloadAllTimelines()
            ok = true
            message = "已保存。小组件下次刷新时会读到新设置。"
        } catch {
            ok = false
            message = "保存失败：\(error.localizedDescription)"
        }
    }

    private func test() async {
        trimmed()
        busy = true
        defer { busy = false }
        do {
            try await WeCom.send("✅ 阿波推送测试成功", config: c)
            ok = true
            message = "发送成功，去企业微信看看。" + (c == saved ? "" : "别忘了点「保存」。")
        } catch {
            ok = false
            message = "发送失败：\(error.localizedDescription)"
        }
    }
}
