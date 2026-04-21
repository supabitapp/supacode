import GhosttyKit
import SwiftUI

struct GhosttySurfaceProgressBar: View {
  let progressState: ghostty_action_progress_report_state_e
  let progressValue: Int?

  var body: some View {
    let color: Color =
      switch progressState {
      case GHOSTTY_PROGRESS_STATE_ERROR: .red
      case GHOSTTY_PROGRESS_STATE_PAUSE: .orange
      default: .accentColor
      }
    let progress: Int? =
      progressValue ?? (progressState == GHOSTTY_PROGRESS_STATE_PAUSE ? 100 : nil)
    let accessibilityLabel: String =
      switch progressState {
      case GHOSTTY_PROGRESS_STATE_ERROR: "Terminal progress - Error"
      case GHOSTTY_PROGRESS_STATE_PAUSE: "Terminal progress - Paused"
      case GHOSTTY_PROGRESS_STATE_INDETERMINATE: "Terminal progress - In progress"
      default: "Terminal progress"
      }
    let accessibilityValue: String =
      if let progress {
        "\(progress) percent complete"
      } else {
        switch progressState {
        case GHOSTTY_PROGRESS_STATE_ERROR: "Operation failed"
        case GHOSTTY_PROGRESS_STATE_PAUSE: "Operation paused at completion"
        case GHOSTTY_PROGRESS_STATE_INDETERMINATE: "Operation in progress"
        default: "Indeterminate progress"
        }
      }

    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        if let progress {
          Rectangle()
            .fill(color)
            .frame(
              width: geometry.size.width * CGFloat(progress) / 100,
              height: geometry.size.height
            )
            .animation(.easeInOut(duration: 0.2), value: progress)
        } else {
          ZStack(alignment: .leading) {
            Rectangle()
              .fill(color.opacity(0.3))
            Rectangle()
              .fill(color)
              .frame(width: geometry.size.width * 0.25, height: geometry.size.height)
              .phaseAnimator([false, true]) { content, moved in
                content.offset(x: moved ? geometry.size.width * 0.75 : 0)
              } animation: { _ in
                .easeInOut(duration: 1.2)
              }
          }
        }
      }
    }
    .frame(height: 2)
    .clipped()
    .allowsHitTesting(false)
    .accessibilityElement(children: .ignore)
    .accessibilityAddTraits(.updatesFrequently)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityValue(accessibilityValue)
  }
}
