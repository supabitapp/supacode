import Foundation

public enum CompileTimeProfileError: Error, Equatable {
  case invalidUsage(String)
  case unreadableInput(String)
  case missingBuildTimingSummary
  case serializationFailed
}

public enum CompileTimeEntryKind: String, Codable, Hashable, Sendable {
  case functionBody
  case expressionTypeCheck
}

public enum CompileTimeEntryScope: String, Codable, Hashable, Sendable {
  case local
  case external
}

public struct CompileTimeSourceLocation: Codable, Hashable, Sendable {
  public let path: String
  public let line: Int
  public let column: Int

  public init(path: String, line: Int, column: Int) {
    self.path = path
    self.line = line
    self.column = column
  }
}

public struct CompileTimeEntry: Codable, Hashable, Sendable {
  public let identity: String
  public let kind: CompileTimeEntryKind
  public let scope: CompileTimeEntryScope
  public let durationMilliseconds: Double
  public let location: CompileTimeSourceLocation?
  public let symbol: String

  public init(
    identity: String,
    kind: CompileTimeEntryKind,
    scope: CompileTimeEntryScope,
    durationMilliseconds: Double,
    location: CompileTimeSourceLocation?,
    symbol: String
  ) {
    self.identity = identity
    self.kind = kind
    self.scope = scope
    self.durationMilliseconds = durationMilliseconds
    self.location = location
    self.symbol = symbol
  }
}

public struct BuildStepTiming: Codable, Hashable, Sendable {
  public let name: String
  public let taskCount: Int
  public let durationMilliseconds: Double

  public init(name: String, taskCount: Int, durationMilliseconds: Double) {
    self.name = name
    self.taskCount = taskCount
    self.durationMilliseconds = durationMilliseconds
  }
}

public struct FileTiming: Codable, Hashable, Sendable {
  public let path: String
  public let durationMilliseconds: Double
  public let entryCount: Int

  public init(path: String, durationMilliseconds: Double, entryCount: Int) {
    self.path = path
    self.durationMilliseconds = durationMilliseconds
    self.entryCount = entryCount
  }
}

public struct ProfileSummary: Codable, Hashable, Sendable {
  public let totalBuildDurationMilliseconds: Double
  public let swiftCompileDurationMilliseconds: Double?
  public let localFunctionBodyDurationMilliseconds: Double
  public let localExpressionTypeCheckDurationMilliseconds: Double
  public let localEntryCount: Int
  public let topLocalFiles: [FileTiming]
  public let topLocalFunctions: [CompileTimeEntry]
  public let topLocalExpressions: [CompileTimeEntry]

  public init(
    totalBuildDurationMilliseconds: Double,
    swiftCompileDurationMilliseconds: Double?,
    localFunctionBodyDurationMilliseconds: Double,
    localExpressionTypeCheckDurationMilliseconds: Double,
    localEntryCount: Int,
    topLocalFiles: [FileTiming],
    topLocalFunctions: [CompileTimeEntry],
    topLocalExpressions: [CompileTimeEntry]
  ) {
    self.totalBuildDurationMilliseconds = totalBuildDurationMilliseconds
    self.swiftCompileDurationMilliseconds = swiftCompileDurationMilliseconds
    self.localFunctionBodyDurationMilliseconds = localFunctionBodyDurationMilliseconds
    self.localExpressionTypeCheckDurationMilliseconds = localExpressionTypeCheckDurationMilliseconds
    self.localEntryCount = localEntryCount
    self.topLocalFiles = topLocalFiles
    self.topLocalFunctions = topLocalFunctions
    self.topLocalExpressions = topLocalExpressions
  }
}

public struct ProfileSnapshot: Codable, Hashable, Sendable {
  public let version: Int
  public let generatedAt: String
  public let buildSteps: [BuildStepTiming]
  public let entries: [CompileTimeEntry]
  public let summary: ProfileSummary

  public init(
    version: Int = 1, generatedAt: String, buildSteps: [BuildStepTiming], entries: [CompileTimeEntry],
    summary: ProfileSummary
  ) {
    self.version = version
    self.generatedAt = generatedAt
    self.buildSteps = buildSteps
    self.entries = entries
    self.summary = summary
  }
}

public struct EntryDelta: Codable, Hashable, Sendable {
  public let identity: String
  public let kind: CompileTimeEntryKind
  public let path: String?
  public let symbol: String
  public let baselineDurationMilliseconds: Double
  public let currentDurationMilliseconds: Double
  public let deltaMilliseconds: Double

  public init(
    identity: String,
    kind: CompileTimeEntryKind,
    path: String?,
    symbol: String,
    baselineDurationMilliseconds: Double,
    currentDurationMilliseconds: Double,
    deltaMilliseconds: Double
  ) {
    self.identity = identity
    self.kind = kind
    self.path = path
    self.symbol = symbol
    self.baselineDurationMilliseconds = baselineDurationMilliseconds
    self.currentDurationMilliseconds = currentDurationMilliseconds
    self.deltaMilliseconds = deltaMilliseconds
  }
}

public struct ComparisonSummary: Codable, Hashable, Sendable {
  public let totalBuildDurationDeltaMilliseconds: Double
  public let swiftCompileDurationDeltaMilliseconds: Double?
  public let localFunctionBodyDurationDeltaMilliseconds: Double
  public let localExpressionTypeCheckDurationDeltaMilliseconds: Double

  public init(
    totalBuildDurationDeltaMilliseconds: Double,
    swiftCompileDurationDeltaMilliseconds: Double?,
    localFunctionBodyDurationDeltaMilliseconds: Double,
    localExpressionTypeCheckDurationDeltaMilliseconds: Double
  ) {
    self.totalBuildDurationDeltaMilliseconds = totalBuildDurationDeltaMilliseconds
    self.swiftCompileDurationDeltaMilliseconds = swiftCompileDurationDeltaMilliseconds
    self.localFunctionBodyDurationDeltaMilliseconds = localFunctionBodyDurationDeltaMilliseconds
    self.localExpressionTypeCheckDurationDeltaMilliseconds = localExpressionTypeCheckDurationDeltaMilliseconds
  }
}

public struct ComparisonResult: Codable, Hashable, Sendable {
  public let version: Int
  public let generatedAt: String
  public let summary: ComparisonSummary
  public let regressions: [EntryDelta]
  public let improvements: [EntryDelta]
  public let added: [CompileTimeEntry]
  public let removed: [CompileTimeEntry]

  public init(
    version: Int = 1,
    generatedAt: String,
    summary: ComparisonSummary,
    regressions: [EntryDelta],
    improvements: [EntryDelta],
    added: [CompileTimeEntry],
    removed: [CompileTimeEntry]
  ) {
    self.version = version
    self.generatedAt = generatedAt
    self.summary = summary
    self.regressions = regressions
    self.improvements = improvements
    self.added = added
    self.removed = removed
  }
}

public struct CompileTimeProfiler: Sendable {
  public let repoRoot: URL
  public let topCount: Int

  public init(repoRoot: URL, topCount: Int = 10) {
    self.repoRoot = repoRoot.standardizedFileURL
    self.topCount = topCount
  }

  public func normalize(log: String, generatedAt: Date = .init()) throws -> ProfileSnapshot {
    let lines = log.split(whereSeparator: \.isNewline).map(String.init)
    let entries = mergeEntries(lines.compactMap(parseEntry(line:)))
    let localEntries =
      entries
      .filter { $0.scope == .local }
      .sorted(by: compareEntries)
    let buildSteps = parseBuildSteps(lines: lines)
    guard buildSteps.isEmpty == false else {
      throw CompileTimeProfileError.missingBuildTimingSummary
    }

    let fileTimings = Dictionary(grouping: localEntries, by: { $0.location?.path ?? "<invalid loc>" })
      .map { path, entries in
        FileTiming(
          path: path,
          durationMilliseconds: entries.reduce(0) { $0 + $1.durationMilliseconds },
          entryCount: entries.count
        )
      }
      .sorted(by: compareFileTimings)

    let summary = ProfileSummary(
      totalBuildDurationMilliseconds: buildSteps.reduce(0) { $0 + $1.durationMilliseconds },
      swiftCompileDurationMilliseconds: buildSteps.first(where: { $0.name == "SwiftCompile" })?.durationMilliseconds,
      localFunctionBodyDurationMilliseconds:
        localEntries
        .filter { $0.kind == .functionBody }
        .reduce(0) { $0 + $1.durationMilliseconds },
      localExpressionTypeCheckDurationMilliseconds:
        localEntries
        .filter { $0.kind == .expressionTypeCheck }
        .reduce(0) { $0 + $1.durationMilliseconds },
      localEntryCount: localEntries.count,
      topLocalFiles: Array(fileTimings.prefix(topCount)),
      topLocalFunctions: Array(localEntries.filter { $0.kind == .functionBody }.prefix(topCount)),
      topLocalExpressions: Array(localEntries.filter { $0.kind == .expressionTypeCheck }.prefix(topCount))
    )

    return ProfileSnapshot(
      generatedAt: Self.timestampString(from: generatedAt),
      buildSteps: buildSteps,
      entries: localEntries,
      summary: summary
    )
  }

  public func compare(baseline: ProfileSnapshot, current: ProfileSnapshot, generatedAt: Date = .init())
    -> ComparisonResult
  {
    let baselineByIdentity = Dictionary(uniqueKeysWithValues: baseline.entries.map { ($0.identity, $0) })
    let currentByIdentity = Dictionary(uniqueKeysWithValues: current.entries.map { ($0.identity, $0) })

    let sharedIdentities = Set(baselineByIdentity.keys).intersection(currentByIdentity.keys)
    let regressions = sharedIdentities.compactMap { identity -> EntryDelta? in
      guard let baselineEntry = baselineByIdentity[identity], let currentEntry = currentByIdentity[identity] else {
        return nil
      }
      let delta = currentEntry.durationMilliseconds - baselineEntry.durationMilliseconds
      guard delta > 0 else {
        return nil
      }
      return EntryDelta(
        identity: identity,
        kind: currentEntry.kind,
        path: currentEntry.location?.path,
        symbol: currentEntry.symbol,
        baselineDurationMilliseconds: baselineEntry.durationMilliseconds,
        currentDurationMilliseconds: currentEntry.durationMilliseconds,
        deltaMilliseconds: delta
      )
    }
    .sorted(by: compareDescendingDeltas)

    let improvements = sharedIdentities.compactMap { identity -> EntryDelta? in
      guard let baselineEntry = baselineByIdentity[identity], let currentEntry = currentByIdentity[identity] else {
        return nil
      }
      let delta = currentEntry.durationMilliseconds - baselineEntry.durationMilliseconds
      guard delta < 0 else {
        return nil
      }
      return EntryDelta(
        identity: identity,
        kind: currentEntry.kind,
        path: currentEntry.location?.path,
        symbol: currentEntry.symbol,
        baselineDurationMilliseconds: baselineEntry.durationMilliseconds,
        currentDurationMilliseconds: currentEntry.durationMilliseconds,
        deltaMilliseconds: delta
      )
    }
    .sorted(by: compareAscendingDeltas)

    let added = current.entries
      .filter { baselineByIdentity[$0.identity] == nil }
      .sorted(by: compareEntries)

    let removed = baseline.entries
      .filter { currentByIdentity[$0.identity] == nil }
      .sorted(by: compareEntries)

    let summary = ComparisonSummary(
      totalBuildDurationDeltaMilliseconds: current.summary.totalBuildDurationMilliseconds
        - baseline.summary.totalBuildDurationMilliseconds,
      swiftCompileDurationDeltaMilliseconds: delta(
        lhs: baseline.summary.swiftCompileDurationMilliseconds, rhs: current.summary.swiftCompileDurationMilliseconds),
      localFunctionBodyDurationDeltaMilliseconds: current.summary.localFunctionBodyDurationMilliseconds
        - baseline.summary.localFunctionBodyDurationMilliseconds,
      localExpressionTypeCheckDurationDeltaMilliseconds: current.summary.localExpressionTypeCheckDurationMilliseconds
        - baseline.summary.localExpressionTypeCheckDurationMilliseconds
    )

    return ComparisonResult(
      generatedAt: Self.timestampString(from: generatedAt),
      summary: summary,
      regressions: regressions,
      improvements: improvements,
      added: added,
      removed: removed
    )
  }

  public func decodeSnapshot(data: Data) throws -> ProfileSnapshot {
    try JSONDecoder().decode(ProfileSnapshot.self, from: data)
  }

  public func encodeSnapshot(_ snapshot: ProfileSnapshot) throws -> Data {
    try Self.encoder.encode(snapshot)
  }

  public func encodeComparison(_ comparison: ComparisonResult) throws -> Data {
    try Self.encoder.encode(comparison)
  }

  public func normalizeFile(input: URL, output: URL) throws -> ProfileSnapshot {
    let log = try readString(at: input)
    let snapshot = try normalize(log: log)
    try write(data: encodeSnapshot(snapshot), to: output)
    return snapshot
  }

  public func compareFiles(baseline: URL, current: URL, output: URL) throws -> ComparisonResult {
    let baselineSnapshot = try decodeSnapshot(data: try Data(contentsOf: baseline))
    let currentSnapshot = try decodeSnapshot(data: try Data(contentsOf: current))
    let comparison = compare(baseline: baselineSnapshot, current: currentSnapshot)
    try write(data: encodeComparison(comparison), to: output)
    return comparison
  }

  public static func render(snapshot: ProfileSnapshot) -> String {
    let localFunctionCount = snapshot.entries.filter { $0.kind == .functionBody }.count
    let localExpressionCount = snapshot.entries.filter { $0.kind == .expressionTypeCheck }.count
    var lines: [String] = [
      "Total build: \(format(durationMilliseconds: snapshot.summary.totalBuildDurationMilliseconds))"
    ]

    if let swiftCompileDurationMilliseconds = snapshot.summary.swiftCompileDurationMilliseconds {
      lines.append("SwiftCompile: \(format(durationMilliseconds: swiftCompileDurationMilliseconds))")
    }

    lines.append(
      "Local function bodies: \(format(durationMilliseconds: snapshot.summary.localFunctionBodyDurationMilliseconds)) across \(localFunctionCount) hotspots"
    )
    lines.append(
      "Local expression type checks: \(format(durationMilliseconds: snapshot.summary.localExpressionTypeCheckDurationMilliseconds)) across \(localExpressionCount) hotspots"
    )

    if snapshot.summary.topLocalFunctions.isEmpty == false {
      lines.append("Slowest local functions:")
      lines.append(contentsOf: snapshot.summary.topLocalFunctions.prefix(5).map(render(entry:)))
    }

    if snapshot.summary.topLocalExpressions.isEmpty == false {
      lines.append("Slowest local expressions:")
      lines.append(contentsOf: snapshot.summary.topLocalExpressions.prefix(5).map(render(entry:)))
    }

    return lines.joined(separator: "\n")
  }

  public static func render(comparison: ComparisonResult) -> String {
    var lines: [String] = [
      "Total build delta: \(formatSigned(durationMilliseconds: comparison.summary.totalBuildDurationDeltaMilliseconds))"
    ]

    if let swiftCompileDurationDeltaMilliseconds = comparison.summary.swiftCompileDurationDeltaMilliseconds {
      lines.append("SwiftCompile delta: \(formatSigned(durationMilliseconds: swiftCompileDurationDeltaMilliseconds))")
    }

    lines.append(
      "Local function body delta: \(formatSigned(durationMilliseconds: comparison.summary.localFunctionBodyDurationDeltaMilliseconds))"
    )
    lines.append(
      "Local expression type-check delta: \(formatSigned(durationMilliseconds: comparison.summary.localExpressionTypeCheckDurationDeltaMilliseconds))"
    )

    if comparison.regressions.isEmpty == false {
      lines.append("Worst regressions:")
      lines.append(contentsOf: comparison.regressions.prefix(5).map(render(delta:)))
    }

    if comparison.improvements.isEmpty == false {
      lines.append("Best improvements:")
      lines.append(contentsOf: comparison.improvements.prefix(5).map(render(delta:)))
    }

    if comparison.added.isEmpty == false {
      lines.append("New local hotspots:")
      lines.append(contentsOf: comparison.added.prefix(5).map(render(entry:)))
    }

    if comparison.removed.isEmpty == false {
      lines.append("Removed local hotspots:")
      lines.append(contentsOf: comparison.removed.prefix(5).map(render(entry:)))
    }

    return lines.joined(separator: "\n")
  }

  private func parseEntry(line: String) -> CompileTimeEntry? {
    if let entry = parseTimingLine(line: line) {
      return entry
    }
    if let entry = parseExpressionWarningLine(line: line) {
      return entry
    }
    return nil
  }

  private func parseTimingLine(line: String) -> CompileTimeEntry? {
    let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
    guard parts.count == 3 else {
      return nil
    }
    guard let durationMilliseconds = parseDuration(token: String(parts[0])) else {
      return nil
    }
    let locationToken = String(parts[1])
    let descriptor = String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines)
    let location = parseLocation(token: locationToken)
    let symbol = normalizeDescriptor(descriptor)
    let scope = location.map { classify(location: $0) } ?? .external

    return CompileTimeEntry(
      identity: entryIdentity(kind: .functionBody, location: location, symbol: symbol),
      kind: .functionBody,
      scope: scope,
      durationMilliseconds: durationMilliseconds,
      location: location,
      symbol: symbol
    )
  }

  private func parseExpressionWarningLine(line: String) -> CompileTimeEntry? {
    guard let range = line.range(of: ": warning: expression took ") else {
      return nil
    }
    let locationToken = String(line[..<range.lowerBound])
    let message = String(line[range.upperBound...])
    guard let location = parseLocation(token: locationToken) else {
      return nil
    }
    guard
      let durationToken = message.split(separator: " ").first,
      let durationMilliseconds = Double(String(durationToken).replacingOccurrences(of: "ms", with: ""))
    else {
      return nil
    }
    let symbol = "expression type-check"

    return CompileTimeEntry(
      identity: entryIdentity(kind: .expressionTypeCheck, location: location, symbol: symbol),
      kind: .expressionTypeCheck,
      scope: classify(location: location),
      durationMilliseconds: durationMilliseconds,
      location: location,
      symbol: symbol
    )
  }

  private func parseBuildSteps(lines: [String]) -> [BuildStepTiming] {
    var steps: [BuildStepTiming] = []
    var isInSummary = false

    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed == "Build Timing Summary" {
        isInSummary = true
        continue
      }
      guard isInSummary else {
        continue
      }
      if trimmed.isEmpty {
        continue
      }
      if trimmed.hasPrefix("** BUILD ") {
        break
      }
      if let step = parseBuildStep(line: trimmed) {
        steps.append(step)
      }
    }

    return steps.sorted(by: compareBuildSteps)
  }

  private func parseBuildStep(line: String) -> BuildStepTiming? {
    guard let pipeIndex = line.lastIndex(of: "|") else {
      return nil
    }
    let leftSide = line[..<pipeIndex].trimmingCharacters(in: .whitespaces)
    let rightSide = line[line.index(after: pipeIndex)...].trimmingCharacters(in: .whitespaces)
    guard rightSide.hasSuffix("seconds"),
      let durationSeconds = Double(
        rightSide.replacingOccurrences(of: "seconds", with: "").trimmingCharacters(in: .whitespaces))
    else {
      return nil
    }
    guard let openParen = leftSide.lastIndex(of: "("), let closeParen = leftSide.lastIndex(of: ")"),
      openParen < closeParen
    else {
      return nil
    }
    let name = leftSide[..<openParen].trimmingCharacters(in: .whitespaces)
    let taskToken = leftSide[leftSide.index(after: openParen)..<closeParen]
      .replacingOccurrences(of: "tasks", with: "")
      .replacingOccurrences(of: "task", with: "")
      .trimmingCharacters(in: .whitespaces)
    guard let taskCount = Int(taskToken) else {
      return nil
    }
    return BuildStepTiming(name: name, taskCount: taskCount, durationMilliseconds: durationSeconds * 1000)
  }

  private func parseDuration(token: String) -> Double? {
    if token.hasSuffix("ms"), let value = Double(token.dropLast(2)) {
      return value
    }
    if token.hasSuffix("s"), let value = Double(token.dropLast()) {
      return value * 1000
    }
    return nil
  }

  private func parseLocation(token: String) -> CompileTimeSourceLocation? {
    guard token != "<invalid loc>" else {
      return nil
    }
    guard let lastColon = token.lastIndex(of: ":") else {
      return nil
    }
    let columnToken = token[token.index(after: lastColon)...]
    guard let column = Int(columnToken) else {
      return nil
    }
    let beforeColumn = token[..<lastColon]
    guard let secondColon = beforeColumn.lastIndex(of: ":") else {
      return nil
    }
    let lineToken = beforeColumn[beforeColumn.index(after: secondColon)...]
    guard let line = Int(lineToken) else {
      return nil
    }
    let path = String(beforeColumn[..<secondColon])
    return CompileTimeSourceLocation(path: normalize(path: path), line: line, column: column)
  }

  private func normalizeDescriptor(_ descriptor: String) -> String {
    guard let atIndex = descriptor.lastIndex(of: "@") else {
      return descriptor
    }
    let suffix = String(descriptor[descriptor.index(after: atIndex)...])
    if suffix == "<invalid loc>" || parseLocation(token: suffix) != nil {
      return String(descriptor[..<atIndex])
    }
    return descriptor
  }

  private func classify(location: CompileTimeSourceLocation) -> CompileTimeEntryScope {
    if location.path.hasPrefix("Tuist/") || location.path.hasPrefix("ThirdParty/") {
      return .external
    }
    if location.path.hasPrefix("/") {
      return .external
    }
    return .local
  }

  private func normalize(path: String) -> String {
    let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
    let rootPath = repoRoot.path
    if standardizedPath == rootPath {
      return "."
    }
    if standardizedPath.hasPrefix(rootPath + "/") {
      return String(standardizedPath.dropFirst(rootPath.count + 1))
    }
    return standardizedPath
  }

  private func entryIdentity(kind: CompileTimeEntryKind, location: CompileTimeSourceLocation?, symbol: String) -> String
  {
    let path = location?.path ?? "<invalid loc>"
    let line = location?.line ?? 0
    let column = location?.column ?? 0
    return "\(kind.rawValue)|\(path)|\(line)|\(column)|\(symbol)"
  }

  private func readString(at url: URL) throws -> String {
    guard let value = try String(contentsOf: url, encoding: .utf8) as String? else {
      throw CompileTimeProfileError.unreadableInput(url.path)
    }
    return value
  }

  private func write(data: Data, to url: URL) throws {
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
    try data.write(to: url)
  }

  private func delta(lhs: Double?, rhs: Double?) -> Double? {
    switch (lhs, rhs) {
    case (.some(let lhs), .some(let rhs)):
      return rhs - lhs
    default:
      return nil
    }
  }

  private func mergeEntries(_ entries: [CompileTimeEntry]) -> [CompileTimeEntry] {
    Dictionary(grouping: entries, by: \.identity)
      .values
      .compactMap { group in
        group.max { lhs, rhs in
          lhs.durationMilliseconds < rhs.durationMilliseconds
        }
      }
  }

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
  }()

  private static func timestampString(from date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }
}

private func render(entry: CompileTimeEntry) -> String {
  let path = entry.location.map { "\($0.path):\($0.line):\($0.column)" } ?? "<invalid loc>"
  return "  \(CompileTimeProfiler.format(durationMilliseconds: entry.durationMilliseconds))  \(path)  \(entry.symbol)"
}

private func render(delta: EntryDelta) -> String {
  let path = delta.path ?? "<invalid loc>"
  return
    "  \(CompileTimeProfiler.formatSigned(durationMilliseconds: delta.deltaMilliseconds))  \(path)  \(delta.symbol)"
}

private func compareEntries(lhs: CompileTimeEntry, rhs: CompileTimeEntry) -> Bool {
  if lhs.durationMilliseconds != rhs.durationMilliseconds {
    return lhs.durationMilliseconds > rhs.durationMilliseconds
  }
  return lhs.identity < rhs.identity
}

private func compareFileTimings(lhs: FileTiming, rhs: FileTiming) -> Bool {
  if lhs.durationMilliseconds != rhs.durationMilliseconds {
    return lhs.durationMilliseconds > rhs.durationMilliseconds
  }
  return lhs.path < rhs.path
}

private func compareDescendingDeltas(lhs: EntryDelta, rhs: EntryDelta) -> Bool {
  if lhs.deltaMilliseconds != rhs.deltaMilliseconds {
    return lhs.deltaMilliseconds > rhs.deltaMilliseconds
  }
  return lhs.identity < rhs.identity
}

private func compareAscendingDeltas(lhs: EntryDelta, rhs: EntryDelta) -> Bool {
  if lhs.deltaMilliseconds != rhs.deltaMilliseconds {
    return lhs.deltaMilliseconds < rhs.deltaMilliseconds
  }
  return lhs.identity < rhs.identity
}

private func compareBuildSteps(lhs: BuildStepTiming, rhs: BuildStepTiming) -> Bool {
  if lhs.durationMilliseconds != rhs.durationMilliseconds {
    return lhs.durationMilliseconds > rhs.durationMilliseconds
  }
  return lhs.name < rhs.name
}

extension CompileTimeProfiler {
  public static func format(durationMilliseconds: Double) -> String {
    if durationMilliseconds >= 1000 {
      return String(format: "%.2fs", durationMilliseconds / 1000)
    }
    return String(format: "%.2fms", durationMilliseconds)
  }

  public static func formatSigned(durationMilliseconds: Double) -> String {
    let prefix = durationMilliseconds >= 0 ? "+" : "-"
    return prefix + format(durationMilliseconds: abs(durationMilliseconds))
  }
}
