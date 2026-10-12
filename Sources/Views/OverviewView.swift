import SwiftUI

/// The active account up top, then every account in the user's order (never sorted by usage).
struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Page {
            PageHeader(title: "Overview", subtitle: subtitle) {
                Button {
                    Task { await model.refreshAllAuth() }
                } label: {
                    Label("Refresh Sign-In Status", systemImage: "arrow.clockwise")
                }
                .disabled(!model.authStore.refreshing.isEmpty)
            }
        } content: {
            if let active = model.profileStore.activeProfile {
                ActiveAccountCard(profile: active)
            } else if let unknown = model.profileStore.unknownActiveDirectory {
                InlineMessage(kind: .warning, text: "The active directory \(unknown) isn't a registered profile. Choose a profile below to switch.")
            }

            VStack(alignment: .leading, spacing: Space.sm) {
                Text("All Accounts").font(.sectionTitle).accessibilityAddTraits(.isHeader)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: Space.md, alignment: .top)], alignment: .leading, spacing: Space.md) {
                    ForEach(model.profiles) { AccountCard(profile: $0) }
                }
            }

            Text("Values are what Claude Code reported in its status line, at the time shown. Usage on claude.ai or other devices after that time isn't included.")
                .font(.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var subtitle: String {
        let count = model.profiles.count
        return "\(count) \(count == 1 ? "account" : "accounts") · switching applies to new claude launches"
    }
}
