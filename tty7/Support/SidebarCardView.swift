import SwiftUI

/// Pinned sidebar card surface (glass background, 10pt radius, leading-aligned).
/// Two slots: `header` (top row, left of the inline dismiss X) and `content`
/// (title / description / inline buttons). Pass a non-nil `onDismiss` to add the
/// X button; it lives in the same HStack as `header`, so wide header content
/// (avatars, icons) can't land underneath the dismiss target.
struct SidebarCard<Header: View, Content: View>: View {
  let onDismiss: (() -> Void)?
  @ViewBuilder let content: () -> Content
  @ViewBuilder let header: () -> Header

  init(
    onDismiss: (() -> Void)? = nil,
    @ViewBuilder content: @escaping () -> Content,
    @ViewBuilder header: @escaping () -> Header = { EmptyView() }
  ) {
    self.onDismiss = onDismiss
    self.content = content
    self.header = header
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 8) {
        header()
        Spacer(minLength: 0)
        if let onDismiss {
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
      content()
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

/// Shared "is this card stamp still considered dismissed?" gate.
/// Each card declares its own `relevantSince` cutoff; bumping that
/// date re-shows the card to users who dismissed before it.
enum SidebarCardRelevance {
  static func isDismissed(at dismissedAt: Date, relevantSince: Date) -> Bool {
    dismissedAt >= relevantSince
  }
}
