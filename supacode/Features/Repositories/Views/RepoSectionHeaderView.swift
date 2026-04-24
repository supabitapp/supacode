import SwiftUI

struct RepoSectionHeaderView: View {
  let name: String
  let customTitle: String?
  let color: RepositoryColor?
  let isRemoving: Bool

  private var displayName: String {
    guard let trimmed = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
      !trimmed.isEmpty
    else {
      return name
    }
    return trimmed
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
