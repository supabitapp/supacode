import SupacodeSettingsShared
import SwiftUI

struct BrowserToolbarActions {
  var goBack: () -> Void = {}
  var goForward: () -> Void = {}
  var reloadOrStop: () -> Void = {}
  var navigate: (String) -> Void = { _ in }
  var addressFocusChanged: (Bool) -> Void = { _ in }
  var focusPage: () -> Void = {}
}

final class BrowserToolbar: TabContentToolbar {
  let contentID: ContentID
  let page: BrowserPageState
  var actions = BrowserToolbarActions()

  init(contentID: ContentID, page: BrowserPageState) {
    self.contentID = contentID
    self.page = page
  }

  nonisolated deinit {}

  var view: AnyView? {
    AnyView(BrowserToolbarView(page: page, actions: actions).id(contentID))
  }
}

private struct BrowserToolbarView: View {
  let page: BrowserPageState
  let actions: BrowserToolbarActions

  @State private var addressText = ""
  @FocusState private var isAddressFocused: Bool

  var body: some View {
    HStack(spacing: 6) {
      Button("Back", systemImage: "chevron.left", action: actions.goBack)
        .disabled(!page.canGoBack)
        .help("Back (⌘[)")
      Button("Forward", systemImage: "chevron.right", action: actions.goForward)
        .disabled(!page.canGoForward)
        .help("Forward (⌘])")
      Button(
        page.isLoading ? "Stop" : "Reload",
        systemImage: page.isLoading ? "xmark" : "arrow.clockwise",
        action: actions.reloadOrStop
      )
      .help(page.isLoading ? "Stop Loading" : "Reload Page (⌘R)")
      TextField("Search or enter address", text: $addressText)
        .textFieldStyle(.roundedBorder)
        .appFont(.callout, monospaced: true)
        .focused($isAddressFocused)
        .onSubmit { actions.navigate(addressText) }
        .onExitCommand(perform: actions.focusPage)
        .help("Address (⌘L)")
        .accessibilityLabel("Address")
    }
    .labelStyle(.iconOnly)
    .buttonStyle(.borderless)
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .overlay(alignment: .bottom) {
      if page.isLoading {
        ProgressView(value: page.loadProgress)
          .progressViewStyle(.linear)
          .controlSize(.mini)
          .accessibilityLabel("Page loading")
      }
    }
    .onChange(of: page.url, initial: true) {
      guard !isAddressFocused else { return }
      addressText = BrowserAddress.display(page.url)
    }
    // Assigning focus in the update that mounts the field is dropped by
    // SwiftUI, so the request is honored on the next main-actor turn.
    .task(id: page.addressFocusRequested) {
      guard page.addressFocusRequested else { return }
      await Task.yield()
      isAddressFocused = true
      page.addressFocusRequested = false
    }
    .onChange(of: isAddressFocused) {
      actions.addressFocusChanged(isAddressFocused)
      if !isAddressFocused {
        addressText = BrowserAddress.display(page.url)
      }
    }
    .onDisappear {
      actions.addressFocusChanged(false)
    }
  }
}
