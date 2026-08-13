import ConcurrencyExtras
import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

struct AgentHookSettingsFileInstallerTests {
  private let fileManager = FileManager.default

  private func makeErrors() -> AgentHookSettingsFileInstaller.Errors {
    .init(
      invalidEventHooks: { TestInstallerError.invalidEventHooks($0) },
      invalidHooksObject: { TestInstallerError.invalidHooksObject },
      invalidJSON: { TestInstallerError.invalidJSON($0) },
      invalidRootObject: { TestInstallerError.invalidRootObject },
    )
  }

  private func makeInstaller() -> AgentHookSettingsFileInstaller {
    AgentHookSettingsFileInstaller(fileManager: fileManager, errors: makeErrors())
  }

  private func makeTempURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("supacode-test-\(UUID().uuidString)")
      .appendingPathComponent("settings.json")
  }

  private func sampleHookGroups() -> [String: [JSONValue]] {
    [
      "Stop": [
        .object([
          "hooks": .array([
            .object([
              "type": "command",
              "command": .string(
                AgentHookSettingsCommand.compositeCommand(
                  events: [.idle], forwardStdinAsNotification: false, agent: .claude)),
              "timeout": 10,
            ])
          ])
        ])
      ]
    ]
  }

  // MARK: - Install.

  @Test func installIntoEmptyFileCreatesCorrectStructure() throws {
    let url = makeTempURL()
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }

    let installer = makeInstaller()
    try installer.install(settingsURL: url, hookGroupsByEvent: sampleHookGroups())

    let data = try Data(contentsOf: url)
    let root = try JSONDecoder().decode(JSONValue.self, from: data)
    guard let hooksObject = root.objectValue?["hooks"]?.objectValue else {
      Issue.record("Expected hooks object")
      return
    }
    #expect(hooksObject["Stop"] != nil)
    let stopGroups = hooksObject["Stop"]?.arrayValue
    #expect(stopGroups?.count == 1)
  }

  @Test func installPreservesExistingNonHookKeys() throws {
    let url = makeTempURL()
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }

    // Write a file with existing keys.
    let existing: JSONValue = .object(["customKey": "customValue"])
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true,
    )
    try JSONEncoder().encode(existing).write(to: url)

    let installer = makeInstaller()
    try installer.install(settingsURL: url, hookGroupsByEvent: sampleHookGroups())

    let data = try Data(contentsOf: url)
    let root = try JSONDecoder().decode(JSONValue.self, from: data)
    #expect(root.objectValue?["customKey"]?.stringValue == "customValue")
    #expect(root.objectValue?["hooks"] != nil)
  }

  @Test func installIsIdempotent() throws {
    let url = makeTempURL()
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }

    let installer = makeInstaller()
    let groups = sampleHookGroups()
    try installer.install(settingsURL: url, hookGroupsByEvent: groups)
    try installer.install(settingsURL: url, hookGroupsByEvent: groups)

    let data = try Data(contentsOf: url)
    let root = try JSONDecoder().decode(JSONValue.self, from: data)
    let stopGroups = root.objectValue?["hooks"]?.objectValue?["Stop"]?.arrayValue
    // Should have exactly one group, not duplicates.
    #expect(stopGroups?.count == 1)
  }

  @Test func installPrunesLegacyCommands() throws {
    let url = makeTempURL()
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }

    // Write a file with a legacy command.
    let legacy: JSONValue = .object([
      "hooks": .object([
        "Stop": .array([
          .object([
            "hooks": .array([
              .object([
                "type": "command",
                "command": "SUPACODE_CLI_PATH agent-hook --stop",
              ])
            ])
          ])
        ])
      ])
    ])
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true,
    )
    try JSONEncoder().encode(legacy).write(to: url)

    let installer = makeInstaller()
    try installer.install(settingsURL: url, hookGroupsByEvent: sampleHookGroups())

    let data = try Data(contentsOf: url)
    let root = try JSONDecoder().decode(JSONValue.self, from: data)
    let stopGroups = root.objectValue?["hooks"]?.objectValue?["Stop"]?.arrayValue ?? []

    // Legacy command should be gone, only the new one remains.
    for group in stopGroups {
      guard let hooks = group.objectValue?["hooks"]?.arrayValue else { continue }
      for hook in hooks {
        let cmd = hook.objectValue?["command"]?.stringValue ?? ""
        #expect(!cmd.contains("SUPACODE_CLI_PATH"))
      }
    }
  }

  // MARK: - Uninstall.

  @Test func uninstallRemovesOnlyMatchingCommands() throws {
    let url = makeTempURL()
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }

    let installer = makeInstaller()
    let groups = sampleHookGroups()
    try installer.install(settingsURL: url, hookGroupsByEvent: groups)

    // Also add a third-party hook manually.
    var data = try Data(contentsOf: url)
    var root = try JSONDecoder().decode(JSONValue.self, from: data).objectValue!
    var hooks = root["hooks"]!.objectValue!
    var stopGroups = hooks["Stop"]!.arrayValue!
    stopGroups.append(
      .object([
        "hooks": .array([
          .object([
            "type": "command",
            "command": "echo third-party",
          ])
        ])
      ]))
    hooks["Stop"] = .array(stopGroups)
    root["hooks"] = .object(hooks)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(JSONValue.object(root)).write(to: url)

    // Uninstall our hooks.
    try installer.uninstall(settingsURL: url, hookGroupsByEvent: groups)

    data = try Data(contentsOf: url)
    let updated = try JSONDecoder().decode(JSONValue.self, from: data)
    let remaining = updated.objectValue?["hooks"]?.objectValue?["Stop"]?.arrayValue ?? []

    // Third-party hook should remain.
    #expect(remaining.count == 1)
    let cmd = remaining[0].objectValue?["hooks"]?.arrayValue?[0].objectValue?["command"]?.stringValue
    #expect(cmd == "echo third-party")
  }

  @Test func uninstallThrowsOnCorruptHooksValueInsteadOfSilentlyDestroyingIt() throws {
    // A non-object `hooks` value (string, number, array) means we're
    // looking at a hand-edited or unfamiliar settings file. Uninstall
    // must throw rather than coerce to `{}` and overwrite user data.
    // Install already throws on the same shape.
    let url = makeTempURL()
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let corrupt: JSONValue = .object(["hooks": "not an object"])
    try JSONEncoder().encode(corrupt).write(to: url)

    #expect(throws: TestInstallerError.self) {
      try makeInstaller().uninstall(settingsURL: url, hookGroupsByEvent: sampleHookGroups())
    }
  }

  @Test func uninstallOnMissingFileIsNoOp() throws {
    let url = makeTempURL()
    let installer = makeInstaller()
    // Should not throw — file doesn't exist.
    try installer.uninstall(settingsURL: url, hookGroupsByEvent: sampleHookGroups())
  }

  @Test func uninstallRemovesEveryPreCollapseSentinelGroup() throws {
    // Regression guard: a settings file produced by the pre-collapse build
    // (before progress + notification hooks were merged into one composite
    // entry per event) has TWO sentinel-tagged groups under both
    // `Notification` and `Stop`. The earlier uninstall path mutated the
    // hooks dict while iterating its keys, which on certain key sets left
    // entries behind. Every sentinel-tagged group must be stripped on
    // uninstall, while the user-authored hook (preserved here under
    // `PreToolUse / Bash`) survives.
    let url = makeTempURL()
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    let sentinel = AgentHookSettingsCommand.ownershipMarker
    func sentinelCommand(_ body: String) -> JSONValue {
      .object([
        "type": "command",
        "command": .string("\(body) \(sentinel)"),
        "timeout": 10,
      ])
    }
    let userBashHook: JSONValue = .object([
      "type": "command",
      "command": "/Users/me/.claude/hooks/confirm-risky-bash.sh",
      "timeout": 5,
    ])
    let preCollapse: JSONValue = .object([
      "hooks": .object([
        "Notification": .array([
          .object(["hooks": .array([sentinelCommand("supacode awaiting_input")]), "matcher": ""]),
          .object(["hooks": .array([sentinelCommand("supacode notify")]), "matcher": ""]),
        ]),
        "Stop": .array([
          .object(["hooks": .array([sentinelCommand("supacode idle")])]),
          .object(["hooks": .array([sentinelCommand("supacode notify")])]),
        ]),
        "PreToolUse": .array([
          .object(["hooks": .array([userBashHook]), "matcher": "Bash"]),
          .object(["hooks": .array([sentinelCommand("supacode busy")]), "matcher": ""]),
        ]),
      ])
    ])
    try JSONEncoder().encode(preCollapse).write(to: url)

    try makeInstaller().uninstall(settingsURL: url, hookGroupsByEvent: sampleHookGroups())

    let data = try Data(contentsOf: url)
    let root = try JSONDecoder().decode(JSONValue.self, from: data)
    let hooks = root.objectValue?["hooks"]?.objectValue ?? [:]
    #expect(hooks["Notification"] == nil)
    #expect(hooks["Stop"] == nil)
    // PreToolUse keeps the user-authored Bash hook, drops the Supacode one.
    let preToolUseGroups = hooks["PreToolUse"]?.arrayValue ?? []
    #expect(preToolUseGroups.count == 1)
    let surviving = preToolUseGroups.first?.objectValue?["hooks"]?.arrayValue?.first?.objectValue
    #expect(surviving?["command"]?.stringValue == "/Users/me/.claude/hooks/confirm-risky-bash.sh")
  }

  @Test func installPrunesStaleSupacodeEntries() throws {
    // Starting from a pre-collapse settings file with stale sentinel-
    // tagged duplicates, install must leave the file in the same shape
    // as a clean install (one group per event with exactly the
    // canonical commands).
    let url = makeTempURL()
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    let sentinel = AgentHookSettingsCommand.ownershipMarker
    let stale: JSONValue = .object([
      "hooks": .object([
        "Stop": .array([
          .object([
            "hooks": .array([
              .object([
                "type": "command",
                "command": .string("supacode old-idle \(sentinel)"),
                "timeout": 5,
              ])
            ])
          ]),
          .object([
            "hooks": .array([
              .object([
                "type": "command",
                "command": .string("supacode old-notify \(sentinel)"),
                "timeout": 10,
              ])
            ])
          ]),
        ])
      ])
    ])
    try JSONEncoder().encode(stale).write(to: url)

    let installer = makeInstaller()
    try installer.install(settingsURL: url, hookGroupsByEvent: sampleHookGroups())

    let data = try Data(contentsOf: url)
    let root = try JSONDecoder().decode(JSONValue.self, from: data)
    let stopGroups = root.objectValue?["hooks"]?.objectValue?["Stop"]?.arrayValue ?? []
    #expect(stopGroups.count == 1)
    let commands = stopGroups.flatMap { $0.objectValue?["hooks"]?.arrayValue ?? [] }
      .compactMap { $0.objectValue?["command"]?.stringValue }
    #expect(commands.count == 1)
    #expect(!(commands[0].contains("old-idle") || commands[0].contains("old-notify")))
    #expect(commands[0].contains(sentinel))
  }

  // MARK: - containsMatchingHooks.

  @Test func containsMatchingHooksReturnsTrueWhenPresent() throws {
    let url = makeTempURL()
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }

    let installer = makeInstaller()
    let groups = sampleHookGroups()
    try installer.install(settingsURL: url, hookGroupsByEvent: groups)

    #expect(try installer.installState(settingsURL: url, hookGroupsByEvent: groups) == .installed)
  }

  @Test func containsMatchingHooksReturnsFalseWhenMissing() throws {
    let url = makeTempURL()
    let installer = makeInstaller()
    #expect(try installer.installState(settingsURL: url, hookGroupsByEvent: sampleHookGroups()) != .installed)
  }

  @Test func containsMatchingHooksLogsInvalidJSONErrors() throws {
    let url = makeTempURL()
    let warnings = LockIsolated<[String]>([])
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }

    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true,
    )
    try Data("not json".utf8).write(to: url)

    let installer = AgentHookSettingsFileInstaller(
      fileManager: fileManager,
      errors: makeErrors(),
      logWarning: { message in
        warnings.withValue { $0.append(message) }
      }
    )

    #expect(throws: (any Error).self) {
      try installer.installState(settingsURL: url, hookGroupsByEvent: sampleHookGroups())
    }
    #expect(warnings.value.count == 1)
    #expect(warnings.value[0].contains(url.path))
  }

  @Test func containsMatchingHooksDoesNotLogMissingFile() throws {
    let url = makeTempURL()
    let warnings = LockIsolated<[String]>([])
    let installer = AgentHookSettingsFileInstaller(
      fileManager: fileManager,
      errors: makeErrors(),
      logWarning: { message in
        warnings.withValue { $0.append(message) }
      }
    )

    #expect(try installer.installState(settingsURL: url, hookGroupsByEvent: sampleHookGroups()) != .installed)
    #expect(warnings.value.isEmpty)
  }

  // MARK: - Error handling.

  @Test func invalidJSONFileThrowsWithDetail() throws {
    let url = makeTempURL()
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }

    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true,
    )
    try Data("not json".utf8).write(to: url)

    let installer = makeInstaller()
    #expect(throws: TestInstallerError.self) {
      try installer.install(settingsURL: url, hookGroupsByEvent: sampleHookGroups())
    }
  }

  @Test func jsonArrayRootThrows() throws {
    let url = makeTempURL()
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }

    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true,
    )
    try Data("[1,2,3]".utf8).write(to: url)

    let installer = makeInstaller()
    do {
      try installer.install(settingsURL: url, hookGroupsByEvent: sampleHookGroups())
      Issue.record("Expected invalidRootObject error")
    } catch let error as TestInstallerError {
      #expect(error == .invalidRootObject)
    }
  }

  // MARK: - Unreadable vs absent.

  @Test func installStateIsNotInstalledWhenTheFileGenuinelyDoesNotExist() throws {
    // The fresh-install path: no file, no parent directory, still `.notInstalled`.
    let installer = makeInstaller()
    let state = try installer.installState(
      settingsURL: makeTempURL(), hookGroupsByEvent: sampleHookGroups())

    #expect(state == .notInstalled)
  }

  @Test func installStateThrowsWhenTheFileExistsButCannotBeRead() throws {
    // The file is there but the OS refuses the read, which must not resolve to
    // `.notInstalled`.
    let url = makeTempURL()
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: url)
    try fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
    defer { try? fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }

    let installer = makeInstaller()
    #expect(throws: AgentFileUnreadableError.self) {
      try installer.installState(settingsURL: url, hookGroupsByEvent: sampleHookGroups())
    }
  }

  @Test func probeTreatsNonUTF8ContentAsUnreadableNotAbsent() throws {
    let url = makeTempURL()
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }
    try Data([0xFF, 0xFE, 0xFD]).write(to: url)

    #expect(throws: AgentFileUnreadableError.self) { try AgentFileProbe.text(at: url) }
  }

  @Test func directoryProbeSeparatesAbsentFromNotADirectory() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("supacode-dirprobe-\(UUID().uuidString)")
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: root) }

    let directory = root.appendingPathComponent("config", isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let regularFile = root.appendingPathComponent("plain", isDirectory: false)
    try Data("x".utf8).write(to: regularFile)

    #expect(try AgentFileProbe.directoryExists(at: directory, fileManager: fileManager))
    // A regular file at the config path is not the agent's config directory.
    #expect(try !AgentFileProbe.directoryExists(at: regularFile, fileManager: fileManager))
    #expect(
      try !AgentFileProbe.directoryExists(
        at: root.appendingPathComponent("missing", isDirectory: true), fileManager: fileManager))
  }

  @Test func directoryProbeFollowsSymlinks() throws {
    // The gate must not call a symlinked config directory absent, which would
    // tell the user to go install an agent they already have.
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("supacode-symlink-\(UUID().uuidString)")
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: root) }

    let target = root.appendingPathComponent("real", isDirectory: true)
    try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
    let link = root.appendingPathComponent("link", isDirectory: true)
    try fileManager.createSymbolicLink(at: link, withDestinationURL: target)

    #expect(try AgentFileProbe.directoryExists(at: link, fileManager: fileManager))
  }

  @Test func probeReportsAbsenceOnlyForFileNotFound() throws {
    // `FileManager.fileExists` collapses every errno into false, which is why
    // the probe classifies the read error instead of asking it.
    #expect(try AgentFileProbe.data(at: makeTempURL()) == nil)
    #expect(AgentFileProbe.isFileNotFound(CocoaError(.fileReadNoSuchFile)))
    #expect(!AgentFileProbe.isFileNotFound(CocoaError(.fileReadNoPermission)))
    #expect(!AgentFileProbe.isFileNotFound(NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))))
  }
}

private enum TestInstallerError: Error, Equatable {
  case invalidEventHooks(String)
  case invalidHooksObject
  case invalidJSON(String)
  case invalidRootObject
}
