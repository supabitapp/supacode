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

  static let github = ForgeVocabulary(
    noun: "Pull Request",
    abbreviation: "PR",
    numberSigil: "#",
    ciNoun: "Checks",
    destinationName: "GitHub"
  )
}

/// What one forge connection can do, resolved per repository and carried as
/// Equatable state so menus and the palette gate synchronously. Every field
/// must name a live UI consumer; thrown `.unsupported` is only the backstop.
nonisolated struct ForgeCapabilities: Equatable, Hashable, Sendable {
  let mergeStrategies: [PullRequestMergeStrategy]
  let canMarkReady: Bool
  let canRerunChecks: Bool
  let canCopyCIFailureLogs: Bool
  let vocabulary: ForgeVocabulary

  static let github = ForgeCapabilities(
    mergeStrategies: [.merge, .squash, .rebase],
    canMarkReady: true,
    canRerunChecks: true,
    canCopyCIFailureLogs: true,
    vocabulary: .github
  )
}
