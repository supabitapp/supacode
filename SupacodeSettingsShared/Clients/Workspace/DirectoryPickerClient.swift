import AppKit
import ComposableArchitecture

/// Presents a folder picker for choosing a custom agent-integration directory.
public nonisolated struct DirectoryPickerClient: Sendable {
  /// Returns the chosen directory, or `nil` when the user cancels.
  public var pickDirectory: @Sendable @MainActor (_ message: String) async -> URL?

  public init(pickDirectory: @escaping @Sendable @MainActor (_ message: String) async -> URL?) {
    self.pickDirectory = pickDirectory
  }
}

extension DirectoryPickerClient: DependencyKey {
  public static let liveValue = Self(pickDirectory: { message in
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Install Here"
    panel.message = message
    return panel.runModal() == .OK ? panel.url : nil
  })

  public static let testValue = Self(pickDirectory: { _ in nil })
}

extension DependencyValues {
  public var directoryPicker: DirectoryPickerClient {
    get { self[DirectoryPickerClient.self] }
    set { self[DirectoryPickerClient.self] = newValue }
  }
}
