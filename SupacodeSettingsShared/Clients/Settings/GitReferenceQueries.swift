import Foundation

private nonisolated let gitReferenceLogger = SupaLogger("Git")

public nonisolated struct GitReferenceQueries: Sendable {
  private let shell: ShellClient

  public init(shell: ShellClient = .live) {
    self.shell = shell
  }

  public func isBareRepository(for repoRoot: URL) async throws -> Bool {
    let output = try await runGit(
      arguments: [
        "-C",
        repoRoot.path(percentEncoded: false),
        "rev-parse",
        "--is-bare-repository",
      ]
    )
    return output.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
  }

  public func branchRefs(for repoRoot: URL) async throws -> [String] {
    let output = try await runGit(
      arguments: [
        "-C",
        repoRoot.path(percentEncoded: false),
        "for-each-ref",
        "--format=%(refname:short)\t%(upstream:short)",
        "refs/heads",
      ]
    )
    let refs = parseLocalRefsWithUpstream(output)
      .filter { !$0.hasSuffix("/HEAD") }
      .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    return deduplicated(refs)
  }

  public func defaultRemoteBranchRef(for repoRoot: URL) async throws -> String? {
    do {
      let output = try await runGit(
        arguments: [
          "-C",
          repoRoot.path(percentEncoded: false),
          "symbolic-ref",
          "-q",
          "refs/remotes/origin/HEAD",
        ]
      )
      let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
      if let resolved = Self.normalizeRemoteRef(trimmed),
        await refExists(resolved, repoRoot: repoRoot)
      {
        return resolved
      }
    } catch {
      gitReferenceLogger.warning(
        "Default remote branch ref failed for \(repoRoot.path(percentEncoded: false)): \(error.localizedDescription)"
      )
    }
    let fallback = "origin/main"
    if await refExists(fallback, repoRoot: repoRoot) {
      return fallback
    }
    return nil
  }

  public func automaticWorktreeBaseRef(for repoRoot: URL) async -> String? {
    let remote = try? await defaultRemoteBranchRef(for: repoRoot)
    if let remote {
      return Self.preferredBaseRef(remote: remote, localHead: nil)
    }
    let localHead = try? await localHeadBranchRef(for: repoRoot)
    let resolvedLocalHead = await resolveLocalHead(localHead, repoRoot: repoRoot)
    return Self.preferredBaseRef(remote: nil, localHead: resolvedLocalHead)
  }

  public static func preferredBaseRef(remote: String?, localHead: String?) -> String? {
    remote ?? localHead
  }

  private func runGit(arguments: [String]) async throws -> String {
    try await shell.run(URL(fileURLWithPath: "/usr/bin/env"), ["git"] + arguments, nil).stdout
  }

  private func parseLocalRefsWithUpstream(_ output: String) -> [String] {
    output
      .split(whereSeparator: \.isNewline)
      .compactMap { line in
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard let local = parts.first else {
          return nil
        }
        let localRef = String(local).trimmingCharacters(in: .whitespacesAndNewlines)
        let upstreamRef =
          parts.count > 1
          ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
          : ""
        if !upstreamRef.isEmpty {
          return upstreamRef
        }
        return localRef.isEmpty ? nil : localRef
      }
  }

  private func deduplicated(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.filter { seen.insert($0).inserted }
  }

  private static func normalizeRemoteRef(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return nil
    }
    let prefix = "refs/remotes/"
    if trimmed.hasPrefix(prefix) {
      return String(trimmed.dropFirst(prefix.count))
    }
    return trimmed
  }

  private func localHeadBranchRef(for repoRoot: URL) async throws -> String? {
    let output = try await runGit(
      arguments: [
        "-C",
        repoRoot.path(percentEncoded: false),
        "symbolic-ref",
        "--short",
        "HEAD",
      ]
    )
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func resolveLocalHead(_ localHead: String?, repoRoot: URL) async -> String? {
    guard let localHead else {
      return nil
    }
    if await refExists(localHead, repoRoot: repoRoot) {
      return localHead
    }
    return nil
  }

  private func refExists(_ ref: String, repoRoot: URL) async -> Bool {
    do {
      _ = try await runGit(
        arguments: [
          "-C",
          repoRoot.path(percentEncoded: false),
          "rev-parse",
          "--verify",
          "--quiet",
          ref,
        ]
      )
      return true
    } catch {
      return false
    }
  }
}
