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
  ) async -> (ForgeClient, ForgeVocabulary)? {
    guard
      let forgeID = await registry.resolveForgeID(repoRoot, repoHost),
      let forge = registry.client(forgeID),
      let capabilities = registry.capabilities(forgeID)
    else {
      await send(
        .presentAlert(
          title: "No git forge configured",
          message: "Supacode could not resolve a git forge for this repository."
        )
      )
      return nil
    }
    let destination = capabilities.vocabulary.destinationName
    guard await forge.isAvailable() else {
      await send(
        .presentAlert(
          title: "\(destination) integration unavailable",
          message: "Enable \(destination) integration to \(unavailableAction)."
        )
      )
      return nil
    }
    return (forge, capabilities.vocabulary)
  }
}
