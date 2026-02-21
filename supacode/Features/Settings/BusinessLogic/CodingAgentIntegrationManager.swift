import Foundation

struct CodingAgentIntegrationManager {
  private let fileManager: FileManager
  private let baseDirectory: URL
  private let ownershipMarker = "SUPACODE_AGENT_INTEGRATION_V1"

  init(
    fileManager: FileManager = .default,
    baseDirectory: URL = SupacodePaths.baseDirectory
  ) {
    self.fileManager = fileManager
    self.baseDirectory = baseDirectory
  }

  func status() throws -> CodingAgentIntegrationStatus {
    let paths = IntegrationPaths(baseDirectory: baseDirectory)
    let notifyInstalled = ownedFileExists(paths.notifyScriptURL)
    let claudeWrapperInstalled = ownedFileExists(paths.wrapperURL(for: .claude))
    let codexWrapperInstalled = ownedFileExists(paths.wrapperURL(for: .codex))
    let claudeSettingsInstalled = fileManager.fileExists(
      atPath: paths.claudeSettingsURL.path(percentEncoded: false)
    )
    return CodingAgentIntegrationStatus(
      claudeEnabled: notifyInstalled && claudeWrapperInstalled && claudeSettingsInstalled,
      codexEnabled: notifyInstalled && codexWrapperInstalled
    )
  }

  func setEnabled(_ agent: CodingAgent, enabled: Bool) throws {
    if enabled {
      try enable(agent)
      return
    }
    try disable(agent)
  }

  private func enable(_ agent: CodingAgent) throws {
    let paths = IntegrationPaths(baseDirectory: baseDirectory)
    try fileManager.createDirectory(at: paths.binDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: paths.scriptsDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: paths.eventsDirectory, withIntermediateDirectories: true)
    try writeText(
      notifyScript(paths: paths),
      to: paths.notifyScriptURL,
      permissions: 0o755
    )

    switch agent {
    case .claude:
      try writeText(
        claudeSettingsJSON(paths: paths),
        to: paths.claudeSettingsURL,
        permissions: 0o644
      )
      try writeText(
        claudeWrapperScript(paths: paths),
        to: paths.wrapperURL(for: .claude),
        permissions: 0o755
      )
    case .codex:
      try writeText(
        codexWrapperScript(paths: paths),
        to: paths.wrapperURL(for: .codex),
        permissions: 0o755
      )
    }
  }

  private func disable(_ agent: CodingAgent) throws {
    let paths = IntegrationPaths(baseDirectory: baseDirectory)
    switch agent {
    case .claude:
      try removeIfExists(paths.wrapperURL(for: .claude))
      try removeIfExists(paths.claudeSettingsURL)
    case .codex:
      try removeIfExists(paths.wrapperURL(for: .codex))
    }

    let currentStatus = try status()
    if !currentStatus.isEnabled {
      try removeIfExists(paths.notifyScriptURL)
      try removeIfExists(paths.eventsLogURL)
    }
  }

  private func writeText(_ text: String, to url: URL, permissions: Int16) throws {
    try Data(text.utf8).write(to: url, options: [.atomic])
    try fileManager.setAttributes(
      [.posixPermissions: NSNumber(value: permissions)],
      ofItemAtPath: url.path(percentEncoded: false)
    )
  }

  private func removeIfExists(_ url: URL) throws {
    let path = url.path(percentEncoded: false)
    guard fileManager.fileExists(atPath: path) else {
      return
    }
    try fileManager.removeItem(at: url)
  }

  private func ownedFileExists(_ url: URL) -> Bool {
    let path = url.path(percentEncoded: false)
    guard fileManager.fileExists(atPath: path),
      let content = try? String(contentsOf: url, encoding: .utf8),
      content.contains(ownershipMarker)
    else {
      return false
    }
    return true
  }

  private func claudeWrapperScript(paths: IntegrationPaths) -> String {
    let binPath = shellSingleQuoted(paths.binDirectory.path(percentEncoded: false))
    let settingsPath = shellSingleQuoted(paths.claudeSettingsURL.path(percentEncoded: false))
    return """
      #!/bin/bash
      set -euo pipefail
      SUPACODE_AGENT_INTEGRATION_MARKER=\(ownershipMarker)
      SUPACODE_HOOKS_BIN=\(binPath)

      find_real_binary() {
        local name="$1"
        local IFS=:
        for dir in $PATH; do
          [ -z "$dir" ] && continue
          dir="${dir%/}"
          if [ "$dir" = "${SUPACODE_HOOKS_BIN%/}" ]; then
            continue
          fi
          if [ -x "$dir/$name" ] && [ ! -d "$dir/$name" ]; then
            printf "%s\\n" "$dir/$name"
            return 0
          fi
        done
        return 1
      }

      REAL_BIN="$(find_real_binary "claude")"
      if [ -z "$REAL_BIN" ]; then
        echo "Supacode: claude not found in PATH." >&2
        exit 127
      fi

      exec "$REAL_BIN" --settings \(settingsPath) "$@"
      """
  }

  private func codexWrapperScript(paths: IntegrationPaths) -> String {
    let binPath = shellSingleQuoted(paths.binDirectory.path(percentEncoded: false))
    let notifyPath = shellSingleQuoted(paths.notifyScriptURL.path(percentEncoded: false))
    return """
      #!/bin/bash
      set -euo pipefail
      SUPACODE_AGENT_INTEGRATION_MARKER=\(ownershipMarker)
      SUPACODE_HOOKS_BIN=\(binPath)

      find_real_binary() {
        local name="$1"
        local IFS=:
        for dir in $PATH; do
          [ -z "$dir" ] && continue
          dir="${dir%/}"
          if [ "$dir" = "${SUPACODE_HOOKS_BIN%/}" ]; then
            continue
          fi
          if [ -x "$dir/$name" ] && [ ! -d "$dir/$name" ]; then
            printf "%s\\n" "$dir/$name"
            return 0
          fi
        done
        return 1
      }

      REAL_BIN="$(find_real_binary "codex")"
      if [ -z "$REAL_BIN" ]; then
        echo "Supacode: codex not found in PATH." >&2
        exit 127
      fi

      NOTIFY_PATH=\(notifyPath)
      exec "$REAL_BIN" -c "notify=[\\"bash\\",\\"${NOTIFY_PATH}\\"]" "$@"
      """
  }

  private func notifyScript(paths: IntegrationPaths) -> String {
    let eventsDirectoryPath = shellSingleQuoted(paths.eventsDirectory.path(percentEncoded: false))
    return """
      #!/bin/bash
      set -euo pipefail
      SUPACODE_AGENT_INTEGRATION_MARKER=\(ownershipMarker)
      EVENTS_DIR="${SUPACODE_AGENT_EVENTS_DIR:-\(eventsDirectoryPath)}"
      WORKTREE_ID="${SUPACODE_WORKTREE_ID:-}"
      [ -z "$WORKTREE_ID" ] && exit 0

      if [ -n "${1:-}" ]; then
        INPUT="$1"
      else
        INPUT=$(cat)
      fi

      HOOK_PATTERN='"hook_event_name"[[:space:]]*:[[:space:]]*"[^"]*"'
      EVENT_PATTERN='"type"[[:space:]]*:[[:space:]]*"[^"]*"'
      VALUE_PATTERN='"[^"]*"$'
      EVENT_TYPE=$(printf '%s' "$INPUT" | grep -oE "$HOOK_PATTERN" | grep -oE "$VALUE_PATTERN" | tr -d '"' || true)
      if [ -z "$EVENT_TYPE" ]; then
        EVENT_TYPE=$(printf '%s' "$INPUT" | grep -oE "$EVENT_PATTERN" | grep -oE "$VALUE_PATTERN" | tr -d '"' || true)
      fi

      if [ -z "$EVENT_TYPE" ]; then
        exit 0
      fi

      case "$EVENT_TYPE" in
        UserPromptSubmit|Start|agent-turn-start)
          EVENT_TYPE="Start"
          ;;
        PermissionRequest)
          EVENT_TYPE="PermissionRequest"
          ;;
        Stop|agent-turn-complete|SessionEnd|session-end)
          EVENT_TYPE="Stop"
          ;;
        *)
          exit 0
          ;;
      esac

      mkdir -p "$EVENTS_DIR" >/dev/null 2>&1
      TS="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
      CWD="$(pwd -P 2>/dev/null || pwd)"
      ESC_WORKTREE_ID="${WORKTREE_ID//\\\\/\\\\\\\\}"
      ESC_WORKTREE_ID="${ESC_WORKTREE_ID//\\"/\\\\\\"}"
      ESC_CWD="${CWD//\\\\/\\\\\\\\}"
      ESC_CWD="${ESC_CWD//\\"/\\\\\\"}"
      printf '{"timestamp":"%s","eventType":"%s","worktreeID":"%s","cwd":"%s"}\\n' \
        "$TS" "$EVENT_TYPE" "$ESC_WORKTREE_ID" "$ESC_CWD" \
        >> "$EVENTS_DIR/agent-events.jsonl" 2>/dev/null
      """
  }

  private func claudeSettingsJSON(paths: IntegrationPaths) -> String {
    let command = "bash \(shellSingleQuoted(paths.notifyScriptURL.path(percentEncoded: false)))"
    let hook = ClaudeHook(type: "command", command: command)
    let settings = ClaudeSettings(
      hooks: [
        "UserPromptSubmit": [.init(matcher: nil, hooks: [hook])],
        "Stop": [.init(matcher: nil, hooks: [hook])],
        "SessionEnd": [.init(matcher: nil, hooks: [hook])],
        "PermissionRequest": [.init(matcher: "*", hooks: [hook])],
      ]
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = (try? encoder.encode(settings)) ?? Data("{}".utf8)
    return String(data: data, encoding: .utf8) ?? "{}"
  }

  private func shellSingleQuoted(_ value: String) -> String {
    if value.isEmpty {
      return "''"
    }
    return "'\(value.replacing("'", with: "'\"'\"'"))'"
  }
}

private struct IntegrationPaths {
  let hooksDirectory: URL
  let binDirectory: URL
  let scriptsDirectory: URL
  let eventsDirectory: URL
  let eventsLogURL: URL
  let notifyScriptURL: URL
  let claudeSettingsURL: URL

  init(baseDirectory: URL) {
    hooksDirectory = SupacodePaths.agentHooksDirectory(in: baseDirectory)
    binDirectory = SupacodePaths.agentHooksBinDirectory(in: baseDirectory)
    scriptsDirectory = SupacodePaths.agentHooksScriptsDirectory(in: baseDirectory)
    eventsDirectory = SupacodePaths.agentEventsDirectory(in: baseDirectory)
    eventsLogURL = SupacodePaths.agentEventsLogURL(in: baseDirectory)
    notifyScriptURL = SupacodePaths.agentNotifyScriptURL(in: baseDirectory)
    claudeSettingsURL = SupacodePaths.agentClaudeSettingsURL(in: baseDirectory)
  }

  func wrapperURL(for agent: CodingAgent) -> URL {
    binDirectory.appending(path: agent.wrapperFileName, directoryHint: .notDirectory)
  }
}

private struct ClaudeSettings: Encodable {
  let hooks: [String: [ClaudeHookEvent]]
}

private struct ClaudeHookEvent: Encodable {
  let matcher: String?
  let hooks: [ClaudeHook]
}

private struct ClaudeHook: Encodable {
  let type: String
  let command: String
}
