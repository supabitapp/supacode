import AppIntents

struct ListTerminalsIntent: AppIntent {
  static var title: LocalizedStringResource = "List Terminals"
  static var description = IntentDescription("Lists all active Supacode terminal panes.")

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<[TerminalEntity]> {
    let terminals = try await TerminalEntity.defaultQuery.allEntities()
    return .result(value: terminals)
  }
}

struct GetTerminalDetailsIntent: AppIntent {
  static var title: LocalizedStringResource = "Get Terminal Details"
  static var description = IntentDescription("Returns an entity with details about the selected terminal pane.")

  @Parameter(title: "Terminal")
  var terminal: TerminalEntity

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<TerminalEntity> {
    // Rebuild from the current surface view (if it still exists) to keep details fresh.
    if let view = terminal.surfaceView {
      return .result(value: TerminalEntity(view))
    }
    return .result(value: terminal)
  }
}

