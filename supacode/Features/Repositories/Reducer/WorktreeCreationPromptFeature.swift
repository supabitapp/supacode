import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

@Reducer
struct WorktreeCreationPromptFeature {
  @ObservableState
  struct State: Equatable {
    let repositoryID: Repository.ID
    /// Canonical repository root, used to resolve relative path overrides in the
    /// preview the same way the reducer does (not reconstructed from the ID).
    let repositoryRootURL: URL
    let repositoryName: String
    /// The resolved auto base ref (e.g. `origin/main`), kept as the default.
    let automaticBaseRef: String
    /// Local branch matching the default ref (e.g. `main`), surfaced as a quick
    /// pick. Cleared once the inventory confirms no such local branch exists.
    var defaultBranch: String?
    /// Configured remote names, used to classify the selected ref as local or remote.
    let remoteNames: [String]
    /// Pre-built local + per-remote branch menu trees; `nil` while still loading.
    var branchMenu: BaseRefBranchMenu?
    var branchName: String
    var selectedBaseRef: String?
    var fetchOrigin: Bool
    /// Resolved default base directory, used to compute the location preview.
    let defaultWorktreeBaseDirectory: String
    /// Leaf folder name override; empty falls back to the branch name.
    var worktreeNameOverride: String = ""
    /// Parent directory override; empty falls back to `defaultWorktreeBaseDirectory`.
    var worktreePathOverride: String = ""
    /// Disclosure state for the advanced placement section. Collapsed by default.
    var showAdvancedOptions: Bool = false
    var validationMessage: String?
    var isValidating = false
    /// Optional sidebar customization captured by the new Title / Color
    /// section; transferred to `PendingWorktree.customization` on submit.
    var title: String = ""
    var color: RepositoryColor?

    /// Default leaf folder name shown as the name-override placeholder.
    var worktreeNamePlaceholder: String {
      branchName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Live validity of the current name override, so the footer can flag an
    /// invalid leaf instead of previewing a destination submit will reject.
    var worktreeNameValidationError: String? {
      WorktreePlacementOverride.nameValidationError(worktreeNameOverride)
    }

    /// Full destination path the worktree will be created at, mirroring the
    /// reducer's resolution.
    var resolvedWorktreeLocationPreview: String {
      SupacodePaths.previewWorktreeDirectory(
        defaultBaseDirectory: URL(filePath: defaultWorktreeBaseDirectory, directoryHint: .isDirectory),
        repositoryRootURL: repositoryRootURL,
        nameOverride: worktreeNameOverride,
        pathOverride: worktreePathOverride,
        branchName: branchName
      )
      .path(percentEncoded: false)
    }

    /// Label shown on the base-ref menu button.
    var baseRefMenuLabel: String {
      if let selectedBaseRef, !selectedBaseRef.isEmpty {
        return selectedBaseRef
      }
      return automaticBaseRef.isEmpty ? "Auto" : automaticBaseRef
    }

    var isLoadingBranches: Bool {
      branchMenu == nil
    }

    /// Whether the effective base ref (selection, or the auto ref when unset)
    /// has no remote to fetch from. A name-prefix heuristic, not a true ref
    /// classification: anything without a known `<remote>/` prefix (a local
    /// branch, but also a tag, SHA, or HEAD) counts as "nothing to fetch",
    /// which is exactly when the fetch toggle should be off.
    var isSelectedBaseRefLocal: Bool {
      let ref = selectedBaseRef ?? automaticBaseRef
      guard !ref.isEmpty else { return true }
      return GitReferenceQueries.localBranchName(fromRemoteRef: ref, remoteNames: remoteNames) == nil
    }
  }

  enum Action: BindableAction, Equatable {
    case binding(BindingAction<State>)
    case baseRefSelected(String?)
    case cancelButtonTapped
    case createButtonTapped
    case setValidationMessage(String?)
    case setValidating(Bool)
    case delegate(Delegate)
  }

  @CasePathable
  enum Delegate: Equatable {
    case cancel
    case submit(
      repositoryID: Repository.ID,
      branchName: String,
      baseRef: String?,
      fetchOrigin: Bool,
      placement: WorktreePlacementOverride,
      title: String?,
      color: RepositoryColor?
    )
  }

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        state.validationMessage = nil
        return .none

      case .baseRefSelected(let ref):
        state.selectedBaseRef = ref
        state.validationMessage = nil
        return .none

      case .cancelButtonTapped:
        return .send(.delegate(.cancel))

      case .createButtonTapped:
        let trimmed = state.branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
          state.validationMessage = "Branch name required."
          return .none
        }
        guard !trimmed.contains(where: \.isWhitespace) else {
          state.validationMessage = "Branch names can't contain spaces."
          return .none
        }
        let nameOverride = state.worktreeNameOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if let nameError = WorktreePlacementOverride.nameValidationError(nameOverride) {
          state.validationMessage = nameError
          return .none
        }
        state.validationMessage = nil
        let pathOverride = state.worktreePathOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        // Preserve the user's typed title verbatim, even when it equals the
        // branch name. The render is identical (no override → fall back to
        // branch name) but the round-trip into the Customize sheet relies
        // on the value surviving.
        let trimmedTitle = state.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = trimmedTitle.isEmpty ? nil : trimmedTitle
        return .send(
          .delegate(
            .submit(
              repositoryID: state.repositoryID,
              branchName: trimmed,
              baseRef: state.selectedBaseRef,
              // Match the disabled toggle: a local base ref has nothing to fetch.
              fetchOrigin: state.isSelectedBaseRefLocal ? false : state.fetchOrigin,
              placement: WorktreePlacementOverride(
                name: nameOverride.isEmpty ? nil : nameOverride,
                path: pathOverride.isEmpty ? nil : pathOverride
              ),
              title: resolvedTitle,
              color: state.color
            )
          )
        )

      case .setValidationMessage(let message):
        state.validationMessage = message
        return .none

      case .setValidating(let isValidating):
        state.isValidating = isValidating
        return .none

      case .delegate:
        return .none
      }
    }
  }
}
