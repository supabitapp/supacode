import SwiftUI

struct TaskRowView: View {
  let row: TaskRowModel
  let isSelected: Bool
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    let showsSpinner = row.isPending || row.isDeleting
    let nameColor = colorScheme == .dark ? Color.white : Color.primary
    HStack(alignment: .center) {
      ZStack {
        Image(systemName: "list.bullet.clipboard")
          .font(.caption)
          .foregroundStyle(.secondary)
          .opacity(showsSpinner ? 0 : 1)
          .accessibilityHidden(true)
        if showsSpinner {
          ProgressView()
            .controlSize(.small)
        }
      }
      .frame(width: 16, height: 16)
      VStack(alignment: .leading, spacing: 2) {
        Text(row.isDeleting ? "\(row.name) (deleting...)" : row.name)
          .font(.body)
          .foregroundStyle(nameColor)
        if !row.agentSummary.isEmpty {
          HStack(spacing: 4) {
            Text(row.agentSummary)
              .foregroundStyle(.secondary)
          }
          .font(.caption)
          .lineLimit(1)
        }
      }
      Spacer(minLength: 8)
      if row.variantCount > 1 {
        Text("\(row.variantCount)")
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .padding(.horizontal, 4)
          .padding(.vertical, 1)
          .background(
            RoundedRectangle(cornerRadius: 3)
              .fill(Color.secondary.opacity(0.15))
          )
          .help("\(row.variantCount) agent variants")
      }
    }
  }
}
