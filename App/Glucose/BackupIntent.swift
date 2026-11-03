import AppIntents
import UniformTypeIdentifiers

/// 快捷指令动作「导出阿波备份」：生成完整备份文件（血糖记录、标签、测量人、备注、照片小图）。
/// 在快捷指令里接「存储文件」存到 iCloud 云盘，再加一个每天定时的自动化，就能自动备份到 iCloud。
struct ExportBackupIntent: AppIntent {
    static var title: LocalizedStringResource = "导出阿波备份"
    static var description = IntentDescription("生成阿波的完整备份文件，可以接「存储文件」存到 iCloud 云盘")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        guard let data = GlucoseBackup.make(includeThumbs: true) else {
            throw NSError(domain: "阿波", code: 1, userInfo: [NSLocalizedDescriptionKey: "生成备份失败"])
        }
        AutoBackup.run()           // 顺便更新本机备份
        AutoBackup.markCloudDone() // 记下备份时间，App 里就不会再提醒
        return .result(value: IntentFile(data: data, filename: "阿波备份.json", type: .json))
    }
}

/// 让快捷指令 App 里直接能搜到「备份阿波」
struct AboShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ExportBackupIntent(),
                    phrases: ["备份\(.applicationName)", "导出\(.applicationName)备份"],
                    shortTitle: "导出阿波备份",
                    systemImageName: "icloud.and.arrow.up")
    }
}
