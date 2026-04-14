## Context

Supacode integrates with coding agents via hook commands that send busy/notification signals over a Unix socket. Claude Code and Codex each have a dedicated installer that writes hooks into a single config file (`~/.claude/settings.json`, `~/.codex/hooks.json`). The shared `AgentHookSettingsFileInstaller` handles the JSON merge/prune logic for any file with a `{ "hooks": { event: [groups] } }` shape.

Kiro CLI stores hooks inside per-agent JSON configs (`~/.kiro/agents/<name>.json`). The built-in `kiro_default` agent has no file on disk and cannot be edited. A user-created file at `~/.kiro/agents/kiro_default.json` overrides the built-in entirely.

Kiro's hook events (`userPromptSubmit`, `stop`) map directly to the busy on/off and notification patterns already used by Claude and Codex. The hook event JSON includes `hook_event_name` (already decoded) and `assistant_response` (not yet decoded).

## Goals / Non-Goals

**Goals:**
- Add Kiro as a third agent in Settings → Coding Agents with progress, notification, and CLI skill rows
- Reuse the existing `AgentHookSettingsFileInstaller` for install/uninstall/check
- Decode Kiro's `assistant_response` field in the socket server's notification parser

**Non-Goals:**
- Installing hooks into custom Kiro agents (e.g., `pr-reviewer.json`) — only the default agent
- Agent inheritance or config merging across Kiro agent files
- Supporting Kiro IDE hooks (only Kiro CLI)

## Decisions

**D1: Target `~/.kiro/agents/kiro_default.json` as the single config file**

Kiro has no global hooks file. Hooks live per-agent. The default agent is what runs in Supacode terminals in the common case. Creating `kiro_default.json` overrides the built-in, so the installer must write a complete agent config (not just hooks).

Alternative considered: inject hooks into all `~/.kiro/agents/*.json` files. Rejected because `isInstalled()` becomes ambiguous, new agents created later wouldn't get hooks, and the default agent (most common) still wouldn't be covered since it has no file.

**D2: Replicate the built-in `kiro_default` config in the created file**

When no `kiro_default.json` exists, the installer creates one with the known built-in defaults (`tools: ["*"]`, standard resources, `useLegacyMcpJson: true`) plus hooks. When the file already exists, the installer uses `AgentHookSettingsFileInstaller` to merge/prune hooks only, preserving user customizations.

The built-in config is small and stable:
```json
{
  "name": "kiro_default",
  "tools": ["*"],
  "resources": [
    "file://AGENTS.md", "file://README.md",
    "skill://.kiro/skills/**/SKILL.md",
    "skill://.kiro/steering/**/*.md"
  ],
  "useLegacyMcpJson": true,
  "hooks": {}
}
```

**D3: Follow the Claude installer pattern (synchronous, no CLI prerequisite)**

Unlike Codex which requires `codex features enable codex_hooks` before install, Kiro has no feature gate. The installer is synchronous like Claude's — just file I/O.

**D4: Add `assistant_response` to `AgentHookPayload`**

Kiro's `stop` event sends `{ "hook_event_name": "stop", "assistant_response": "..." }`. The existing `parseNotification` body fallback chain becomes: `message ?? lastAssistantMessage ?? assistantResponse`.

**D5: Kiro hook events — minimal set**

Progress hooks:
- `userPromptSubmit` → busy ON
- `stop` → busy OFF

Notification hooks:
- `stop` → notify (body from `assistant_response`)

No equivalent to Claude's `PostToolUseFailure` or `SessionEnd` in Kiro. Simpler payload.

**D6: Kiro-specific payload structs and file installer wrapper**

Kiro's hook JSON format differs from Claude/Codex:
- Flat array per event: `{ "command": "...", "timeout_ms": 10000 }` (no `type` field, no group wrapper, milliseconds not seconds)
- Claude/Codex use: `[{ matcher?, hooks: [{ type: "command", command: "...", timeout: 10 }] }]`

The existing `AgentHookGroup`/`AgentCommandHook`/`AgentHookPayloadSupport.extractHookGroups` and `AgentHookSettingsFileInstaller.containsMatchingHooks` all assume the grouped shape. Rather than generalizing shared code, create:
- `KiroHookEntry` struct (Encodable): `command` + `timeout_ms`
- `KiroHookPayloadSupport`: extracts `[String: [JSONValue]]` from the flat format
- `KiroHookSettingsFileInstaller`: thin wrapper with `install`/`uninstall`/`containsMatchingHooks` that walks the flat `hooks → event → entries[] → command` structure

This keeps Claude/Codex code untouched and isolates Kiro's format differences.

**D7: Uninstall leaves `kiro_default.json` in place**

Uninstalling hooks removes the managed commands but never deletes the file. A file with empty hooks and default config is harmless, and deleting it would silently revert the user to the built-in which may differ from their customizations. Same approach as Claude (never deletes `settings.json`).

**D8: Kiro CLI skill uses Codex-style compact format**

Kiro's skill format matches Codex (SKILL.md with YAML frontmatter). Use the trimmed Codex-style content rather than the verbose Claude version.

## Risks / Trade-offs

**[Risk] Built-in `kiro_default` config changes across Kiro versions** → The created file freezes the config at install time. Mitigation: the config is minimal (tools `"*"` + standard resources). If Kiro adds new defaults, users can uninstall and reinstall to pick up changes. Document this in the settings footer.

**[Risk] User already has a customized `kiro_default.json`** → The installer uses `AgentHookSettingsFileInstaller` which merges hooks into existing files without touching other keys. No data loss.

**[Risk] Kiro renames hook events** → Low probability. The event names (`userPromptSubmit`, `stop`) follow the same convention as Claude/Codex. If they change, hooks silently stop firing — same failure mode as the other agents.
