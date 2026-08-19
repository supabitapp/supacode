import Foundation
import SupacodeSettingsShared

/// A merged `supaignore` blob proven to hold at least one effective (non-blank,
/// non-comment) pattern, so a `.resolved` filter can never be a silent no-op that
/// suppresses the `wt` copy while excluding nothing.
nonisolated struct EffectiveSupaignorePatterns: Equatable, Sendable {
  let value: String

  /// `nil` when `value` has no effective pattern (all blank / comment lines).
  init?(_ value: String) {
    guard SupaignoreMerge.hasEffectivePattern(in: value) else { return nil }
    self.value = value
  }
}

/// Outcome of resolving the layered `supaignore` filter for a worktree copy.
nonisolated enum SupaignoreResolution: Equatable, Sendable {
  /// No `supaignore` anywhere: keep the unfiltered `wt` copy path.
  case absent
  /// Effective merged patterns to filter the copy with. The validated payload
  /// makes an empty / ineffective filter unrepresentable.
  case resolved(EffectiveSupaignorePatterns)
  /// A layer could not be read: copy nothing rather than fall back to `wt`'s
  /// unfiltered copy so excluded files never leak, and advise the user. The
  /// associated value is the failure reason.
  case failed(reason: String)

  /// Whether supaignore governs the copy, so `wt` must not run its own
  /// unfiltered copy. True for both `resolved` and `failed`.
  var governsCopy: Bool {
    if case .absent = self { return false }
    return true
  }
}
