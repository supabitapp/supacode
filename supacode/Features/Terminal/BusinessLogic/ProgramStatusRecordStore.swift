import Foundation

/// The OSC 7501 records of one terminal: whole-record replacement, subtree
/// `clear`, `app` inheritance and least-recently-updated eviction, plus the
/// prompt rule that ends a program's `working`/`blocked`/`idle` records.
///
/// The rule can't take a prompt at face value: agents nest their own OSC 133
/// marks inside the shell's command. So the store counts command depth
/// (C minus D) and stamps each record with the depth it arrived at; only a
/// prompt below that depth means the shell got control back from the
/// reporter. Lost or extra marks can only miss a drop, never drop a live
/// program's record.
nonisolated struct ProgramStatusRecordStore: Equatable, Sendable {
  /// The protocol's upper bound; terminals must keep at least 64.
  static let capacity = 256

  struct Record: Equatable, Sendable {
    var report: ProgramStatusReport
    var commandDepth: Int
    var updateOrder: UInt64
  }

  /// The coarse view a badge needs: the root record plus whether any child is
  /// working or blocked. Never carries the program's text.
  struct Summary: Equatable, Sendable, CustomStringConvertible {
    var app: String?
    var state: ProgramStatusReport.State?
    var kind: ProgramStatusReport.Kind?
    var hasWorkingChild = false
    var hasBlockedChild = false

    var description: String {
      var parts = ["app=\(app ?? "-")", "state=\(state?.rawValue ?? "-")"]
      if let kind { parts.append("kind=\(kind.rawValue)") }
      if hasWorkingChild { parts.append("workingChild") }
      if hasBlockedChild { parts.append("blockedChild") }
      return parts.joined(separator: " ")
    }
  }

  private(set) var records: [String: Record] = [:]
  /// Signed on purpose: shells emit stray Ds (zsh on an empty line, fish twice
  /// per command), and the gate only compares depths relative to each other.
  private(set) var commandDepth = 0
  private var updateCount: UInt64 = 0

  var summary: Summary {
    let root = records[""]?.report
    let children = records.values.filter { !$0.report.id.isEmpty }
    return Summary(
      app: root.flatMap { effectiveApp(of: $0) },
      state: root?.state,
      kind: root?.kind,
      hasWorkingChild: children.contains { $0.report.state == .working },
      hasBlockedChild: children.contains { $0.report.state == .blocked }
    )
  }

  mutating func apply(_ event: ProgramStatusEvent) {
    switch event {
    case .report(let report):
      updateCount += 1
      records[report.id] = Record(report: report, commandDepth: commandDepth, updateOrder: updateCount)
      if records.count > Self.capacity,
        let oldest = records.min(by: { $0.value.updateOrder < $1.value.updateOrder })
      {
        records.removeValue(forKey: oldest.key)
      }
    case .clear(let id):
      guard !id.isEmpty else {
        records.removeAll()
        return
      }
      records = records.filter { key, _ in key != id && !key.hasPrefix(id + "/") }
    case .commandStart:
      commandDepth += 1
    case .commandEnd:
      commandDepth -= 1
    case .promptStart:
      records = records.filter { _, record in
        !(record.report.state.endsWithProgram && commandDepth < record.commandDepth)
      }
    }
  }

  /// The record's own `app`, else the nearest existing ancestor's. The root
  /// is every record's ultimate ancestor.
  func effectiveApp(of report: ProgramStatusReport) -> String? {
    if let app = report.app { return app }
    guard !report.id.isEmpty else { return nil }
    var id = Substring(report.id)
    while let slash = id.lastIndex(of: "/") {
      id = id[..<slash]
      if let app = records[String(id)]?.report.app { return app }
    }
    return records[""]?.report.app
  }
}
