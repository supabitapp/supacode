import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import SupacodeSettingsFeature
@testable import SupacodeSettingsShared

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

    await store.send(.addScript) {
      #expect($0.settings.scripts.count == 1)
      #expect($0.settings.scripts.first?.kind == .custom)
      #expect($0.settings.scripts.first?.name == "Custom")
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
