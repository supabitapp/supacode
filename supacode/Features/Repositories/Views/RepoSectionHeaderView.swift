import SupacodeSettingsShared
import SwiftUI

struct RepoSectionHeaderView: View {
  let name: String
  let customTitle: String?
  let color: RepositoryColor?
  let isRemoving: Bool

  private var displayName: String {
    Repository.sidebarDisplayName(custom: customTitle, fallback: name)
  }

  var body: some View {
    HStack {
      Text(displayName).foregroundStyle(color?.color ?? .secondary)
      if isRemoving {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel("Removing repository")
      }
    }
  }
}
