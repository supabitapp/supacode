import Kingfisher
import SwiftUI

/// Detail toolbar title: rename-popover button for git worktrees;
/// static folder label for non-git folder repositories.
struct WorktreeDetailTitleView: View {
  let title: String
  let rootURL: URL
  let isFolder: Bool
  let onRenameBranch: (String) -> Void

  @State private var isPresented = false
  @State private var draftName = ""

  var body: some View {
    Button {
      draftName = title
      isPresented = true
    } label: {
      Label {
        Text(title)
      } icon: {
        if isFolder {
          Image(systemName: "folder")
            .accessibilityHidden(true)
        } else {
          RepositoryOwnerAvatar(rootURL: rootURL)
        }
      }
      .labelStyle(.titleAndIcon)
    }
    .help("Rename \(isFolder ? "folder" : "branch")")
    .disabled(isFolder)
    .popover(isPresented: $isPresented) {
      RenameBranchPopover(
        draftName: $draftName,
        onCancel: { isPresented = false },
        onSubmit: { newName in
          isPresented = false
          guard newName != title else { return }
          onRenameBranch(newName)
        }
      )
    }
  }
}

/// Falls back to a branch glyph while loading or when the remote
/// doesn't resolve to a GitHub owner.
private struct RepositoryOwnerAvatar: View {
  let rootURL: URL
  @State private var avatarURL: URL?

  var body: some View {
    KFImage(avatarURL)
      .placeholder {
        Image(systemName: "arrow.trianglehead.branch")
          .accessibilityHidden(true)
      }
      .resizable()
      .aspectRatio(1, contentMode: .fit)
      .frame(width: 20, height: 20)
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .task(id: rootURL) { avatarURL = await Self.ownerAvatarURL(for: rootURL) }
  }

  private static func ownerAvatarURL(for rootURL: URL) async -> URL? {
    guard let info = await GitClient().remoteInfo(for: rootURL) else {
      return nil
    }
    // 64 px covers retina rendering of the 20 pt icon frame.
    return URL(string: "https://github.com/\(info.owner).png?size=64")
  }
}

private struct RenameBranchPopover: View {
  @Binding var draftName: String
  let onCancel: () -> Void
  let onSubmit: (String) -> Void
  @FocusState private var isFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Rename Branch")
        .font(.headline)

      TextField("Branch name", text: $draftName)
        .textFieldStyle(.roundedBorder)
        .focused($isFocused)
        .onChange(of: draftName) { _, newValue in
          let filtered = String(newValue.filter { !$0.isWhitespace })
          if filtered != newValue {
            draftName = filtered
          }
        }
        .onSubmit { submit() }
        .onExitCommand { onCancel() }

      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { onCancel() }
          .keyboardShortcut(.cancelAction)
        Button("Rename") { submit() }
          .keyboardShortcut(.defaultAction)
          .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding()
    .frame(width: 280)
    .task { isFocused = true }
  }

  private func submit() {
    let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    onSubmit(trimmed)
  }
}

#Preview("supabitapp/supacode") {
  // Walk up from this source file to the repo root so the live preview
  // resolves the real supabitapp/supacode origin.
  let supacodeRepoRoot: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // Views
    .deletingLastPathComponent()  // Repositories
    .deletingLastPathComponent()  // Features
    .deletingLastPathComponent()  // supacode
    .deletingLastPathComponent()  // repo root

  Text("").toolbar {
    WorktreeDetailTitleView(
      title: "sbertix/small-ui-improvements",
      rootURL: supacodeRepoRoot,
      isFolder: false,
      onRenameBranch: { _ in }
    )
  }.frame(width: 600, height: 600)
}

#Preview("Folder") {
  Text("").toolbar {
    WorktreeDetailTitleView(
      title: "Documents",
      rootURL: URL(fileURLWithPath: "/Users/stefanobertagno/Documents"),
      isFolder: true,
      onRenameBranch: { _ in }
    )
  }.frame(width: 600, height: 600)
}

#Preview("Missing repo") {
  Text("").toolbar {
    WorktreeDetailTitleView(
      title: "ghost-branch",
      rootURL: URL(fileURLWithPath: "/tmp/supacode-preview-no-such-repo"),
      isFolder: false,
      onRenameBranch: { _ in }
    )
  }.frame(width: 600, height: 600)
}
