import SupacodeSettingsShared
import SwiftUI

struct RepoSectionHeaderView: View {
  let name: String
  let customTitle: String?
  let color: RepositoryColor?
  let isRemoving: Bool
  /// `[user@]host[:port]` when the repository lives on an SSH host, else nil;
  /// surfaces a `wifi` glyph beside the title, full value shown on hover.
  var hostInfo: String?
  /// Remote repository whose SSH listing is still resolving; shows a spinner.
  var isResolving: Bool = false

  private var displayName: String {
    Repository.sidebarDisplayName(custom: customTitle, fallback: name)
  }

  var body: some View {
    HStack {
      HStack(spacing: 4) {
        Text(displayName).foregroundStyle(color?.color ?? .secondary)
        if let hostInfo {
          Image(systemName: "wifi")
            .imageScale(.small)
            .foregroundStyle(.secondary)
            .help(hostInfo)
            .accessibilityLabel("Remote host \(hostInfo)")
        }
      }
      if isRemoving {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel("Removing repository")
      } else if isResolving {
        ProgressView()
          .controlSize(.mini)
          .accessibilityLabel("Connecting to remote")
      }
    }
  }
}
