nonisolated struct WorktreeCreationProgress: Hashable, Sendable {
  var stage: WorktreeCreationStage
  var worktreeName: String?
  var baseRef: String?
  var copyIgnored: Bool?
  var copyUntracked: Bool?
  var ignoredFilesToCopyCount: Int?
  var untrackedFilesToCopyCount: Int?
  var fetchRemoteName: String?
  var commandText: String?
  var latestOutputLine: String?
  var outputLines: [String]

  init(
    stage: WorktreeCreationStage,
    worktreeName: String? = nil,
    baseRef: String? = nil,
    copyIgnored: Bool? = nil,
    copyUntracked: Bool? = nil,
    ignoredFilesToCopyCount: Int? = nil,
    untrackedFilesToCopyCount: Int? = nil,
    fetchRemoteName: String? = nil,
    commandText: String? = nil,
    latestOutputLine: String? = nil,
    outputLines: [String] = []
  ) {
    self.stage = stage
    self.worktreeName = worktreeName
    self.baseRef = baseRef
    self.copyIgnored = copyIgnored
    self.copyUntracked = copyUntracked
    self.ignoredFilesToCopyCount = ignoredFilesToCopyCount
    self.untrackedFilesToCopyCount = untrackedFilesToCopyCount
    self.fetchRemoteName = fetchRemoteName
    self.commandText = commandText
    self.latestOutputLine = latestOutputLine
    self.outputLines = outputLines
  }

  var titleText: String {
    if let worktreeName, !worktreeName.isEmpty {
      return "Creating \(worktreeName)"
    }
    return "Creating worktree"
  }

  var detailText: String {
    switch stage {
    case .loadingLocalBranches:
      return "Reading local branches"
    case .choosingWorktreeName:
      return "Choosing available worktree name"
    case .checkingRepositoryMode:
      return "Checking repository mode"
    case .resolvingBaseReference:
      return "Resolving base reference (\(baseRefDisplay))"
    case .fetchingOrigin:
      return "Fetching latest from \(fetchRemoteName ?? "remote")"
    case .creatingWorktree:
      if let outputLine = outputLines.last, !outputLine.isEmpty {
        return outputLine
      }
      if let latestOutputLine, !latestOutputLine.isEmpty {
        return latestOutputLine
      }
      var copyDetails: [String] = []
      if copyIgnored == true {
        let ignoredCount = ignoredFilesToCopyCount ?? 0
        copyDetails.append("Copying \(ignoredCount) ignored files")
      }
      if copyUntracked == true {
        let untrackedCount = untrackedFilesToCopyCount ?? 0
        copyDetails.append("copying \(untrackedCount) untracked files")
      }
      let copySummary = copyDetails.joined(separator: " and ")
      return if copySummary.isEmpty {
        "Creating from \(baseRefBranchDisplay)."
      } else {
        "Creating from \(baseRefBranchDisplay). \(copySummary)"
      }
    }
  }

  var liveOutputLines: [String] {
    guard stage == .creatingWorktree else {
      return []
    }
    if !outputLines.isEmpty {
      return outputLines
    }
    if let latestOutputLine, !latestOutputLine.isEmpty {
      return [latestOutputLine]
    }
    return []
  }

  mutating func appendOutputLine(_ line: String, maxLines: Int) {
    latestOutputLine = line
    outputLines.append(line)
    if outputLines.count > maxLines {
      outputLines.removeFirst(outputLines.count - maxLines)
    }
  }

  private var baseRefDisplay: String {
    guard let baseRef, !baseRef.isEmpty else {
      return "HEAD"
    }
    return baseRef
  }

  private var baseRefBranchDisplay: String {
    let normalized = baseRefDisplay.lowercased()
    if normalized == "main" || normalized == "origin/main" {
      return "main branch"
    }
    if normalized == "head" {
      return "HEAD"
    }
    return "\(baseRefDisplay) branch"
  }
}

nonisolated enum WorktreeCreationStage: Hashable, Sendable {
  case loadingLocalBranches
  case choosingWorktreeName
  case checkingRepositoryMode
  case resolvingBaseReference
  case fetchingOrigin
  case creatingWorktree
}
