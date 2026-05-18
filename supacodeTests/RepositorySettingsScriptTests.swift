import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import SupacodeSettingsFeature
@testable import SupacodeSettingsShared

// MARK: - Codable migration tests.

struct RepositorySettingsCodableTests {
  @Test func decodeFromLegacyRunScriptOnly() throws {
    // JSON with only `runScript` and no `scripts` key should produce
    // a single `.run`-kind ScriptDefinition.
    let json = """
      {
        "setupScript": "",
        "archiveScript": "",
        "deleteScript": "",
        "runScript": "npm start",
        "openActionID": "automatic"
      }
      """
    let data = Data(json.utf8)
    let settings = try JSONDecoder().decode(RepositorySettings.self, from: data)
    #expect(settings.scripts.count == 1)
    #expect(settings.scripts.first?.kind == .run)
    #expect(settings.scripts.first?.command == "npm start")
  }

  @Test func decodeWithBothRunScriptAndScripts() throws {
    // When both `runScript` and `scripts` are present, `scripts` wins.
    let json = """
      {
        "setupScript": "",
        "archiveScript": "",
        "deleteScript": "",
        "runScript": "legacy command",
        "scripts": [
          {
            "id": "00000000-0000-0000-0000-000000000001",
            "kind": "test", "name": "Test",
            "systemImage": "checkmark.diamond.fill",
            "tintColor": "blue", "command": "npm test"
          }
        ],
        "openActionID": "automatic"
      }
      """
    let data = Data(json.utf8)
    let settings = try JSONDecoder().decode(RepositorySettings.self, from: data)
    #expect(settings.scripts.count == 1)
    #expect(settings.scripts.first?.kind == .test)
    #expect(settings.scripts.first?.command == "npm test")
  }

  @Test func encodeRoundTripPopulatesRunScript() throws {
    // Encoding settings with scripts should derive `runScript` from
    // the first `.run`-kind script's command.
    var settings = RepositorySettings.default
    settings.scripts = [
      ScriptDefinition(kind: .test, command: "npm test"),
      ScriptDefinition(kind: .run, command: "npm run dev"),
    ]
    let data = try JSONEncoder().encode(settings)
    let raw = try JSONDecoder().decode([String: AnyCodable].self, from: data)
    #expect(raw["runScript"]?.stringValue == "npm run dev")
  }

  @Test func encodeWithNoRunKindScriptClearsRunScript() throws {
    // When no `.run`-kind script exists, the encoded `runScript`
    // should be empty — not the stale legacy value.
    var settings = RepositorySettings(
      setupScript: "",
      archiveScript: "",
      deleteScript: "",
      runScript: "stale legacy command",
      scripts: [ScriptDefinition(kind: .test, command: "npm test")],
      openActionID: "automatic",
      worktreeBaseRef: nil
    )
    let data = try JSONEncoder().encode(settings)
    let raw = try JSONDecoder().decode([String: AnyCodable].self, from: data)
    #expect(raw["runScript"]?.stringValue == "")
  }

  @Test func decodeWithUnknownScriptKindDropsOnlyInvalidEntries() throws {
    // An unknown `kind` value should only drop that entry, not the
    // entire array. Valid sibling scripts must survive.
    let json = """
      {
        "setupScript": "",
        "archiveScript": "",
        "deleteScript": "",
        "runScript": "",
        "scripts": [
          {
            "id": "00000000-0000-0000-0000-000000000001",
            "kind": "run", "name": "Run",
            "systemImage": "play",
            "tintColor": "green", "command": "npm start"
          },
          {
            "id": "00000000-0000-0000-0000-000000000002",
            "kind": "unknown_future_kind", "name": "X",
            "systemImage": "star",
            "tintColor": "red", "command": "echo hi"
          },
          {
            "id": "00000000-0000-0000-0000-000000000003",
            "kind": "test", "name": "Test",
            "systemImage": "play.diamond",
            "tintColor": "yellow", "command": "npm test"
          }
        ],
        "openActionID": "automatic"
      }
      """
    let data = Data(json.utf8)
    let settings = try JSONDecoder().decode(RepositorySettings.self, from: data)
    #expect(settings.scripts.count == 2)
    #expect(settings.scripts[0].kind == .run)
    #expect(settings.scripts[0].command == "npm start")
    #expect(settings.scripts[1].kind == .test)
    #expect(settings.scripts[1].command == "npm test")
  }
}

// MARK: - Global scripts decoding.

struct GlobalSettingsScriptsCodableTests {
  @Test func decodeMissingGlobalScriptsKeyDefaultsToEmpty() throws {
    let json = try baseGlobalSettingsJSON()
    let settings = try JSONDecoder().decode(GlobalSettings.self, from: Data(json.utf8))
    #expect(settings.globalScripts.isEmpty)
  }

  @Test func decodeMalformedGlobalScriptsValueDefaultsToEmpty() throws {
    var dict = baseGlobalSettingsDict()
    dict["globalScripts"] = "not-an-array"
    let data = try JSONSerialization.data(withJSONObject: dict)
    let settings = try JSONDecoder().decode(GlobalSettings.self, from: data)
    #expect(settings.globalScripts.isEmpty)
  }

  @Test func decodeWithUnknownGlobalScriptKindDropsOnlyInvalidEntries() throws {
    var dict = baseGlobalSettingsDict()
    dict["globalScripts"] = [
      [
        "id": "00000000-0000-0000-0000-000000000001",
        "kind": "custom", "name": "Lint", "command": "make lint",
      ],
      [
        "id": "00000000-0000-0000-0000-000000000002",
        "kind": "unknown_future_kind", "name": "Bad", "command": "noop",
      ],
    ]
    let data = try JSONSerialization.data(withJSONObject: dict)
    let settings = try JSONDecoder().decode(GlobalSettings.self, from: data)
    #expect(settings.globalScripts.count == 1)
    #expect(settings.globalScripts.first?.name == "Lint")
  }

  @Test func decodeMissingRequiredFieldDropsOnlyThatEntry() throws {
    // A script entry missing a required field (id / kind / name / command)
    // is dropped by `Lossy<ScriptDefinition>` rather than failing the whole
    // `globalScripts` decode.
    var dict = baseGlobalSettingsDict()
    dict["globalScripts"] = [
      [
        "id": "00000000-0000-0000-0000-000000000001",
        "kind": "custom", "name": "Good", "command": "echo good",
      ],
      [
        "kind": "custom", "name": "MissingID", "command": "echo bad",
      ],
    ]
    let data = try JSONSerialization.data(withJSONObject: dict)
    let settings = try JSONDecoder().decode(GlobalSettings.self, from: data)
    #expect(settings.globalScripts.count == 1)
    #expect(settings.globalScripts.first?.name == "Good")
  }

  @Test func decodeMalformedTintColorPreservesScript() throws {
    // A bad `tintColor` payload should drop just the override, not the
    // entire script — otherwise one malformed hex wipes the user's name
    // and command for that entry.
    var dict = baseGlobalSettingsDict()
    dict["globalScripts"] = [
      [
        "id": "00000000-0000-0000-0000-000000000001",
        "kind": "custom", "name": "Lint", "command": "make lint",
        "tintColor": "not-a-color",
      ]
    ]
    let data = try JSONSerialization.data(withJSONObject: dict)
    let settings = try JSONDecoder().decode(GlobalSettings.self, from: data)
    #expect(settings.globalScripts.count == 1)
    #expect(settings.globalScripts.first?.name == "Lint")
    #expect(settings.globalScripts.first?.command == "make lint")
    #expect(settings.globalScripts.first?.tintColor == nil)
  }

  @Test func decodeRoundTripsCustomHexTintOnGlobalScript() throws {
    // Custom hex tint chosen via the SwiftUI color picker should survive a
    // settings file round-trip without normalization stripping it.
    var dict = baseGlobalSettingsDict()
    dict["globalScripts"] = [
      [
        "id": "00000000-0000-0000-0000-000000000001",
        "kind": "custom", "name": "Lint", "command": "make lint",
        "tintColor": "#A1B2C3",
      ]
    ]
    let data = try JSONSerialization.data(withJSONObject: dict)
    let settings = try JSONDecoder().decode(GlobalSettings.self, from: data)
    #expect(settings.globalScripts.first?.tintColor == .custom("#A1B2C3"))
  }

  @Test func decodeNormalizesNonCustomGlobalScriptKindToCustom() throws {
    // A hand-edited or forged settings file shipping a `.run` global must not
    // be able to hijack the primary toolbar slot. Decoder forces `.custom`.
    var dict = baseGlobalSettingsDict()
    dict["globalScripts"] = [
      [
        "id": "00000000-0000-0000-0000-000000000001",
        "kind": "run", "name": "Sneaky", "command": "rm -rf /",
      ]
    ]
    let data = try JSONSerialization.data(withJSONObject: dict)
    let settings = try JSONDecoder().decode(GlobalSettings.self, from: data)
    #expect(settings.globalScripts.count == 1)
    #expect(settings.globalScripts.first?.kind == .custom)
  }

  // MARK: - Helpers.

  private func baseGlobalSettingsDict() -> [String: Any] {
    [
      "appearanceMode": "dark",
      "defaultEditorID": "automatic",
      "updateChannel": "stable",
      "updatesAutomaticallyCheckForUpdates": true,
      "updatesAutomaticallyDownloadUpdates": false,
      "inAppNotificationsEnabled": true,
      "notificationSoundEnabled": true,
      "systemNotificationsEnabled": false,
      "moveNotifiedWorktreeToTop": true,
      "analyticsEnabled": true,
      "crashReportsEnabled": true,
      "githubIntegrationEnabled": true,
      "deleteBranchOnDeleteWorktree": true,
      "promptForWorktreeCreation": true,
    ]
  }

  private func baseGlobalSettingsJSON() throws -> String {
    let data = try JSONSerialization.data(withJSONObject: baseGlobalSettingsDict())
    return String(bytes: data, encoding: .utf8) ?? ""
  }
}

/// Lightweight type-erased wrapper for JSON inspection in tests.
private struct AnyCodable: Decodable {
  let value: Any

  var stringValue: String? { value as? String }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let string = try? container.decode(String.self) {
      value = string
    } else if let int = try? container.decode(Int.self) {
      value = int
    } else if let bool = try? container.decode(Bool.self) {
      value = bool
    } else if let array = try? container.decode([AnyCodable].self) {
      value = array.map(\.value)
    } else if let dict = try? container.decode([String: AnyCodable].self) {
      value = dict.mapValues(\.value)
    } else {
      value = NSNull()
    }
  }
}

// MARK: - Feature tests.

@MainActor
struct RepositorySettingsScriptTests {
  private static let rootURL = URL(filePath: "/tmp/test-repo")

  private func makeStore(
    scripts: [ScriptDefinition] = []
  ) -> TestStore<RepositorySettingsFeature.State, RepositorySettingsFeature.Action> {
    var settings = RepositorySettings.default
    settings.scripts = scripts
    return TestStore(
      initialState: RepositorySettingsFeature.State(
        rootURL: Self.rootURL,
        settings: settings,
      ),
    ) {
      RepositorySettingsFeature()
    }
  }

  @Test(.dependencies) func addScriptAppendsCustomScript() async {
    let store = makeStore()
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.addScript(.custom)) {
      #expect($0.settings.scripts.count == 1)
      #expect($0.settings.scripts.first?.kind == .custom)
      #expect($0.settings.scripts.first?.name == "Custom")
    }
  }

  @Test(.dependencies) func addScriptRejectsDuplicatePredefinedKind() async {
    let store = makeStore(scripts: [ScriptDefinition(kind: .lint, command: "swiftlint")])
    store.exhaustivity = .off(showSkippedAssertions: false)

    // Second .lint is silently rejected.
    await store.send(.addScript(.lint))
    #expect(store.state.settings.scripts.count == 1)
  }

  @Test(.dependencies) func addScriptAllowsMultipleCustomKinds() async {
    let store = makeStore(scripts: [ScriptDefinition(kind: .custom, name: "A", command: "a")])
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.addScript(.custom)) {
      #expect($0.settings.scripts.count == 2)
    }
  }

  @Test(.dependencies) func removeScriptShowsConfirmationAndRemovesByID() async {
    let script1 = ScriptDefinition(kind: .run, command: "npm run dev")
    let script2 = ScriptDefinition(kind: .test, command: "npm test")
    let script3 = ScriptDefinition(kind: .deploy, command: "deploy.sh")
    let store = makeStore(scripts: [script1, script2, script3])
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.removeScript(script2.id)) {
      $0.alert = AlertState {
        TextState("Remove \"\(script2.displayName)\" script?")
      } actions: {
        ButtonState(role: .destructive, action: .confirmRemoveScript(script2.id)) {
          TextState("Remove")
        }
        ButtonState(role: .cancel) {
          TextState("Cancel")
        }
      } message: {
        TextState(
          "This action cannot be undone. Any running instance keeps running in its terminal "
            + "tab until you close it manually."
        )
      }
    }

    await store.send(.alert(.presented(.confirmRemoveScript(script2.id)))) {
      $0.alert = nil
      $0.settings.scripts = [script1, script3]
    }
  }

  @Test(.dependencies) func removeScriptCancelDoesNotRemove() async {
    let script = ScriptDefinition(kind: .run, command: "npm run dev")
    let store = makeStore(scripts: [script])
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.removeScript(script.id)) {
      $0.alert = AlertState {
        TextState("Remove \"\(script.displayName)\" script?")
      } actions: {
        ButtonState(role: .destructive, action: .confirmRemoveScript(script.id)) {
          TextState("Remove")
        }
        ButtonState(role: .cancel) {
          TextState("Cancel")
        }
      } message: {
        TextState(
          "This action cannot be undone. Any running instance keeps running in its terminal "
            + "tab until you close it manually."
        )
      }
    }

    await store.send(.alert(.dismiss)) {
      $0.alert = nil
    }

    #expect(store.state.settings.scripts.count == 1)
  }

}
