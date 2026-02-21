import Foundation

nonisolated enum SupacodePaths {
  static var baseDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".supacode", directoryHint: .isDirectory)
  }

  static var reposDirectory: URL {
    baseDirectory.appending(path: "repos", directoryHint: .isDirectory)
  }

  static func repositoryDirectory(for rootURL: URL) -> URL {
    let repoName = rootURL.lastPathComponent
    let fallback = rootURL.path(percentEncoded: false).replacing("/", with: "_")
    let name = repoName.isEmpty ? fallback : repoName
    return reposDirectory.appending(path: name, directoryHint: .isDirectory)
  }

  static var settingsURL: URL {
    baseDirectory.appending(path: "settings.json", directoryHint: .notDirectory)
  }

  static func agentHooksDirectory(in baseDirectory: URL) -> URL {
    baseDirectory.appending(path: "agent-hooks", directoryHint: .isDirectory)
  }

  static var agentHooksDirectory: URL {
    agentHooksDirectory(in: baseDirectory)
  }

  static func agentHooksBinDirectory(in baseDirectory: URL) -> URL {
    agentHooksDirectory(in: baseDirectory).appending(path: "bin", directoryHint: .isDirectory)
  }

  static var agentHooksBinDirectory: URL {
    agentHooksBinDirectory(in: baseDirectory)
  }

  static func agentHooksScriptsDirectory(in baseDirectory: URL) -> URL {
    agentHooksDirectory(in: baseDirectory).appending(path: "scripts", directoryHint: .isDirectory)
  }

  static var agentHooksScriptsDirectory: URL {
    agentHooksScriptsDirectory(in: baseDirectory)
  }

  static func agentNotifyScriptURL(in baseDirectory: URL) -> URL {
    agentHooksScriptsDirectory(in: baseDirectory).appending(path: "notify.sh", directoryHint: .notDirectory)
  }

  static var agentNotifyScriptURL: URL {
    agentNotifyScriptURL(in: baseDirectory)
  }

  static func agentClaudeSettingsURL(in baseDirectory: URL) -> URL {
    agentHooksDirectory(in: baseDirectory).appending(path: "claude-settings.json", directoryHint: .notDirectory)
  }

  static var agentClaudeSettingsURL: URL {
    agentClaudeSettingsURL(in: baseDirectory)
  }

  static func agentEventsDirectory(in baseDirectory: URL) -> URL {
    agentHooksDirectory(in: baseDirectory).appending(path: "events", directoryHint: .isDirectory)
  }

  static var agentEventsDirectory: URL {
    agentEventsDirectory(in: baseDirectory)
  }

  static func agentEventsLogURL(in baseDirectory: URL) -> URL {
    agentEventsDirectory(in: baseDirectory).appending(path: "agent-events.jsonl", directoryHint: .notDirectory)
  }

  static var agentEventsLogURL: URL {
    agentEventsLogURL(in: baseDirectory)
  }
}
