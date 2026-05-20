import AppKit
import SupacodeSettingsShared
import SwiftUI

struct FailedRepositoryRow: View {
  let name: String
  let path: String
  let removeRepository: () -> Void

  var body: some View {
    Label {
      Text(name)
    } icon: {
      Image(systemName: "exclamationmark.triangle.fill")
        .resizable()
        .aspectRatio(contentMode: .fit)
        .fontWeight(.semibold)
        .foregroundStyle(.pink)
        .frame(width: 16, height: 16)
        .accessibilityLabel("Repository unavailable")
    }
    .labelStyle(.verticallyCentered)
    .listRowInsets(.trailing, 4)
    .listRowInsets(.vertical, 6)
    .contextMenu {
      Button("Copy as Pathname", systemImage: "doc.on.doc") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
      }
      Divider()
      Button(
        "Remove Repository…",
        systemImage: "folder.badge.minus",
        role: .destructive,
        action: removeRepository
      )
      .help("Remove this repository from Supacode. Files on disk are untouched.")
    }
  }
}
