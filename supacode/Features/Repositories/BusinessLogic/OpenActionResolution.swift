import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

/// The Sendable slice of a repository the resolver needs. Snapshotted in the
/// reducer so the effect never reaches back into `State`.
nonisolated struct OpenActionResolutionInput: Equatable, Sendable {
  let repositoryID: Repository.ID
  let rootURL: URL
  let host: RemoteHost?

  init(_ repository: Repository) {
    repositoryID = repository.id
    rootURL = repository.rootURL
    host = repository.host
  }
}

/// Resolves each repository's open action by reading its `<repoRoot>/supacode.json`.
/// That is disk work, so it belongs in an effect, never in the reducer or a view body:
/// resolving it from a menu build is what hung the app on right-click (#657).
///
/// `nonisolated` is load-bearing: the module builds with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so without it `.run`'s `@Sendable`
/// (nonisolated) closure would hop right back onto the main actor to call this.
nonisolated enum OpenActionResolver {
  /// Precedence per repository: the local `supacode.json` (`RepositorySettingsKey`
  /// probes it first for local repos, never for remote ones), then the global
  /// settings-file entry, then the global default editor, then the preferred
  /// installed default.
  static func resolve(
    inputs: [OpenActionResolutionInput],
    installed: [OpenWorktreeAction]
  ) -> [Repository.ID: OpenWorktreeAction] {
    guard !inputs.isEmpty else { return [:] }
    var resolved: [Repository.ID: OpenWorktreeAction] = [:]
    resolved.reserveCapacity(inputs.count)

    @Shared(.settingsFile) var settingsFile
    let defaultEditorID = settingsFile.global.defaultEditorID
    for input in inputs {
      // `currentSettings()`, not `@Shared(.repositorySettings(...))`: a live terminal pins
      // the cached reference, and re-reading the file is the whole point of the pass.
      let settings = RepositorySettingsKey(rootURL: input.rootURL, host: input.host).currentSettings()
      resolved[input.repositoryID] = OpenWorktreeAction.fromSettingsID(
        settings.openActionID,
        defaultEditorID: defaultEditorID,
        installed: installed
      )
    }
    return resolved
  }
}
