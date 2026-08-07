import AppKit
import Testing

@testable import supacode

@MainActor
struct ContentRuntimeTests {
  @MainActor
  private final class MockContent: TabContent {
    let id: ContentID
    let kind: ContentKind = .terminal
    private(set) var startSessionCalls = 0
    private(set) var hibernateCalls = 0
    private var view: NSView?

    init(id: ContentID = ContentID()) {
      self.id = id
    }

    var renderer: NSView? { view }

    func startSession(at geometry: ContentGeometry) {
      startSessionCalls += 1
      view = NSView()
    }

    func hibernate() {
      hibernateCalls += 1
      view = nil
    }

    func snapshot() -> ContentSnapshot {
      ContentSnapshot(id: id, state: .terminal(TerminalContentState(workingDirectory: nil)))
    }
  }

  @Test func provisionStartsTheSessionExactlyOnce() {
    let runtime = ContentRuntime()
    let content = MockContent()
    #expect(runtime.provision(content, at: .fallback))
    #expect(content.startSessionCalls == 1)
    #expect(runtime.provision(content, at: .fallback) == false)
    #expect(content.startSessionCalls == 1)
  }

  @Test func provisionIsRefusedWhileTombstoned() {
    let runtime = ContentRuntime()
    let content = MockContent()
    #expect(runtime.provision(content, at: .fallback))
    runtime.remove(content.id, tombstone: true)
    let replacement = MockContent(id: content.id)
    #expect(runtime.provision(replacement, at: .fallback) == false)
    #expect(replacement.startSessionCalls == 0)
    #expect(runtime.content(for: content.id) == nil)
  }

  @Test func confirmKillClearsTheTombstoneAndAllowsReProvision() {
    let runtime = ContentRuntime()
    let content = MockContent()
    #expect(runtime.provision(content, at: .fallback))
    runtime.remove(content.id, tombstone: true)
    runtime.confirmKill(content.id)
    let replacement = MockContent(id: content.id)
    #expect(runtime.provision(replacement, at: .fallback))
    #expect(replacement.startSessionCalls == 1)
    #expect(runtime.content(for: content.id) === replacement)
  }

  @Test func hibernateKeepsTheEntryRegistered() {
    let runtime = ContentRuntime()
    let content = MockContent()
    #expect(runtime.provision(content, at: .fallback))
    runtime.hibernate(content.id)
    #expect(content.hibernateCalls == 1)
    #expect(runtime.content(for: content.id) === content)
  }

  @Test func rendererIsNilForUnknownAndHibernatedContent() {
    let runtime = ContentRuntime()
    #expect(runtime.renderer(for: ContentID()) == nil)
    let content = MockContent()
    #expect(runtime.provision(content, at: .fallback))
    #expect(runtime.renderer(for: content.id) != nil)
    runtime.hibernate(content.id)
    #expect(runtime.renderer(for: content.id) == nil)
  }

  @Test func removeWithoutTombstoneUnregistersAndAllowsReProvision() {
    let runtime = ContentRuntime()
    let content = MockContent()
    #expect(runtime.provision(content, at: .fallback))
    runtime.remove(content.id, tombstone: false)
    #expect(runtime.content(for: content.id) == nil)
    #expect(runtime.renderer(for: content.id) == nil)
    let replacement = MockContent(id: content.id)
    #expect(runtime.provision(replacement, at: .fallback))
    #expect(replacement.startSessionCalls == 1)
  }
}
