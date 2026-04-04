import SwiftUI

struct RepoSectionHeaderView: View {
  let name: String
  let isRemoving: Bool

  var body: some View {
    HStack {
      Text(name).foregroundStyle(.secondary)
      if isRemoving {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel("Removing repository")
      }
    }
  }
}
