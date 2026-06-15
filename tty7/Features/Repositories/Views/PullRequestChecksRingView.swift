import SwiftUI

struct PullRequestChecksRingView: View {
  let breakdown: PullRequestCheckBreakdown
  @ScaledMetric(relativeTo: .caption) private var diameter: CGFloat = 12
  @ScaledMetric(relativeTo: .caption) private var lineWidth: CGFloat = 2
  private let segmentGapFraction = 0.05

  var body: some View {
    if breakdown.total == 0 {
      EmptyView()
    } else {
      let segments = segments(for: breakdown)
      let applyGap = segments.count > 1
      ZStack {
        ForEach(segments) { segment in
          if let trimmed = trimmedSegment(segment, applyGap: applyGap) {
            Circle()
              .trim(from: trimmed.start, to: trimmed.end)
              .rotation(.degrees(-90))
              .stroke(trimmed.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
          }
        }
      }
      .frame(width: diameter, height: diameter)
      .accessibilityHidden(true)
    }
  }

  private func segments(for breakdown: PullRequestCheckBreakdown) -> [Segment] {
    let total = Double(breakdown.total)
    guard total > 0 else {
      return []
    }
    var start = 0.0
    var segments: [Segment] = []
    func addSegment(id: String, count: Int, color: Color) {
      guard count > 0 else {
        return
      }
      let sweep = Double(count) / total
      let end = start + sweep
      segments.append(
        Segment(
          id: id,
          start: start,
          end: end,
          color: color
        )
      )
      start = end
    }
    addSegment(id: "failed", count: breakdown.failed, color: .red)
    addSegment(id: "inProgress", count: breakdown.inProgress, color: .yellow)
    addSegment(id: "skipped", count: breakdown.skipped, color: .gray)
    addSegment(id: "expected", count: breakdown.expected, color: .yellow)
    addSegment(id: "passed", count: breakdown.passed, color: .green)
    return segments
  }

  private func trimmedSegment(_ segment: Segment, applyGap: Bool) -> Segment? {
    let length = segment.end - segment.start
    guard length > 0 else {
      return nil
    }
    let gap = applyGap ? min(segmentGapFraction, length * 0.45) : 0
    let start = segment.start + gap
    let end = segment.end - gap
    guard end > start else {
      return nil
    }
    return Segment(id: segment.id, start: start, end: end, color: segment.color)
  }

  private struct Segment: Identifiable {
    let id: String
    let start: Double
    let end: Double
    let color: Color
  }
}
