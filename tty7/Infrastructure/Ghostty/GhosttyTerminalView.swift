import SwiftUI

struct GhosttyTerminalView: NSViewRepresentable {
  let surfaceView: GhosttySurfaceView

  func makeNSView(context: Context) -> GhosttySurfaceScrollView {
    GhosttySurfaceScrollView(surfaceView: surfaceView)
  }

  func updateNSView(_ view: GhosttySurfaceScrollView, context: Context) {
    _ = view
  }
}
