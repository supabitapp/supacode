import SupacodeSettingsShared
import SwiftUI

extension TerminalTabTintColor {
  var color: Color {
    switch self {
    case .green: .green
    case .orange: .orange
    case .red: .red
    case .blue: .blue
    case .purple: .purple
    case .yellow: .yellow
    case .teal: .teal
    }
  }
}
