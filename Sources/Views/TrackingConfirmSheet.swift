import SwiftUI

/// Shows the exact before/after `statusLine` values before anything is written.
struct TrackingConfirmSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: TrackingRequest

    var body: some View {
        SheetScaffold(
            title: request.enable ? "Turn On Usage Tracking for “\(request.profile.name)”?" : "Turn Off Usage Tracking for “\(request.profile.name)”?",
            subtitle: "Only the statusLine key of \(model.paths.abbreviate(SettingsPatcher.settingsURL(for: request.profile).path)) changes. A backup is saved to ~/.claude-pool/backups first.",
            width: 640
        ) {
            HStack(alignment: .top, spacing: Space.sm) {
                valueBox(title: "Before", value: request.preview.before)
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                    .padding(.top, 60)
                    .accessibilityHidden(true)
                valueBox(title: "After", value: request.preview.after)
            }
            if request.enable {
                InlineMessage(kind: .info, text: SettingsPatcher.confirmationText)
                if request.preview.before != nil {
                    Text("Your current status line keeps working: the collector runs it with the same input and shows its output. Turning tracking off restores it exactly.")
                        .font(.meta)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if request.preview.before == request.preview.after {
                InlineMessage(kind: .info, text: "statusLine no longer points to the collector, so it's left as it is.")
            }
        } buttons: {
            Button("Cancel", role: .cancel) {
                model.cancelTrackingRequest()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button(request.enable ? "Turn On Tracking" : "Turn Off Tracking") {
                model.confirmTrackingChange(request)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private func valueBox(title: String, value: String?) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(title).font(.meta.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView(.vertical) {
                Text(value ?? "No statusLine key")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(value == nil ? .secondary : .primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(Space.xs)
            }
            .frame(height: 140)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value ?? "no statusLine key")")
    }
}
