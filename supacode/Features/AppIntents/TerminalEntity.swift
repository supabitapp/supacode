import AppIntents
import Foundation

struct TerminalEntity: AppEntity {
  let id: UUID

  @Property(title: "Title")
  var title: String

  @Property(title: "Working Directory")
  var workingDirectory: String?

  @Property(title: "Foreground Process")
  var foregroundProcess: String?

  @Property(title: "Process Category")
  var processCategory: ProcessCategory

  @Property(title: "Shell State")
  var shellState: ShellState

  static var typeDisplayRepresentation: TypeDisplayRepresentation {
    TypeDisplayRepresentation(name: "Terminal Pane")
  }

  @MainActor
  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(title)")
  }

  /// Returns the surface view associated with this entity. This may no longer exist.
  @MainActor
  var surfaceView: GhosttySurfaceView? {
    TerminalIntentRegistry.shared.terminalManager?.surfaceView(id: id)
  }

  static var defaultQuery = TerminalQuery()

  @MainActor
  init(_ view: GhosttySurfaceView) {
    id = view.id

    let rawTitle = view.bridge.state.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let rawPwd = view.bridge.state.pwd?.trimmingCharacters(in: .whitespacesAndNewlines)

    title = rawTitle.isEmpty ? (rawPwd ?? "Terminal pane") : rawTitle
    workingDirectory = rawPwd

    let inferredProcess = TerminalForegroundProcessInference.infer(
      fromTitle: view.bridge.state.title,
      pwd: view.bridge.state.pwd
    )
    foregroundProcess = inferredProcess

    let internalCategory = inferredProcess.map { TerminalProcessClassifier.category(for: $0) } ?? .other
    processCategory = ProcessCategory(rawValue: internalCategory.rawValue) ?? .other

    let internalShellState = TerminalProcessClassifier.shellState(from: view.bridge.state.progressState)
    shellState = ShellState(rawValue: internalShellState.rawValue) ?? .idle
  }
}

extension TerminalEntity {
  enum ProcessCategory: String, AppEnum {
    case shell
    case editor
    case aiTool
    case pager
    case ssh
    case other

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Process Category")

    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
      .shell: .init(title: "Shell"),
      .editor: .init(title: "Editor"),
      .aiTool: .init(title: "AI Tool"),
      .pager: .init(title: "Pager"),
      .ssh: .init(title: "SSH"),
      .other: .init(title: "Other"),
    ]
  }

  enum ShellState: String, AppEnum {
    case idle
    case running
    case waitingForInput

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Shell State")

    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
      .idle: .init(title: "Idle"),
      .running: .init(title: "Running"),
      .waitingForInput: .init(title: "Waiting for Input"),
    ]
  }
}

struct TerminalQuery: EntityStringQuery, EnumerableEntityQuery {
  @MainActor
  func entities(for identifiers: [TerminalEntity.ID]) async throws -> [TerminalEntity] {
    all
      .filter { identifiers.contains($0.id) }
      .map(TerminalEntity.init)
  }

  @MainActor
  func entities(matching string: String) async throws -> [TerminalEntity] {
    let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return try await allEntities() }

    return all.filter { view in
      let title = view.bridge.state.title ?? ""
      let pwd = view.bridge.state.pwd ?? ""
      let inferred = TerminalForegroundProcessInference.infer(fromTitle: title, pwd: pwd) ?? ""
      return title.localizedCaseInsensitiveContains(query)
        || pwd.localizedCaseInsensitiveContains(query)
        || inferred.localizedCaseInsensitiveContains(query)
    }
    .map(TerminalEntity.init)
  }

  @MainActor
  func allEntities() async throws -> [TerminalEntity] {
    all.map(TerminalEntity.init)
  }

  @MainActor
  func suggestedEntities() async throws -> [TerminalEntity] {
    try await allEntities()
  }

  @MainActor
  var all: [GhosttySurfaceView] {
    let views = TerminalIntentRegistry.shared.terminalManager?.allSurfaceViews() ?? []
    return views.sorted { $0.id.uuidString < $1.id.uuidString }
  }
}

