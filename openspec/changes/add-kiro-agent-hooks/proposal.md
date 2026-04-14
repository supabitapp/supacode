## Why

Supacode supports Claude Code and Codex as coding agents with progress and notification hooks. Kiro CLI is a third coding agent that supports the same hook event model (`userPromptSubmit`, `stop`) but has no Supacode integration. Users running Kiro in Supacode terminals get no busy indicators or rich notifications.

## What Changes

- Add Kiro CLI as a third coding agent in Settings → Coding Agents
- Install progress hooks (busy on/off) into Kiro's agent config at `~/.kiro/agents/kiro_default.json`
- Install notification hooks (forward stop events) into the same config
- Add a CLI skill that teaches Kiro how to use the `supacode` CLI
- Extend `AgentHookPayload` to decode Kiro's `assistant_response` field from stop events
- Add Kiro icon asset to the asset catalog

## Capabilities

### New Capabilities
- `kiro-agent-hooks`: Progress and notification hook installation/uninstallation for Kiro CLI, including settings UI, installer, and TCA client.

### Modified Capabilities

## Impact

- **Settings UI**: New Kiro section in `DeveloperSettingsView` (progress, notifications, CLI skill rows)
- **State**: New `kiroProgressState`, `kiroNotificationsState`, `kiroSkillState` in `SettingsFeature.State`
- **Enums**: `AgentHookSlot` gains `.kiroProgress`, `.kiroNotifications`; `SkillAgent` gains `.kiro`
- **Socket server**: `AgentHookPayload` adds `assistant_response` coding key; `parseNotification` falls back to it
- **Assets**: New `kiro-mark` image set
- **New files**: `KiroHookSettings.swift`, `KiroSettingsInstaller.swift`, `KiroSettingsClient.swift`, Kiro skill content in `CLISkillContent`
