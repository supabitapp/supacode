import ComposableArchitecture
import SwiftUI

struct MobileKeyboardShortcuts: ViewModifier {
  let store: StoreOf<MobileAppFeature>

  func body(content: Content) -> some View {
    content
      .background {
        Group {
          Button("New Session") {
            store.send(.openSession(commandOverride: nil))
          }
          .keyboardShortcut("t", modifiers: .command)

          Button("Close Session") {
            if let id = store.selectedSessionID {
              store.send(.closeSession(id))
            }
          }
          .keyboardShortcut("w", modifiers: .command)

          Button("Add Server") {
            store.send(.addServerTapped)
          }
          .keyboardShortcut("n", modifiers: .command)

          ForEach(1 ... 9, id: \.self) { index in
            Button("Switch to Session \(index)") {
              store.send(.switchToSession(index - 1))
            }
            .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
          }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
      }
  }
}

extension View {
  func mobileKeyboardShortcuts(store: StoreOf<MobileAppFeature>) -> some View {
    modifier(MobileKeyboardShortcuts(store: store))
  }
}
