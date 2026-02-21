import Foundation
import Testing

@testable import supacode

struct CodingAgentIntegrationManagerTests {
  @Test func enableClaudeCreatesExpectedFiles() throws {
    let baseDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }

    let manager = CodingAgentIntegrationManager(baseDirectory: baseDirectory)

    try manager.setEnabled(.claude, enabled: true)

    let status = try manager.status()
    #expect(status.claudeEnabled == true)
    #expect(status.codexEnabled == false)

    let wrapperURL = SupacodePaths.agentHooksBinDirectory(in: baseDirectory)
      .appending(path: "claude", directoryHint: .notDirectory)
    let notifyURL = SupacodePaths.agentNotifyScriptURL(in: baseDirectory)
    let settingsURL = SupacodePaths.agentClaudeSettingsURL(in: baseDirectory)

    #expect(FileManager.default.isExecutableFile(atPath: wrapperURL.path(percentEncoded: false)))
    #expect(FileManager.default.isExecutableFile(atPath: notifyURL.path(percentEncoded: false)))
    #expect(FileManager.default.fileExists(atPath: settingsURL.path(percentEncoded: false)))

    let wrapper = try String(contentsOf: wrapperURL, encoding: .utf8)
    let notify = try String(contentsOf: notifyURL, encoding: .utf8)
    let settings = try String(contentsOf: settingsURL, encoding: .utf8)

    #expect(wrapper.contains("SUPACODE_AGENT_INTEGRATION_V1"))
    #expect(wrapper.contains("--settings"))
    #expect(notify.contains("agent-turn-complete"))
    #expect(settings.contains("UserPromptSubmit"))
    #expect(settings.contains("PermissionRequest"))
  }

  @Test func enableCodexCreatesExpectedFiles() throws {
    let baseDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }

    let manager = CodingAgentIntegrationManager(baseDirectory: baseDirectory)

    try manager.setEnabled(.codex, enabled: true)

    let status = try manager.status()
    #expect(status.claudeEnabled == false)
    #expect(status.codexEnabled == true)

    let wrapperURL = SupacodePaths.agentHooksBinDirectory(in: baseDirectory)
      .appending(path: "codex", directoryHint: .notDirectory)
    let notifyURL = SupacodePaths.agentNotifyScriptURL(in: baseDirectory)

    #expect(FileManager.default.isExecutableFile(atPath: wrapperURL.path(percentEncoded: false)))
    #expect(FileManager.default.isExecutableFile(atPath: notifyURL.path(percentEncoded: false)))

    let wrapper = try String(contentsOf: wrapperURL, encoding: .utf8)
    #expect(wrapper.contains("SUPACODE_AGENT_INTEGRATION_V1"))
    #expect(wrapper.contains("notify=["))
  }

  @Test func disableCleansUpFiles() throws {
    let baseDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }

    let manager = CodingAgentIntegrationManager(baseDirectory: baseDirectory)

    try manager.setEnabled(.claude, enabled: true)
    try manager.setEnabled(.codex, enabled: true)
    try manager.setEnabled(.codex, enabled: false)

    var status = try manager.status()
    #expect(status.claudeEnabled == true)
    #expect(status.codexEnabled == false)
    #expect(
      FileManager.default.fileExists(
        atPath: SupacodePaths.agentNotifyScriptURL(in: baseDirectory).path(percentEncoded: false)))

    try manager.setEnabled(.claude, enabled: false)

    status = try manager.status()
    #expect(status == .disabled)
    #expect(
      !FileManager.default.fileExists(
        atPath: SupacodePaths.agentNotifyScriptURL(in: baseDirectory).path(percentEncoded: false)))
    #expect(
      !FileManager.default.fileExists(
        atPath: SupacodePaths.agentClaudeSettingsURL(in: baseDirectory).path(percentEncoded: false)))
  }

  @Test func statusRequiresOwnedWrappers() throws {
    let baseDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }

    let binDirectory = SupacodePaths.agentHooksBinDirectory(in: baseDirectory)
    let scriptsDirectory = SupacodePaths.agentHooksScriptsDirectory(in: baseDirectory)
    try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: scriptsDirectory, withIntermediateDirectories: true)

    let codexWrapperURL = binDirectory.appending(path: "codex", directoryHint: .notDirectory)
    try Data("#!/bin/bash\nexit 0\n".utf8).write(to: codexWrapperURL, options: [.atomic])
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o755))],
      ofItemAtPath: codexWrapperURL.path(percentEncoded: false)
    )

    let notifyURL = SupacodePaths.agentNotifyScriptURL(in: baseDirectory)
    try Data("#!/bin/bash\nSUPACODE_AGENT_INTEGRATION_V1\n".utf8).write(to: notifyURL, options: [.atomic])
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o755))],
      ofItemAtPath: notifyURL.path(percentEncoded: false)
    )

    let manager = CodingAgentIntegrationManager(baseDirectory: baseDirectory)
    let status = try manager.status()
    #expect(status == .disabled)
  }

  private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "supacode-coding-agents-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}
