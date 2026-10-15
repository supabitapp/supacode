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
    let metadataComponents =
      if components.first == "worktrees", components.count >= 3 {
        components.dropFirst(2)
      } else {
        components[...]
      }
    if let name = metadataComponents.first, Self.isDaemonName(name) { return false }
    guard metadataComponents.first == "modules" else { return true }
    return !metadataComponents.indices.contains { index in
      guard Self.isDaemonName(components[index]) else { return false }
      let directory = gitDirectoryPrefix + components[..<index].joined(separator: "/")
      return Self.isGitDirectory(directory)
    }
  }

  private static func isDaemonName(_ name: Substring) -> Bool {
    name == "fsmonitor--daemon" || name == "fsmonitor--daemon.ipc" || name == "fsmonitor--daemon.ipc.lock"
  }

  private static func isGitDirectory(_ path: String) -> Bool {
    let fileManager = FileManager.default
    var isDirectory = ObjCBool(false)
    guard fileManager.fileExists(atPath: path + "/HEAD", isDirectory: &isDirectory), !isDirectory.boolValue else {
      return false
    }
    if fileManager.fileExists(atPath: path + "/objects", isDirectory: &isDirectory), isDirectory.boolValue {
      return true
    }
    return fileManager.fileExists(atPath: path + "/commondir", isDirectory: &isDirectory) && !isDirectory.boolValue
  }
}
