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

/// Resolves a repo ID from an explicit flag or `$SUPACODE_REPO_ID`.
nonisolated func resolveRepoID(_ explicit: String?) throws -> String {
  guard let id = nonEmpty(explicit) ?? EnvironmentDefaults.repoID else {
    throw ValidationError(
      "Missing repo ID. Pass -r <id> or run inside a Supacode terminal ($SUPACODE_REPO_ID)."
    )
  }
  return id
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
