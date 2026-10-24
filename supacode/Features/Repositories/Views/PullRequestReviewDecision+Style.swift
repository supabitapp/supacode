import SwiftUI

extension PullRequestReviewDecision {
  var color: Color {
    switch self {
    case .approved: .green
    case .changesRequested: .red
    case .reviewRequired: .orange
    }
  }
}
