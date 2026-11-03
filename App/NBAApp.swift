import SwiftUI
import WidgetKit
import PhotosUI

@main
struct NBAApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

private let accent = Color(red: 0.88, green: 0.15, blue: 0.25)

struct TeamPicker: View {
    @Binding var favorites: Set<String>
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var refreshTick = 0

    var body: some View {
        NavigationStack {
            List {
                Section {
                    let _ = refreshTick // 从桌面切回来时重新检查同步状态
                    let status = FavoriteStore.syncStatus(for: favorites)
                    Label(status.text, systemImage: status.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(status.ok ? Color.green : Color.orange)
                }
                teamSection("东部", NBAService.east)
                teamSection("西部", NBAService.west)
            }
            .navigationTitle("我的球队")
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { refreshTick += 1 }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !favorites.isEmpty {
                        Button("清空") { favorites = [] }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }.bold()
                }
            }
        }
    }

    private func teamSection(_ title: String, _ codes: [String]) -> some View {
        let sorted = codes.sorted { (NBAService.teams[$0] ?? $0).localizedCompare(NBAService.teams[$1] ?? $1) == .orderedAscending }
        return Section(header: Text(title)) {
            ForEach(sorted, id: \.self) { code in
                Button {
                    if favorites.contains(code) { favorites.remove(code) } else { favorites.insert(code) }
                } label: {
                    HStack {
                        Text(NBAService.teams[code] ?? code)
                            .foregroundStyle(.primary)
                        Text(code)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: favorites.contains(code) ? "star.fill" : "star")
                            .foregroundStyle(favorites.contains(code) ? accent : Color.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct AppGameRow: View {
    let game: Game
    let favorites: Set<String>

    var body: some View {
        HStack {
            team(game.away, game.awayCode)
                .frame(maxWidth: .infinity, alignment: .trailing)
            VStack(spacing: 2) {
                Text(game.middleText)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(game.state == "in" ? .red : .primary)
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 90)
            team(game.home, game.homeCode)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }

    private func team(_ name: String, _ code: String) -> some View {
        let fav = favorites.contains(code)
        return Text(name)
            .font(.body.weight(fav ? .heavy : .medium))
            .foregroundStyle(fav ? accent : .primary)
    }

    private var statusText: String {
        switch game.state {
        case "pre": return "客 @ 主"
        case "in": return game.liveText
        default: return game.isPostponed ? "" : "已结束"
        }
    }
}

struct HealthSnapshot {
    var sleep: HealthService.SleepData?
    var weight: HealthService.WeightData?
    var hrv: HealthService.HRVData?
    var steps: Int?
}

struct HealthRow: View {
    let icon: String
    let title: String
    let value: String?

    var body: some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            Text(value ?? "暂无数据")
                .font(.body.weight(.semibold).monospacedDigit())
                .foregroundStyle(value == nil ? .secondary : .primary)
        }
    }
}

/// 一行：当前图标 + 换照片 + 恢复默认
struct IconRow: View {
    let slot: IconSlot
    let changed: () -> Void
    @State private var item: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var errorText: String?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    ZStack {
                        Circle().fill(Color.accentColor.opacity(0.2))
                        Image(systemName: slot.symbol).foregroundStyle(Color.accentColor)
                    }
                }
            }
            .frame(width: 36, height: 36)
            .clipShape(Circle())

            Text(slot.title)
            Spacer()
            PhotosPicker(selection: $item, matching: .images, photoLibrary: .shared()) {
                Text("换照片")
            }
            .buttonStyle(.borderless)
            if image != nil {
                Button("默认", role: .destructive) {
                    IconStore.reset(slot)
                    image = nil
                    Task {
                        await IconStore.clearAlbum(slot)
                        refresh()
                    }
                }
                .buttonStyle(.borderless)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let errorText {
                Text(errorText).font(.caption2).foregroundStyle(.red).offset(y: 14)
            }
        }
        .onAppear { image = IconStore.image(for: slot) }
        .onChange(of: item) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                    IconStore.save(img, for: slot)
                    image = img
                    do {
                        try await IconStore.putInAlbum(slot, assetID: newItem.itemIdentifier, image: img)
                        errorText = nil
                    } catch {
                        errorText = "放进相簿失败：" + error.localizedDescription
                    }
                    refresh()
                }
                item = nil
            }
        }
    }

    private func refresh() {
        WidgetCenter.shared.reloadAllTimelines()
        changed()
    }
}
