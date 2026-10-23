import AppKit
import SwiftUI

/// Settings › Updates: automatic updates, the running version, and Check for Updates….
struct UpdatesCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card(title: "Updates") {
            VStack(spacing: Space.xs) {
                SettingRow(title: "Update automatically",
                           detail: "Checks GitHub for a new release at launch and every 6 hours, installs it and reopens Claude Pool. Running claude sessions keep running. Each check is one request to api.github.com.") {
                    Toggle("Update automatically", isOn: Binding(
                        get: { model.settings.updateAutomatically },
                        set: { enabled in
                            model.settings.updateAutomatically = enabled
                            if enabled { Task { await model.checkForUpdatesIfDue() } }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                Divider()
                SettingRow(title: "Claude Pool \(AppVersion.current?.description ?? "development build")", detail: status) {
                    actions
                }
                if case let .failed(message) = model.updateState {
                    InlineMessage(kind: .error, text: message) { model.dismissUpdateMessage() }
                }
            }
        }
    }

    private var status: String {
        let checked = model.lastUpdateCheck.map { "Checked \(model.formatting.age(since: $0))." }
        switch model.updateState {
        case .idle: return checked ?? "Not checked yet."
        case .checking: return "Checking for updates…"
        case .upToDate: return ["Up to date.", checked].compactMap { $0 }.joined(separator: " ")
        case let .available(release): return "Claude Pool \(release.version) is available."
        case let .installing(release): return "Installing \(release.version). Claude Pool reopens when it's done."
        case .failed: return "The last check didn't finish."
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch model.updateState {
        case .checking, .installing:
            ProgressView().controlSize(.small)
        case let .available(release):
            HStack(spacing: Space.xs) {
                Button("Release Notes") { NSWorkspace.shared.open(release.pageURL) }
                Button("Install and Relaunch") { Task { await model.installUpdate(release) } }
                    .buttonStyle(.borderedProminent)
            }
        default:
            Button("Check for Updates…") { Task { await model.checkForUpdates() } }
        }
    }
}

/// The menu's update line: an update that's available or installing, and what Check for
/// Updates… found. Results of automatic checks other than a new version stay in Settings.
struct MenuUpdateBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if isVisible {
            content.padding([.horizontal, .bottom], Space.sm)
        }
    }

    private var isVisible: Bool {
        switch model.updateState {
        case .available, .installing: true
        case .checking, .upToDate, .failed: model.updateCheckWasManual
        case .idle: false
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.updateState {
        case let .available(release):
            InlineMessage(kind: .info, text: "Claude Pool \(release.version) is available.") {
                Button("Install") { Task { await model.installUpdate(release) } }
                    .controlSize(.small)
            }
        case let .installing(release):
            progress("Installing Claude Pool \(release.version)…")
        case .checking:
            progress("Checking for updates…")
        case .upToDate:
            InlineMessage(kind: .info, text: "Claude Pool \(AppVersion.current?.description ?? "") is up to date.") {
                model.dismissUpdateMessage()
            }
        case let .failed(message):
            InlineMessage(kind: .error, text: message) { model.dismissUpdateMessage() }
        case .idle:
            EmptyView()
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: Space.xs) {
            ProgressView().controlSize(.small)
            Text(text).font(.rowDetail).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}
