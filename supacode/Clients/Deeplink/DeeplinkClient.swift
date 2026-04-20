import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

struct DeeplinkClient: Sendable {
  var parse: @Sendable (URL) -> Deeplink?
}

extension DeeplinkClient: DependencyKey {
  static let liveValue = DeeplinkClient { DeeplinkParser.parse($0) }
  static let testValue = DeeplinkClient(parse: unimplemented("DeeplinkClient.parse", placeholder: nil))
}

extension DependencyValues {
  var deeplinkClient: DeeplinkClient {
    get { self[DeeplinkClient.self] }
    set { self[DeeplinkClient.self] = newValue }
  }
}

// MARK: - Parser.

private nonisolated enum DeeplinkParser {
  private static let logger = SupaLogger("Deeplink")

  static func parse(_ url: URL) -> Deeplink? {
    guard url.scheme == "supacode" else {
      logger.debug("Ignoring non-supacode URL: \(url.scheme ?? "nil")")
      return nil
    }
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      logger.warning("Failed to parse URL components: \(url)")
      return nil
    }
    // For custom-scheme URLs, the host acts as the top-level route (e.g., "worktree", "repo", "settings").
    guard let host = components.host, !host.isEmpty else { return .open }
    // url.path() defaults to percentEncoded: true, keeping %2F intact so encoded slashes
    // are not split as path separators. components.path is percent-decoded, which would
    // incorrectly split worktree IDs containing literal slashes.
    let pathSegments = url.path()
      .split(separator: "/", omittingEmptySubsequences: true)
      .map(String.init)
    let queryItems = components.queryItems ?? []

    switch host {
    case "worktree":
      return parseWorktree(pathSegments: pathSegments, queryItems: queryItems)
    case "repo":
      return parseRepo(pathSegments: pathSegments, queryItems: queryItems)
    case "help":
      return .help
    case "settings":
      // settings/repo/<encoded-repo-id> → open repository settings.
      if pathSegments.first == "repo" {
        guard pathSegments.count >= 2,
          let repositoryID = pathSegments[1].removingPercentEncoding, !repositoryID.isEmpty
        else {
          logger.warning("Settings repo deeplink missing or invalid repository ID.")
          return nil
        }
        return .settingsRepo(repositoryID: repositoryID)
      }
      let section: Deeplink.DeeplinkSettingsSection? = pathSegments.first.flatMap { raw in
        guard let parsed = Deeplink.DeeplinkSettingsSection(rawValue: raw) else {
          logger.warning("Unrecognized settings section: \(raw).")
          return nil
        }
        return parsed
      }
      return .settings(section: section)
    default:
      logger.warning("Unrecognized deeplink host: \(host)")
      return nil
    }
  }

  // MARK: - Worktree.

  private static func parseWorktree(
    pathSegments: [String],
    queryItems: [URLQueryItem]
  ) -> Deeplink? {
    // Expected: <percent-encoded-worktree-id>[/<action>[/<sub-path>...]].
    guard !pathSegments.isEmpty else {
      logger.warning("Worktree deeplink missing id")
      return nil
    }
    guard let rawWorktreeID = pathSegments[0].removingPercentEncoding, !rawWorktreeID.isEmpty else {
      logger.warning("Failed to percent-decode worktree ID")
      return nil
    }
    // Normalize trailing slashes so that IDs with and without a trailing
    // slash resolve to the same worktree.
    let worktreeID = rawWorktreeID.hasSuffix("/") ? String(rawWorktreeID.dropLast()) : rawWorktreeID
    guard pathSegments.count >= 2 else {
      return .worktree(id: worktreeID, action: .select)
    }
    let action = pathSegments[1]

    switch action {
    case "run":
      return .worktree(id: worktreeID, action: .run)
    case "stop":
      return .worktree(id: worktreeID, action: .stop)
    case "archive":
      return .worktree(id: worktreeID, action: .archive)
    case "unarchive":
      return .worktree(id: worktreeID, action: .unarchive)
    case "delete":
      return .worktree(id: worktreeID, action: .delete)
    case "pin":
      return .worktree(id: worktreeID, action: .pin)
    case "unpin":
      return .worktree(id: worktreeID, action: .unpin)
    case "tab":
      return parseWorktreeTab(
        worktreeID: worktreeID,
        pathSegments: pathSegments,
        queryItems: queryItems,
      )
    case "script":
      return parseWorktreeScript(worktreeID: worktreeID, pathSegments: pathSegments)
    default:
      logger.warning("Unrecognized worktree action: \(action)")
      return nil
    }
  }

  private static func parseWorktreeScript(
    worktreeID: Worktree.ID,
    pathSegments: [String]
  ) -> Deeplink? {
    // Expected: "script/<script-uuid>/run" or "script/<script-uuid>/stop".
    guard pathSegments.count >= 4 else {
      logger.warning("Script deeplink missing script ID or action")
      return nil
    }
    guard let scriptID = UUID(uuidString: pathSegments[2]) else {
      logger.warning("Invalid script UUID: \(pathSegments[2])")
      return nil
    }
    let verb = pathSegments[3]
    switch verb {
    case "run":
      return .worktree(id: worktreeID, action: .runScript(scriptID: scriptID))
    case "stop":
      return .worktree(id: worktreeID, action: .stopScript(scriptID: scriptID))
    default:
      logger.warning("Unrecognized script action: \(verb)")
      return nil
    }
  }

  private static func parseWorktreeTab(
    worktreeID: Worktree.ID,
    pathSegments: [String],
    queryItems: [URLQueryItem]
  ) -> Deeplink? {
    // "tab/<tab-uuid>" → focus tab.
    // "tab/new" → create new tab.
    // "tab/<tab-uuid>/destroy" → close tab.
    // "tab/<tab-uuid>/surface/<surface-uuid>" → focus surface.
    // "tab/<tab-uuid>/surface/<surface-uuid>/split" → split surface.
    // "tab/<tab-uuid>/surface/<surface-uuid>/destroy" → close surface.
    guard pathSegments.count >= 3 else {
      logger.warning("Tab deeplink missing sub-action or tab ID")
      return nil
    }
    let thirdSegment = pathSegments[2]

    if thirdSegment == "new" {
      let input = queryItems.first(where: { $0.name == "input" })?.value
      let id = queryItems.first(where: { $0.name == "id" })?.value.flatMap(UUID.init(uuidString:))
      return .worktree(id: worktreeID, action: .tabNew(input: input, id: id))
    }

    guard let tabUUID = UUID(uuidString: thirdSegment) else {
      logger.warning("Invalid tab UUID: \(thirdSegment)")
      return nil
    }

    if pathSegments.count >= 4, pathSegments[3] == "destroy" {
      return .worktree(id: worktreeID, action: .tabDestroy(tabID: tabUUID))
    }

    // Check for surface sub-path: tab/<tab-uuid>/surface/<surface-uuid>[/split|/destroy].
    if pathSegments.count >= 5, pathSegments[3] == "surface" {
      return parseWorktreeSurface(
        worktreeID: worktreeID,
        tabUUID: tabUUID,
        pathSegments: pathSegments,
        queryItems: queryItems,
      )
    }

    return .worktree(id: worktreeID, action: .tab(tabID: tabUUID))
  }

  private static func parseWorktreeSurface(
    worktreeID: Worktree.ID,
    tabUUID: UUID,
    pathSegments: [String],
    queryItems: [URLQueryItem]
  ) -> Deeplink? {
    guard let surfaceUUID = UUID(uuidString: pathSegments[4]) else {
      logger.warning("Invalid surface UUID: \(pathSegments[4])")
      return nil
    }

    let input = queryItems.first(where: { $0.name == "input" })?.value

    if pathSegments.count >= 6, pathSegments[5] == "destroy" {
      return .worktree(
        id: worktreeID,
        action: .surfaceDestroy(tabID: tabUUID, surfaceID: surfaceUUID),
      )
    }

    if pathSegments.count >= 6, pathSegments[5] == "split" {
      let directionRaw = queryItems.first(where: { $0.name == "direction" })?.value ?? "horizontal"
      guard let direction = SplitDirection(rawValue: directionRaw) else {
        logger.warning("Invalid split direction '\(directionRaw)'.")
        return nil
      }
      let id = queryItems.first(where: { $0.name == "id" })?.value.flatMap(UUID.init(uuidString:))
      return .worktree(
        id: worktreeID,
        action: .surfaceSplit(tabID: tabUUID, surfaceID: surfaceUUID, direction: direction, input: input, id: id),
      )
    }

    return .worktree(
      id: worktreeID,
      action: .surface(tabID: tabUUID, surfaceID: surfaceUUID, input: input),
    )
  }

  // MARK: - Repo.

  private static func parseRepo(
    pathSegments: [String],
    queryItems: [URLQueryItem]
  ) -> Deeplink? {
    // "open" → add repository.
    // "<encoded-id>/worktree/new" → create worktree.
    guard let first = pathSegments.first else {
      logger.warning("Repo deeplink missing action or id")
      return nil
    }

    if first == "open" {
      guard let pathValue = queryItems.first(where: { $0.name == "path" })?.value,
        !pathValue.isEmpty, pathValue.hasPrefix("/")
      else {
        logger.warning("Repo open deeplink missing or invalid path query param.")
        return nil
      }
      return .repoOpen(path: URL(fileURLWithPath: pathValue))
    }

    guard let repositoryID = first.removingPercentEncoding, !repositoryID.isEmpty else {
      logger.warning("Failed to percent-decode repository ID")
      return nil
    }
    guard pathSegments.count >= 3,
      pathSegments[1] == "worktree",
      pathSegments[2] == "new"
    else {
      logger.warning("Unrecognized repo deeplink path")
      return nil
    }
    let branch = queryItems.first(where: { $0.name == "branch" })?.value
    let baseRef = queryItems.first(where: { $0.name == "base" })?.value
    let fetchOrigin = queryItems.first(where: { $0.name == "fetch" })?.value == "true"
    return .repoWorktreeNew(
      repositoryID: repositoryID,
      branch: branch,
      baseRef: baseRef,
      fetchOrigin: fetchOrigin,
    )
  }
}
