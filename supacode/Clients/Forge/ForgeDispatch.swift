import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

/// Shared preamble for forge-backed user actions: resolve the repository's
/// forge, check its CLI, and surface one vocabulary-correct alert on failure.
nonisolated enum ForgeDispatch {
  @MainActor
  static func resolve(
    registry: ForgeRegistry,
    repoRoot: URL,
    repoHost: RemoteHost?,
    send: Send<RepositoriesFeature.Action>,
    unavailableAction: String
  ) async -> (ForgeClient, ForgeCapabilities)? {
    guard
      let forgeID = await registry.resolveForgeID(repoRoot, repoHost),
      let forge = registry.client(forgeID),
      let capabilities = registry.capabilities(forgeID)
    else {
      await send(
        .presentAlert(
          title: "No git forge configured",
          message: "Supacode could not resolve a git forge for this repository. "
            + "Check the repository's forge setting and that the forge is enabled in Git Forges settings."
        )
      )
      return nil
    }
    let vocabulary = capabilities.vocabulary
    guard await forge.isAvailable() else {
      await send(
        .presentAlert(
          title: "\(vocabulary.destinationName) CLI not found",
          message: "Install `\(vocabulary.cliName)` to \(unavailableAction)."
        )
      )
      return nil
    }
    return (forge, capabilities)
  }

  /// Copy strings that differ between the two CI actions.
  struct FailingRunCopy {
    let inProgressToast: String
    let noFailingRunMessage: String
  }

  /// Shared preamble for the CI actions: the latest failing run, nil after
  /// presenting the relevant alert, or a thrown fetch error for the caller's
  /// own failure alert.
  @MainActor
  static func resolveFailingRun(
    forge: ForgeClient,
    worktreeRoot: URL,
    branchName: String,
    copy: FailingRunCopy,
    send: Send<RepositoriesFeature.Action>
  ) async throws -> ForgeWorkflowRun? {
    guard !branchName.isEmpty else {
      await send(
        .presentAlert(
          title: "Branch name unavailable",
          message: "Supacode could not determine the pull request branch."
        )
      )
      return nil
    }
    await send(.showToast(.inProgress(copy.inProgressToast)))
    guard let run = try await forge.latestRun(worktreeRoot, branchName) else {
      await send(.dismissToast)
      await send(
        .presentAlert(
          title: "No workflow runs found",
          message: "Supacode could not find any workflow runs for this branch."
        )
      )
      return nil
    }
    guard run.conclusion?.lowercased() == "failure" else {
      await send(.dismissToast)
      await send(
        .presentAlert(
          title: "No failing workflow run",
          message: copy.noFailingRunMessage
        )
      )
      return nil
    }
    return run
  }
}
