import Foundation

enum ScratchPadViewMode: String, CaseIterable, Codable, Sendable {
  case edit
  case split
  case preview
}

enum ScratchPadSyncState: Hashable, Codable, Sendable {
  case saved
  case saving
  case syncing
  case synced
  case failed(String)
}

struct ScratchPadNote: Identifiable, Hashable, Codable, Sendable {
  typealias ID = String

  var id: ID
  var text: String
  var filePath: String?
  var createdAt: Date
  var updatedAt: Date
  var syncedAt: Date?
  var syncState: ScratchPadSyncState

  nonisolated init(
    id: ID = UUID().uuidString,
    text: String = "",
    filePath: String? = nil,
    createdAt: Date = .now,
    updatedAt: Date = .now,
    syncedAt: Date? = nil,
    syncState: ScratchPadSyncState = .saved
  ) {
    self.id = id
    self.text = text
    self.filePath = filePath
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.syncedAt = syncedAt
    self.syncState = syncState
  }

  var isBlankUntitled: Bool {
    filePath == nil && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}
