/// UI-side install state for a per-agent integration row. Distinct from
/// `AgentIntegrationState` (which is the on-disk truth) because the row also
/// has to represent in-flight operations and the most recent failure.
public nonisolated enum AgentIntegrationRowState: Equatable, Sendable {
  case checking
  case ready(AgentIntegrationState)
  case installing
  case uninstalling
  /// A persistent failure (uninstall / update of an already-present
  /// integration): stays as a main-list row so the user can see and retry it.
  case failed(String)
  /// A transient failure from installing a not-yet-present agent: shown only
  /// inside the modal and cleared when the modal is dismissed.
  case failedTransient(String)
  /// The on-disk state could not be read. Carries the last verdict observed
  /// (nil on a cold launch) so the row keeps showing what it knew while warning
  /// that the check failed. Never sticky: it re-probes and self-heals.
  case undetermined(lastKnown: AgentIntegrationState?, reason: String)

  /// Surfaced under the row when present.
  public var errorMessage: String? {
    switch self {
    case .failed(let message), .failedTransient(let message), .undetermined(_, let message): message
    case .checking, .ready, .installing, .uninstalling: nil
    }
  }

  /// The most recent verdict actually read from disk, across both a resolved row
  /// and one whose latest probe failed. Carried through a write so an
  /// unverifiable read-back doesn't blank the row.
  public var lastKnownState: AgentIntegrationState? {
    switch self {
    case .ready(let state): state
    case .undetermined(let lastKnown, _): lastKnown
    case .checking, .installing, .uninstalling, .failed, .failedTransient: nil
    }
  }

  /// Cleanly resolved to "not installed": drives the collapsed install prompt.
  /// Exhaustive so a new state forces a placement decision here.
  public var isNotInstalled: Bool {
    switch self {
    case .ready(.notInstalled): true
    case .checking, .installing, .uninstalling, .failed, .failedTransient, .ready(.installed),
      .ready(.outdated), .undetermined:
      false
    }
  }

  /// True when the latest probe could not determine the state. Consumers that
  /// only prompt when they are sure (the sidebar upsell) must stay quiet.
  public var isUndetermined: Bool {
    if case .undetermined = self { return true }
    return false
  }

  /// Belongs in the main "Coding Agents" list: installed, outdated, still
  /// resolving, an operation in flight, a persistent error, or an unreadable
  /// probe. Not-installed and transiently-errored agents live in the collapsed
  /// prompt / modal instead, so a transient install error never leaks outside
  /// the sheet. Exhaustive by design.
  public var isMainListRow: Bool {
    switch self {
    case .checking, .installing, .uninstalling, .failed, .ready(.installed), .ready(.outdated),
      .undetermined:
      true
    case .ready(.notInstalled), .failedTransient: false
    }
  }

  /// Belongs in the install modal: not installed, mid-install, transiently
  /// errored, or outdated, so a non-converged install stays visible instead of
  /// reading as a silent success. An undetermined row is excluded: its Install
  /// button would be a guess against a file Supacode could not read.
  /// Exhaustive so a new state forces a decision.
  public var isInstallSheetCandidate: Bool {
    switch self {
    case .ready(.notInstalled), .installing, .failedTransient, .ready(.outdated): true
    case .checking, .uninstalling, .failed, .ready(.installed), .undetermined: false
    }
  }
}
