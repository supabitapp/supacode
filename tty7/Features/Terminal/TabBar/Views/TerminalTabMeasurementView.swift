import SwiftUI

struct TerminalTabMeasurementView: View {
  let tabId: TerminalTabID
  let onFrameChange: (TerminalTabID, CGRect) -> Void

  var body: some View {
    GeometryReader { proxy in
      Color.clear
        .onAppear {
          onFrameChange(tabId, proxy.frame(in: .global))
        }
        .onChange(of: proxy.frame(in: .global)) { _, newFrame in
          onFrameChange(tabId, newFrame)
        }
    }
  }
}
