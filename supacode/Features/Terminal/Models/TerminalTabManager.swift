import Foundation
import Observation

@MainActor
@Observable
final class TerminalTabManager {
  var tabs: [TerminalTabItem] = []
  var selectedTabId: TerminalTabID?

  private static let logger = SupaLogger("TabManager")

  func createTab(
    title: String,
    icon: String?,
    isTitleLocked: Bool = false,
    tintColor: TerminalTabTintColor? = nil,
    id: UUID? = nil
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
    let tab = TerminalTabItem(id: tabID, title: title, icon: icon, isTitleLocked: isTitleLocked, tintColor: tintColor)
    if let selectedTabId,
      let selectedIndex = tabs.firstIndex(where: { $0.id == selectedTabId })
    {
      tabs.insert(tab, at: selectedIndex + 1)
    } else {
      tabs.append(tab)
    }
    selectedTabId = tab.id
    return tab.id
  }

  func selectTab(_ id: TerminalTabID) {
    guard tabs.contains(where: { $0.id == id }) else { return }
    selectedTabId = id
  }

  func updateTitle(_ id: TerminalTabID, title: String) {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
    guard !tabs[index].isTitleLocked else { return }
    tabs[index].title = title
  }

  func unlockAndUpdateTitle(_ id: TerminalTabID, title: String) {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
    tabs[index].isTitleLocked = false
    tabs[index].title = title
    tabs[index].icon = nil
    tabs[index].tintColor = nil
  }

  func updateDirty(_ id: TerminalTabID, isDirty: Bool) {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
    tabs[index].isDirty = isDirty
  }

  func reorderTabs(_ orderedIds: [TerminalTabID]) {
    let existingIds = Set(tabs.map(\.id))
    let incomingIds = Set(orderedIds)
    guard existingIds == incomingIds else { return }
    let map = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
    tabs = orderedIds.compactMap { map[$0] }
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

  func closeAll() {
    tabs.removeAll()
    selectedTabId = nil
  }
}
