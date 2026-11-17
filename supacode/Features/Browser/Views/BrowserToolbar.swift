import SupacodeSettingsShared
import SwiftUI

struct BrowserToolbarView: View {
  let page: BrowserPageState
  weak var content: BrowserContent?

  @State private var addressText = ""
  @FocusState private var isAddressFocused: Bool

  var body: some View {
    HStack(spacing: 6) {
      Button("Back", systemImage: "chevron.left") { content?.perform(.goBack) }
        .disabled(!page.canGoBack)
        .help("Back (⌘[)")
      Button("Forward", systemImage: "chevron.right") { content?.perform(.goForward) }
        .disabled(!page.canGoForward)
        .help("Forward (⌘])")
      Button(page.isLoading ? "Stop" : "Reload", systemImage: page.isLoading ? "xmark" : "arrow.clockwise") {
        content?.reloadOrStop()
      }
      .help(page.isLoading ? "Stop Loading" : "Reload Page (⌘R)")
      TextField("Search or enter address", text: $addressText)
        .textFieldStyle(.roundedBorder)
        .appFont(.callout, monospaced: true)
        .focused($isAddressFocused)
        .onSubmit { content?.navigate(to: addressText) }
        .onExitCommand { content?.focus() }
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
    .task(id: page.addressFocusRequested) {
      guard page.addressFocusRequested else { return }
      await Task.yield()
      isAddressFocused = true
      page.addressFocusRequested = false
    }
    .onChange(of: isAddressFocused) {
      content?.addressFocusChanged(isAddressFocused)
      if !isAddressFocused {
        addressText = BrowserAddress.display(page.url)
      }
    }
    .onDisappear {
      content?.addressFocusChanged(false)
    }
  }
}
