import AppKit
import SwiftUI

struct SplitView<L: View, R: View>: View {
  let direction: SplitDirection
  let dividerColor: Color
  let resizeIncrements: CGSize
  let left: L
  let right: R
  let onResize: (Double) -> Void
  let onEqualize: () -> Void
  let minSize: CGFloat = 10
  // Fraction of the container the left/top child occupies, matching
  // `SplitTree.Split.ratio`; a plain value, not a closure binding, so the
  // children re-evaluate only when the ratio actually changes.
  let ratio: Double
  private let splitterVisibleSize: CGFloat = 1
  private let splitterInvisibleSize: CGFloat = 6

  var body: some View {
    GeometryReader { geo in
      let leftRect = leftRect(for: geo.size)
      let rightRect = rightRect(for: geo.size, leftRect: leftRect)
      let splitterPoint = splitterPoint(for: geo.size, leftRect: leftRect)

      ZStack(alignment: .topLeading) {
        left
          .frame(width: leftRect.size.width, height: leftRect.size.height)
          .offset(x: leftRect.origin.x, y: leftRect.origin.y)
        right
          .frame(width: rightRect.size.width, height: rightRect.size.height)
          .offset(x: rightRect.origin.x, y: rightRect.origin.y)
        SplitDivider(
          direction: direction,
          visibleSize: splitterVisibleSize,
          invisibleSize: splitterInvisibleSize,
          color: dividerColor
        )
        .position(splitterPoint)
        .gesture(dragGesture(geo.size))
        .onTapGesture(count: 2) {
          onEqualize()
        }
      }
    }
  }

  init(
    _ direction: SplitDirection,
    ratio: Double,
    dividerColor: Color,
    resizeIncrements: CGSize = .init(width: 1, height: 1),
    @ViewBuilder left: (() -> L),
    @ViewBuilder right: (() -> R),
    onResize: @escaping (Double) -> Void,
    onEqualize: @escaping () -> Void
  ) {
    self.direction = direction
    self.ratio = ratio
    self.dividerColor = dividerColor
    self.resizeIncrements = resizeIncrements
    self.left = left()
    self.right = right()
    self.onResize = onResize
    self.onEqualize = onEqualize
  }

  private func dragGesture(_ size: CGSize) -> some Gesture {
    DragGesture()
      .onChanged { gesture in
        switch direction {
        case .horizontal:
          let new = min(max(minSize, gesture.location.x), size.width - minSize)
          onResize(Double(new / size.width))
        case .vertical:
          let new = min(max(minSize, gesture.location.y), size.height - minSize)
          onResize(Double(new / size.height))
        }
      }
  }

  private func leftRect(for size: CGSize) -> CGRect {
    var result = CGRect(x: 0, y: 0, width: size.width, height: size.height)
    switch direction {
    case .horizontal:
      result.size.width *= CGFloat(ratio)
      result.size.width -= splitterVisibleSize / 2
      result.size.width -= result.size.width.truncatingRemainder(dividingBy: resizeIncrements.width)
    case .vertical:
      result.size.height *= CGFloat(ratio)
      result.size.height -= splitterVisibleSize / 2
      result.size.height -= result.size.height.truncatingRemainder(
        dividingBy: resizeIncrements.height)
    }
    return result
  }

  private func rightRect(for size: CGSize, leftRect: CGRect) -> CGRect {
    var result = CGRect(x: 0, y: 0, width: size.width, height: size.height)
    switch direction {
    case .horizontal:
      result.origin.x += leftRect.size.width
      result.origin.x += splitterVisibleSize / 2
      result.size.width -= result.origin.x
    case .vertical:
      result.origin.y += leftRect.size.height
      result.origin.y += splitterVisibleSize / 2
      result.size.height -= result.origin.y
    }
    return result
  }

  private func splitterPoint(for size: CGSize, leftRect: CGRect) -> CGPoint {
    switch direction {
    case .horizontal:
      return CGPoint(x: leftRect.size.width, y: size.height / 2)
    case .vertical:
      return CGPoint(x: size.width / 2, y: leftRect.size.height)
    }
  }

  private struct SplitDivider: View {
    let direction: SplitDirection
    let visibleSize: CGFloat
    let invisibleSize: CGFloat
    let color: Color
    @State private var isHovered = false
    var body: some View {
      ZStack {
        Rectangle()
          .fill(color)
          .frame(width: visibleWidth, height: visibleHeight)
      }
      .frame(width: hitboxWidth, height: hitboxHeight)
      .contentShape(.rect)
      .onHover { hovering in
        guard hovering != isHovered else { return }
        isHovered = hovering
        if hovering {
          hoverCursor.push()
        } else {
          NSCursor.pop()
        }
      }
      .onDisappear {
        if isHovered {
          isHovered = false
          NSCursor.pop()
        }
      }
    }

    private var hoverCursor: NSCursor {
      switch direction {
      case .horizontal:
        return .resizeLeftRight
      case .vertical:
        return .resizeUpDown
      }
    }

    private var visibleWidth: CGFloat? {
      switch direction {
      case .horizontal:
        return visibleSize
      case .vertical:
        return nil
      }
    }

    private var visibleHeight: CGFloat? {
      switch direction {
      case .horizontal:
        return nil
      case .vertical:
        return visibleSize
      }
    }

    private var hitboxWidth: CGFloat? {
      switch direction {
      case .horizontal:
        return visibleSize + invisibleSize
      case .vertical:
        return nil
      }
    }

    private var hitboxHeight: CGFloat? {
      switch direction {
      case .horizontal:
        return nil
      case .vertical:
        return visibleSize + invisibleSize
      }
    }
  }
}
