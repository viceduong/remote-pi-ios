import SwiftUI
import UIKit

/// Contract §11 model picker: searchable list of the models pi reports as
/// available, one section per provider, current model checked. Tapping a
/// row switches optimistically (checkmark moves at once, reverts on
/// failure via `ChatViewModel.switchModel`) and dismisses. Usable while the
/// agent is busy — pi applies the new model from the next turn.
struct ModelPickerSheet: View {
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject var status: ChatLiveStatus
    let theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationView {
            // `.searchable` sits on the always-present container (not the
            // list that appears after loading): on iOS 15 a search modifier
            // that shows up after the first render may never install its bar.
            content
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                            prompt: "Search models")
                .disableAutocorrection(true)
                .navigationTitle("Model")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .navigationViewStyle(.stack)
        .environment(\.theme, theme)
        .preferredColorScheme(theme.scheme)
        .onAppear { viewModel.loadModels() }
    }

    private var content: some View {
        ZStack {
            Color(UIColor.systemGroupedBackground).ignoresSafeArea()
            stateView
        }
    }

    @ViewBuilder
    private var stateView: some View {
        switch viewModel.modelList {
        case .idle, .loading:
            VStack(spacing: 10) {
                ProgressView()
                Text("Loading models…")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Loading models")
        case .failed(let message):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundColor(.orange)
                    .accessibilityHidden(true)
                Text("Couldn't load models")
                    .font(.headline)
                Text(message)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry") { viewModel.loadModels() }
                    .font(.body.weight(.semibold))
                    .padding(.top, 4)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let models):
            modelList(models)
        }
    }

    private var footerNote: String {
        status.isBusy
            ? "The agent is working — a new model applies from the next turn."
            : "Applies from the next turn."
    }

    private func modelList(_ models: [ModelEntry]) -> some View {
        let groups = ModelPicker.groups(models, query: query)
        return List {
            if models.isEmpty {
                Section(footer: Text(footerNote)) {
                    Text("No models available. Check the provider logins on the host.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            } else if groups.isEmpty {
                Section {
                    Text("No models match “\(query)”")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            ForEach(Array(groups.enumerated()), id: \.element.provider) { index, group in
                Section(header: Text(ModelPicker.providerTitle(group.provider)),
                        footer: index == groups.count - 1 ? Text(footerNote) : nil) {
                    ForEach(group.models, id: \.key) { entry in
                        row(entry)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func row(_ entry: ModelEntry) -> some View {
        let isCurrent = viewModel.currentModel?.matches(entry) ?? false
        let context = ModelPicker.contextLabel(entry.contextWindow)
        return Button {
            select(entry, isCurrent: isCurrent)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(entry.name)
                            .font(.body)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        if entry.reasoning {
                            ReasoningBadge(tint: theme.accent)
                        }
                    }
                    HStack(spacing: 8) {
                        Text(entry.id)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let context {
                            Text(context)
                                .font(.caption2.monospacedDigit())
                                .foregroundColor(.secondary)
                                .fixedSize()
                        }
                    }
                }
                Spacer(minLength: 8)
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundColor(theme.accent)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(entry, context: context))
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(isCurrent ? "Current model" : "Switches the session to this model")
    }

    private func accessibilityLabel(_ entry: ModelEntry, context: String?) -> String {
        var parts = [entry.name, ModelPicker.providerTitle(entry.provider)]
        if entry.reasoning { parts.append("reasoning") }
        if let context { parts.append(context.replacingOccurrences(of: " ctx", with: " context")) }
        return parts.joined(separator: ", ")
    }

    private func select(_ entry: ModelEntry, isCurrent: Bool) {
        if !isCurrent {
            UISelectionFeedbackGenerator().selectionChanged()
            viewModel.switchModel(entry)
        }
        dismiss()
    }
}

/// Small "reasoning" capsule on models that support extended thinking.
struct ReasoningBadge: View {
    let tint: Color

    var body: some View {
        Text("reasoning")
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(tint.opacity(0.14))
            .clipShape(Capsule())
            .fixedSize()
            .accessibilityHidden(true)
    }
}
