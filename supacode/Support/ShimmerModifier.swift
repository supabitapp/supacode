import SwiftUI

struct ShimmerModifier: ViewModifier {
  let isActive: Bool
  @State private var animating = false
  @Environment(\.layoutDirection) private var layoutDirection

  private let bandSize: CGFloat = 0.3
  private let animation: Animation = .linear(duration: 1.5).delay(0.25).repeatForever(autoreverses: false)
  private let gradient = Gradient(colors: [
    .black.opacity(0.6),
    .black,
    .black.opacity(0.6),
  ])

  private var min: CGFloat { 0 - bandSize }
  private var max: CGFloat { 1 + bandSize }

  private var startPoint: UnitPoint {
    if layoutDirection == .rightToLeft {
      return animating ? UnitPoint(x: 0, y: 1) : UnitPoint(x: max, y: min)
    }
    return animating ? UnitPoint(x: 1, y: 1) : UnitPoint(x: min, y: min)
  }

  private var endPoint: UnitPoint {
    if layoutDirection == .rightToLeft {
      return animating ? UnitPoint(x: min, y: max) : UnitPoint(x: 1, y: 0)
    }
    return animating ? UnitPoint(x: max, y: max) : UnitPoint(x: 0, y: 0)
  }

  func body(content: Content) -> some View {
    content
      .mask(
        LinearGradient(
          gradient: isActive ? gradient : Gradient(colors: [.black]),
          startPoint: startPoint,
          endPoint: endPoint
        )
      )
      .animation(isActive ? animation : nil, value: animating)
      .onChange(of: isActive) { oldValue, newValue in
        guard oldValue != newValue else { return }
        if newValue {
          animating = false
          Task { @MainActor in
            animating = true
          }
        } else {
          animating = false
        }
      }
      .task {
        guard isActive else { return }
        try? await Task.sleep(for: .milliseconds(50))
        animating = true
      }
  }
}

extension View {
  func shimmer(isActive: Bool) -> some View {
    modifier(ShimmerModifier(isActive: isActive))
  }
}
