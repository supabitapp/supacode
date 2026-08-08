import CoreGraphics

enum TerminalTabBarMetrics {
  static let barHeight: CGFloat = 33
  static let barPadding: CGFloat = 0
  static let tabHeight: CGFloat = 32
  static let tabMinWidth: CGFloat = 140
  static let tabMaxWidth: CGFloat = 220
  static let tabCornerRadius: CGFloat = 0
  static let tabSpacing: CGFloat = 0
  static let tabHorizontalPadding: CGFloat = 12
  static let contentSpacing: CGFloat = 6
  static let contentTrailingSpacing: CGFloat = 0
  static let activeIndicatorHeight: CGFloat = 2
  static let activeTabOffset: CGFloat = 0.5
  static let activeTabBottomPadding: CGFloat = 1
  static let closeButtonSize: CGFloat = 16
  static let dirtyIndicatorSize: CGFloat = 8
  static let overflowShadowWidth: CGFloat = 24
  static let dropIndicatorWidth: CGFloat = 2
  static let dropIndicatorHeight: CGFloat = 20
  static let hoverAnimationDuration: Double = 0.1
  static let closeAnimationDuration: Double = 0.2
  static let fadeAnimationDuration: Double = 0.15
  static let selectionAnimationDuration: Double = 0.15
  static let reorderAnimationDuration: Double = 0.3
  static let reorderAnimationBounce: Double = 0.15

  // Inactive tabs use full-alpha `.primary` text and reduce to this opacity
  // at the tab level so 11pt caption stays above WCAG AA 4.5:1 in both modes.
  static let inactiveContentOpacityIdle: Double = 0.7
  static let inactiveContentOpacityHover: Double = 0.85
  static let inactiveContentSaturationIdle: Double = 0.4
  static let inactiveContentSaturationHover: Double = 0.8
}
