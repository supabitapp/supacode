import ComposableArchitecture
import SupacodeSettingsFeature
import SupacodeSettingsShared
import SwiftUI

struct WorktreeCreationPromptView: View {
  @Bindable var store: StoreOf<WorktreeCreationPromptFeature>
  @FocusState private var isBranchFieldFocused: Bool

  var body: some View {
    Form {
      Section {
        TextField("Branch name", text: $store.branchName)
          .focused($isBranchFieldFocused)
          .onSubmit {
            store.send(.createButtonTapped)
          }
      } header: {
        // `NavigationStack` with title and subtitle is bugged inside
        // sheets in macOS 26.*, and this is a nice enough fallback.
        Text("New Worktree")
        Text("Create a branch in `\(store.repositoryName)`.")
      } footer: {
        WorktreeCreationFooter(store: store)
      }
      .headerProminence(.increased)

      Section {
        WorktreeBaseRefField(store: store)

        Toggle(isOn: $store.fetchOrigin) {
          Text("Fetch remote branch")
          Text(
            "Runs `git fetch` to ensure the base branch is up to date before creating the worktree."
          )
        }
        .disabled(store.isSelectedBaseRefLocal)
      }

      WorktreeAppearanceSection(store: store)

      WorktreeOptionsSection(store: store)
    }
    .formStyle(.grouped)
    .scrollBounceBehavior(.basedOnSize)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      HStack {
        if store.isValidating {
          ProgressView()
            .controlSize(.small)
        }
        Spacer()
        Button("Cancel") {
          store.send(.cancelButtonTapped)
        }
        .keyboardShortcut(.cancelAction)
        .help("Cancel (Esc)")
        Button("Create") {
          store.send(.createButtonTapped)
        }
        .keyboardShortcut(.defaultAction)
        .help("Create (↩)")
        .disabled(store.isValidating)
      }
      .padding(.horizontal, 20)
      .padding(.bottom, 20)
    }
    .frame(minWidth: 420)
    .task { isBranchFieldFocused = true }
    .dismissSystemColorPanelOnDisappear()
  }
}

private struct WorktreeAppearanceSection: View {
  @Bindable var store: StoreOf<WorktreeCreationPromptFeature>

  var body: some View {
    Section("Appearance", isExpanded: $store.showAppearanceOptions) {
      TextField("Title", text: $store.title, prompt: Text(store.worktreeNamePlaceholder))
      LabeledContent("Color") {
        ColorSwatchRow(color: $store.color)
      }
    }
  }
}

private struct WorktreeOptionsSection: View {
  @Bindable var store: StoreOf<WorktreeCreationPromptFeature>

  var body: some View {
    Section("Advanced", isExpanded: $store.showAdvancedOptions) {
      // Title-string fields so tapping the label focuses the field, matching
      // the branch-name field above.
      TextField("Worktree name", text: $store.worktreeNameOverride, prompt: Text(store.worktreeNamePlaceholder))
      TextField("Parent folder", text: $store.worktreePathOverride, prompt: Text(store.defaultWorktreeBaseDirectory))
    }
  }
}

private struct WorktreeCreationFooter: View {
  let store: StoreOf<WorktreeCreationPromptFeature>

  var body: some View {
    if let message = store.validationMessage ?? store.worktreeNameValidationError, !message.isEmpty {
      Text(message)
        .foregroundStyle(.red)
    } else {
      Text(store.resolvedWorktreeLocationPreview)
        .monospaced()
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

private struct WorktreeBaseRefField: View {
  @Bindable var store: StoreOf<WorktreeCreationPromptFeature>
  @State private var isPickerPresented = false

  var body: some View {
    LabeledContent {
      HStack(spacing: 8) {
        if store.isLoadingBranches {
          ProgressView()
            .controlSize(.small)
        }
        Button {
          isPickerPresented = true
        } label: {
          HStack(spacing: 4) {
            Text(store.baseRefMenuLabel)
              .lineLimit(1)
              .truncationMode(.middle)
            Image(systemName: "chevron.up.chevron.down")
              .imageScale(.small)
              .foregroundStyle(.secondary)
              .accessibilityHidden(true)
          }
        }
        .help("Choose the base ref to branch from. Type to filter local and remote branches.")
        .popover(isPresented: $isPickerPresented, arrowEdge: .bottom) {
          WorktreeBaseRefPicker(store: store) { isPickerPresented = false }
        }
      }
    } label: {
      Text("Base ref")
      Text("The branch or ref the new worktree will be created from.")
    }
  }
}

/// Searchable base-ref picker (#387): a filter field over a flat list of local
/// and remote refs, replacing the old nested submenus so the user can type any
/// fragment of a branch name instead of drilling namespaces.
private struct WorktreeBaseRefPicker: View {
  @Bindable var store: StoreOf<WorktreeCreationPromptFeature>
  let dismiss: () -> Void

  @State private var query = ""
  @FocusState private var filterFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      TextField("Filter branches", text: $query)
        .textFieldStyle(.roundedBorder)
        .focused($filterFocused)
        .padding(12)
        .onAppear { filterFocused = true }

      Divider()

      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          WorktreeBaseRefRow(
            title: store.automaticBaseRef.isEmpty ? "Auto" : "\(store.automaticBaseRef) · Auto",
            isSelected: store.selectedBaseRef == nil
          ) { select(nil) }

          if let defaultBranch = store.defaultBranch {
            WorktreeBaseRefRow(
              title: "\(defaultBranch) · Local",
              isSelected: store.selectedBaseRef == defaultBranch
            ) { select(defaultBranch) }
          }

          Divider()
            .padding(.vertical, 4)

          if let branchMenu = store.branchMenu {
            let refs = branchMenu.refs(matching: query)
            if refs.isEmpty {
              WorktreeBaseRefPlaceholder(text: "No matching branches")
            } else {
              ForEach(refs, id: \.self) { ref in
                WorktreeBaseRefRow(
                  title: ref,
                  isSelected: store.selectedBaseRef == ref,
                  monospaced: true
                ) { select(ref) }
              }
            }
          } else {
            WorktreeBaseRefPlaceholder(text: "Loading branches…")
          }
        }
        .padding(.bottom, 8)
      }
    }
    .frame(width: 340, height: 380)
  }

  private func select(_ ref: String?) {
    store.send(.baseRefSelected(ref))
    dismiss()
  }
}

private struct WorktreeBaseRefRow: View {
  let title: String
  let isSelected: Bool
  var monospaced = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Image(systemName: "checkmark")
          .imageScale(.small)
          .opacity(isSelected ? 1 : 0)
          .accessibilityHidden(true)
        Text(title)
          .monospaced(monospaced)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: 0)
      }
      .contentShape(.rect)
      .padding(.horizontal, 12)
      .padding(.vertical, 5)
    }
    .buttonStyle(.plain)
    .help(title)
  }
}

private struct WorktreeBaseRefPlaceholder: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.callout)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
  }
}
