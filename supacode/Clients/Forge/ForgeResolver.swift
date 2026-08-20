/// Pure per-repository forge resolution: explicit override, then membership in
/// a forge CLI's own authenticated-host set, then known-host substrings, then
/// unresolved. Never falls back to a default forge.
nonisolated enum ForgeResolver {
  /// Per-repo override value meaning "no forge, stop guessing".
  static let noneSettingsID = "none"

  struct Candidate: Equatable, Sendable {
    let id: ForgeID
    /// Hosts the forge's CLI is authenticated against (lowercased).
    let authenticatedHosts: Set<String>
    /// Substrings identifying obvious hosts ("github", "gitlab").
    let knownHostSubstrings: [String]
  }

  static func resolve(
    host: String?,
    override settingsID: String?,
    candidates: [Candidate]
  ) -> ForgeID? {
    if let settingsID = settingsID?.lowercased(), !settingsID.isEmpty {
      guard settingsID != noneSettingsID else { return nil }
      return candidates.first(where: { $0.id.rawValue == settingsID })?.id
    }
    guard let host = host?.lowercased(), !host.isEmpty else { return nil }
    for candidate in candidates {
      // Normalized here so a future adapter's mixed-case set still matches.
      let authenticatedHosts = Set(candidate.authenticatedHosts.map { $0.lowercased() })
      if authenticatedHosts.contains(host) {
        return candidate.id
      }
    }
    for candidate in candidates {
      for substring in candidate.knownHostSubstrings where host.contains(substring) {
        return candidate.id
      }
    }
    return nil
  }
}
