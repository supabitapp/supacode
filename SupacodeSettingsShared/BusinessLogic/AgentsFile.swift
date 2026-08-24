import Dependencies
import Foundation
import Sharing

/// One installed agent integration on record. `path` is nil for the default
/// config directory, or the resolved config-dir path for a custom folder.
public nonisolated struct AgentInstallRecord: Codable, Equatable, Sendable {
  public var agent: SkillAgent
  public var path: String?

  public init(agent: SkillAgent, path: String? = nil) {
    self.agent = agent
    self.path = path
  }
}

/// Contents of `~/.config/supacode/agents.json`: the integrations the user
/// installed. The on-disk source of truth for which rows exist; the filesystem
/// probe reconciles live status on top, so a gone target reads as a wrong install.
public nonisolated struct AgentsFile: Codable, Equatable, Sendable {
  public var agents: [AgentInstallRecord]

  public init(agents: [AgentInstallRecord] = []) {
    self.agents = agents
  }

  enum CodingKeys: String, CodingKey { case agents }

  /// One array element, decoded so it can never throw: a malformed or
  /// unrecognized record becomes `nil` (and, crucially, still advances the array
  /// decoder), so one bad record drops only itself, never its valid siblings.
  private struct FailableRecord: Decodable {
    let record: AgentInstallRecord?

    private struct RawRecord: Decodable {
      let agent: String
      let path: String?
    }

    init(from decoder: any Decoder) throws {
      guard let raw = try? RawRecord(from: decoder), let agent = SkillAgent(rawValue: raw.agent) else {
        record = nil
        return
      }
      record = AgentInstallRecord(agent: agent, path: raw.path)
    }
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // A file that isn't an array of records at all resets to empty; a single bad
    // record within it drops only itself (see `FailableRecord`).
    let elements = (try? container.decodeIfPresent([FailableRecord].self, forKey: .agents)) ?? []
    agents = elements.compactMap(\.record)
  }
}

extension AgentInstallTarget {
  /// The persistable record for this target.
  public var installRecord: AgentInstallRecord {
    switch location {
    case .standard: AgentInstallRecord(agent: agent, path: nil)
    case .custom(let path): AgentInstallRecord(agent: agent, path: path)
    }
  }
}

extension AgentInstallRecord {
  /// The install target this record identifies.
  public var target: AgentInstallTarget {
    AgentInstallTarget(
      agent: agent,
      location: path.map { AgentInstallLocation.custom(configDirectoryPath: $0) } ?? .standard)
  }
}

/// Reads and writes `agents.json` through the shared settings-file storage
/// (in-memory in tests, symlink-preserving on disk in release). Absent or
/// undecodable both serve an empty file; a later mutation writes a clean one.
public nonisolated struct AgentsFileKey: SharedKey {
  private static let logger = SupaLogger("Settings")

  let url: URL

  public init(url: URL = SupacodePaths.agentsURL) {
    self.url = url
  }

  public var id: URL { url }

  public func load(context _: LoadContext<AgentsFile>, continuation: LoadContinuation<AgentsFile>) {
    @Dependency(\.settingsFileStorage) var storage
    guard let data = try? storage.load(url) else {
      continuation.resumeReturningInitialValue()
      return
    }
    guard let file = try? JSONDecoder().decode(AgentsFile.self, from: data) else {
      Self.logger.error("agents.json present but undecodable; serving an empty file.")
      continuation.resumeReturningInitialValue()
      return
    }
    continuation.resume(returning: file)
  }

  public func subscribe(
    context _: LoadContext<AgentsFile>,
    subscriber _: SharedSubscriber<AgentsFile>
  ) -> SharedSubscription {
    SharedSubscription {}
  }

  public func save(_ value: AgentsFile, context _: SaveContext, continuation: SaveContinuation) {
    @Dependency(\.settingsFileStorage) var storage
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try storage.save(try encoder.encode(value), url)
      continuation.resume()
    } catch {
      continuation.resume(throwing: error)
    }
  }
}

nonisolated extension SharedReaderKey where Self == AgentsFileKey.Default {
  public static var agentsFile: Self {
    Self[AgentsFileKey(), default: AgentsFile()]
  }
}
