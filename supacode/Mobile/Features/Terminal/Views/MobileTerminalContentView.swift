import SwiftUI

struct MobileTerminalContentView: View {
  let session: MobileTerminalSession?

  var body: some View {
    if let session {
      MobileGhosttySurfaceViewRepresentable(surfaceView: session.surfaceView)
        .ignoresSafeArea(.keyboard)
        .id(session.id)
        .onAppear {
          session.surfaceView.activateInput()
        }
        .onDisappear {
          session.surfaceView.deactivateInput()
        }
    } else {
      Color.black
        .ignoresSafeArea()
    }
  }
}
