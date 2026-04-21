import SwiftUI

struct ShimmerModifier: ViewModifier {
  let isActive: Bool
  @Environment(\.layoutDirection) private var layoutDirection

  private let bandSize: CGFloat = 0.3
  private let gradient = Gradient(colors: [
    .black.opacity(0.6),
    .black,
    .black.opacity(0.6),
  ])

  private var min: CGFloat { 0 - bandSize }
  private var max: CGFloat { 1 + bandSize }

  private func startPoint(animating: Bool) -> UnitPoint {
    if layoutDirection == .rightToLeft {
      return animating ? UnitPoint(x: 0, y: 1) : UnitPoint(x: max, y: min)
    }
    return animating ? UnitPoint(x: 1, y: 1) : UnitPoint(x: min, y: min)
  }

  private func endPoint(animating: Bool) -> UnitPoint {
    if layoutDirection == .rightToLeft {
      return animating ? UnitPoint(x: min, y: max) : UnitPoint(x: 1, y: 0)
    }
    return animating ? UnitPoint(x: max, y: max) : UnitPoint(x: 0, y: 0)
  }

  func body(content: Content) -> some View {
    if isActive {
      // Driving the sweep via `phaseAnimator` lets SwiftUI pause the
      // timeline when the view is occluded — `.repeatForever` kept
      // the animation pipeline active even when nothing was visible.
      content.phaseAnimator([false, true]) { content, animating in
        content.mask(
          LinearGradient(
            gradient: gradient,
            startPoint: startPoint(animating: animating),
            endPoint: endPoint(animating: animating)
          )
        )
      } animation: { animating in
        animating ? .linear(duration: 1.5).delay(0.25) : .linear(duration: 0.001)
      }
    } else {
      content
    }
  }
}

extension View {
  func shimmer(isActive: Bool) -> some View {
    modifier(ShimmerModifier(isActive: isActive))
  }
}
