import SwiftUI

/// A label style that arranges the icon and title
/// horizontally with vertical center alignment.
public struct VerticallyCenteredLabelStyle: LabelStyle {
  public init() {}

  public func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 6) {
      configuration.icon
      configuration.title
    }
  }
}

extension LabelStyle where Self == VerticallyCenteredLabelStyle {
  public static var verticallyCentered: VerticallyCenteredLabelStyle { .init() }
}
