import SwiftUI

@main
struct ClaudePoolApp: App {
    @State private var model: AppModel

    init() {
        let model = AppModel(paths: .live())
        model.start()
        _model = State(initialValue: model)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("Claude Pool", id: "manager") {
            ManagerWindow()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1040, height: 680)
        .windowResizability(.contentMinSize)
    }
}

/// Menu bar label: symbol, then optional active name (12 chars), active "5h:23% · 7d:41%" and
/// the Mac's "CPU 12% · MEM 64%".
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: BrandMark.menuBarImage)
            if !text.isEmpty {
                Text(text).monospacedDigit()
            }
        }
        .accessibilityLabel("Claude Pool, active profile \(model.profileStore.activeProfile?.name ?? "unknown")")
    }

    private var text: String {
        var parts: [String] = []
        let active = model.profileStore.activeProfile
        if model.settings.showNameInMenuBar {
            let name = active?.name ?? "?"
            parts.append(name.count > 12 ? String(name.prefix(12)) + "…" : name)
        }
        if model.settings.showActiveUsageInMenuBar, let active,
           let usage = MenuBarText.usage(fiveHour: model.usageState(active, .fiveHour).displayedWindow,
                                         sevenDay: model.usageState(active, .sevenDay).displayedWindow) {
            parts.append(usage)
        }
        if model.settings.showSystemStatsInMenuBar, let system = MenuBarText.system(model.resourceStore.system) {
            parts.append(system)
        }
        return parts.joined(separator: " · ")
    }
}
