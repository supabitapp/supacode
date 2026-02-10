import ComposableArchitecture
import Foundation

nonisolated struct GitDiffEntry: Identifiable, Hashable, Sendable {
  let path: String
  let statusCode: String
  let kind: GitDiffKind
  let originalPath: String?

  var id: String { path }

  var displayPath: String {
    if let originalPath, !originalPath.isEmpty {
      return "\(path) ← \(originalPath)"
    }
    return path
  }
}

nonisolated enum GitDiffKind: Hashable, Sendable {
  case modified
  case added
  case deleted
  case renamed
  case copied
  case untracked
  case conflicted
  case unknown
}

nonisolated enum GitDiffClientError: LocalizedError, Equatable, Sendable {
  case commandFailed(command: String, message: String)

  var errorDescription: String? {
    switch self {
    case .commandFailed(let command, let message):
      if message.isEmpty {
        return "Git command failed: \(command)"
      }
      return "Git command failed: \(command)\n\(message)"
    }
  }
}

nonisolated struct GitDiffClient {
  var statusEntries: @Sendable (URL) async throws -> [GitDiffEntry]
  var diffText: @Sendable (URL, GitDiffEntry) async throws -> String
}

extension GitDiffClient: DependencyKey {
  static let liveValue = GitDiffClient(
    statusEntries: { worktreeRoot in
      let store = GitDiffStore()
      return try await store.statusEntries(worktreeRoot: worktreeRoot)
    },
    diffText: { worktreeRoot, entry in
      let store = GitDiffStore()
      return try await store.diffText(worktreeRoot: worktreeRoot, entry: entry)
    }
  )

  static let testValue = GitDiffClient(
    statusEntries: { _ in [] },
    diffText: { _, _ in "" }
  )
}

extension DependencyValues {
  var gitDiffClient: GitDiffClient {
    get { self[GitDiffClient.self] }
    set { self[GitDiffClient.self] = newValue }
  }
}

nonisolated private struct GitDiffStore {
  struct CommandResult: Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
    let command: String
  }

  func statusEntries(worktreeRoot: URL) async throws -> [GitDiffEntry] {
    let result = try await runGit(
      arguments: [
        "--no-optional-locks",
        "status",
        "--porcelain=v1",
        "-b",
        "-z",
        "-M",
        "-uall",
      ],
      currentDirectoryURL: worktreeRoot
    )
    guard result.exitCode == 0 else {
      throw GitDiffClientError.commandFailed(command: result.command, message: result.stderr)
    }
    return GitDiffStatusParser.parseStatusV1Z(result.stdout)
  }

  func diffText(worktreeRoot: URL, entry: GitDiffEntry) async throws -> String {
    let args: [String]
    if entry.kind == .untracked {
      args = [
        "--no-optional-locks",
        "-c",
        "color.ui=never",
        "diff",
        "--no-index",
        "--",
        "/dev/null",
        entry.path,
      ]
    } else if entry.kind == .renamed || entry.kind == .copied, let originalPath = entry.originalPath {
      args = [
        "--no-optional-locks",
        "-c",
        "color.ui=never",
        "diff",
        "-M",
        "HEAD",
        "--",
        originalPath,
        entry.path,
      ]
    } else {
      args = [
        "--no-optional-locks",
        "-c",
        "color.ui=never",
        "diff",
        "-M",
        "HEAD",
        "--",
        entry.path,
      ]
    }

    let result = try await runGit(arguments: args, currentDirectoryURL: worktreeRoot)
    if result.exitCode != 0 && result.exitCode != 1 {
      throw GitDiffClientError.commandFailed(command: result.command, message: result.stderr)
    }
    return result.stdout
  }

  private func runGit(arguments: [String], currentDirectoryURL: URL) async throws -> CommandResult {
    let envURL = URL(fileURLWithPath: "/usr/bin/env")
    let command = ([envURL.path(percentEncoded: false)] + ["git"] + arguments)
      .joined(separator: " ")

    return try await Task.detached(priority: .userInitiated) {
      let process = Process()
      process.executableURL = envURL
      process.arguments = ["git"] + arguments
      process.currentDirectoryURL = currentDirectoryURL
      process.standardInput = FileHandle.nullDevice

      let stdoutPipe = Pipe()
      let stderrPipe = Pipe()
      process.standardOutput = stdoutPipe
      process.standardError = stderrPipe

      try process.run()

      let stdoutHandle = stdoutPipe.fileHandleForReading
      let stderrHandle = stderrPipe.fileHandleForReading
      let stdoutTask = Task.detached { stdoutHandle.readDataToEndOfFile() }
      let stderrTask = Task.detached { stderrHandle.readDataToEndOfFile() }

      process.waitUntilExit()

      let stdoutData = await stdoutTask.value
      let stderrData = await stderrTask.value
      let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
      let stderr = String(data: stderrData, encoding: .utf8) ?? ""
      return CommandResult(
        stdout: stdout,
        stderr: stderr,
        exitCode: process.terminationStatus,
        command: command
      )
    }.value
  }

}

nonisolated enum GitDiffStatusParser {
  static func parseStatusV1Z(_ output: String) -> [GitDiffEntry] {
    var entries: [GitDiffEntry] = []
    let tokens = output.split(separator: "\0", omittingEmptySubsequences: true)
    var index = 0
    while index < tokens.count {
      let header = String(tokens[index])
      if header.hasPrefix("## ") {
        index += 1
        continue
      }
      if header.count < 3 {
        index += 1
        continue
      }

      let indexStatus = header[header.startIndex]
      let workingStatus = header[header.index(after: header.startIndex)]
      let statusCode = String(header.prefix(2))
      let pathStart = header.index(header.startIndex, offsetBy: 3)
      let path = String(header[pathStart...])

      if indexStatus == "?" && workingStatus == "?" {
        entries.append(
          GitDiffEntry(
            path: path,
            statusCode: "??",
            kind: .untracked,
            originalPath: nil
          )
        )
        index += 1
        continue
      }

      let isRenameOrCopy = indexStatus == "R" || indexStatus == "C" || workingStatus == "R" || workingStatus == "C"
      if isRenameOrCopy && (index + 1) < tokens.count {
        let newPath = String(tokens[index + 1])
        entries.append(
          GitDiffEntry(
            path: newPath,
            statusCode: statusCode,
            kind: kindFrom(indexStatus: indexStatus, workingStatus: workingStatus),
            originalPath: path
          )
        )
        index += 2
        continue
      }

      entries.append(
        GitDiffEntry(
          path: path,
          statusCode: statusCode,
          kind: kindFrom(indexStatus: indexStatus, workingStatus: workingStatus),
          originalPath: nil
        )
      )
      index += 1
    }
    return entries
  }

  private static func kindFrom(indexStatus: Character, workingStatus: Character) -> GitDiffKind {
    if indexStatus == "U" || workingStatus == "U" { return .conflicted }
    if indexStatus == "A" || workingStatus == "A" { return .added }
    if indexStatus == "D" || workingStatus == "D" { return .deleted }
    if indexStatus == "R" || workingStatus == "R" { return .renamed }
    if indexStatus == "C" || workingStatus == "C" { return .copied }
    if indexStatus == "M" || workingStatus == "M" { return .modified }
    if indexStatus == "?" || workingStatus == "?" { return .untracked }
    return .unknown
  }
}
