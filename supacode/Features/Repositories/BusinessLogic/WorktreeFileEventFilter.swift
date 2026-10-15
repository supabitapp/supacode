import CoreServices
import Darwin
import Foundation

nonisolated struct WorktreeFileEventFilter {
  private let gitDirectoryPrefix: String

  init(gitDirectoryURL: URL) {
    let path: String
    if let resolved = realpath(gitDirectoryURL.path(percentEncoded: false), nil) {
      path = String(cString: resolved)
      free(resolved)
    } else {
      path = gitDirectoryURL.path(percentEncoded: false)
    }
    gitDirectoryPrefix = path.hasSuffix("/") ? path : path + "/"
  }

  func shouldRefresh(paths: [String], flags: [FSEventStreamEventFlags]) -> Bool {
    guard paths.count == flags.count else { return true }
    let recoveryFlags = FSEventStreamEventFlags(
      kFSEventStreamEventFlagMustScanSubDirs
        | kFSEventStreamEventFlagUserDropped
        | kFSEventStreamEventFlagKernelDropped
        | kFSEventStreamEventFlagEventIdsWrapped
        | kFSEventStreamEventFlagRootChanged
        | kFSEventStreamEventFlagMount
        | kFSEventStreamEventFlagUnmount
    )
    return zip(paths, flags).contains { path, flags in
      flags & recoveryFlags != 0 || isRelevantPath(path)
    }
  }

  private func isRelevantPath(_ path: String) -> Bool {
    guard path.hasPrefix(gitDirectoryPrefix) else { return true }
    let components = path.dropFirst(gitDirectoryPrefix.count).split(separator: "/")
    let name =
      if components.first == "worktrees", components.count >= 3 {
        components[2]
      } else {
        components.first
      }
    return name != "fsmonitor--daemon" && name != "fsmonitor--daemon.ipc"
  }
}
