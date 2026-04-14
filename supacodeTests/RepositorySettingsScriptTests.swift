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
          {"id": "00000000-0000-0000-0000-000000000001", "kind": "test", "name": "Test", "systemImage": "checkmark.diamond.fill", "tintColor": "blue", "command": "npm test"}
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

  @Test func decodeWithUnknownScriptKindFallsBackGracefully() throws {
    // An unknown `kind` value should not crash; scripts should fall
    // back to an empty array.
    let json = """
      {
        "setupScript": "",
        "archiveScript": "",
        "deleteScript": "",
        "runScript": "",
        "scripts": [
          {"id": "00000000-0000-0000-0000-000000000001", "kind": "unknown_future_kind", "name": "X", "systemImage": "star", "tintColor": "red", "command": "echo hi"}
        ],
        "openActionID": "automatic"
      }
      """
    let data = Data(json.utf8)
    let settings = try JSONDecoder().decode(RepositorySettings.self, from: data)
    #expect(settings.scripts.isEmpty)
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

  @Test(.dependencies) func removeScriptsRemovesAtOffsets() async {
    let script1 = ScriptDefinition(kind: .run, command: "npm run dev")
    let script2 = ScriptDefinition(kind: .test, command: "npm test")
    let script3 = ScriptDefinition(kind: .debug, command: "lldb")
    let store = makeStore(scripts: [script1, script2, script3])
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.removeScripts(IndexSet(integer: 1))) {
      #expect($0.settings.scripts.count == 2)
      #expect($0.settings.scripts[0].id == script1.id)
      #expect($0.settings.scripts[1].id == script3.id)
    }
  }

  @Test(.dependencies) func moveScriptsReordersCorrectly() async {
    let script1 = ScriptDefinition(kind: .run, command: "npm run dev")
    let script2 = ScriptDefinition(kind: .test, command: "npm test")
    let script3 = ScriptDefinition(kind: .deploy, command: "deploy.sh")
    let store = makeStore(scripts: [script1, script2, script3])
    store.exhaustivity = .off(showSkippedAssertions: false)

    // Move the last item to the beginning.
    await store.send(.moveScripts(IndexSet(integer: 2), 0)) {
      #expect($0.settings.scripts[0].id == script3.id)
      #expect($0.settings.scripts[1].id == script1.id)
      #expect($0.settings.scripts[2].id == script2.id)
    }
  }

  @Test(.dependencies) func moveScriptsToEnd() async {
    let script1 = ScriptDefinition(kind: .run, command: "npm run dev")
    let script2 = ScriptDefinition(kind: .test, command: "npm test")
    let store = makeStore(scripts: [script1, script2])
    store.exhaustivity = .off(showSkippedAssertions: false)

    // Move the first item past the end.
    await store.send(.moveScripts(IndexSet(integer: 0), 2)) {
      #expect($0.settings.scripts[0].id == script2.id)
      #expect($0.settings.scripts[1].id == script1.id)
    }
  }
}
