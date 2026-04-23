import SwiftUI

struct ConversationPaneView: View {
  let thread: ConversationThread

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
        .padding(.horizontal, 14)
        .padding(.vertical, 10)

      Divider()

      if thread.messages.isEmpty {
        ContentUnavailableView(
          "No conversation yet",
          systemImage: "message",
          description: Text("Agents can append messages here with `supacode comms send`.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
              ForEach(thread.messages) { message in
                ConversationMessageRow(message: message)
                  .id(message.id)
              }
            }
            .padding(14)
          }
          .textSelection(.enabled)
          .onAppear {
            scrollToLatestMessage(with: proxy, animated: false)
          }
          .onChange(of: thread.messages.last?.id) { _, _ in
            scrollToLatestMessage(with: proxy, animated: true)
          }
        }
      }
    }
    .background(.regularMaterial)
  }

  private var header: some View {
    HStack(spacing: 10) {
      Label("Conversation", systemImage: "message")
        .font(.headline)
      Spacer()
      if !thread.messages.isEmpty {
        Text("\(thread.messages.count)")
          .font(.caption)
          .monospaced()
          .foregroundStyle(.secondary)
      }
    }
  }

  private func scrollToLatestMessage(with proxy: ScrollViewProxy, animated: Bool) {
    guard let messageID = thread.messages.last?.id else { return }
    Task { @MainActor in
      if animated {
        withAnimation(.easeOut(duration: 0.18)) {
          proxy.scrollTo(messageID, anchor: .bottom)
        }
      } else {
        proxy.scrollTo(messageID, anchor: .bottom)
      }
    }
  }
}

private struct ConversationMessageRow: View {
  let message: ConversationMessage

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(message.sender.name)
          .font(.caption.weight(.semibold))
        Spacer(minLength: 12)
        Text(message.createdAt.formatted(date: .abbreviated, time: .shortened))
          .font(.caption2)
          .monospaced()
          .foregroundStyle(.secondary)
      }

      if let title = message.title {
        Text(title)
          .font(.subheadline.weight(.semibold))
      }

      Text(message.body)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color.secondary.opacity(0.10))
    }
  }
}
