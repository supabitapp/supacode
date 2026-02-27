import SwiftUI

struct MobileSidebarFooterView: View {
  let onConnect: () -> Void

  var body: some View {
    HStack {
      Button {
        onConnect()
      } label: {
        Label("Connect", systemImage: "server.rack")
          .font(.callout)
      }
      .help("Connect to Server")

      Spacer()
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.ultraThinMaterial)
    .overlay(alignment: .top) {
      Divider()
    }
  }
}
