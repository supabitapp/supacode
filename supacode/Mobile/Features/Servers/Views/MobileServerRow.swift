import SwiftUI

struct MobileSessionRow: View {
  let serverName: String
  let sessionTitle: String
  let isClosed: Bool

  var body: some View {
    HStack(alignment: .center, spacing: 8) {
      Image(systemName: "terminal")
        .foregroundStyle(isClosed ? .red : .secondary)
        .font(.caption)
        .frame(width: 16, height: 16)

      VStack(alignment: .leading, spacing: 2) {
        Text(serverName)
          .font(.body)
          .lineLimit(1)

        Text(sessionTitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer(minLength: 4)

      if isClosed {
        Circle()
          .fill(.red)
          .frame(width: 6, height: 6)
      }
    }
    .padding(.horizontal, 2)
    .frame(maxWidth: .infinity, minHeight: 42, alignment: .center)
  }
}
