import AppKit
import SwiftUI

struct WindowAppearanceSetter: NSViewRepresentable {
  let colorScheme: ColorScheme?

  func makeNSView(context: Context) -> WindowAppearanceView {
    let view = WindowAppearanceView()
    view.colorScheme = colorScheme
    return view
  }

  func updateNSView(_ nsView: WindowAppearanceView, context: Context) {
    nsView.colorScheme = colorScheme
  }
}

final class WindowAppearanceView: NSView {
  var colorScheme: ColorScheme? {
    didSet {
      applyAppearance()
    }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    applyAppearance()
  }

  private func applyAppearance() {
    guard let window else {
      return
    }
    let targetName: NSAppearance.Name? = switch colorScheme {
    case .none:
      nil
    case .some(let scheme):
      switch scheme {
      case .light:
        .aqua
      case .dark:
        .darkAqua
      @unknown default:
        nil
      }
    }
    if window.appearance?.name == targetName {
      return
    }
    switch targetName {
    case .some(let name):
      window.appearance = NSAppearance(named: name)
    case .none:
      window.appearance = nil
    }
  }
}
