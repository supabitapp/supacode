import ArgumentParser

/// Client-side validation for `worktree appearance --color`; the app re-validates
/// authoritatively via `RepositoryColor.parse`. Keep accepted forms in sync with
/// `SupacodeSettingsShared/Models/RepositoryColor.swift`.
nonisolated enum CLIWorktreeColor {
  static let predefinedNames = ["red", "orange", "yellow", "green", "teal", "blue", "purple"]

  /// Returns the canonical value: lowercased predefined name / `none`,
  /// uppercased `#RRGGBB[AA]` hex. Throws on anything else.
  static func validated(_ raw: String) throws -> String {
    let lowered = raw.lowercased()
    if lowered == "none" || predefinedNames.contains(lowered) {
      return lowered
    }
    if isValidHex(raw) {
      return raw.uppercased()
    }
    throw ValidationError(
      "Invalid color value. Expected \(predefinedNames.joined(separator: "|")), #RRGGBB[AA], or none."
    )
  }

  private static func isValidHex(_ value: String) -> Bool {
    guard value.hasPrefix("#") else { return false }
    let digits = value.dropFirst()
    guard digits.count == 6 || digits.count == 8 else { return false }
    // `isHexDigit` alone also matches fullwidth Unicode digits, which the
    // app's Scanner-based `RepositoryColor` validation rejects.
    return digits.allSatisfy { $0.isASCII && $0.isHexDigit }
  }
}
