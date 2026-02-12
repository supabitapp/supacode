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
    ZStack {
      ForEach(tabs) { tab in
        content(tab.id)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .opacity(tab.id == selectedTabId ? 1 : 0)
          .zIndex(tab.id == selectedTabId ? 1 : 0)
          .allowsHitTesting(tab.id == selectedTabId)
          .accessibilityHidden(tab.id != selectedTabId)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
