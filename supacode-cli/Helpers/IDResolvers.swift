import ArgumentParser

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

private nonisolated func nonEmpty(_ value: String?) -> String? {
  guard let value, !value.isEmpty else { return nil }
  return value
}
