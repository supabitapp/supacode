import SwiftUI

struct TerminalTabContentStack<Content: View>: View {
  let tabs: [TerminalTabItem]
  let selectedTabId: TerminalTabID
  let content: (TerminalTabID) -> Content

  init(
    tabs: [TerminalTabItem],
    selectedTabId: TerminalTabID,
    @ViewBuilder content: @escaping (TerminalTabID) -> Content
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

  static func selectedTabID(in tabs: [TerminalTabItem], selectedTabId: TerminalTabID) -> TerminalTabID? {
    tabs.contains { $0.id == selectedTabId } ? selectedTabId : nil
  }
}
