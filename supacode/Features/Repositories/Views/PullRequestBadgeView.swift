import SupacodeSettingsShared
import SwiftUI

enum PullRequestBadgeStyle {
  static let mergedColor = Color.purple
  static let openColor = Color.green
  static let queuedColor = Color.brown

  static func style(
    state: PullRequestState?,
    number: Int?,
    isQueued: Bool = false,
    numberSigil: String = "#"
  ) -> (text: String, color: Color)? {
    switch state {
    case .merged:
      return (text: number.map { "\(numberSigil)\($0)" } ?? "MERGED", color: mergedColor)
    case .open:
      return (text: number.map { "\(numberSigil)\($0)" } ?? "OPEN", color: isQueued ? queuedColor : openColor)
    case .closed, .unknown, .none:
      return nil
    }
  }

  static func helpText(state: PullRequestState?, url: URL?) -> String {
    switch state {
    case .merged:
      return url == nil ? "Pull request merged" : "Open merged pull request on GitHub"
    case .open:
      return url == nil ? "Pull request open" : "Open pull request on GitHub"
    case .closed, .unknown, .none:
      return url == nil ? "Pull request" : "Open pull request on GitHub"
    }
  }
}

struct PullRequestBadgeView: View {
  let text: String
  let color: Color

  var body: some View {
    Text(text)
      .appFont(.caption2)
      .foregroundStyle(color)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .fixedSize(horizontal: true, vertical: false)
      .overlay {
        RoundedRectangle(cornerRadius: 4)
          .stroke(color, lineWidth: 1)
      }
      .accessibilityLabel(text)
  }
}
