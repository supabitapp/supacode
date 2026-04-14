## 1. Hook Settings & Installer

- [x] 1.1 Create `KiroHookSettings.swift` with `KiroHookEntry` struct (`command` + `timeout_ms`, no `type`), progress payload (`userPromptSubmit` → busy on, `stop` → busy off) and notification payload (`stop` → notify with agent `"kiro"`)
- [x] 1.2 Create `KiroHookSettingsFileInstaller.swift` — thin wrapper that handles Kiro's flat hook format (`hooks → event → entries[]`) for `install`, `uninstall`, and `containsMatchingHooks`
- [x] 1.3 Create `KiroSettingsInstaller.swift` targeting `~/.kiro/agents/kiro_default.json`, with default agent config creation when file is absent, using `KiroHookSettingsFileInstaller`
- [x] 1.4 Create `KiroSettingsClient.swift` TCA dependency with `checkInstalled`, `installProgress`, `installNotifications`, `uninstallProgress`, `uninstallNotifications`

## 2. Enums & State Wiring

- [x] 2.1 Add `.kiroProgress`, `.kiroNotifications` to `AgentHookSlot` and wire the `subscript(hookSlot:)` accessor in `SettingsFeature.State`
- [x] 2.2 Add `.kiro` to `SkillAgent` with `configDirectoryName: ".kiro"` and wire `subscript(skillAgent:)`
- [x] 2.3 Add `kiroProgressState`, `kiroNotificationsState`, `kiroSkillState` to `SettingsFeature.State`

## 3. Reducer

- [x] 3.1 Add `@Dependency(KiroSettingsClient.self)` to `SettingsFeature`
- [x] 3.2 Wire Kiro hook check in `.task` effect alongside Claude/Codex checks
- [x] 3.3 Wire Kiro install/uninstall cases in `agentHookInstallTapped` and `agentHookUninstallTapped` switch statements
- [x] 3.4 Wire `.kiro` in `cliSkillInstallTapped`/`cliSkillUninstallTapped` and skill check

## 4. CLI Skill Content

- [x] 4.1 Add Kiro skill content to `CLISkillContent` (SKILL.md format with frontmatter)
- [x] 4.2 Handle `.kiro` case in `CLISkillInstaller` (install to `~/.kiro/skills/supacode-cli/SKILL.md`)

## 5. Socket Server

- [x] 5.1 Add `assistantResponse` (`assistant_response`) to `AgentHookPayload` CodingKeys
- [x] 5.2 Update `parseNotification` body fallback: `message ?? lastAssistantMessage ?? assistantResponse`

## 6. UI & Assets

- [x] 6.1 Add `kiro-mark` image set to asset catalog
- [x] 6.2 Add Kiro section to `DeveloperSettingsView` with progress, notifications, and CLI skill rows, footer `Applied to ~/.kiro`

## 7. Verify

- [x] 7.1 Run `make build-app` and confirm clean build
