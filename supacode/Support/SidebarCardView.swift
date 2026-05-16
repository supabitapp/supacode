import SwiftUI

/// Pinned sidebar card surface (glass background, 10pt radius, leading-aligned).
/// Three slots: `header` (top row, left of the inline dismiss X), `content`
/// (title / description / inline composition), and `actions` (primary buttons
/// rendered below the content). `isDismissable` adds an X button that lives in
/// the same HStack as `header`, so wide header content (avatars, icons) can't
/// land underneath the dismiss target.
struct SidebarCard<Header: View, Content: View, Actions: View>: View {
  let isDismissable: Bool
  @ViewBuilder let content: () -> Content
  @ViewBuilder let actions: () -> Actions
  @ViewBuilder let header: () -> Header
  let onDismiss: () -> Void

  init(
    isDismissable: Bool = true,
    @ViewBuilder content: @escaping () -> Content,
    @ViewBuilder actions: @escaping () -> Actions = { EmptyView() },
    @ViewBuilder header: @escaping () -> Header = { EmptyView() },
    onDismiss: @escaping () -> Void = {}
  ) {
    self.isDismissable = isDismissable
    self.content = content
    self.actions = actions
    self.header = header
    self.onDismiss = onDismiss
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 8) {
        header()
        Spacer(minLength: 0)
        if isDismissable {
          Button {
            onDismiss()
          } label: {
            Image(systemName: "xmark")
              .font(.caption2)
              .foregroundStyle(.secondary)
              .frame(width: 18, height: 18)
              .contentShape(.rect)
          }
          .buttonStyle(.plain)
          .help("Dismiss")
          .accessibilityLabel("Dismiss")
        }
      }
      VStack(alignment: .leading, spacing: 6) {
        content()
        actions()
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .glassEffect(.regular, in: .rect(cornerRadius: 10))
    .padding(.horizontal, 10)
    .padding(.bottom, 10)
  }
}

/// Standard title + optional description pair used by every sidebar card today.
/// Callers that need richer composition can pass arbitrary content instead.
struct SidebarCardLabel: View {
  let title: LocalizedStringKey
  let description: LocalizedStringKey?

  init(title: LocalizedStringKey, description: LocalizedStringKey? = nil) {
    self.title = title
    self.description = description
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.subheadline)
        .fontWeight(.semibold)
      if let description {
        Text(description)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}
