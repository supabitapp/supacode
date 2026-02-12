import Foundation
import Testing

@testable import supacode

private let agentHooksInstallerTestLock = NSLock()

@MainActor
struct AgentHooksInstallerTests {
  @Test func synchronizeCreatesExpectedFilesAndPrunesDisabledIntegrations() throws {
    agentHooksInstallerTestLock.lock()
    defer { agentHooksInstallerTestLock.unlock() }

    let fileManager = FileManager.default
    let tempRoot = fileManager.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let resourcesDirectory = tempRoot.appending(path: "resources", directoryHint: .isDirectory)
    try fileManager.createDirectory(at: resourcesDirectory, withIntermediateDirectories: true)

    try "#!/usr/bin/env bash\n".write(
      to: resourcesDirectory.appending(path: "notify.sh", directoryHint: .notDirectory),
      atomically: true,
      encoding: .utf8
    )
    try "#!/usr/bin/env bash\n".write(
      to: resourcesDirectory.appending(path: "claude-wrapper.sh", directoryHint: .notDirectory),
      atomically: true,
      encoding: .utf8
    )
    try "#!/usr/bin/env bash\n".write(
      to: resourcesDirectory.appending(path: "codex-wrapper.sh", directoryHint: .notDirectory),
      atomically: true,
      encoding: .utf8
    )
    try "{\"hooks\":{\"UserPromptSubmit\":[{\"command\":[\"bash\",\"__NOTIFY_PATH__\"]}]}}".write(
      to: resourcesDirectory.appending(path: "claude-settings-template.json", directoryHint: .notDirectory),
      atomically: true,
      encoding: .utf8
    )

    AgentHooksInstaller.baseDirectoryOverride = tempRoot
    AgentHooksInstaller.resourceDirectoryOverride = resourcesDirectory
    AgentHooksInstaller.signalsDirectoryOverride = tempRoot.appending(path: "signals", directoryHint: .isDirectory)

    defer {
      AgentHooksInstaller.baseDirectoryOverride = nil
      AgentHooksInstaller.resourceDirectoryOverride = nil
      AgentHooksInstaller.signalsDirectoryOverride = nil
      try? fileManager.removeItem(at: tempRoot)
    }

    try AgentHooksInstaller.synchronize(claudeEnabled: true, codexEnabled: false)

    #expect(fileManager.fileExists(atPath: AgentHooksInstaller.hooksDirectory.path(percentEncoded: false)))
    #expect(
      fileManager.fileExists(
        atPath: AgentHooksInstaller.binDirectory.appending(path: "claude").path(percentEncoded: false)))
    #expect(
      !fileManager.fileExists(
        atPath: AgentHooksInstaller.binDirectory.appending(path: "codex").path(percentEncoded: false)))
    #expect(
      fileManager.fileExists(
        atPath: AgentHooksInstaller.hooksDirectory
          .appending(path: "claude-settings.json", directoryHint: .notDirectory)
          .path(percentEncoded: false)
      )
    )

    let renderedSettings = try String(
      contentsOf: AgentHooksInstaller.hooksDirectory
        .appending(path: "claude-settings.json", directoryHint: .notDirectory),
      encoding: .utf8
    )
    #expect(
      renderedSettings.contains(
        AgentHooksInstaller.hooksDirectory
          .appending(path: "notify.sh", directoryHint: .notDirectory)
          .path(percentEncoded: false)
      )
    )

    try AgentHooksInstaller.synchronize(claudeEnabled: false, codexEnabled: true)

    #expect(
      !fileManager.fileExists(
        atPath: AgentHooksInstaller.binDirectory.appending(path: "claude").path(percentEncoded: false)))
    #expect(
      fileManager.fileExists(
        atPath: AgentHooksInstaller.binDirectory.appending(path: "codex").path(percentEncoded: false)))
    #expect(
      !fileManager.fileExists(
        atPath: AgentHooksInstaller.hooksDirectory
          .appending(path: "claude-settings.json", directoryHint: .notDirectory)
          .path(percentEncoded: false)
      )
    )

    try AgentHooksInstaller.synchronize(claudeEnabled: false, codexEnabled: false)

    #expect(!fileManager.fileExists(atPath: AgentHooksInstaller.hooksDirectory.path(percentEncoded: false)))
  }

  @Test func synchronizeThrowsWhenRequiredResourcesAreMissing() throws {
    agentHooksInstallerTestLock.lock()
    defer { agentHooksInstallerTestLock.unlock() }

    let fileManager = FileManager.default
    let tempRoot = fileManager.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let resourcesDirectory = tempRoot.appending(path: "resources", directoryHint: .isDirectory)
    try fileManager.createDirectory(at: resourcesDirectory, withIntermediateDirectories: true)

    AgentHooksInstaller.baseDirectoryOverride = tempRoot
    AgentHooksInstaller.resourceDirectoryOverride = resourcesDirectory
    AgentHooksInstaller.signalsDirectoryOverride = tempRoot.appending(path: "signals", directoryHint: .isDirectory)

    defer {
      AgentHooksInstaller.baseDirectoryOverride = nil
      AgentHooksInstaller.resourceDirectoryOverride = nil
      AgentHooksInstaller.signalsDirectoryOverride = nil
      try? fileManager.removeItem(at: tempRoot)
    }

    var didThrow = false
    do {
      try AgentHooksInstaller.synchronize(claudeEnabled: true, codexEnabled: false)
    } catch {
      didThrow = true
    }

    #expect(didThrow)
  }
}
