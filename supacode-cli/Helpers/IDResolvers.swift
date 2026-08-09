import ArgumentParser
import Foundation

/// Resolves a worktree ID from an explicit flag or `$SUPACODE_WORKTREE_ID`.
nonisolated func resolveWorktreeID(_ explicit: String?) throws -> String {
  guard let id = nonEmpty(explicit) ?? EnvironmentDefaults.worktreeID else {
    throw ValidationError(
      "Missing worktree ID. Pass -w <id> or run inside a Supacode terminal ($SUPACODE_WORKTREE_ID)."
    )
  }
  return id
}

/// Resolves a tab ID from an explicit flag or `$SUPACODE_TAB_ID`.
nonisolated func resolveTabID(_ explicit: String?) throws -> String {
  guard let id = nonEmpty(explicit) ?? EnvironmentDefaults.tabID else {
    throw ValidationError(
      "Missing tab ID. Pass -t <id> or run inside a Supacode terminal ($SUPACODE_TAB_ID)."
    )
  }
  return id
}

/// Resolves a surface ID from an explicit flag or `$SUPACODE_SURFACE_ID`.
nonisolated func resolveSurfaceID(_ explicit: String?) throws -> String {
  guard let id = nonEmpty(explicit) ?? EnvironmentDefaults.surfaceID else {
    throw ValidationError(
      "Missing surface ID. Pass -s <id> or run inside a Supacode terminal ($SUPACODE_SURFACE_ID)."
    )
  }
  return id
}

/// Resolves the worktree for a go-forward command: the explicit flag, else the
/// app's focused worktree. Never reads the deprecated `$SUPACODE_WORKTREE_ID`.
nonisolated func resolveFocusedWorktreeID(_ explicit: String?, timeoutSeconds: Int) throws -> String {
  try resolveFocused(
    explicit, resource: "worktrees", timeoutSeconds: timeoutSeconds,
    noneFocused: "No worktree is focused. Pass -w <id> (see `supacode worktree list`).")
}

/// Resolves the pane token for a go-forward command: the explicit flag, else the
/// app's focused pane. Never reads a session env var.
nonisolated func resolveFocusedPaneToken(
  _ explicit: String?, worktreeID: String, timeoutSeconds: Int
) throws -> String {
  try resolveFocused(
    explicit, resource: "panes", params: ["worktreeID": worktreeID], timeoutSeconds: timeoutSeconds,
    noneFocused: "No pane is focused in this worktree. Pass -p <id> (see `supacode pane list`).")
}

/// Resolves the tab for a go-forward command: the explicit flag, else the app's
/// focused tab. Never reads the deprecated `$SUPACODE_TAB_ID`.
nonisolated func resolveFocusedTabID(
  _ explicit: String?, worktreeID: String, timeoutSeconds: Int
) throws -> String {
  try resolveFocused(
    explicit, resource: "tabs", params: ["worktreeID": worktreeID], timeoutSeconds: timeoutSeconds,
    noneFocused: "No tab is focused in this worktree. Pass -t <id> (see `supacode tab list`).")
}

/// Explicit flag, else the resource's focused row, else a validation error.
private nonisolated func resolveFocused(
  _ explicit: String?, resource: String, params: [String: String] = [:],
  timeoutSeconds: Int, noneFocused: String
) throws -> String {
  if let id = nonEmpty(explicit) { return id }
  let items = try QueryDispatcher.query(resource: resource, params: params, timeoutSeconds: timeoutSeconds)
  guard let focused = items.first(where: { !($0["focused"] ?? "").isEmpty })?["id"] else {
    throw ValidationError(noneFocused)
  }
  return focused
}

/// Throws unless `newID` is nil or a well-formed UUID.
nonisolated func validateNewID(_ newID: String?) throws {
  if let newID, UUID(uuidString: newID) == nil {
    throw ValidationError("--id must be a UUID.")
  }
}

/// Resolves a repo ID from an explicit flag or `$SUPACODE_REPO_ID`, percent-encoded.
nonisolated func resolveRepoID(_ explicit: String?) throws -> String {
  if let explicit = nonEmpty(explicit) {
    return normalizeRepoID(explicit)
  }
  guard let id = EnvironmentDefaults.repoID else {
    throw ValidationError(
      "Missing repo ID. Pass -r <id> or run inside a Supacode terminal ($SUPACODE_REPO_ID)."
    )
  }
  return id
}

private nonisolated func normalizeRepoID(_ value: String) -> String {
  var decoded = value.removingPercentEncoding ?? value
  if !decoded.hasSuffix("/") { decoded += "/" }
  let allowed = CharacterSet.urlPathAllowed.subtracting(.init(charactersIn: "/"))
  return decoded.addingPercentEncoding(withAllowedCharacters: allowed) ?? decoded
}

/// Validates that a `--script` argument is a well-formed UUID and returns
/// the canonical `UUID.uuidString` form (uppercased). Fails early so the
/// CLI surfaces a helpful error before dispatching an unparsable deeplink.
nonisolated func validatedScriptID(_ raw: String) throws -> String {
  guard let uuid = UUID(uuidString: raw) else {
    throw ValidationError(
      "Invalid --script value: expected a UUID. Run `supacode worktree script list` to list script IDs."
    )
  }
  return uuid.uuidString
}

private nonisolated func nonEmpty(_ value: String?) -> String? {
  guard let value, !value.isEmpty else { return nil }
  return value
}
