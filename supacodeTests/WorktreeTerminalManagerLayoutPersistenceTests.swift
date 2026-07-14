import Clocks
import Dependencies
import Foundation
import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
@Suite(.serialized)
struct LayoutPersistenceManagerTests {
  /// Counts writer saves and mirrors the in-memory `@Shared(.layouts)` mutation
  /// the app performs, so a test can assert both coalescing and final on-disk
  /// state from one storage.
  private struct Harness {
    let manager: WorktreeTerminalManager
    let clock: TestClock<Duration>
    let saveCount: LockIsolated<Int>
    let storage: SettingsFileStorage
    let url: URL
    /// When non-nil, the next save whose payload still contains `worktreeID`
    /// (a positive snapshot) blocks on this semaphore so the test can hold the
    /// positive flush Task in-flight while it triggers the prune.
    let gate: LockIsolated<(worktreeID: String, semaphore: DispatchSemaphore)?>
    /// Flips true once the gated positive save is blocked, proving the flush
    /// Task is suspended inside `writer.flush` (i.e. `layoutFlushTasks[id]` is
    /// still non-nil, before the spawning Task can clear it).
    let gateEngaged: LockIsolated<Bool>
  }

  private func makeHarness() -> Harness {
    let clock = TestClock()
    let saveCount = LockIsolated(0)
    let gate = LockIsolated<(worktreeID: String, semaphore: DispatchSemaphore)?>(nil)
    let gateEngaged = LockIsolated(false)
    let inner = SettingsFileStorage.inMemory()
    let url = SupacodePaths.layoutsURL
    let storage = SettingsFileStorage(
      load: { try inner.load($0) },
      save: { data, target in
        if target == url { saveCount.withValue { $0 += 1 } }
        // Block a positive snapshot write so the spawning flush Task stays
        // in-flight; a delete payload (key absent) passes straight through.
        if target == url,
          let active = gate.value,
          let dict = try? JSONDecoder().decode([String: TerminalLayoutSnapshot].self, from: data),
          dict[active.worktreeID] != nil
        {
          gate.setValue(nil)
          gateEngaged.setValue(true)
          active.semaphore.wait()
        }
        try inner.save(data, target)
      }
    )
    let manager = withDependencies {
      $0.settingsFileStorage = storage
    } operation: {
      WorktreeTerminalManager(runtime: GhosttyRuntime(), clock: clock)
    }
    // Mirror the app's in-memory dict mutation; the writer's storage is the
    // on-disk source of truth these tests assert against.
    manager.saveLayoutSnapshot = { _, _ in }
    return Harness(
      manager: manager,
      clock: clock,
      saveCount: saveCount,
      storage: storage,
      url: url,
      gate: gate,
      gateEngaged: gateEngaged
    )
  }

  private func readDict(_ harness: Harness) -> [String: TerminalLayoutSnapshot] {
    guard let data = try? harness.storage.load(harness.url) else { return [:] }
    return (try? JSONDecoder().decode([String: TerminalLayoutSnapshot].self, from: data)) ?? [:]
  }

  /// Awaits a condition by pumping the off-main actor flush onto the executor;
  /// bounded so a never-true predicate can't hang the suite. No `Task.sleep`.
  /// `megaYield` runs detached background work between checks so the writer
  /// actor's flush actually lands even under a saturated cooperative pool.
  private func waitUntil(_ predicate: () -> Bool) async {
    for _ in 0..<200 {
      if predicate() { return }
      await Task.megaYield()
    }
  }

  /// Yields enough for the latest debounce task to register its sleep with the
  /// TestClock, then advances past the window so the flush fires.
  private func settleThenAdvance(_ clock: TestClock<Duration>) async {
    await Task.megaYield()
    await clock.advance(by: .seconds(1))
  }

  private func makeWorktree(id: String = "/tmp/repo/wt-1") -> Worktree {
    Worktree(
      id: WorktreeID(id),
      name: URL(fileURLWithPath: id).lastPathComponent,
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: id),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
  }

  @Test func debounceCoalescesBurstIntoOneWrite() async {
    let harness = makeHarness()
    let worktree = makeWorktree()
    let state = harness.manager.state(for: worktree)

    // Several structural mutations within the window must coalesce to one flush.
    _ = state.createTab(focusing: false)
    _ = state.createTab(focusing: false)
    _ = state.createTab(focusing: false)

    #expect(harness.saveCount.value == 0)
    await settleThenAdvance(harness.clock)
    await waitUntil { harness.saveCount.value == 1 }
    #expect(harness.saveCount.value == 1)
    #expect(readDict(harness)[worktree.id.rawValue] != nil)
  }

  @Test func pruneDeletesAndCancelsQueuedSave() async {
    let harness = makeHarness()
    let worktree = makeWorktree()
    let state = harness.manager.state(for: worktree)
    _ = state.createTab(focusing: false)

    // Seed disk with a prior snapshot so the delete has something to remove.
    await settleThenAdvance(harness.clock)
    await waitUntil { readDict(harness)[worktree.id.rawValue] != nil }

    // Queue a positive save, then prune before the window elapses.
    _ = state.createTab(focusing: false)
    harness.manager.prune(keeping: [])
    await waitUntil { readDict(harness)[worktree.id.rawValue] == nil }

    // Pin the save count once the delete has flushed; a resurrecting positive
    // write would bump it, so gating on a positive increment proves whether the
    // queued save was actually cancelled rather than merely lagging.
    let savesAfterDelete = harness.saveCount.value
    await harness.clock.advance(by: .seconds(1))
    await waitUntil { harness.saveCount.value > savesAfterDelete }
    #expect(harness.saveCount.value == savesAfterDelete)
    #expect(readDict(harness)[worktree.id.rawValue] == nil)
  }

  @Test func pruneAfterDebounceFiresDoesNotResurrect() async {
    let harness = makeHarness()
    let worktree = makeWorktree()
    let state = harness.manager.state(for: worktree)
    _ = state.createTab(focusing: false)

    // Seed disk with a prior snapshot so the delete has something to remove.
    await settleThenAdvance(harness.clock)
    await waitUntil { readDict(harness)[worktree.id.rawValue] != nil }

    // Arm the gate so the positive snapshot write blocks mid-flush, pinning the
    // flush Task in-flight. Then queue the positive save and fire the debounce.
    let release = DispatchSemaphore(value: 0)
    let gatedID = worktree.id.rawValue
    harness.gate.setValue((worktreeID: gatedID, semaphore: release))
    _ = state.createTab(focusing: false)
    await settleThenAdvance(harness.clock)

    // The positive flush Task is provably suspended inside `writer.flush` (save
    // blocked), so `layoutFlushTasks[id]` is still non-nil. Prune now captures
    // that in-flight Task and must await it before deleting.
    await waitUntil { harness.gateEngaged.value }
    #expect(harness.gateEngaged.value)
    harness.manager.prune(keeping: [])

    // Release the positive flush; the delete chained behind it must win.
    release.signal()
    await waitUntil { readDict(harness)[worktree.id.rawValue] == nil }
    #expect(readDict(harness)[worktree.id.rawValue] == nil)
  }

  @Test func cancelPendingLayoutSavesDropsQueuedFlush() async {
    let harness = makeHarness()
    let worktree = makeWorktree()
    let state = harness.manager.state(for: worktree)
    _ = state.createTab(focusing: false)

    harness.manager.cancelPendingLayoutSaves()
    await harness.clock.advance(by: .seconds(1))

    // Queue and flush a control worktree's save AFTER the cancel. Once the
    // control write lands, the executor has run long enough that the cancelled
    // save would have fired too, so its continued absence proves suppression
    // rather than mere lag.
    let control = makeWorktree(id: "/tmp/repo/wt-control")
    let controlState = harness.manager.state(for: control)
    _ = controlState.createTab(focusing: false)
    await settleThenAdvance(harness.clock)
    await waitUntil { readDict(harness)[control.id.rawValue] != nil }

    #expect(readDict(harness)[control.id.rawValue] != nil)
    #expect(harness.saveCount.value == 1)
    #expect(readDict(harness)[worktree.id.rawValue] == nil)
  }

  @Test func mergePreservesSiblingKeyWrittenByAnotherFlush() async {
    let harness = makeHarness()
    let wt1 = makeWorktree(id: "/tmp/repo/wt-1")
    let wt2 = makeWorktree(id: "/tmp/repo/wt-2")

    let state1 = harness.manager.state(for: wt1)
    _ = state1.createTab(focusing: false)
    await settleThenAdvance(harness.clock)
    await waitUntil { readDict(harness)[wt1.id.rawValue] != nil }

    let state2 = harness.manager.state(for: wt2)
    _ = state2.createTab(focusing: false)
    await settleThenAdvance(harness.clock)
    await waitUntil { readDict(harness)[wt2.id.rawValue] != nil }

    let dict = readDict(harness)
    #expect(Set(dict.keys) == [wt1.id.rawValue, wt2.id.rawValue])
  }

  @Test func incrementalCaptureEmbedsLiveAgentRecords() async {
    let harness = makeHarness()
    let worktree = makeWorktree()
    let state = harness.manager.state(for: worktree)
    guard let tabID = state.createTab(focusing: false),
      let surface = state.splitTree(for: tabID).root?.leftmostLeaf()
    else {
      Issue.record("Expected a tab and surface")
      return
    }
    let record = TerminalLayoutSnapshot.SurfaceAgentRecord(agent: "claude", pids: [42], activity: "busy")
    harness.manager.currentAgentsBySurface = { [surface.id: [record]] }
    // Mark dirty again now that the agent reader is wired.
    harness.manager.markLayoutDirty(worktreeID: worktree.id)

    await settleThenAdvance(harness.clock)
    await waitUntil { readDict(harness)[worktree.id.rawValue]?.tabs.first?.layout != nil }

    let leaf = readDict(harness)[worktree.id.rawValue]?.tabs.first?.layout
    guard case .leaf(let persisted) = leaf else {
      Issue.record("Expected a leaf layout")
      return
    }
    #expect(persisted.agents == [record])
  }

  @Test func presentButUnreadableFileAbortsAndPreservesSiblings() async {
    let clock = TestClock()
    let inner = SettingsFileStorage.inMemory()
    let url = SupacodePaths.layoutsURL
    // Flips on after the two siblings are seeded so the third flush's read fails
    // with a non-absent error, exercising the abort branch.
    let failLoad = LockIsolated(false)
    let loadFailCount = LockIsolated(0)
    let storage = SettingsFileStorage(
      load: { target in
        if target == url, failLoad.value {
          loadFailCount.withValue { $0 += 1 }
          throw CocoaError(.fileReadCorruptFile)
        }
        return try inner.load(target)
      },
      save: { data, target in try inner.save(data, target) }
    )
    let manager = withDependencies {
      $0.settingsFileStorage = storage
    } operation: {
      WorktreeTerminalManager(runtime: GhosttyRuntime(), clock: clock)
    }
    manager.saveLayoutSnapshot = { _, _ in }

    // Raw reader bypasses the throwing flag so assertions see the real disk state.
    let readRaw: () -> [String: TerminalLayoutSnapshot] = {
      guard let data = try? inner.load(url) else { return [:] }
      return (try? JSONDecoder().decode([String: TerminalLayoutSnapshot].self, from: data)) ?? [:]
    }

    let wt1 = makeWorktree(id: "/tmp/repo/wt-1")
    let wt2 = makeWorktree(id: "/tmp/repo/wt-2")
    let state1 = manager.state(for: wt1)
    _ = state1.createTab(focusing: false)
    await Task.megaYield()
    await clock.advance(by: .seconds(1))
    await waitUntil { readRaw()[wt1.id.rawValue] != nil }
    let state2 = manager.state(for: wt2)
    _ = state2.createTab(focusing: false)
    await Task.megaYield()
    await clock.advance(by: .seconds(1))
    await waitUntil { readRaw()[wt2.id.rawValue] != nil }
    #expect(Set(readRaw().keys) == [wt1.id.rawValue, wt2.id.rawValue])

    // Make the merge read fail, then flush a third key. The writer must abort
    // rather than splice into an empty dict and clobber the two siblings.
    failLoad.setValue(true)
    let wt3 = makeWorktree(id: "/tmp/repo/wt-3")
    let state3 = manager.state(for: wt3)
    _ = state3.createTab(focusing: false)
    await Task.megaYield()
    await clock.advance(by: .seconds(1))
    await waitUntil { loadFailCount.value > 0 }
    #expect(loadFailCount.value > 0)

    let dict = readRaw()
    #expect(Set(dict.keys) == [wt1.id.rawValue, wt2.id.rawValue])
    #expect(dict[wt3.id.rawValue] == nil)
  }

  @Test func creationPersistsCustomTitleAtomically() async {
    let harness = makeHarness()
    let worktree = makeWorktree()
    let state = harness.manager.state(for: worktree)
    guard state.createTab(focusing: false, customTitle: "implement") != nil else {
      Issue.record("Expected a tab")
      return
    }

    await settleThenAdvance(harness.clock)
    await waitUntil { readDict(harness)[worktree.id.rawValue]?.tabs.first?.customTitle == "implement" }

    #expect(readDict(harness)[worktree.id.rawValue]?.tabs.first?.customTitle == "implement")
  }

  @Test func renamePersistsCustomTitleIncrementally() async {
    let harness = makeHarness()
    let worktree = makeWorktree()
    let state = harness.manager.state(for: worktree)
    guard let tabID = state.createTab(focusing: false) else {
      Issue.record("Expected a tab")
      return
    }
    await settleThenAdvance(harness.clock)
    await waitUntil { readDict(harness)[worktree.id.rawValue] != nil }

    state.renameTab(tabID, title: "Renamed")
    await settleThenAdvance(harness.clock)
    await waitUntil { readDict(harness)[worktree.id.rawValue]?.tabs.first?.customTitle == "Renamed" }

    #expect(readDict(harness)[worktree.id.rawValue]?.tabs.first?.customTitle == "Renamed")
  }

  @Test func renameWithEmptyTitlePersistsClearedOverride() async {
    let harness = makeHarness()
    let worktree = makeWorktree()
    let state = harness.manager.state(for: worktree)
    guard let tabID = state.createTab(focusing: false, customTitle: "implement") else {
      Issue.record("Expected a tab")
      return
    }
    await settleThenAdvance(harness.clock)
    await waitUntil { readDict(harness)[worktree.id.rawValue]?.tabs.first?.customTitle == "implement" }

    state.renameTab(tabID, title: "")
    await settleThenAdvance(harness.clock)
    await waitUntil { readDict(harness)[worktree.id.rawValue]?.tabs.first?.customTitle == nil }

    #expect(readDict(harness)[worktree.id.rawValue]?.tabs.first?.customTitle == nil)
  }

  @Test func renameThatDoesNotApplySkipsThePersistWrite() async {
    let harness = makeHarness()
    let worktree = makeWorktree()
    let state = harness.manager.state(for: worktree)
    guard state.createTab(focusing: false) != nil else {
      Issue.record("Expected a tab")
      return
    }
    await settleThenAdvance(harness.clock)
    await waitUntil { readDict(harness)[worktree.id.rawValue] != nil }
    let savesBefore = harness.saveCount.value

    #expect(state.renameTab(TerminalTabID(), title: "implement") == false)
    await settleThenAdvance(harness.clock)

    #expect(harness.saveCount.value == savesBefore)
  }

  @Test func onQuitFlushSyncPersistsLiveStatesAsTerminalWrite() {
    let harness = makeHarness()
    let wt1 = makeWorktree(id: "/tmp/repo/wt-1")
    let wt2 = makeWorktree(id: "/tmp/repo/wt-2")
    _ = harness.manager.state(for: wt1).createTab(focusing: false)
    _ = harness.manager.state(for: wt2).createTab(focusing: false)

    // Mirror the quit path: drop queued debounce saves, then the synchronous
    // on-quit flush must land every live state as the terminal on-disk write.
    harness.manager.cancelPendingLayoutSaves()
    harness.manager.saveAllLayoutSnapshots()

    #expect(Set(readDict(harness).keys) == [wt1.id.rawValue, wt2.id.rawValue])
  }

  @Test func capturedSnapshotRoundTripsThroughDisk() async {
    let harness = makeHarness()
    let worktree = makeWorktree()
    let state = harness.manager.state(for: worktree)
    _ = state.createTab(focusing: false)
    _ = state.createTab(focusing: false)

    await settleThenAdvance(harness.clock)
    await waitUntil { readDict(harness)[worktree.id.rawValue] != nil }

    let persisted = readDict(harness)[worktree.id.rawValue]
    let inMemory = state.captureLayoutSnapshot()
    #expect(persisted == inMemory)
  }
}
