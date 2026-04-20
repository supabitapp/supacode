import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

struct KiroHookSettingsFileInstallerTests {
  private let fileManager = FileManager.default

  private func makeErrors() -> KiroHookSettingsFileInstaller.Errors {
    .init(
      invalidEventHooks: { TestInstallerError.invalidEventHooks($0) },
      invalidHooksObject: { TestInstallerError.invalidHooksObject },
      invalidJSON: { TestInstallerError.invalidJSON($0) },
      invalidRootObject: { TestInstallerError.invalidRootObject },
    )
  }

  private func makeInstaller() -> KiroHookSettingsFileInstaller {
    KiroHookSettingsFileInstaller(fileManager: fileManager, errors: makeErrors())
  }

  private func makeTempURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("supacode-kiro-test-\(UUID().uuidString)")
      .appendingPathComponent("kiro_default.json")
  }

  private func sampleHookEntries() -> [String: [JSONValue]] {
    [
      "stop": [
        .object([
          "command": .string(AgentHookSettingsCommand.busyCommand(active: false)),
          "timeout_ms": 10_000,
        ])
      ]
    ]
  }

  // MARK: - Install.

  @Test func installIntoEmptyFileCreatesCorrectStructure() throws {
    let url = makeTempURL()
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }

    let installer = makeInstaller()
    try installer.install(settingsURL: url, hookEntriesByEvent: sampleHookEntries())

    let data = try Data(contentsOf: url)
    let root = try JSONDecoder().decode(JSONValue.self, from: data)
    guard let hooksObject = root.objectValue?["hooks"]?.objectValue else {
      Issue.record("Expected hooks object")
      return
    }
    #expect(hooksObject["stop"] != nil)
    let stopEntries = hooksObject["stop"]?.arrayValue
    #expect(stopEntries?.count == 1)
  }

  @Test func installPreservesExistingNonHookKeys() throws {
    let url = makeTempURL()
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }

    let existing: JSONValue = .object(["name": "kiro_default", "tools": .array([.string("*")])])
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true,
    )
    try JSONEncoder().encode(existing).write(to: url)

    let installer = makeInstaller()
    try installer.install(settingsURL: url, hookEntriesByEvent: sampleHookEntries())

    let data = try Data(contentsOf: url)
    let root = try JSONDecoder().decode(JSONValue.self, from: data)
    #expect(root.objectValue?["name"]?.stringValue == "kiro_default")
    #expect(root.objectValue?["hooks"] != nil)
  }

  @Test func installIsIdempotent() throws {
    let url = makeTempURL()
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }

    let installer = makeInstaller()
    let entries = sampleHookEntries()
    try installer.install(settingsURL: url, hookEntriesByEvent: entries)
    try installer.install(settingsURL: url, hookEntriesByEvent: entries)

    let data = try Data(contentsOf: url)
    let root = try JSONDecoder().decode(JSONValue.self, from: data)
    let stopEntries = root.objectValue?["hooks"]?.objectValue?["stop"]?.arrayValue
    #expect(stopEntries?.count == 1)
  }

  // MARK: - Uninstall.

  @Test func uninstallRemovesHookEntries() throws {
    let url = makeTempURL()
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }

    let installer = makeInstaller()
    let entries = sampleHookEntries()
    try installer.install(settingsURL: url, hookEntriesByEvent: entries)
    try installer.uninstall(settingsURL: url, hookEntriesByEvent: entries)

    let data = try Data(contentsOf: url)
    let root = try JSONDecoder().decode(JSONValue.self, from: data)
    let stopEntries = root.objectValue?["hooks"]?.objectValue?["stop"]?.arrayValue
    #expect(stopEntries == nil || stopEntries?.isEmpty == true)
  }

  @Test func uninstallRemovesOnlyMatchingCommands() throws {
    let url = makeTempURL()
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }

    let installer = makeInstaller()
    let entries = sampleHookEntries()
    try installer.install(settingsURL: url, hookEntriesByEvent: entries)

    // Add a user's hand-written hook entry alongside the managed one.
    var data = try Data(contentsOf: url)
    var root = try JSONDecoder().decode(JSONValue.self, from: data).objectValue!
    var hooks = root["hooks"]!.objectValue!
    var stopEntries = hooks["stop"]!.arrayValue!
    stopEntries.append(.object(["command": .string("echo user-hook"), "timeout_ms": 5_000]))
    hooks["stop"] = .array(stopEntries)
    root["hooks"] = .object(hooks)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(JSONValue.object(root)).write(to: url)

    // Uninstall managed hooks.
    try installer.uninstall(settingsURL: url, hookEntriesByEvent: entries)

    data = try Data(contentsOf: url)
    let updated = try JSONDecoder().decode(JSONValue.self, from: data)
    let remaining = updated.objectValue?["hooks"]?.objectValue?["stop"]?.arrayValue ?? []

    // User's hook should remain.
    #expect(remaining.count == 1)
    #expect(remaining[0].objectValue?["command"]?.stringValue == "echo user-hook")
  }

  // MARK: - Check.

  @Test func containsMatchingHooksReturnsFalseForMissingFile() {
    let url = makeTempURL()
    let installer = makeInstaller()
    #expect(
      installer.containsMatchingHooks(settingsURL: url, hookEntriesByEvent: sampleHookEntries())
        == false)
  }

  @Test func containsMatchingHooksReturnsTrueAfterInstall() throws {
    let url = makeTempURL()
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }

    let installer = makeInstaller()
    let entries = sampleHookEntries()
    try installer.install(settingsURL: url, hookEntriesByEvent: entries)
    #expect(installer.containsMatchingHooks(settingsURL: url, hookEntriesByEvent: entries) == true)
  }

  @Test func containsMatchingHooksReturnsFalseAfterUninstall() throws {
    let url = makeTempURL()
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }

    let installer = makeInstaller()
    let entries = sampleHookEntries()
    try installer.install(settingsURL: url, hookEntriesByEvent: entries)
    try installer.uninstall(settingsURL: url, hookEntriesByEvent: entries)
    #expect(installer.containsMatchingHooks(settingsURL: url, hookEntriesByEvent: entries) == false)
  }

  // MARK: - Error paths.

  @Test func installThrowsInvalidJSONForMalformedFile() throws {
    let url = makeTempURL()
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }

    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true,
    )
    try Data("{{{".utf8).write(to: url)

    let installer = makeInstaller()
    #expect(throws: TestInstallerError.self) {
      try installer.install(settingsURL: url, hookEntriesByEvent: sampleHookEntries())
    }
  }

  @Test func installThrowsInvalidRootObjectForArrayRoot() throws {
    let url = makeTempURL()
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }

    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true,
    )
    try Data("[1,2,3]".utf8).write(to: url)

    let installer = makeInstaller()
    #expect(throws: TestInstallerError.invalidRootObject) {
      try installer.install(settingsURL: url, hookEntriesByEvent: sampleHookEntries())
    }
  }

  @Test func installThrowsInvalidHooksObjectWhenHooksIsNotAnObject() throws {
    let url = makeTempURL()
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }

    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true,
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let settings: JSONValue = .object(["hooks": .string("definitely not an object")])
    try encoder.encode(settings).write(to: url)

    let installer = makeInstaller()
    #expect(throws: TestInstallerError.invalidHooksObject) {
      try installer.install(settingsURL: url, hookEntriesByEvent: sampleHookEntries())
    }
    #expect(throws: TestInstallerError.invalidHooksObject) {
      try installer.uninstall(settingsURL: url, hookEntriesByEvent: sampleHookEntries())
    }
  }

  @Test func installThrowsInvalidEventHooksWhenEventValueIsNotAnArray() throws {
    let url = makeTempURL()
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }

    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true,
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let settings: JSONValue = .object([
      "hooks": .object(["stop": .string("not an array")])
    ])
    try encoder.encode(settings).write(to: url)

    let installer = makeInstaller()
    #expect(throws: TestInstallerError.invalidEventHooks("stop")) {
      try installer.install(settingsURL: url, hookEntriesByEvent: sampleHookEntries())
    }
  }

  @Test func uninstallRemovesLegacyManagedCommands() throws {
    let url = makeTempURL()
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }

    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true,
    )
    let legacyCommand = "SUPACODE_CLI_PATH=/usr/bin/supacode agent-hook --stop"
    #expect(AgentHookCommandOwnership.isLegacyCommand(legacyCommand))
    let seeded: JSONValue = .object([
      "hooks": .object([
        "stop": .array([
          .object(["command": .string(legacyCommand), "timeout_ms": 5_000]),
          .object(["command": .string("echo user-hook"), "timeout_ms": 5_000]),
        ])
      ])
    ])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(seeded).write(to: url)

    let installer = makeInstaller()
    try installer.uninstall(settingsURL: url, hookEntriesByEvent: sampleHookEntries())

    let data = try Data(contentsOf: url)
    let root = try JSONDecoder().decode(JSONValue.self, from: data)
    let remaining = root.objectValue?["hooks"]?.objectValue?["stop"]?.arrayValue ?? []
    #expect(remaining.count == 1)
    #expect(remaining.first?.objectValue?["command"]?.stringValue == "echo user-hook")
  }
}

private enum TestInstallerError: Error, Equatable {
  case invalidEventHooks(String)
  case invalidHooksObject
  case invalidJSON(String)
  case invalidRootObject
}
