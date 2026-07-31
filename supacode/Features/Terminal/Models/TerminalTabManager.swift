import Foundation
import Observation
import SupacodeSettingsShared

@MainActor
@Observable
final class TerminalTabManager {
  var tabs: [TerminalTabItem] = [] {
    // Drops `editingTabID` when the edited tab disappears across any close path.
    didSet {
      guard let id = editingTabID, !tabs.contains(where: { $0.id == id }) else { return }
      editingTabID = nil
    }
  }
  var selectedTabId: TerminalTabID? {
    // Single choke point for the ~nine selection write sites: the owning state
    // recomputes tab visibility (and its hibernation timers) once per change.
    didSet {
      guard oldValue != selectedTabId else { return }
      onSelectedTabChanged?()
    }
  }
  private(set) var editingTabID: TerminalTabID?

  /// Fires whenever `selectedTabId` changes. Set by `WorktreeTerminalState` so a
  /// selection change drives `refreshTabVisibility()` from one place.
  @ObservationIgnored var onSelectedTabChanged: (() -> Void)?

  private static let logger = SupaLogger("TabManager")

  /// `selecting: false` appends a background tab and leaves the selection alone.
  /// Keyboard focus is the caller's business; see `TabActivation`.
  func createTab(
    title: String,
    customTitle: String? = nil,
    icon: String?,
    isTitleLocked: Bool = false,
    tintColor: RepositoryColor? = nil,
    isBlockingScript: Bool = false,
    id: UUID? = nil,
    selecting: Bool = true
  ) -> TerminalTabID {
    let tabID: TerminalTabID
    if let id {
      let candidate = TerminalTabID(rawValue: id)
      if tabs.contains(where: { $0.id == candidate }) {
        Self.logger.warning("Duplicate tab ID \(id), generating a new one.")
        tabID = TerminalTabID()
      } else {
        tabID = candidate
      }
    } else {
      tabID = TerminalTabID()
    }
    if isTitleLocked, customTitle != nil {
      Self.logger.warning("Dropping the custom title of locked tab \(tabID.rawValue).")
    }
    let tab = TerminalTabItem(
      id: tabID,
      title: title,
      customTitle: isTitleLocked ? nil : customTitle.flatMap(Self.normalizedCustomTitle),
      icon: icon,
      isTitleLocked: isTitleLocked,
      tintColor: tintColor,
      isBlockingScript: isBlockingScript
    )
    // Background tabs append: inserting after the unchanged selection would land a
    // run of them in reverse order.
    if selecting, let selectedTabId,
      let selectedIndex = tabs.firstIndex(where: { $0.id == selectedTabId })
    {
      tabs.insert(tab, at: selectedIndex + 1)
    } else {
      tabs.append(tab)
    }
    // Still select when nothing was selected: "don't move the selection" cannot
    // mean leaving the worktree with no visible tab at all.
    if selecting || selectedTabId == nil {
      selectedTabId = tab.id
    }
    return tab.id
  }

  func selectTab(_ id: TerminalTabID) {
    guard tabs.contains(where: { $0.id == id }) else { return }
    selectedTabId = id
  }

  func updateTitle(_ id: TerminalTabID, title: String) {
    guard let index = renamableTabIndex(id) else { return }
    // TUIs rewrite their title constantly; skip no-op writes so an unchanged
    // title doesn't re-render the tab bar on every report.
    guard tabs[index].title != title else { return }
    tabs[index].title = title
  }

  /// Returns false when the tab is gone or its title is locked, so callers can
  /// skip persisting a rename that never applied.
  @discardableResult
  func setCustomTitle(_ id: TerminalTabID, title: String) -> Bool {
    guard let index = renamableTabIndex(id) else { return false }
    tabs[index].customTitle = Self.normalizedCustomTitle(title)
    return true
  }

  func canRename(_ id: TerminalTabID) -> Bool {
    renamableTabIndex(id) != nil
  }

  private func renamableTabIndex(_ id: TerminalTabID) -> Int? {
    guard let index = tabs.firstIndex(where: { $0.id == id }), !tabs[index].isTitleLocked else {
      return nil
    }
    return index
  }

  /// Nil for a title that carries no visible characters. Callers reject such a
  /// title up front rather than let it drop silently here.
  nonisolated static func normalizedCustomTitle(_ title: String) -> String? {
    // Blank control scalars, not the whole control-characters set, so emoji joiners survive.
    let scalars = title.unicodeScalars.map { scalar in
      scalar.properties.generalCategory == .control || CharacterSet.newlines.contains(scalar)
        ? UnicodeScalar(" ") : scalar
    }
    let sanitized = String(String.UnicodeScalarView(scalars))
    let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  func isBlockingScript(_ id: TerminalTabID) -> Bool {
    tabs.first(where: { $0.id == id })?.isBlockingScript == true
  }

  /// Mark a blocking-script tab as completed. Title / icon / lock survive so
  /// the row reads as "this WAS an Archive Script run"; tint clears and the
  /// completed flag flips so views can show the freeze indicator.
  func markBlockingScriptCompleted(_ id: TerminalTabID) {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
    tabs[index].tintColor = nil
    tabs[index].isBlockingScriptCompleted = true
  }

  func reorderTabs(_ orderedIds: [TerminalTabID]) {
    let existingIds = Set(tabs.map(\.id))
    let incomingIds = Set(orderedIds)
    guard existingIds == incomingIds else { return }
    let map = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
    tabs = orderedIds.compactMap { map[$0] }
  }

  /// Moves the tab by `amount`, wrapping cyclically at the ends per Ghostty's
  /// `move_tab` contract. Leaves the selection untouched. Returns whether the
  /// order actually changed.
  @discardableResult
  func moveTab(_ id: TerminalTabID, by amount: Int) -> Bool {
    guard amount != 0, tabs.count > 1,
      let current = tabs.firstIndex(where: { $0.id == id })
    else { return false }
    let count = tabs.count
    // Reduce first: `amount` is Ghostty's unrestricted `ssize_t`, so adding a
    // near-`Int.max` offset straight to `current` would overflow and trap.
    let destination = (current + amount % count + count) % count
    guard destination != current else { return false }
    var moved = tabs
    let item = moved.remove(at: current)
    moved.insert(item, at: destination)
    tabs = moved
    return true
  }

  func closeTab(_ id: TerminalTabID) {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
    tabs.remove(at: index)
    guard selectedTabId == id else { return }
    if index > 0 {
      selectedTabId = tabs[index - 1].id
    } else if !tabs.isEmpty {
      selectedTabId = tabs[0].id
    } else {
      selectedTabId = nil
    }
  }

  func closeOthers(keeping id: TerminalTabID) {
    tabs = tabs.filter { $0.id == id }
    selectedTabId = tabs.first?.id
  }

  func closeToRight(of id: TerminalTabID) {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
    tabs = Array(tabs.prefix(index + 1))
    if let selectedTabId, !tabs.contains(where: { $0.id == selectedTabId }) {
      self.selectedTabId = tabs.last?.id
    }
  }

  func beginTabRename(_ id: TerminalTabID) {
    guard canRename(id) else { return }
    editingTabID = id
  }

  func endTabRename() {
    editingTabID = nil
  }

  func closeAll() {
    tabs.removeAll()
    selectedTabId = nil
  }
}
