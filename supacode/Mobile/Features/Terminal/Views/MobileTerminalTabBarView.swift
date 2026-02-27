import SwiftUI

struct MobileTerminalTabBarView: View {
  let sessions: [MobileSession]
  let selectedSessionID: MobileSession.ID?
  let onSelectSession: (MobileSession.ID) -> Void
  let onCloseSession: (MobileSession.ID) -> Void
  let onNewSession: () -> Void

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 0) {
        ForEach(sessions) { session in
          MobileTerminalTabView(
            title: session.title,
            isSelected: session.id == selectedSessionID,
            isClosed: session.isClosed,
            onSelect: {
              onSelectSession(session.id)
            },
            onClose: {
              onCloseSession(session.id)
            },
          )
        }

        Button {
          onNewSession()
        } label: {
          Image(systemName: "plus")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help("New Session (⌘T)")
      }
      .padding(.horizontal, 4)
    }
    .frame(height: 32)
    .background(.ultraThinMaterial)
    .overlay(alignment: .bottom) {
      Divider()
    }
  }
}

private struct MobileTerminalTabView: View {
  let title: String
  let isSelected: Bool
  let isClosed: Bool
  let onSelect: () -> Void
  let onClose: () -> Void

  @State private var isHovered = false

  var body: some View {
    Button {
      onSelect()
    } label: {
      HStack(spacing: 4) {
        if isClosed {
          Image(systemName: "xmark.circle.fill")
            .font(.caption2)
            .foregroundStyle(.red)
        }

        Text(title)
          .font(.caption)
          .lineLimit(1)
          .foregroundStyle(isSelected ? .primary : .secondary)

        Button {
          onClose()
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: 14, height: 14)
        }
        .buttonStyle(.plain)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(
        isSelected
          ? AnyShapeStyle(.regularMaterial)
          : AnyShapeStyle(.clear),
        in: RoundedRectangle(cornerRadius: 4),
      )
    }
    .buttonStyle(.plain)
  }
}
