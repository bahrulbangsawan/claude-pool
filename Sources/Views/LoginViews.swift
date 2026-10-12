import AppKit
import SwiftUI

/// The in-app sign-in: authorization link (open or copy), code entry, and every outcome.
struct LoginPanel: View {
    @Environment(AppModel.self) private var model
    let flow: LoginFlow
    var onRetry: () -> Void
    @State private var code = ""
    @State private var copied = false
    @FocusState private var codeFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            switch flow.phase {
            case .starting:
                progress("Starting Claude Code's sign-in…")
            case .waitingForAuthorization:
                waiting
            case .submittingCode:
                progress("Checking the code with Claude Code…")
            case .verifying:
                progress("Verifying the new sign-in…")
            case let .succeeded(status):
                succeeded(status)
            case let .failed(message):
                outcome(kind: .error, text: message)
            case .expired:
                outcome(kind: .warning, text: "The authorization link expired after \(Int(LoginFlow.lifetime / 60)) minutes. Start again for a fresh link.")
            case .cancelled:
                outcome(kind: .info, text: "Sign-in cancelled. Nothing was changed.")
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
        step(1, "Open the authorization page") {
            if let url = flow.manualURL ?? flow.callbackURL {
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
            HStack(spacing: Space.xs) {
                Button {
                    if let url = flow.callbackURL ?? flow.manualURL { NSWorkspace.shared.open(url) }
                } label: {
                    Label("Open in Browser", systemImage: "safari")
                }
                .buttonStyle(.borderedProminent)
                Button {
                    guard let url = flow.manualURL ?? flow.callbackURL else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy Link", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = max(0, Int(flow.expiresAt.timeIntervalSince(context.date)))
                    Text("Expires in \(remaining / 60):\(String(format: "%02d", remaining % 60))")
                        .font(.meta.monospacedDigit())
                        .foregroundStyle(remaining < 60 ? Color.statusWarn : Color.secondary)
                }
            }
            Text("The page signs in whichever claude.ai account your browser is using. Opened on this Mac, sign-in completes here on its own. The copied link works in any browser and shows a code instead.")
                .font(.meta).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        step(2, "If the page shows a code, paste it") {
            HStack(spacing: Space.xs) {
                TextField("Authorization code", text: $code, prompt: Text("Paste the code (it contains a #)"))
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .focused($codeFocused)
                    .onSubmit(submit)
                    .accessibilityLabel("Authorization code")
                Button("Complete Authentication", action: submit)
                    .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        HStack(spacing: Space.xs) {
            ProgressView().controlSize(.mini)
            Text("Waiting for authorization…").font(.meta).foregroundStyle(.secondary)
        }
    }

    private func step<Content: View>(_ number: Int, _ title: String, @ViewBuilder content: () -> Content) -> some View {
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
        let value = code
        code = ""   // The code is single-use; don't keep it around.
        flow.submit(code: value)
    }

    @ViewBuilder
    private func succeeded(_ status: AuthStatus) -> some View {
        HStack(alignment: .top, spacing: Space.sm) {
            Image(systemName: "checkmark.seal.fill").font(.title).foregroundStyle(Color.statusOK).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("Signed in as \(status.email ?? "your account")").font(.sectionTitle)
                HStack(spacing: Space.xs) {
                    if let plan = model.authStore.plan(for: flow.profile.id) { PlanBadge(plan: plan) }
                    if let org = status.orgName { Text(org).font(.meta).foregroundStyle(.secondary) }
                }
                Text("Credentials were saved by Claude Code in your macOS Keychain for \(model.paths.abbreviate(flow.profile.configDir)).")
                    .font(.meta).foregroundStyle(.secondary)
            }
        }
        if let previous = flow.previousIdentity, let email = status.email, previous.lowercased() != email.lowercased() {
            InlineMessage(kind: .warning, text: "This profile was signed in as \(previous) and now uses \(email). Sessions already running with this profile may keep the old sign-in until they restart.")
        }
        let duplicates = model.authStore.duplicates(of: flow.profile.id, among: model.profiles)
        if !duplicates.isEmpty {
            InlineMessage(kind: .warning, text: "Same account as \(duplicates.map(\.name).joined(separator: ", ")). Two profiles on one account share the same usage limits.")
        }
    }

    private func outcome(kind: MessageKind, text: String) -> some View {
        InlineMessage(kind: kind, text: text) {
            Button("Start Again", action: onRetry).controlSize(.small)
        }
    }
}

/// Sign in (or re-sign) an existing profile in the app.
struct SignInSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let profile: Profile
    @State private var error: String?

    var body: some View {
        SheetScaffold(title: "Sign In “\(profile.name)”", subtitle: "Uses Claude Code's own sign-in for \(model.paths.abbreviate(profile.configDir)). Claude Pool never sees your password or tokens.", width: 600) {
            if let flow = model.loginFlow, flow.profile.id == profile.id {
                LoginPanel(flow: flow, onRetry: start)
            } else if let error {
                InlineMessage(kind: .error, text: error)
            } else {
                ProgressView().controlSize(.small)
            }
        } buttons: {
            Button("Sign In with Terminal Instead") {
                cancelFlow()
                Task { try? await model.openTerminal(profile, forSignIn: true); dismiss() }
            }
            .disabled(model.binary == nil)
            Spacer()
            if finished {
                Button("Done") { model.loginFlow = nil; dismiss() }.keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel", role: .cancel) { cancelFlow(); dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .task { if model.loginFlow?.profile.id != profile.id { start() } }
    }

    private var finished: Bool { model.loginFlow?.phase.isFinished ?? false }

    private func start() {
        Task {
            do { try await model.beginLogin(for: profile) } catch { self.error = error.localizedDescription }
        }
    }

    private func cancelFlow() {
        model.loginFlow?.cancel()
        model.loginFlow = nil
    }
}

/// Add Account: name and directory, then the in-app sign-in, then the result.
struct AddAccountSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var nameEdited = false
    @State private var slug = ""
    @State private var slugEdited = false
    @State private var directory = ""
    @State private var directoryEdited = false
    @State private var colorHex = ProfileColor.presets[1].hex
    @State private var emailHint = ""
    @State private var trackUsage = true
    @State private var error: String?
    @State private var created: Profile?
    @State private var createdDirectory = false

    var body: some View {
        if let created {
            signInStep(created)
        } else {
            form
        }
    }

    private var form: some View {
        SheetScaffold(title: "Add Account", subtitle: "Each account gets its own Claude Code config directory and sign-in. You'll sign in on the next step, without Terminal.") {
            VStack(spacing: Space.sm) {
                field("Name") {
                    TextField("Name", text: Binding(get: { name }, set: { name = $0; nameEdited = true }), prompt: Text("Work"))
                        .labelsHidden().textFieldStyle(.roundedBorder)
                }
                field("Email") {
                    TextField("Email", text: $emailHint, prompt: Text("Optional — pre-fills the sign-in page"))
                        .labelsHidden().textFieldStyle(.roundedBorder)
                        .textContentType(.emailAddress)
                }
                field("Directory") {
                    HStack(spacing: Space.xs) {
                        TextField("Directory", text: Binding(get: { directory }, set: { directory = $0; directoryEdited = true }), prompt: Text("~/.claude-work"))
                            .labelsHidden().textFieldStyle(.roundedBorder).font(.body.monospaced())
                        Button("Choose…") {
                            if let url = Panels.chooseDirectory(startingAt: model.paths.userHome.path) {
                                directory = url.standardizedFileURL.path
                                directoryEdited = true
                            }
                        }
                    }
                }
                field("Color") { ColorSwatchPicker(selection: $colorHex) }
                field("") {
                    Toggle("Collect usage windows from Claude Code's status line", isOn: $trackUsage)
                        .help("Points this new profile's statusLine at the Claude Pool collector. Existing settings are never replaced without the before/after confirmation.")
                }
            }
            .onChange(of: name) { _, value in
                if !slugEdited { slug = Slug.make(from: value) }
                if !directoryEdited { directory = defaultDirectory(for: slug) }
            }
            .onChange(of: emailHint) { _, value in
                // Name the account after its email unless a name was typed.
                if !nameEdited || name.isEmpty {
                    name = String(value.prefix(Profile.maxNameLength))
                    nameEdited = false
                    slug = Slug.make(from: name)
                    if !directoryEdited { directory = defaultDirectory(for: slug) }
                }
            }
            if let message = validationMessage ?? error {
                InlineMessage(kind: .warning, text: message)
            }
        } buttons: {
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Continue to Sign-In", action: create)
                .keyboardShortcut(.defaultAction)
                .disabled(model.binary == nil)
        }
    }

    private func signInStep(_ profile: Profile) -> some View {
        SheetScaffold(title: "Sign In “\(profile.name)”", subtitle: "Claude Code's own sign-in runs in the background for \(model.paths.abbreviate(profile.configDir)).", width: 600) {
            if let flow = model.loginFlow, flow.profile.id == profile.id {
                LoginPanel(flow: flow) { startLogin(profile) }
            } else {
                ProgressView().controlSize(.small)
            }
            if let error { InlineMessage(kind: .error, text: error) }
        } buttons: {
            if case .succeeded = model.loginFlow?.phase {
                Button("Make Active") {
                    model.setActive(profile)
                    finish()
                }
                Spacer()
                Button("Done", action: finish).keyboardShortcut(.defaultAction)
            } else {
                Button(createdDirectory ? "Cancel and Remove Account" : "Cancel and Remove Profile", role: .destructive) {
                    discard(profile)
                }
                Spacer()
                Button("Keep Signed-Out Profile") { model.loginFlow?.cancel(); finish() }
                    .help("Keep the profile and sign in later")
            }
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: Space.sm) {
            Text(label).foregroundStyle(.secondary).frame(width: 72, alignment: .trailing)
            content()
        }
    }

    private func defaultDirectory(for slug: String) -> String {
        slug.isEmpty ? "" : model.paths.userHome.appendingPathComponent(".claude-\(slug)").path
    }

    private var validationMessage: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
        do {
            try model.profileStore.validate(name: name, slug: slug, configDir: model.paths.expandTilde(directory))
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func create() {
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            error = ProfileValidationError.nameEmpty.localizedDescription
            return
        }
        if let validationMessage { error = validationMessage; return }
        let dir = model.paths.expandTilde(directory)
        let existed = FileManager.default.fileExists(atPath: dir)
        do {
            let profile = try model.profileStore.add(name: name, slug: slug, configDir: dir, colorHex: colorHex)
            createdDirectory = !existed
            model.refreshLocalState()
            // A brand-new directory has no settings to preserve, so the toggle above is the consent.
            // An existing directory goes through the before/after confirmation later instead.
            if trackUsage, !existed { try? model.enableTracking(profile) }
            created = profile
            startLogin(profile)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func startLogin(_ profile: Profile) {
        Task {
            do { try await model.beginLogin(for: profile, emailHint: emailHint) } catch { self.error = error.localizedDescription }
        }
    }

    private func discard(_ profile: Profile) {
        model.loginFlow?.cancel()
        model.loginFlow = nil
        do {
            try model.deleteProfile(profile, moveDirectoryToTrash: createdDirectory, restoreSettings: true)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func finish() {
        if let created { model.route = .profile(created.id) }
        model.loginFlow = nil
        dismiss()
    }
}
