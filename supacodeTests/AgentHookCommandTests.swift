import Foundation
import Testing

@testable import supacode

struct AgentHookCommandTests {
  // MARK: - Command generation.

  @Test func busyActiveCommandContainsFlag1() {
    let command = AgentHookSettingsCommand.busyCommand(active: true)
    #expect(command.contains("$SUPACODE_SURFACE_ID 1"))
  }

  @Test func busyInactiveCommandContainsFlag0() {
    let command = AgentHookSettingsCommand.busyCommand(active: false)
    #expect(command.contains("$SUPACODE_SURFACE_ID 0"))
  }

  @Test func busyCommandChecksAllFourEnvVars() {
    let command = AgentHookSettingsCommand.busyCommand(active: true)
    #expect(command.contains("SUPACODE_SOCKET_PATH"))
    #expect(command.contains("SUPACODE_WORKTREE_ID"))
    #expect(command.contains("SUPACODE_TAB_ID"))
    #expect(command.contains("SUPACODE_SURFACE_ID"))
  }

  @Test func busyCommandSuppressesErrors() {
    let command = AgentHookSettingsCommand.busyCommand(active: true)
    #expect(command.hasSuffix("2>/dev/null || true"))
  }

  @Test func notificationCommandIncludesAgent() {
    let command = AgentHookSettingsCommand.notificationCommand(agent: "claude")
    #expect(command.contains("claude"))
  }

  @Test func notificationCommandIncludesAllThreeIDs() {
    let command = AgentHookSettingsCommand.notificationCommand(agent: "codex")
    #expect(command.contains("$SUPACODE_WORKTREE_ID"))
    #expect(command.contains("$SUPACODE_TAB_ID"))
    #expect(command.contains("$SUPACODE_SURFACE_ID"))
  }

  // MARK: - Command ownership.

  @Test func currentCommandIsRecognized() {
    let command = AgentHookSettingsCommand.busyCommand(active: true)
    #expect(AgentHookCommandOwnership.isSupacodeManagedCommand(command))
  }

  @Test func notificationCommandIsRecognized() {
    let command = AgentHookSettingsCommand.notificationCommand(agent: "claude")
    #expect(AgentHookCommandOwnership.isSupacodeManagedCommand(command))
  }

  @Test func legacyCommandIsRecognized() {
    let legacy = "SUPACODE_CLI_PATH=/usr/bin/supacode agent-hook --stop"
    #expect(AgentHookCommandOwnership.isSupacodeManagedCommand(legacy))
    #expect(AgentHookCommandOwnership.isLegacyCommand(legacy))
  }

  @Test func legacyCommandRequiresBothMarkers() {
    #expect(!AgentHookCommandOwnership.isLegacyCommand("SUPACODE_CLI_PATH only"))
    #expect(!AgentHookCommandOwnership.isLegacyCommand("agent-hook only"))
  }

  @Test func unrelatedCommandIsNotRecognized() {
    #expect(!AgentHookCommandOwnership.isSupacodeManagedCommand("echo hello"))
    #expect(!AgentHookCommandOwnership.isSupacodeManagedCommand(nil))
  }

  @Test func currentCommandIsNotLegacy() {
    let command = AgentHookSettingsCommand.busyCommand(active: true)
    #expect(!AgentHookCommandOwnership.isLegacyCommand(command))
  }

  // MARK: - Shared constants consistency.

  @Test func socketPathEnvVarPresentInGeneratedCommands() {
    let busy = AgentHookSettingsCommand.busyCommand(active: true)
    let notify = AgentHookSettingsCommand.notificationCommand(agent: "test")
    #expect(busy.contains(AgentHookSettingsCommand.socketPathEnvVar))
    #expect(notify.contains(AgentHookSettingsCommand.socketPathEnvVar))
  }
}
