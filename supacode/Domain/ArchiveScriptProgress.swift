import Foundation

nonisolated struct ArchiveScriptProgress: Hashable, Sendable {
  var titleText: String
  var detailText: String
  var commandText: String?
  var outputLines: [String]

  init(
    titleText: String,
    detailText: String,
    commandText: String? = nil,
    outputLines: [String] = []
  ) {
    self.titleText = titleText
    self.detailText = detailText
    self.commandText = commandText
    self.outputLines = outputLines
  }

  mutating func appendOutputLine(_ line: String, maxLines: Int) {
    detailText = line
    outputLines.append(line)
    if outputLines.count > maxLines {
      outputLines.removeFirst(outputLines.count - maxLines)
    }
  }
}
