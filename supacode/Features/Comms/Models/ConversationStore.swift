import Foundation

struct ConversationStore: Codable, Equatable, Sendable {
  static let schemaVersion = 1
  static let defaultMaxMessagesPerThread = 200

  var schemaVersion = Self.schemaVersion
  var threadsByWorktreeID: [Worktree.ID: ConversationThread] = [:]

  func thread(for worktreeID: Worktree.ID) -> ConversationThread {
    threadsByWorktreeID[worktreeID] ?? ConversationThread(worktreeID: worktreeID)
  }

  func messages(for worktreeID: Worktree.ID, limit: Int? = nil) -> [ConversationMessage] {
    let messages = thread(for: worktreeID).messages
    guard let limit, limit > 0, messages.count > limit else {
      return messages
    }
    return Array(messages.suffix(limit))
  }

  mutating func append(
    _ message: ConversationMessage,
    to worktreeID: Worktree.ID,
    maxMessagesPerThread: Int = Self.defaultMaxMessagesPerThread
  ) {
    var thread = thread(for: worktreeID)
    thread.messages.append(message)
    thread.messages.sort { $0.createdAt < $1.createdAt }
    if thread.messages.count > maxMessagesPerThread {
      thread.messages = Array(thread.messages.suffix(maxMessagesPerThread))
    }
    thread.updatedAt = message.createdAt
    threadsByWorktreeID[worktreeID] = thread
  }
}

struct ConversationThread: Codable, Equatable, Sendable {
  let worktreeID: Worktree.ID
  var updatedAt: Date?
  var messages: [ConversationMessage] = []

  init(
    worktreeID: Worktree.ID,
    updatedAt: Date? = nil,
    messages: [ConversationMessage] = []
  ) {
    self.worktreeID = worktreeID
    self.updatedAt = updatedAt
    self.messages = messages
  }
}

struct ConversationMessage: Identifiable, Codable, Equatable, Sendable {
  struct Sender: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
      case agent
      case human
      case system
    }

    var kind: Kind
    var name: String

    init(kind: Kind, name: String) {
      self.kind = kind
      self.name = name
    }
  }

  let id: UUID
  let sender: Sender
  let title: String?
  let body: String
  let createdAt: Date

  init(
    id: UUID = UUID(),
    sender: Sender,
    title: String?,
    body: String,
    createdAt: Date
  ) {
    self.id = id
    self.sender = sender
    self.title = title?.trimmedNilIfEmpty
    self.body = body
    self.createdAt = createdAt
  }

  var notificationTitle: String {
    title ?? sender.name
  }

  var notificationBody: String {
    guard title != nil else {
      return body
    }
    if sender.name.isEmpty {
      return body
    }
    return sender.name + " — " + body
  }
}

struct ConversationSendRequest: Equatable, Sendable {
  let worktreeID: Worktree.ID
  let senderName: String
  let title: String?
  let body: String

  init(worktreeID: Worktree.ID, senderName: String, title: String?, body: String) {
    self.worktreeID = worktreeID
    self.senderName = senderName
    self.title = title?.trimmedNilIfEmpty
    self.body = body
  }

  func makeMessage(createdAt: Date) -> ConversationMessage {
    ConversationMessage(
      sender: .init(kind: .agent, name: senderName),
      title: title,
      body: body,
      createdAt: createdAt
    )
  }
}

private extension String {
  var trimmedNilIfEmpty: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
