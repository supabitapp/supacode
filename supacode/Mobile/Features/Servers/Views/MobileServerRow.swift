import SwiftUI

struct MobileServerRow: View {
  let server: MobileServer
  let activeSessionCount: Int

  var body: some View {
    HStack(alignment: .center, spacing: 8) {
      Image(systemName: "server.rack")
        .symbolVariant(.fill)
        .foregroundStyle(.secondary)
        .font(.caption)
        .frame(width: 16, height: 16)

      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(server.displayName)
            .font(.body)
            .lineLimit(1)

          Spacer(minLength: 4)

          if activeSessionCount > 0 {
            Text("\(activeSessionCount)")
              .font(.caption2)
              .fontWeight(.semibold)
              .monospacedDigit()
              .foregroundStyle(.white)
              .padding(.horizontal, 5)
              .padding(.vertical, 1)
              .background(.blue, in: Capsule())
          }
        }

        Text(server.detailLine)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .padding(.horizontal, 2)
    .frame(maxWidth: .infinity, minHeight: 42, alignment: .center)
  }
}
