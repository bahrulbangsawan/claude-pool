import SwiftUI

/// Registers existing `~/.claude-*` directories as profiles. Nothing inside them is read.
struct AdoptExistingSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [URL] = []
    @State private var selected: Set<URL> = []
    @State private var errors: [String] = []

    var body: some View {
        SheetScaffold(title: "Adopt Existing Directories", subtitle: "Directories in your home folder named .claude-*. Ones already registered are shown but can't be selected.") {
            if candidates.isEmpty {
                ContentUnavailableView {
                    Label("No Directories Found", systemImage: "folder.badge.questionmark")
                } description: {
                    Text("There are no .claude-* directories in \(model.paths.abbreviate(model.paths.userHome.path)). Use Add Profile to create one.")
                }
                .frame(height: 160)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(candidates.enumerated()), id: \.element) { index, url in
                        if index > 0 { Divider() }
                        let registered = model.isRegistered(directory: url)
                        Toggle(isOn: Binding(
                            get: { selected.contains(url) || registered },
                            set: { if $0 { selected.insert(url) } else { selected.remove(url) } }
                        )) {
                            HStack {
                                Text(model.paths.abbreviate(url.path)).font(.body.monospaced())
                                Spacer()
                                if registered { StatusBadge(text: "Registered", systemImage: "checkmark", tint: .secondary) }
                            }
                        }
                        .toggleStyle(.checkbox)
                        .disabled(registered)
                        .padding(.vertical, Space.xs)
                    }
                }
                .padding(.horizontal, Space.sm)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
            }
            ForEach(errors, id: \.self) { InlineMessage(kind: .error, text: $0) }
        } buttons: {
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(selected.isEmpty ? "Adopt" : "Adopt \(selected.count)", action: adopt)
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
        }
        .onAppear { candidates = model.adoptableDirectories() }
    }

    private func adopt() {
        errors = []
        for url in selected.sorted(by: { $0.path < $1.path }) {
            let suffix = String(url.lastPathComponent.dropFirst(".claude-".count))
            let baseName = suffix.isEmpty ? url.lastPathComponent : suffix.prefix(1).uppercased() + suffix.dropFirst()
            let (name, slug) = uniqueNameAndSlug(String(baseName.prefix(Profile.maxNameLength - 3)))
            do {
                try model.profileStore.add(name: name, slug: slug, configDir: url.path)
            } catch {
                errors.append("\(model.paths.abbreviate(url.path)): \(error.localizedDescription) Rename the existing profile or choose a different directory.")
            }
        }
        model.refreshLocalState()
        if errors.isEmpty { dismiss() }
    }

    private func uniqueNameAndSlug(_ base: String) -> (String, String) {
        let baseSlug = Slug.make(from: base).isEmpty ? "profile" : Slug.make(from: base)
        var name = base
        var slug = baseSlug
        var counter = 2
        while model.profiles.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame || $0.slug == slug }) {
            name = "\(base) \(counter)"
            slug = "\(baseSlug)-\(counter)"
            counter += 1
        }
        return (name, slug)
    }
}
