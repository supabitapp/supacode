import SwiftUI
import UniformTypeIdentifiers

extension View {
  /// Applies `.contentShape` only on macOS 15.0+. A no-op on earlier versions.
  @ViewBuilder
  func contentShapeIfAvailable(_ kind: some ContentShapeKind, _ shape: some Shape) -> some View {
    if #available(macOS 15.0, *) {
      self.contentShape(kind, shape)
    } else {
      self
    }
  }

  /// Applies `.fileImporter` only on macOS 15.0+. A no-op on earlier versions.
  /// Wraps a `Void`-returning success handler into the View-required form.
  func fileImporterIfAvailable(
    isPresented: Binding<Bool>,
    allowedContentTypes: [UTType],
    allowsMultipleSelection: Bool,
    onSuccess: @escaping (Result<[URL], any Error>) -> Void
  ) -> some View {
    if #available(macOS 15.0, *) {
      self.fileImporter(
        isPresented: isPresented,
        allowedContentTypes: allowedContentTypes,
        allowsMultipleSelection: allowsMultipleSelection
      ) { result in
        onSuccess(result)
        return EmptyView()
      }
    } else {
      self
    }
  }

  /// Applies `.onDragSessionUpdated` only on macOS 15.0+. A no-op on earlier versions.
  func onDragSessionUpdatedIfAvailable(
    _ action: @escaping (DragSession) -> Void
  ) -> some View {
    if #available(macOS 15.0, *) {
      self.onDragSessionUpdated(action)
    } else {
      self
    }
  }

  /// Applies `.scrollBounceBehavior(.basedOnSize)` only on macOS 15.0+. A no-op on earlier versions.
  @ViewBuilder
  func scrollBounceBehaviorIfAvailable() -> some View {
    if #available(macOS 15.0, *) {
      self.scrollBounceBehavior(.basedOnSize)
    } else {
      self
    }
  }

  /// Applies `.scrollContentBackground(.hidden)` only on macOS 15.0+. A no-op on earlier versions.
  @ViewBuilder
  func scrollContentBackgroundIfHidden() -> some View {
    if #available(macOS 15.0, *) {
      self.scrollContentBackground(.hidden)
    } else {
      self
    }
  }

  /// Applies `.scrollIndicators(.never)` only on macOS 15.0+. A no-op on earlier versions.
  @ViewBuilder
  func scrollIndicatorsIfNever() -> some View {
    if #available(macOS 15.0, *) {
      self.scrollIndicators(.never)
    } else {
      self
    }
  }
}
