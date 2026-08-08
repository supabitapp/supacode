import SwiftUI

struct TerminalTabContentStack<Content: View>: View {
  let tabs: [TerminalTabItem]
  let selectedTabId: TabID
  let content: (TabID) -> Content

  init(
    tabs: [TerminalTabItem],
    selectedTabId: TabID,
    @ViewBuilder content: @escaping (TabID) -> Content
  ) {
    self.tabs = tabs
    self.selectedTabId = selectedTabId
    self.content = content
  }

  var body: some View {
    if let selectedTabID = Self.selectedTabID(in: tabs, selectedTabId: selectedTabId) {
      content(selectedTabID)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  static func selectedTabID(in tabs: [TerminalTabItem], selectedTabId: TabID) -> TabID? {
    tabs.contains { $0.id == selectedTabId } ? selectedTabId : nil
  }
}
