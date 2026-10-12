import SwiftUI

struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let checks = model.diagnostics
        Page {
            PageHeader(title: "Diagnostics", subtitle: subtitle) {
                if model.isRunningDiagnostics { ProgressView().controlSize(.small) }
                Button {
                    Task {
                        await model.refreshAllAuth()
                        await model.runDiagnostics()
                    }
                } label: {
                    Label("Run Again", systemImage: "arrow.clockwise")
                }
                .disabled(model.isRunningDiagnostics)
            }
        } content: {
            if checks.isEmpty {
                Card {
                    HStack(spacing: Space.xs) {
                        ProgressView().controlSize(.small)
                        Text("Running checks…").foregroundStyle(.secondary)
                    }
                }
            } else {
                summary(checks)
                DiagnosticGroup(title: "General", checks: checks.filter { $0.profileName == nil && $0.status != .info })
                ForEach(model.profiles) { profile in
                    let rows = checks.filter { $0.id.hasPrefix("profile-\(profile.id.uuidString)") }
                    if !rows.isEmpty {
                        DiagnosticGroup(title: profile.name, colorHex: profile.colorHex, checks: rows)
                    }
                }
                DiagnosticGroup(title: "Not Checked Automatically", checks: checks.filter { $0.profileName == nil && $0.status == .info })
            }
        }
    }

    private var subtitle: String {
        guard let ranAt = model.diagnosticsRunAt else { return "Checks your setup. Values of environment variables are never read." }
        return "Checked \(model.formatting.age(since: ranAt)) · environment variable values are never read"
    }

    private func summary(_ checks: [DiagnosticCheck]) -> some View {
        let counts = (
            pass: checks.filter { $0.status == .pass }.count,
            warn: checks.filter { $0.status == .warn }.count,
            fail: checks.filter { $0.status == .fail }.count
        )
        return HStack(spacing: Space.sm) {
            SummaryTile(title: "Passed", count: counts.pass, systemImage: "checkmark.circle.fill", tint: .statusOK)
            SummaryTile(title: "Warnings", count: counts.warn, systemImage: "exclamationmark.triangle.fill", tint: .statusWarn)
            SummaryTile(title: "Failed", count: counts.fail, systemImage: "xmark.octagon.fill", tint: .statusFail)
        }
    }
}

private struct SummaryTile: View {
    let title: String
    let count: Int
    let systemImage: String
    let tint: Color

    var body: some View {
        Card {
            HStack(spacing: Space.sm) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(count == 0 ? Color.secondary.opacity(0.5) : tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(count)").font(.metric)
                    Text(title).font(.meta).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct DiagnosticGroup: View {
    let title: String
    var colorHex: String?
    let checks: [DiagnosticCheck]

    var body: some View {
        if !checks.isEmpty {
            Card {
                HStack(spacing: Space.xs) {
                    if let colorHex { ProfileAvatar(name: title, colorHex: colorHex, size: 20) }
                    Text(title).font(.sectionTitle).accessibilityAddTraits(.isHeader)
                }
                VStack(alignment: .leading, spacing: Space.xs) {
                    ForEach(Array(checks.enumerated()), id: \.element.id) { index, check in
                        if index > 0 { Divider().padding(.leading, 28) }
                        DiagnosticRow(check: check)
                    }
                }
            }
        }
    }
}

private struct DiagnosticRow: View {
    let check: DiagnosticCheck

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(check.title).font(.rowTitle.weight(.medium))
                    Spacer()
                    Text(statusWord).font(.meta.weight(.medium)).foregroundStyle(color)
                }
                Text(check.detail)
                    .font(.rowDetail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let fix = check.fix {
                    Label(fix, systemImage: "wrench.and.screwdriver")
                        .font(.rowDetail)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, Space.xxs)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch check.status {
        case .pass: "checkmark.circle.fill"
        case .info: "info.circle"
        case .warn: "exclamationmark.triangle.fill"
        case .fail: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch check.status {
        case .pass: .statusOK
        case .info: .secondary
        case .warn: .statusWarn
        case .fail: .statusFail
        }
    }

    private var statusWord: String {
        switch check.status {
        case .pass: "Pass"
        case .info: "Info"
        case .warn: "Warning"
        case .fail: "Fail"
        }
    }
}
