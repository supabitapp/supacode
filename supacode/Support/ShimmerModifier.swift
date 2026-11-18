import AppKit
import SwiftUI

extension View {
  func shimmer(isActive: Bool) -> some View {
    Shimmer(isActive: isActive, label: self)
  }
}

private struct Shimmer<Label: View>: View {
  let isActive: Bool
  let label: Label
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    if isActive, !reduceMotion {
      ShimmerHost(label: label).accessibilityRepresentation { label }
    } else {
      label
    }
  }
}

/// SwiftUI interpolates its own animations on the main thread every frame, and renders an
/// AppKit view inside `.mask` from its model layer, so a sweep only stays off the main thread
/// as a Core Animation mask on a layer that owns the label (#951).
private struct ShimmerHost<Label: View>: NSViewRepresentable {
  typealias NSViewType = ShimmerHostView<EnvironmentForwarded<Label>>

  let label: Label

  func makeNSView(context: Context) -> NSViewType {
    ShimmerHostView(rootView: EnvironmentForwarded(label: label, environment: context.environment))
  }

  func updateNSView(_ nsView: NSViewType, context: Context) {
    nsView.update(rootView: EnvironmentForwarded(label: label, environment: context.environment))
    nsView.isRightToLeft = context.environment.layoutDirection == .rightToLeft
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSViewType, context: Context) -> CGSize? {
    nsView.sizeThatFits(proposal)
  }
}

private struct EnvironmentForwarded<Label: View>: View {
  let label: Label
  let environment: EnvironmentValues

  var body: some View {
    label.environment(\.self, environment)
  }
}

private final class ShimmerHostView<Content: View>: NSView {
  private let hosting: NSHostingController<Content>
  var isRightToLeft = false {
    didSet {
      guard oldValue != isRightToLeft else { return }
      restartSweep()
    }
  }
  private let band = CAGradientLayer()
  private let bandSize: CGFloat = 0.3
  private let trackScale: CGFloat = 3
  private let sweepDelay: CFTimeInterval = 0.25
  private let sweepDuration: CFTimeInterval = 1.5
  private var sweptSize: CGSize = .zero

  init(rootView: Content) {
    hosting = NSHostingController(rootView: rootView)
    hosting.sizingOptions = []
    super.init(frame: .zero)
    wantsLayer = true
    addSubview(hosting.view)
    let half = bandSize / (2 * trackScale)
    let dim = NSColor.black.withAlphaComponent(0.6).cgColor
    band.colors = [dim, dim, NSColor.black.cgColor, dim, dim]
    band.locations = [0, 0.5 - half, 0.5, 0.5 + half, 1].map { NSNumber(value: Double($0)) }
    let mask = CALayer()
    mask.addSublayer(band)
    layer?.mask = mask
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  nonisolated deinit {}

  override var isFlipped: Bool { true }

  func update(rootView: Content) {
    hosting.rootView = rootView
  }

  func sizeThatFits(_ proposal: ProposedViewSize) -> CGSize {
    hosting.sizeThatFits(in: CGSize(width: proposal.width ?? .infinity, height: proposal.height ?? .infinity))
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil, band.animation(forKey: "shimmer") == nil else { return }
    restartSweep()
  }

  override func layout() {
    super.layout()
    hosting.view.frame = bounds
    guard bounds.size != sweptSize else { return }
    sweptSize = bounds.size
    restartSweep()
  }

  private func restartSweep() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer?.mask?.frame = bounds
    band.startPoint = CGPoint(x: isRightToLeft ? 1 : 0, y: 0)
    band.endPoint = CGPoint(x: isRightToLeft ? 0 : 1, y: 1)
    band.bounds = CGRect(
      origin: .zero, size: CGSize(width: bounds.width * trackScale, height: bounds.height * trackScale))
    band.position = CGPoint(x: bounds.midX, y: bounds.midY)
    CATransaction.commit()
    let travelX = bounds.width * (1 + bandSize) / 2 * (isRightToLeft ? -1 : 1)
    let travelY = bounds.height * (1 + bandSize) / 2
    let start = NSValue(size: CGSize(width: -travelX, height: -travelY))
    let sweep = CAKeyframeAnimation(keyPath: "transform.translation")
    sweep.values = [start, start, NSValue(size: CGSize(width: travelX, height: travelY))]
    sweep.keyTimes = [0, NSNumber(value: sweepDelay / (sweepDelay + sweepDuration)), 1]
    sweep.duration = sweepDelay + sweepDuration
    sweep.repeatCount = .infinity
    let now = band.convertTime(CACurrentMediaTime(), from: nil)
    sweep.beginTime = now - now.truncatingRemainder(dividingBy: sweep.duration)
    sweep.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
    band.add(sweep, forKey: "shimmer")
  }
}
