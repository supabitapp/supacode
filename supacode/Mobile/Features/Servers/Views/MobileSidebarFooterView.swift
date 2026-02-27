import SwiftUI

struct MobileSidebarFooterView: View {
  let onAddServer: () -> Void

  var body: some View {
    HStack {
      Button {
        onAddServer()
      } label: {
        Label("Add Server", systemImage: "plus.circle")
          .font(.callout)
      }
      .help("Add Server")

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
