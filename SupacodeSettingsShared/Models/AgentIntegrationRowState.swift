import Foundation

/// Where an agent integration is installed: its default config directory, or a
/// custom one the user chose. The custom payload is the resolved config dir
/// itself, canonicalized so it keys per-install state uniquely.
public nonisolated enum AgentInstallLocation: Hashable, Sendable {
  case standard
  case custom(configDirectoryPath: String)
}

/// One installable integration: an agent at a specific location. Keys the
/// per-install row state and the install/uninstall effects so two installs of
/// the same agent into different folders never cancel or clobber each other.
public nonisolated struct AgentInstallTarget: Hashable, Sendable {
  public let agent: SkillAgent
  public let location: AgentInstallLocation

  public init(agent: SkillAgent, location: AgentInstallLocation = .standard) {
    self.agent = agent
    self.location = location
  }

  /// The default-directory target for an agent.
  public static func standard(_ agent: SkillAgent) -> AgentInstallTarget {
    AgentInstallTarget(agent: agent, location: .standard)
  }

  /// Config-dir override to hand `AgentIntegrationFactory`: `nil` for the
  /// default location (the factory then derives it under home).
  public var configDirectoryURL: URL? {
    switch location {
    case .standard: nil
    case .custom(let path): URL(filePath: path, directoryHint: .isDirectory)
    }
  }

  /// The actual config directory: the agent's dir under `home` for the default,
  /// or the chosen folder for a custom install.
  public func configDirectory(
    underHome home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> URL {
    switch location {
    case .standard: home.appending(path: agent.configDirectoryName, directoryHint: .isDirectory)
    case .custom(let path): URL(filePath: path, directoryHint: .isDirectory)
    }
  }
}

extension [AgentInstallTarget: AgentIntegrationRowState] {
  /// Convenience access to an agent's DEFAULT-location row.
  public subscript(agent: SkillAgent) -> AgentIntegrationRowState? {
    get { self[.standard(agent)] }
    set { self[.standard(agent)] = newValue }
  }
}

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

  /// A transient operation is in flight, so no settled verdict exists yet.
  public var isInFlight: Bool {
    switch self {
    case .checking, .installing, .uninstalling: true
    case .ready, .failed, .failedTransient, .undetermined: false
    }
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
