import SupacodeSettingsShared
import SwiftUI

/// Multi-color ping dot used by leaf rows for running-script indicators
/// and by collapsed group headers for aggregated indicators. A single color
/// renders a steady ping; multiple colors cycle through them (or fall back
/// to a static dot when Reduce Motion is on).
struct SidebarPingMultiColorDot: View {
  let colors: [RepositoryColor]
  let isEmphasized: Bool
  let size: CGFloat
  let showsSolidCenter: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var uniqueColors: [Color] {
    guard !isEmphasized else { return [.primary] }
    var seen = Set<RepositoryColor>()
    return colors.compactMap { tint in
      guard seen.insert(tint).inserted else { return nil }
      return tint.color
    }
  }

  var body: some View {
    let resolved = uniqueColors
    if resolved.count <= 1 {
      SidebarPingDot(
        color: resolved.first ?? .green,
        size: size,
        showsSolidCenter: showsSolidCenter
      )
    } else if reduceMotion {
      SidebarPingStaticDot(color: resolved[0], size: size, showsSolidCenter: showsSolidCenter)
    } else {
      SidebarPingCyclingDot(colors: resolved, size: size, showsSolidCenter: showsSolidCenter)
    }
  }
}

struct SidebarPingStaticDot: View {
  let color: Color
  let size: CGFloat
  let showsSolidCenter: Bool
  @Environment(\.pixelLength) private var pixelLength

  var body: some View {
    ZStack {
      Circle()
        .stroke(color, lineWidth: pixelLength)
        .frame(width: size, height: size)
        .opacity(0.6)
      if showsSolidCenter {
        Circle()
          .fill(color)
          .frame(width: size, height: size)
      }
    }
    .accessibilityLabel("Run script active")
  }
}

struct SidebarPingCyclingDot: View {
  let colors: [Color]
  let size: CGFloat
  let showsSolidCenter: Bool

  var body: some View {
    TimelineView(.periodic(from: .now, by: 2.0)) { timeline in
      let index = Self.colorIndex(for: timeline.date, count: colors.count)
      let color = colors[index]
      ZStack {
        SidebarPingRing(color: color, size: size)
        if showsSolidCenter {
          Circle()
            .fill(color)
            .frame(width: size, height: size)
        }
      }
      .animation(.easeInOut(duration: 0.6), value: index)
    }
    .accessibilityLabel("Run script active")
  }

  private static func colorIndex(for date: Date, count: Int) -> Int {
    guard count > 0 else { return 0 }
    let seconds = Int(date.timeIntervalSinceReferenceDate)
    return (seconds / 2) % count
  }
}

struct SidebarPingDot: View {
  let color: Color
  let size: CGFloat
  let showsSolidCenter: Bool

  var body: some View {
    ZStack {
      SidebarPingRing(color: color, size: size)
      if showsSolidCenter {
        Circle()
          .fill(color)
          .frame(width: size, height: size)
      }
    }
    .accessibilityLabel("Run script active")
  }
}

struct SidebarPingRing: View {
  let color: Color
  let size: CGFloat
  @Environment(\.pixelLength) private var pixelLength
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let ring = Circle()
      .stroke(color, lineWidth: pixelLength)
      .frame(width: size, height: size)
    if reduceMotion {
      ring.opacity(0.6)
    } else {
      ring.phaseAnimator([false, true]) { content, expanded in
        content
          .scaleEffect(expanded ? 2 : 1)
          .opacity(expanded ? 0 : 0.6)
      } animation: { expanded in
        expanded ? .easeOut(duration: 1) : .linear(duration: 0.001)
      }
    }
  }
}
