import SwiftUI
import UIKit

/// New-session sheet (contract §12): optional name + working folder (typed,
/// picked from Recent, or browsed), live folder status, Create with an
/// idempotent `clientRequestId`. Against a pre-§12 server (`/api/dirs`
/// 404) the folder UI is hidden and Create sends the name only.
struct NewSessionSheet: View {
    @StateObject private var model: NewSessionModel
    let theme: AppTheme
    let onCreated: (SessionSummary) -> Void
    @Environment(\.dismiss) private var dismiss

    init(model: @autoclosure @escaping () -> NewSessionModel, theme: AppTheme,
         onCreated: @escaping (SessionSummary) -> Void) {
        _model = StateObject(wrappedValue: model())
        self.theme = theme
        self.onCreated = onCreated
    }

    var body: some View {
        NavigationView {
            List {
                nameSection
                if model.showsFolderUI {
                    folderSection
                    if !model.recent.isEmpty {
                        recentSection
                    }
                }
                if let error = model.createError {
                    Section {
                        Label {
                            Text(error)
                                .font(.footnote)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .foregroundColor(.red)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Couldn't create the session: \(error)")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("New Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(model.isCreating)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.isCreating {
                        ProgressView()
                            .accessibilityLabel("Creating session")
                    } else {
                        Button("Create") { create() }
                            .font(.body.weight(.semibold))
                            .disabled(!model.canCreate)
                            .accessibilityHint(createHint)
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .environment(\.theme, theme)
        .preferredColorScheme(theme.scheme)
        .interactiveDismissDisabled(model.isCreating)
        .onAppear { model.start() }
    }

    // MARK: Sections

    private var nameSection: some View {
        Section(header: Text("Name")) {
            TextField("Optional", text: $model.name)
                .submitLabel(.done)
                .accessibilityLabel("Session name, optional")
        }
    }

    @ViewBuilder
    private var folderSection: some View {
        Section(header: Text("Folder"), footer: folderFooter) {
            TextField("D:\\projects\\app", text: $model.path)
                .font(.system(.body, design: .monospaced))
                .disableAutocorrection(true)
                .textInputAutocapitalization(.never)
                .submitLabel(.done)
                .accessibilityLabel("Folder path")
                .accessibilityHint("Full path of the session's working folder. Missing folders are created.")
            if model.support != .loading {
                statusRow
            }
            switch model.support {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading folders…")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Loading folders")
            case .failed(let message):
                Button {
                    model.retryLoad()
                } label: {
                    Label("Couldn't load folders — Retry", systemImage: "arrow.clockwise")
                        .font(.footnote)
                }
                .accessibilityHint(message)
            case .supported(let info):
                NavigationLink(destination: FolderBrowserView(
                    model: FolderBrowserModel(api: model.api, roots: info.roots, start: model.browseStart),
                    onPick: { model.pick($0) })) {
                    Label("Browse…", systemImage: "folder")
                        .foregroundColor(theme.accent)
                }
                .accessibilityLabel("Browse folders")
            case .unsupported:
                EmptyView()
            }
        }
    }

    private var folderFooter: Text {
        if let roots = rootsText {
            return Text("Leave empty for the server default. Allowed inside \(roots).")
        }
        return Text("Leave empty for the server default.")
    }

    private var rootsText: String? {
        model.roots.isEmpty ? nil : model.roots.joined(separator: ", ")
    }

    private var statusRow: some View {
        let status = model.status
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            if status == .checking {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: status.systemImage)
                    .font(.footnote)
            }
            Text(status.text)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundColor(statusColor(status))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Folder status: \(status.text)")
    }

    private func statusColor(_ status: WorkdirStatus) -> Color {
        switch status {
        case .existing: return .green
        case .willCreate: return theme.accent
        case .invalid, .notAllowed: return .red
        case .notADirectory: return .orange
        case .checking, .serverDefault, .unknown: return .secondary
        }
    }

    private var recentSection: some View {
        Section(header: Text("Recent")) {
            ForEach(model.recent) { recent in
                let selected = model.isSelected(recent)
                Button {
                    UISelectionFeedbackGenerator().selectionChanged()
                    model.pick(recent.path)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "folder.fill")
                            .foregroundColor(theme.accent)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(recent.name)
                                .font(.body.weight(.semibold))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            Text(recent.path)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 8)
                        if let count = recent.sessions, count > 0 {
                            Text("\(count)")
                                .font(.caption2.monospacedDigit())
                                .foregroundColor(.secondary)
                                .accessibilityHidden(true)
                        }
                        if selected {
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundColor(theme.accent)
                                .accessibilityHidden(true)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(recentLabel(recent))
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                .accessibilityHint("Uses this folder")
            }
        }
    }

    private func recentLabel(_ recent: RecentDir) -> String {
        var label = "\(recent.name), \(recent.path)"
        if let count = recent.sessions, count > 0 {
            label += ", \(count) session\(count == 1 ? "" : "s")"
        }
        return label
    }

    private var createHint: String {
        model.canCreate ? "Creates the session and opens it" : model.status.text
    }

    private func create() {
        Task { @MainActor in
            if let session = await model.create() {
                onCreated(session)
            }
        }
    }
}

/// Folder browser pushed from the new-session sheet: lists subfolders of one
/// folder at a time (tap to drill in, Up for the parent), "New folder"
/// appends a name (created on Create via `createDir`), "Use this folder"
/// fills the sheet's field.
struct FolderBrowserView: View {
    @StateObject private var model: FolderBrowserModel
    let onPick: (String) -> Void
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var showingNewFolder = false
    @State private var newFolderName = ""
    @FocusState private var newFolderFocused: Bool

    init(model: @autoclosure @escaping () -> FolderBrowserModel, onPick: @escaping (String) -> Void) {
        _model = StateObject(wrappedValue: model())
        self.onPick = onPick
    }

    var body: some View {
        List {
            locationSection
            if showingNewFolder, model.path != nil {
                newFolderSection
            }
            contentSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(model.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingNewFolder.toggle()
                    newFolderFocused = showingNewFolder
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .disabled(!model.canUse)
                .accessibilityLabel("New folder")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { useBar }
        .onAppear { model.onAppear() }
    }

    // MARK: Sections

    private var locationSection: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: model.path == nil ? "externaldrive" : "folder")
                    .foregroundColor(theme.accent)
                    .accessibilityHidden(true)
                Text(model.path ?? "All folders")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .truncationMode(.head)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Current folder: \(model.path ?? "all folders")")
            if let destination = model.upDestination {
                Button {
                    model.goUp()
                } label: {
                    Label(destination.map { "Up to \(WorkdirPath.lastComponent($0))" } ?? "Up to all folders",
                          systemImage: "arrow.turn.left.up")
                        .foregroundColor(theme.accent)
                }
                .accessibilityLabel("Parent folder")
                .accessibilityHint(destination ?? "Shows all allowed folders")
            }
        }
    }

    private var newFolderSection: some View {
        let error = newFolderName.isEmpty ? nil : WorkdirPath.folderNameError(newFolderName)
        let preview: String = model.path.map { WorkdirPath.appending(newFolderName, to: $0) } ?? newFolderName
        let footer: String
        if let error {
            footer = error
        } else if newFolderName.isEmpty {
            footer = "Created when you tap Create."
        } else {
            footer = "Will be created: \(preview)"
        }
        let footerColor: Color = error == nil ? .secondary : .red
        return Section(header: Text("New folder"),
                       footer: Text(footer).foregroundColor(footerColor)) {
            HStack(spacing: 8) {
                TextField("Folder name", text: $newFolderName)
                    .disableAutocorrection(true)
                    .textInputAutocapitalization(.never)
                    .focused($newFolderFocused)
                    .submitLabel(.done)
                    .onSubmit { useNewFolder() }
                    .accessibilityLabel("New folder name")
                Button("Use") { useNewFolder() }
                    .font(.body.weight(.semibold))
                    .disabled(WorkdirPath.folderNameError(newFolderName) != nil)
                    .accessibilityHint("Uses a new folder with this name inside the current folder")
            }
        }
    }

    @ViewBuilder
    private var contentSection: some View {
        switch model.state {
        case .loading:
            Section {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading…")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Loading folders")
            }
        case .rootList:
            Section(header: Text("Allowed folders")) {
                ForEach(model.roots, id: \.self) { root in
                    folderRow(name: root, path: root)
                }
            }
        case .loaded(let listing):
            loadedSection(listing)
        case .forbidden(let roots):
            Section {
                messageRow(icon: "xmark.octagon.fill", tint: .red,
                           text: WorkdirStatus.notAllowed(roots: roots).text)
            }
        case .failed(let message):
            Section {
                messageRow(icon: "exclamationmark.triangle.fill", tint: .orange,
                           text: "Couldn't load folders — \(message)")
                Button("Retry") { model.retry() }
                    .font(.body.weight(.semibold))
            }
        }
    }

    @ViewBuilder
    private func loadedSection(_ listing: DirListing) -> some View {
        if !listing.exists {
            Section {
                messageRow(icon: "plus.circle.fill", tint: theme.accent,
                           text: "This folder doesn't exist yet — it will be created.")
            }
        } else if !listing.isDir {
            Section {
                messageRow(icon: "doc.fill", tint: .orange, text: "Not a folder")
            }
        } else if listing.entries.isEmpty {
            Section(header: Text("Subfolders")) {
                Text("No subfolders")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        } else {
            Section(header: Text("Subfolders"),
                    footer: listing.truncated
                        ? Text("Showing the first \(listing.entries.count) folders — type the path for others.")
                        : nil) {
                ForEach(listing.entries) { entry in
                    folderRow(name: entry.name, path: entry.path)
                }
            }
        }
    }

    private func folderRow(name: String, path: String) -> some View {
        Button {
            model.open(path)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .foregroundColor(theme.accent)
                    .accessibilityHidden(true)
                Text(name)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens \(path)")
    }

    private func messageRow(icon: String, tint: Color, text: String) -> some View {
        Label {
            Text(text)
                .font(.footnote)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: icon)
                .foregroundColor(tint)
        }
        .accessibilityElement(children: .combine)
    }

    private var useBar: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                if let path = model.path { pick(path) }
            } label: {
                Text("Use this folder")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(theme.accent)
            .disabled(!model.canUse)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .accessibilityHint(model.path ?? "")
        }
        .background(.regularMaterial)
    }

    // MARK: Actions

    private func useNewFolder() {
        guard let base = model.path, WorkdirPath.folderNameError(newFolderName) == nil else { return }
        pick(WorkdirPath.appending(newFolderName, to: base))
    }

    private func pick(_ path: String) {
        UISelectionFeedbackGenerator().selectionChanged()
        onPick(path)
        dismiss()
    }
}
