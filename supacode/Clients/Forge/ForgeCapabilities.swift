import SupacodeSettingsShared

/// Display vocabulary for one forge. Views read these strings; they never
/// branch on the forge itself.
nonisolated struct ForgeVocabulary: Equatable, Hashable, Sendable {
  /// "Pull Request" / "Merge Request".
  let noun: String
  /// "PR" / "MR".
  let abbreviation: String
  /// "#" / "!".
  let numberSigil: String
  /// "Checks" / "Pipelines".
  let ciNoun: String
  /// Destination shown by open-in-browser affordances: "GitHub", "GitLab",
  /// or the bare host for self-managed instances.
  let destinationName: String
  /// The CLI binary backing the forge ("gh", "glab"), for install guidance.
  let cliName: String

  static let github = ForgeVocabulary(
    noun: "Pull Request",
    abbreviation: "PR",
    numberSigil: "#",
    ciNoun: "Checks",
    destinationName: "GitHub",
    cliName: "gh"
  )

  static let gitlab = ForgeVocabulary(
    noun: "Merge Request",
    abbreviation: "MR",
    numberSigil: "!",
    ciNoun: "Pipelines",
    destinationName: "GitLab",
    cliName: "glab"
  )
}

/// What one forge connection can do, resolved per repository and carried as
/// Equatable state so menus and the palette gate synchronously. Every field
/// must name a live UI consumer; thrown `.unsupported` is only the backstop.
nonisolated struct ForgeCapabilities: Equatable, Hashable, Sendable {
  let mergeStrategies: [PullRequestMergeStrategy]
  /// Whether the summary tier is thin and a per-selection detail fetch adds
  /// data. False for forges whose summaries already carry everything.
  let providesDetailTier: Bool
  let canMarkReady: Bool
  let canRerunChecks: Bool
  let canCopyCIFailureLogs: Bool
  let vocabulary: ForgeVocabulary

  static let github = ForgeCapabilities(
    mergeStrategies: [.merge, .squash, .rebase],
    providesDetailTier: false,
    canMarkReady: true,
    canRerunChecks: true,
    canCopyCIFailureLogs: true,
    vocabulary: .github
  )

  // GitLab's merge method is a project setting; only squash is a per-merge
  // choice. Aggregate CI failure logs have no glab equivalent.
  static let gitlab = ForgeCapabilities(
    mergeStrategies: [.merge, .squash],
    providesDetailTier: true,
    canMarkReady: true,
    canRerunChecks: true,
    canCopyCIFailureLogs: false,
    vocabulary: .gitlab
  )
}

extension ForgeCapabilities {
  nonisolated static func forID(_ forgeID: ForgeID) -> ForgeCapabilities? {
    switch forgeID {
    case .github: .github
    case .gitlab: .gitlab
    default: nil
    }
  }
}
