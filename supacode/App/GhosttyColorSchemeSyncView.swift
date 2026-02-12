import SwiftUI

struct GhosttyColorSchemeSyncView<Content: View>: View {
  @Environment(\.colorScheme) private var colorScheme
  let ghostty: GhosttyRuntime
  let content: Content

  init(ghostty: GhosttyRuntime, @ViewBuilder content: () -> Content) {
    self.ghostty = ghostty
    self.content = content()
  }

  var body: some View {
    content
      .task(id: colorScheme) {
        apply(colorScheme)
      }
  }

  private func apply(_ scheme: ColorScheme) {
    ghostty.setColorScheme(scheme)
  }
}
