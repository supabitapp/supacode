## ADDED Requirements

### Requirement: Kiro progress hooks install and uninstall
The system SHALL install progress hooks into `~/.kiro/agents/kiro_default.json` that send busy-on on `userPromptSubmit` and busy-off on `stop` via the Supacode Unix socket. The system SHALL uninstall these hooks by removing the managed commands from the file.

#### Scenario: Install progress hooks when no kiro_default.json exists
- **WHEN** user taps Install on Kiro progress hooks and `~/.kiro/agents/kiro_default.json` does not exist
- **THEN** the system creates the file with the full default agent config plus `userPromptSubmit` and `stop` busy hooks

#### Scenario: Install progress hooks when kiro_default.json already exists
- **WHEN** user taps Install on Kiro progress hooks and `~/.kiro/agents/kiro_default.json` already exists with user content
- **THEN** the system merges the busy hooks into the existing `hooks` key without modifying other keys

#### Scenario: Uninstall progress hooks
- **WHEN** user taps Uninstall on Kiro progress hooks
- **THEN** the system removes the managed busy commands from the file, preserving other hooks, config, and the file itself

#### Scenario: Check progress hooks installed
- **WHEN** the settings view loads
- **THEN** the system checks `~/.kiro/agents/kiro_default.json` for the presence of managed busy commands and reflects the state as installed or not installed

### Requirement: Kiro notification hooks install and uninstall
The system SHALL install notification hooks into `~/.kiro/agents/kiro_default.json` that forward the `stop` event payload to Supacode via the Unix socket. The system SHALL uninstall these hooks by removing the managed commands.

#### Scenario: Install notification hooks
- **WHEN** user taps Install on Kiro notification hooks
- **THEN** the system adds a `stop` hook with the notification command to the file

#### Scenario: Uninstall notification hooks
- **WHEN** user taps Uninstall on Kiro notification hooks
- **THEN** the system removes the managed notification commands from the file

### Requirement: Kiro CLI skill install and uninstall
The system SHALL install a `supacode-cli` skill into `~/.kiro/skills/supacode-cli/SKILL.md` that documents the Supacode CLI commands for Kiro agents.

#### Scenario: Install CLI skill
- **WHEN** user taps Install on Kiro CLI skill
- **THEN** the system writes `~/.kiro/skills/supacode-cli/SKILL.md` with Supacode CLI documentation

#### Scenario: Uninstall CLI skill
- **WHEN** user taps Uninstall on Kiro CLI skill
- **THEN** the system removes the `~/.kiro/skills/supacode-cli/` directory

### Requirement: Kiro section in settings UI
The system SHALL display a Kiro section in Settings → Coding Agents with progress, notifications, and CLI skill rows, matching the layout of the Claude Code and Codex sections.

#### Scenario: Kiro section renders with correct states
- **WHEN** user opens Settings → Coding Agents
- **THEN** a Kiro section appears with a Kiro icon, three install rows (Progress, Notifications, CLI Skill), and a footer noting `Applied to ~/.kiro`

### Requirement: Socket server decodes Kiro assistant_response
The system SHALL decode the `assistant_response` field from Kiro's `stop` hook event JSON and use it as the notification body when `message` and `last_assistant_message` are absent.

#### Scenario: Notification from Kiro stop event
- **WHEN** the socket server receives a notification with agent `kiro` and JSON containing `assistant_response` but no `message` or `last_assistant_message`
- **THEN** the notification body is set to the value of `assistant_response`

### Requirement: Kiro hooks use flat format
The installer SHALL write hooks in Kiro's native flat format (`{ "command": "...", "timeout_ms": 10000 }` per event entry) rather than the grouped format used by Claude/Codex. The installer SHALL NOT reuse `AgentHookGroup`, `AgentCommandHook`, or `AgentHookPayloadSupport`.

#### Scenario: Installed hooks match Kiro format
- **WHEN** hooks are installed into `kiro_default.json`
- **THEN** each event key contains a flat array of `{ "command", "timeout_ms" }` objects with no `type` field and no group wrapper

### Requirement: App builds successfully after all changes
After all code changes are applied, the app SHALL build without errors using `make build-app`.

#### Scenario: Clean build after implementation
- **WHEN** all tasks are complete
- **THEN** `make build-app` succeeds with exit code 0

### Requirement: Kiro installer creates complete default agent config
When `~/.kiro/agents/kiro_default.json` does not exist, the installer SHALL create it with the known built-in defaults (`tools: ["*"]`, standard resources, `useLegacyMcpJson: true`) plus the requested hooks, so the file fully replaces the built-in agent.

#### Scenario: Fresh install creates complete config
- **WHEN** progress hooks are installed and no `kiro_default.json` exists
- **THEN** the created file contains `name`, `tools`, `resources`, `useLegacyMcpJson`, and `hooks` keys
