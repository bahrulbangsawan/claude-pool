import AppKit
import SwiftUI

/// Signs in one or more profile × server pairs, one after another; see `McpSignInQueue`.
struct McpSignInSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let queue: McpSignInQueue

    var body: some View {
        SheetScaffold(title: title, subtitle: "Runs Claude Code's own sign-in for each profile. Claude Pool never sees your password or tokens.", width: 640) {
            if queue.steps.count > 1 { stepList }
            if queue.isComplete {
                summary
            } else if let flow = queue.flow, let step = queue.current {
                McpLoginPanel(flow: flow, step: step, onRetry: queue.retry)
                    .id(flow.id)
            } else {
                ProgressView().controlSize(.small)
            }
        } buttons: {
            if !queue.isComplete {
                if queue.flow?.phase == .finishOnClaudeAI || queue.flow.map({ isFailure($0.phase) }) == true {
                    if queue.hasNext { Button("Next") { queue.next() }.keyboardShortcut(.defaultAction) }
                } else if queue.hasNext {
                    Button("Skip") { queue.skip() }
                        .help("Leave this profile signed out for now and go on to the next")
                }
            }
            Spacer()
            if queue.isComplete || (!queue.hasNext && queue.flow?.phase.isFinished == true) {
                Button("Done", action: close).keyboardShortcut(queue.isComplete ? .defaultAction : .cancelAction)
            } else {
                Button("Cancel", role: .cancel, action: close).keyboardShortcut(.cancelAction)
            }
        }
        // However the sheet goes away, no sign-in keeps running behind it.
        .onDisappear { queue.cancel() }
    }

    private var title: String {
        if let name = queue.singleServerName { return "Sign In to \(McpCatalog.title(for: name))" }
        return "Sign In to MCP Servers"
    }

    private func isFailure(_ phase: McpLoginFlow.Phase) -> Bool {
        switch phase {
        case .failed, .expired: true
        default: false
        }
    }

    private var stepList: some View {
        let showServer = queue.singleServerName == nil
        return ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(queue.steps.enumerated()), id: \.element.id) { index, step in
                    HStack(spacing: Space.xs) {
                        stepSymbol(step, isCurrent: index == queue.index && !queue.isComplete)
                            .frame(width: 18)
                        ProfileAvatar(name: step.profile.name, colorHex: step.profile.colorHex, size: 16)
                        Text(step.profile.name).lineLimit(1)
                        if showServer {
                            Text(McpCatalog.title(for: step.serverName)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(stepWord(step, isCurrent: index == queue.index && !queue.isComplete))
                            .font(.meta).foregroundStyle(.secondary)
                    }
                    .font(.rowDetail)
                    .padding(.vertical, 3)
                    .padding(.horizontal, Space.xs)
                    .background(index == queue.index && !queue.isComplete ? Color.accentColor.opacity(0.1) : .clear,
                                in: RoundedRectangle(cornerRadius: Radius.inner))
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .frame(maxHeight: min(CGFloat(queue.steps.count) * 26 + 6, 170))
    }

    @ViewBuilder
    private func stepSymbol(_ step: McpSignInStep, isCurrent: Bool) -> some View {
        switch queue.outcome(of: step) {
        case .signedIn?: Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.statusOK)
        case .finishOnClaudeAI?: Image(systemName: "arrow.up.forward.circle").foregroundStyle(Color.accentColor)
        case .skipped?: Image(systemName: "forward.circle").foregroundStyle(.secondary)
        case .failed?: Image(systemName: "xmark.octagon.fill").foregroundStyle(Color.statusFail)
        case nil:
            if isCurrent { Image(systemName: "arrow.right.circle.fill").foregroundStyle(Color.accentColor) }
            else { Image(systemName: "circle").foregroundStyle(.tertiary) }
        }
    }

    private func stepWord(_ step: McpSignInStep, isCurrent: Bool) -> String {
        switch queue.outcome(of: step) {
        case .signedIn?: "Signed in"
        case .finishOnClaudeAI?: "Finish on claude.ai"
        case .skipped?: "Skipped"
        case .failed?: "Didn't finish"
        case nil: isCurrent ? "Now" : "Waiting"
        }
    }

    private var summary: some View {
        let signedIn = queue.signedInCount
        let total = queue.steps.count
        return HStack(alignment: .top, spacing: Space.sm) {
            Image(systemName: signedIn == total ? "checkmark.seal.fill" : "checkmark.circle")
                .font(.title)
                .foregroundStyle(signedIn == total ? Color.statusOK : .secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(signedIn == total ? (total == 1 ? "Signed in" : "All \(total) signed in") : "\(signedIn) of \(total) signed in")
                    .font(.sectionTitle)
                Text(signedIn == 0
                     ? "Nothing was changed. Servers still waiting for a sign-in show a key on the MCP Servers page."
                     : "Claude Code saved each sign-in in that profile's Keychain entry. New sessions can use the tools; sessions already running pick them up after /mcp or a restart.")
                    .font(.meta).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func close() {
        queue.cancel()
        model.mcpSignIn = nil
        dismiss()
    }
}

/// One `claude mcp login`: the authorization link (open or copy), the pasted address, every outcome.
struct McpLoginPanel: View {
    @Environment(AppModel.self) private var model
    let flow: McpLoginFlow
    let step: McpSignInStep
    var onRetry: () -> Void
    @State private var address = ""
    @State private var copied = false

    private var server: String { McpCatalog.title(for: step.serverName) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.xs) {
                ProfileAvatar(name: step.profile.name, colorHex: step.profile.colorHex, size: 22)
                Text("\(server) on \(step.profile.name)").font(.sectionTitle)
                if let email = model.authStore.status(for: step.profile.id)?.email {
                    Text(email).font(.meta).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            switch flow.phase {
            case .starting:
                progress("Starting Claude Code's sign-in…")
            case .waitingForAuthorization:
                waiting
            case .checkingRedirect:
                progress("Passing the address to Claude Code…")
            case .verifying:
                progress("Checking the connection…")
            case .succeeded:
                succeeded
            case .finishOnClaudeAI:
                connector
            case let .failed(message):
                outcome(kind: .error, text: message)
            case .expired:
                outcome(kind: .warning, text: "The link expired after \(Int(McpLoginFlow.lifetime / 60)) minutes. Start again for a fresh link.")
            case .cancelled:
                outcome(kind: .info, text: "Sign-in stopped. Nothing was changed.")
            }
        }
        .animation(.default, value: flow.phase)
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: Space.xs) {
            ProgressView().controlSize(.small)
            Text(text).font(.rowDetail).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var waiting: some View {
        numbered(1, "Open the link and approve access") {
            linkBox
            HStack(spacing: Space.xs) {
                Button {
                    if let url = flow.authorizationURL { NSWorkspace.shared.open(url) }
                } label: {
                    Label("Open in Browser", systemImage: "safari")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(address.isEmpty ? .defaultAction : .init(.return, modifiers: .command))
                copyButton
                Spacer()
                countdown
            }
            Text("Opened on this Mac, the sign-in finishes here on its own after you approve. Sign in to \(server) with the account you want this profile to use.")
                .font(.meta).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        numbered(2, "Or paste the address the browser ends on") {
            HStack(spacing: Space.xs) {
                TextField("Address", text: $address, prompt: Text("http://localhost:…/callback?code=…"))
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .onSubmit(submit)
                    .accessibilityLabel("Address the browser ended on")
                Button("Complete Sign-In", action: submit)
                    .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(address.isEmpty ? .init(.return, modifiers: .command) : .defaultAction)
            }
            Text("Used the link on another device, or the page says it can't connect? Copy the whole address from that browser's address bar and paste it here.")
                .font(.meta).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = flow.redirectError {
                InlineMessage(kind: .warning, text: error)
            }
        }
        HStack(spacing: Space.xs) {
            ProgressView().controlSize(.mini)
            Text("Waiting for approval…").font(.meta).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var linkBox: some View {
        if let url = flow.authorizationURL {
            Text(url.absoluteString)
                .font(.meta.monospaced())
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .padding(Space.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.inner))
                .accessibilityLabel("Authorization link")
        }
    }

    private var copyButton: some View {
        Button {
            guard let url = flow.authorizationURL else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
            copied = true
            Task { try? await Task.sleep(for: .seconds(2)); copied = false }
        } label: {
            Label(copied ? "Copied" : "Copy Link", systemImage: copied ? "checkmark" : "doc.on.doc")
        }
    }

    private var countdown: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, Int(flow.expiresAt.timeIntervalSince(context.date)))
            Text("Expires in \(remaining / 60):\(String(format: "%02d", remaining % 60))")
                .font(.meta.monospacedDigit())
                .foregroundStyle(remaining < 60 ? Color.statusWarn : Color.secondary)
        }
    }

    private func numbered<Content: View>(_ number: Int, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.xs) {
                Text("\(number)")
                    .font(.meta.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Color.accentColor, in: Circle())
                    .accessibilityHidden(true)
                Text(title).font(.rowTitle.weight(.semibold)).accessibilityAddTraits(.isHeader)
            }
            content()
        }
    }

    private func submit() {
        let value = address
        address = ""   // The address carries a one-time code; don't keep it around.
        flow.submit(redirect: value)
    }

    private var succeeded: some View {
        HStack(alignment: .top, spacing: Space.sm) {
            Image(systemName: "checkmark.seal.fill").font(.title).foregroundStyle(Color.statusOK).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("Signed in to \(server)").font(.sectionTitle)
                Text("Claude Code saved the sign-in in its Keychain entry for \(model.paths.abbreviate(step.profile.configDir)).")
                    .font(.meta).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var connector: some View {
        let email = model.authStore.status(for: step.profile.id)?.email
        Text("\(server) is a claude.ai connector, so its sign-in finishes on claude.ai. Open the link in a browser signed in to claude.ai as \(email ?? "this profile's account"). The connector is ready the next time Claude Code starts with this profile.")
            .font(.rowDetail).fixedSize(horizontal: false, vertical: true)
        linkBox
        HStack(spacing: Space.xs) {
            Button {
                if let url = flow.authorizationURL { NSWorkspace.shared.open(url) }
            } label: {
                Label("Open in Browser", systemImage: "safari")
            }
            .buttonStyle(.borderedProminent)
            copyButton
        }
    }

    private func outcome(kind: MessageKind, text: String) -> some View {
        InlineMessage(kind: kind, text: text) {
            Button("Start Again", action: onRetry).controlSize(.small)
        }
    }
}

/// Add Server: a preset (Cloudflare, AWS, Neon, Polar …) or any remote address, then sign-in.
struct McpAddServerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var selection: String? = McpCatalog.presets.first?.id
    @State private var name = McpCatalog.presets.first?.id ?? ""
    @State private var region = McpCatalog.presets.first?.defaultRegion ?? ""
    @State private var customURL = ""
    @State private var transport: McpTransport = .http
    @State private var targets: Set<UUID> = []
    @State private var signInAfter = true
    @State private var isAdding = false
    @State private var error: String?

    private static let customID = "custom"
    private var preset: McpPreset? { McpCatalog.presets.first { $0.id == selection } }
    private var isCustom: Bool { selection == Self.customID }

    var body: some View {
        SheetScaffold(title: "Add MCP Server",
                      subtitle: "Adds a remote server with Claude Code's own claude mcp add. Servers that need an account sign in through your browser, so no API key is typed here.",
                      width: 640) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(McpCatalog.presets) { preset in
                        presetRow(preset)
                    }
                    customRow
                }
            }
            .frame(height: 250)
            .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: Radius.inner))
            details
            if let message = validationMessage ?? error {
                InlineMessage(kind: error == nil ? .warning : .error, text: message)
            }
        } buttons: {
            if isAdding { ProgressView().controlSize(.small) }
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(signInAfter ? "Add and Sign In" : "Add", action: add)
                .keyboardShortcut(.defaultAction)
                .disabled(isAdding || validationMessage != nil || selection == nil || model.binary == nil || effectiveTargets.isEmpty)
        }
        .onAppear {
            targets = Set(model.profiles.map(\.id))
            // Start on the first suggestion that isn't set up yet.
            if let first = McpCatalog.presets.first(where: { !isAdded($0) }) { choose(first) }
        }
    }

    private func isAdded(_ preset: McpPreset) -> Bool {
        model.mcpStore.hasServer(named: preset.id, orURL: preset.url(region: preset.defaultRegion))
    }

    private func choose(_ preset: McpPreset) {
        selection = preset.id
        name = preset.id
        region = preset.defaultRegion ?? ""
        transport = preset.transport
    }

    private func presetRow(_ preset: McpPreset) -> some View {
        choiceRow(id: preset.id, title: preset.title, detail: preset.summary, badge: isAdded(preset) ? "Added" : nil) {
            choose(preset)
        }
    }

    private var customRow: some View {
        choiceRow(id: Self.customID, title: "Other server", detail: "Any remote MCP server address (HTTP or SSE).", badge: nil) {
            if McpCatalog.presets.contains(where: { $0.id == name }) { name = "" }
        }
    }

    private func choiceRow(id: String, title: String, detail: String, badge: String?, onSelect: @escaping () -> Void) -> some View {
        let selected = selection == id
        return Button {
            selection = id
            error = nil
            onSelect()
        } label: {
            HStack(spacing: Space.sm) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.rowTitle.weight(.medium))
                    Text(detail).font(.meta).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if let badge { StatusBadge(text: badge, systemImage: "checkmark", tint: .statusOK) }
            }
            .padding(.horizontal, Space.sm)
            .padding(.vertical, 6)
            .background(selected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: Radius.inner))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var details: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            field("Name") {
                TextField("Name", text: $name, prompt: Text("my-server"))
                    .labelsHidden().textFieldStyle(.roundedBorder).font(.body.monospaced())
            }
            if let preset, !preset.regions.isEmpty {
                field("Region") {
                    Picker("Region", selection: $region) {
                        ForEach(preset.regions, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            if isCustom {
                field("Address") {
                    TextField("Address", text: $customURL, prompt: Text("https://example.com/mcp"))
                        .labelsHidden().textFieldStyle(.roundedBorder).font(.body.monospaced())
                }
                field("Transport") {
                    Picker("Transport", selection: $transport) {
                        ForEach(McpTransport.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                }
            } else if !url.isEmpty {
                field("Address") {
                    Text(url).font(.meta.monospaced()).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                }
            }
            field("Profiles") { profilePicker }
            field("") {
                Toggle("Sign in right after adding", isOn: $signInAfter)
            }
            if let note = preset?.note {
                InlineMessage(kind: .info, text: note)
            }
        }
    }

    @ViewBuilder
    private var profilePicker: some View {
        if model.settings.shareExtensions {
            Text("Every profile (Shared Extensions is on)").foregroundStyle(.secondary)
        } else {
            HStack(spacing: Space.sm) {
                ForEach(model.profiles) { profile in
                    Toggle(profile.name, isOn: Binding(
                        get: { targets.contains(profile.id) },
                        set: { if $0 { targets.insert(profile.id) } else { targets.remove(profile.id) } }
                    ))
                    .toggleStyle(.checkbox)
                }
            }
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Text(label).foregroundStyle(.secondary).frame(width: 72, alignment: .trailing)
            content()
            Spacer(minLength: 0)
        }
    }

    private var url: String {
        if isCustom { return customURL.trimmingCharacters(in: .whitespaces) }
        return preset?.url(region: region.isEmpty ? nil : region) ?? ""
    }

    private var effectiveTargets: [Profile] {
        model.settings.shareExtensions ? model.profiles : model.profiles.filter { targets.contains($0.id) }
    }

    private var validationMessage: String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, !McpCatalog.isValidName(trimmed) {
            return "Use only letters, digits, “-” and “_” in the name."
        }
        if isCustom, !customURL.isEmpty, !McpCatalog.isValidURL(customURL) {
            return "Enter an https:// address (http:// only for a server on this Mac)."
        }
        if trimmed.isEmpty || url.isEmpty { return nil }
        // Profiles that already have it are skipped; only when all do is there nothing to add.
        let having = effectiveTargets.filter { model.mcpStore.entry(trimmed, for: $0.id) != nil }
        if !having.isEmpty, having.count == effectiveTargets.count {
            let place = having.count == 1 ? "“\(having[0].name)”" : "every chosen profile"
            return "“\(trimmed)” is already in \(place). Sign it in from the MCP Servers page, or use another name to add a second copy."
        }
        return nil
    }

    private func add() {
        let serverName = name.trimmingCharacters(in: .whitespaces)
        guard McpCatalog.isValidName(serverName), McpCatalog.isValidURL(url), validationMessage == nil else {
            error = serverName.isEmpty ? "Enter a name." : "Enter a valid address."
            return
        }
        isAdding = true
        error = nil
        let signIn = signInAfter
        Task {
            defer { isAdding = false }
            do {
                let result = try await model.addMcpServer(name: serverName, url: url, transport: transport, to: effectiveTargets)
                if !result.failures.isEmpty {
                    error = "Added, except: " + result.failures.joined(separator: "; ")
                    return
                }
                dismiss()
                if signIn, !result.needingSignIn.isEmpty {
                    // Let this sheet close before the sign-in sheet opens.
                    try? await Task.sleep(for: .milliseconds(350))
                    try await model.beginMcpSignIn(result.needingSignIn.map { McpSignInStep(profile: $0, serverName: serverName) })
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
