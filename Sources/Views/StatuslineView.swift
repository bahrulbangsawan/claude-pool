import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Claude Code status line manager: build a layout, preview it live, apply it per profile.
struct StatuslineView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: UUID?
    @State private var previewProfileID: UUID?
    @State private var message: (MessageKind, String)?
    @State private var savingPreset = false
    @State private var presetName = ""
    @State private var restoring: (Profile, URL)?

    var body: some View {
        let store = model.statuslineStore
        Page {
            PageHeader(title: "Status Line", subtitle: "Design the line Claude Code shows under the prompt, then apply it to the profiles you choose") {
                presetsMenu
            }
        } content: {
            if let message { InlineMessage(kind: message.0, text: message.1) { self.message = nil } }
            previewCard
            applyBar
            layoutCard
            HStack(alignment: .top, spacing: Space.md) {
                paletteCard.frame(minWidth: 280)
                if let id = selection, let widget = store.widget(id) {
                    InspectorCard(widget: widget, onRemove: { store.remove(id); selection = nil })
                        .id(id)
                } else {
                    Card(title: "Component") {
                        Text("Select a component in the layout to change its colours, label or text. Drag components to reorder them or move them between lines.")
                            .font(.rowDetail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            appearanceCard
            integrationCard
            notesCard
        }
        .onAppear {
            if previewProfileID == nil { previewProfileID = model.profileStore.activeProfileID ?? model.profiles.first?.id }
        }
        .sheet(isPresented: $savingPreset) { savePresetSheet }
        .confirmationDialog("Restore the status line from this backup?", isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }),
                            presenting: restoring) { item in
            Button("Restore statusLine") { restore(item.0, from: item.1) }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text("Only the statusLine key of \(model.paths.abbreviate(SettingsPatcher.settingsURL(for: item.0).path)) is replaced with the value from \(item.1.lastPathComponent). Every other setting keeps its current value. The current file is backed up first.")
        }
    }

    // MARK: Preview

    private var previewCard: some View {
        let store = model.statuslineStore
        let profile = previewProfileID.flatMap(model.profileStore.profile(id:))
        return Card(title: "Live preview", subtitle: "Account, plan and usage are this profile's real values; model, folder, git and context use sample session values") {
            Picker("Preview profile", selection: $previewProfileID) {
                ForEach(model.profiles) { Text($0.name).tag(Optional($0.id)) }
            }
            .labelsHidden()
            .frame(maxWidth: 200)
        } content: {
            TerminalPreview(config: store.draft, values: previewValues(for: profile))
            if store.draft.powerline.enabled {
                Text("Powerline glyphs need a Powerline or Nerd Font in your terminal; the preview approximates them.")
                    .font(.meta).foregroundStyle(.secondary)
            }
            let errors = store.draft.validationErrors()
            if !errors.isEmpty {
                InlineMessage(kind: .warning, text: errors.joined(separator: " "))
            }
        }
    }

    private func previewValues(for profile: Profile?) -> StatuslineValues {
        var v = StatuslineValues(now: model.usageStore.now)
        v.model = "Opus 5.5"
        v.cwd = model.paths.userHome.appendingPathComponent("projects/my-app").path
        v.gitBranch = "main"
        v.gitStatus = .init(staged: 2, modified: 3, untracked: 1, ahead: 1, behind: 0)
        v.contextPercent = 34
        v.contextTokens = 68_400
        v.contextSize = 200_000
        v.lastInput = 1_204
        v.lastOutput = 862
        v.lastCacheRead = 64_100
        v.lastCacheWrite = 2_350
        v.costUSD = 1.42
        v.durationMs = 47 * 60 * 1000
        v.linesAdded = 156
        v.linesRemoved = 23
        v.effort = "high"
        v.version = model.binary?.version?.split(separator: " ").first.map(String.init) ?? "2.1.296"
        v.originalStatusLine = "original status line"
        if let profile {
            v.profile = profile.name
            v.account = model.authStore.status(for: profile.id)?.email
            v.plan = model.authStore.plan(for: profile.id)?.displayName
            if let snapshot = model.usageStore.snapshot(for: profile.id) {
                v.fiveHour = snapshot.fiveHour
                v.sevenDay = snapshot.sevenDay
            }
        }
        return v
    }

    // MARK: Apply bar

    private var applyBar: some View {
        let store = model.statuslineStore
        let managedCount = model.profiles.filter { store.isManaged($0.id) }.count
        return HStack(spacing: Space.sm) {
            Image(systemName: store.hasUnappliedChanges ? "pencil.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(store.hasUnappliedChanges ? Color.statusWarn : Color.statusOK)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(store.hasUnappliedChanges ? "Unapplied changes" : "Applied").font(.rowTitle.weight(.semibold))
                Text(managedCount == 0 ? "No profile uses this layout yet — turn it on under Profiles below." :
                        "Used by \(managedCount) \(managedCount == 1 ? "profile" : "profiles") · Claude Code picks up changes on its next status line refresh")
                    .font(.meta).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Revert") { model.statuslineStore.revertDraft(); selection = nil }
                .disabled(!store.hasUnappliedChanges || store.applied == nil)
                .help("Discard edits that haven't been applied")
            Button("Undo Last Apply") {
                do { try model.statuslineStore.undoLastApply(); message = (.info, "The previous layout is in effect again.") }
                catch { message = (.error, error.localizedDescription) }
            }
            .disabled(store.historyCount == 0)
            Button("Apply") {
                do {
                    try model.statuslineStore.apply()
                    message = (.info, managedCount == 0 ? "Applied. Turn it on for a profile below to see it in Claude Code." : "Applied. Claude Code shows it on its next status line refresh.")
                } catch { message = (.error, error.localizedDescription) }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!store.hasUnappliedChanges)
        }
        .padding(Space.sm)
        .background(Color.cardFill, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Color.cardStroke.opacity(0.6), lineWidth: 0.5))
    }

    // MARK: Layout

    private var layoutCard: some View {
        let store = model.statuslineStore
        return Card(title: "Layout", subtitle: "Drag to reorder or move between lines · click to edit") {
            Button {
                store.addLine()
            } label: {
                Label("Add Line", systemImage: "plus")
            }
            .disabled(store.draft.lines.count >= StatuslineConfig.maxLines)
        } content: {
            VStack(spacing: Space.xs) {
                ForEach(Array(store.draft.lines.enumerated()), id: \.offset) { index, line in
                    LineEditor(index: index, widgets: line, selection: $selection, canRemove: store.draft.lines.count > 1)
                }
            }
        }
    }

    private var paletteCard: some View {
        let groups = Dictionary(grouping: StatuslineWidgetKind.allCases, by: \.group)
        let order = ["Session", "Account", "Location", "Tokens & context", "Usage windows", "Layout & text"]
        return Card(title: "Components", subtitle: "Drag onto a line, or click to add to the last line") {
            VStack(alignment: .leading, spacing: Space.sm) {
                ForEach(order, id: \.self) { group in
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text(group).font(.meta.weight(.semibold)).foregroundStyle(.secondary)
                        FlowLayout(spacing: Space.xxs) {
                            ForEach(groups[group] ?? []) { kind in
                                Button {
                                    let line = max(0, model.statuslineStore.draft.lines.count - 1)
                                    selection = model.statuslineStore.add(kind, toLine: line)
                                } label: {
                                    Text(kind.title)
                                        .font(.meta)
                                        .padding(.horizontal, Space.xs)
                                        .padding(.vertical, 4)
                                        .background(Color.secondary.opacity(0.1), in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .help(kind.detail)
                                .draggable("add:\(kind.rawValue)")
                                .accessibilityHint("Adds \(kind.title) to the last line")
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Appearance

    private var appearanceCard: some View {
        @Bindable var store = model.statuslineStore
        let separators = [" │ ", " | ", " · ", " • ", " › ", "  ", " / "]
        return Card(title: "Appearance") {
            VStack(spacing: Space.xs) {
                SettingRow(title: "Theme", detail: "Colours for components that don't set their own") {
                    Picker("Theme", selection: $store.draft.theme) {
                        ForEach(StatuslineTheme.all) { theme in
                            Text(theme.name).tag(theme.id)
                        }
                    }
                    .labelsHidden().frame(width: 180)
                }
                Divider()
                SettingRow(title: "Separator", detail: "Between components when Powerline is off") {
                    Picker("Separator", selection: $store.draft.separator) {
                        ForEach(separators, id: \.self) { Text("“\($0)”").font(.body.monospaced()).tag($0) }
                        if !separators.contains(store.draft.separator) { Text("“\(store.draft.separator)”").tag(store.draft.separator) }
                    }
                    .labelsHidden().frame(width: 180)
                }
                Divider()
                SettingRow(title: "Padding", detail: "Spaces inside components that have a background colour") {
                    Stepper("\(store.draft.padding)", value: $store.draft.padding, in: 0...4).frame(width: 90)
                }
                Divider()
                SettingRow(title: "Powerline", detail: "Coloured blocks joined by arrow glyphs") {
                    HStack(spacing: Space.xs) {
                        Picker("Style", selection: Binding(
                            get: { store.draft.powerline.separator },
                            set: { glyph in
                                if let style = PowerlineOptions.styles.first(where: { $0.separator == glyph }) {
                                    store.draft.powerline.separator = style.separator
                                    store.draft.powerline.startCap = style.start
                                    store.draft.powerline.endCap = style.end
                                }
                            })) {
                            ForEach(PowerlineOptions.styles, id: \.separator) { Text($0.name).tag($0.separator) }
                        }
                        .labelsHidden().frame(width: 190)
                        .disabled(!store.draft.powerline.enabled)
                        Toggle("Powerline", isOn: $store.draft.powerline.enabled).toggleStyle(.switch).labelsHidden()
                    }
                }
                Divider()
                SettingRow(title: "Alignment", detail: "Centre and right alignment use the terminal width when Claude Code's terminal reports it") {
                    Picker("Alignment", selection: $store.draft.alignment) {
                        Text("Left").tag(StatuslineAlignment.left)
                        Text("Centre").tag(StatuslineAlignment.center)
                        Text("Right").tag(StatuslineAlignment.right)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                }
                Divider()
                SettingRow(title: "Colours", detail: "Use fewer colours if your terminal shows odd colours") {
                    Picker("Colour level", selection: $store.draft.colorLevel) {
                        ForEach(StatuslineColorLevel.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().frame(width: 180)
                }
                Divider()
                SettingRow(title: "Bold everything") {
                    Toggle("Bold everything", isOn: $store.draft.globalBold).toggleStyle(.switch).labelsHidden()
                }
            }
        }
    }

    // MARK: Presets

    private var presetsMenu: some View {
        Menu {
            Section("Built in") {
                ForEach(StatuslinePresets.all, id: \.name) { preset in
                    Button(preset.name) { model.statuslineStore.draft = preset.config; selection = nil }
                }
            }
            if !model.statuslineStore.presets.isEmpty {
                Section("Saved") {
                    ForEach(model.statuslineStore.presets) { preset in
                        Button(preset.name) { model.statuslineStore.draft = preset.config; selection = nil }
                    }
                }
                Menu("Delete Saved Preset") {
                    ForEach(model.statuslineStore.presets) { preset in
                        Button(preset.name, role: .destructive) { try? model.statuslineStore.deletePreset(preset.id) }
                    }
                }
            }
            Divider()
            Button("Save Current Layout as Preset…") { presetName = ""; savingPreset = true }
            Button("Import from ccstatusline…", action: importCCStatusline)
            Divider()
            Button("Restore Defaults") { model.statuslineStore.restoreDefaults(); selection = nil }
        } label: {
            Label("Presets", systemImage: "square.stack")
        }
        .fixedSize()
    }

    private var savePresetSheet: some View {
        SheetScaffold(title: "Save Preset", subtitle: "Saves the layout as it is now, including unapplied edits.", width: 420) {
            TextField("Name", text: $presetName, prompt: Text("My layout")).textFieldStyle(.roundedBorder)
        } buttons: {
            Button("Cancel", role: .cancel) { savingPreset = false }.keyboardShortcut(.cancelAction)
            Button("Save") {
                do { try model.statuslineStore.savePreset(named: presetName); savingPreset = false }
                catch { message = (.error, error.localizedDescription); savingPreset = false }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func importCCStatusline() {
        let fm = FileManager.default
        var url = model.paths.userHome.appendingPathComponent(CCStatuslineImporter.defaultLocation)
        if !fm.fileExists(atPath: url.path) {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.json]
            panel.showsHiddenFiles = true
            panel.prompt = "Import"
            panel.message = "Choose a ccstatusline settings.json"
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            url = chosen
        }
        do {
            let data = try Data(contentsOf: url)
            let (config, skipped) = try CCStatuslineImporter.convert(data)
            model.statuslineStore.draft = config
            selection = nil
            message = (.info, "Imported from \(model.paths.abbreviate(url.path)). Review it in the preview, then Apply." +
                       (skipped.isEmpty ? "" : " Skipped (no equivalent): \(skipped.joined(separator: ", ")).") +
                       " ccstatusline's own settings were not changed.")
        } catch {
            message = (.error, error.localizedDescription)
        }
    }

    // MARK: Integration

    private var integrationCard: some View {
        Card(title: "Profiles", subtitle: "Where the layout is shown. Turning it on routes the profile's status line through Claude Pool's collector (the same opt-in as usage tracking).") {
            VStack(spacing: Space.sm) {
                ForEach(model.profiles) { profile in
                    ProfileStatuslineRow(profile: profile, onMessage: { message = $0 }, onRestore: { restoring = (profile, $0) })
                    if profile.id != model.profiles.last?.id { Divider() }
                }
            }
        }
    }

    private func restore(_ profile: Profile, from url: URL) {
        do {
            try model.patcher.restoreStatusLine(fromBackup: url, for: profile)
            model.refreshLocalState()
            message = (.info, "Restored the statusLine of \(profile.name) from \(url.lastPathComponent). Other settings were left as they were.")
        } catch {
            message = (.error, error.localizedDescription)
        }
    }

    private var notesCard: some View {
        Card(title: "Good to know") {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("• Claude Code runs the status line when messages change and, with “Refresh every 10 s”, on a timer. Countdowns only move when it runs.")
                Text("• Another status line tool (ccstatusline, a shell script, …) installed in the same profile is replaced while Claude Pool's layout is on. Its command is kept and can be shown with the “Original status line” component; turning Claude Pool's layout off shows it again.")
                Text("• A project's own .claude/settings.json statusLine overrides the profile's. Claude Code also skips status lines in untrusted folders and when disableAllHooks is set.")
                Text("• Only settings.json's statusLine key is ever changed, with a backup before each change.")
            }
            .font(.meta).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Line editor

private struct LineEditor: View {
    @Environment(AppModel.self) private var model
    let index: Int
    let widgets: [StatuslineWidget]
    @Binding var selection: UUID?
    let canRemove: Bool
    @State private var targeted = false

    var body: some View {
        HStack(alignment: .center, spacing: Space.xs) {
            Text("Line \(index + 1)").font(.meta.weight(.semibold)).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.xxs) {
                    ForEach(Array(widgets.enumerated()), id: \.element.id) { position, widget in
                        WidgetChip(widget: widget, selected: selection == widget.id)
                            .onTapGesture { selection = widget.id }
                            .draggable("move:\(widget.id.uuidString)")
                            .dropDestination(for: String.self) { items, _ in
                                handleDrop(items, at: position)
                            }
                    }
                    if widgets.isEmpty {
                        Text("Drop components here").font(.meta).foregroundStyle(.tertiary).padding(.horizontal, Space.xs)
                    }
                }
                .padding(Space.xxs)
            }
            .frame(minHeight: 36)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.inner).fill(targeted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06)))
            .dropDestination(for: String.self) { items, _ in
                handleDrop(items, at: widgets.count)
            } isTargeted: { targeted = $0 }
            Menu {
                ForEach(StatuslineWidgetKind.allCases) { kind in
                    Button(kind.title) { selection = model.statuslineStore.add(kind, toLine: index) }
                }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Add a component to line \(index + 1)")
            .accessibilityLabel("Add component to line \(index + 1)")
            Button {
                model.statuslineStore.removeLine(index)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .disabled(!canRemove)
            .help("Remove line \(index + 1)")
            .accessibilityLabel("Remove line \(index + 1)")
        }
    }

    private func handleDrop(_ items: [String], at position: Int) -> Bool {
        guard let item = items.first else { return false }
        if item.hasPrefix("move:"), let id = UUID(uuidString: String(item.dropFirst(5))) {
            model.statuslineStore.move(id, toLine: index, at: position)
            return true
        }
        if item.hasPrefix("add:"), let kind = StatuslineWidgetKind(rawValue: String(item.dropFirst(4))) {
            selection = model.statuslineStore.add(kind, toLine: index, at: position)
            return true
        }
        return false
    }
}

private struct WidgetChip: View {
    let widget: StatuslineWidget
    let selected: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "line.3.horizontal").font(.caption2).foregroundStyle(.tertiary).accessibilityHidden(true)
            if let color = widget.foreground?.swiftUIColor {
                Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
            }
            Text(title).font(.meta.weight(selected ? .semibold : .regular)).lineLimit(1)
        }
        .padding(.horizontal, Space.xs)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: Radius.inner).fill(selected ? Color.accentColor.opacity(0.2) : Color.cardFill))
        .overlay(RoundedRectangle(cornerRadius: Radius.inner).strokeBorder(selected ? Color.accentColor : Color.cardStroke, lineWidth: selected ? 1.5 : 0.5))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var title: String {
        switch widget.kind {
        case .customText: "“\(widget.text ?? "")”"
        case .separator: "Separator \(widget.text ?? "│")"
        default: widget.kind.title
        }
    }
}

// MARK: - Inspector

private struct InspectorCard: View {
    @Environment(AppModel.self) private var model
    @State var widget: StatuslineWidget
    let onRemove: () -> Void

    var body: some View {
        Card(title: widget.kind.title, subtitle: widget.kind.detail) {
            Button(role: .destructive, action: onRemove) { Label("Remove", systemImage: "trash") }
                .controlSize(.small)
        } content: {
            VStack(spacing: Space.xs) {
                if widget.kind == .customText || widget.kind == .separator {
                    SettingRow(title: widget.kind == .separator ? "Character" : "Text") {
                        TextField("Text", text: Binding(get: { widget.text ?? "" }, set: { widget.text = String($0.prefix(widget.kind == .separator ? 4 : 120)) }))
                            .textFieldStyle(.roundedBorder).frame(width: 200)
                    }
                    Divider()
                }
                if !widget.kind.label.isEmpty {
                    SettingRow(title: "Show label", detail: "e.g. “\(widget.kind.label) …”") {
                        Toggle("Show label", isOn: $widget.showLabel).toggleStyle(.switch).labelsHidden()
                    }
                    Divider()
                }
                if widget.kind != .flexSpacer {
                    SettingRow(title: "Text colour") { ColorChooser(color: $widget.foreground) }
                    Divider()
                    if widget.kind != .separator {
                        SettingRow(title: "Background") { ColorChooser(color: $widget.background) }
                        Divider()
                    }
                    SettingRow(title: "Bold") {
                        Toggle("Bold", isOn: $widget.bold).toggleStyle(.switch).labelsHidden()
                    }
                }
            }
        }
        .onChange(of: widget) { _, value in model.statuslineStore.update(value) }
    }
}

/// Theme default, one of the 16 terminal colours, or a custom colour.
private struct ColorChooser: View {
    @Binding var color: StatuslineColor?

    var body: some View {
        HStack(spacing: Space.xs) {
            Menu {
                Button("Theme default") { color = nil }
                Divider()
                ForEach(StatuslineColor.ansiNames, id: \.self) { name in
                    Button { color = StatuslineColor(name) } label: {
                        Label(name, systemImage: color?.rawValue == name ? "checkmark" : "circle.fill")
                    }
                }
            } label: {
                Text(color?.rawValue ?? "Theme default").font(.meta.monospaced())
            }
            .fixedSize()
            ColorPicker("Custom colour", selection: Binding(
                get: { color?.swiftUIColor ?? .gray },
                set: { color = StatuslineColor(hex: $0) }
            ), supportsOpacity: false)
            .labelsHidden()
        }
    }
}

// MARK: - Profiles

private struct ProfileStatuslineRow: View {
    @Environment(AppModel.self) private var model
    let profile: Profile
    let onMessage: ((MessageKind, String)) -> Void
    let onRestore: (URL) -> Void

    var body: some View {
        let current = model.patcher.describeCurrent(for: profile)
        let managed = model.statuslineStore.isManaged(profile.id)
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.sm) {
                ProfileAvatar(name: profile.name, colorHex: profile.colorHex, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.name).font(.rowTitle.weight(.semibold))
                    Text(describe(current, managed: managed)).font(.meta).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                }
                Spacer()
                Toggle("Use Claude Pool's status line", isOn: Binding(
                    get: { managed && model.trackingState(for: profile) == .enabled },
                    set: { on in
                        do {
                            try model.setStatuslineManaged(on, for: profile)
                        } catch { onMessage((.error, error.localizedDescription)) }
                    }))
                    .toggleStyle(.switch)
                    .help(managed ? "Shows the applied layout" : "Shows the applied layout in this profile's Claude Code sessions")
            }
            HStack(spacing: Space.sm) {
                if case let .claudePool(interval) = current {
                    Toggle("Refresh every 10 s", isOn: Binding(
                        get: { interval != nil },
                        set: { on in
                            do { try model.patcher.setRefreshInterval(on ? 10 : nil, for: profile); model.refreshLocalState() }
                            catch { onMessage((.error, error.localizedDescription)) }
                        }))
                        .toggleStyle(.checkbox)
                        .help("Adds refreshInterval to the statusLine (Claude Code 2.1.97 or later), so countdowns move while idle")
                }
                if case .ccstatusline = current {
                    StatusBadge(text: "ccstatusline installed", systemImage: "exclamationmark.triangle.fill", tint: .statusWarn)
                        .help("Turning on Claude Pool's layout replaces it in this profile (kept and restorable).")
                }
                Spacer()
                let backups = model.patcher.backups(for: profile.id)
                Menu("Backups (\(backups.count))") {
                    ForEach(backups.prefix(10), id: \.self) { url in
                        Button(url.lastPathComponent) { onRestore(url) }
                    }
                }
                .fixedSize()
                .disabled(backups.isEmpty)
                .help("Restore only the statusLine key from an earlier settings.json backup")
            }
            .controlSize(.small)
        }
    }

    private func describe(_ current: SettingsPatcher.CurrentStatusLine, managed: Bool) -> String {
        switch current {
        case .none: return "No status line configured"
        case .claudePool:
            if managed { return "Shows Claude Pool's layout" }
            return profile.originalStatusLine != nil ? "Claude Pool collector, showing your original status line" : "Claude Pool collector, showing the usage summary"
        case let .ccstatusline(command): return "ccstatusline: \(command)"
        case let .other(command): return "Custom command: \(command)"
        case let .unreadable(error): return "settings.json can't be read: \(error)"
        }
    }
}

// MARK: - Terminal preview

/// A dark terminal strip rendering exactly the segments the collector would print.
struct TerminalPreview: View {
    let config: StatuslineConfig
    let values: StatuslineValues

    var body: some View {
        GeometryReader { geometry in
            let columns = max(30, Int((geometry.size.width - 2 * Space.sm) / 7.25))
            let lines = StatuslineRenderer(config: config).segments(values: values, width: columns)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 0) {
                    Text("> ").foregroundStyle(Color(white: 0.55))
                    Text("Try “refactor the parser”").foregroundStyle(Color(white: 0.35))
                }
                Rectangle().fill(Color(white: 0.25)).frame(height: 0.5)
                if lines.isEmpty {
                    Text("(nothing to show with these values)").foregroundStyle(Color(white: 0.45))
                }
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(attributed(line)).lineLimit(1).fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.system(size: 12, design: .monospaced))
            .padding(Space.sm)
            .frame(width: geometry.size.width, alignment: .leading)
        }
        .frame(height: CGFloat(52 + 17 * max(1, config.lines.count)))
        .background(Color(red: 0.11, green: 0.11, blue: 0.13), in: RoundedRectangle(cornerRadius: Radius.inner))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status line preview: \(StatuslineRenderer(config: config).segments(values: values).map { $0.map(\.text).joined() }.joined(separator: ", "))")
    }

    private func attributed(_ segments: [StatuslineSegment]) -> AttributedString {
        var result = AttributedString()
        for segment in segments {
            var run = AttributedString(Self.approximateGlyphs(segment.text))
            run.foregroundColor = segment.foreground?.swiftUIColor ?? Color(white: 0.85)
            if let background = segment.background?.swiftUIColor { run.backgroundColor = background }
            if segment.bold { run.font = .system(size: 12, weight: .bold, design: .monospaced) }
            result += run
        }
        return result
    }

    /// Powerline private-use glyphs aren't in the system font; show close shapes instead.
    static func approximateGlyphs(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{E0B0}", with: "▶")
            .replacingOccurrences(of: "\u{E0B4}", with: "◗")
            .replacingOccurrences(of: "\u{E0B6}", with: "◖")
            .replacingOccurrences(of: "\u{E0BC}", with: "◤")
            .replacingOccurrences(of: "\u{E0C0}", with: "▶")
    }
}

extension StatuslineColor {
    var swiftUIColor: Color? {
        guard let (r, g, b) = rgb else { return nil }
        return Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }

    init(hex color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .gray
        let r = Int((ns.redComponent * 255).rounded()), g = Int((ns.greenComponent * 255).rounded()), b = Int((ns.blueComponent * 255).rounded())
        self.init(String(format: "#%02X%02X%02X", r, g, b))
    }
}

/// Wraps children onto new rows, for the component palette.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
