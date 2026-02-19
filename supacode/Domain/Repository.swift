import Foundation
import IdentifiedCollections

struct Repository: Identifiable, Hashable, Sendable {
  let id: String
  let rootURL: URL
  let name: String
  let worktrees: IdentifiedArrayOf<Worktree>

  var initials: String {
    Self.initials(from: name)
  }

  nonisolated static func name(for rootURL: URL, configuredName: String?) -> String {
    if let configuredName = normalizedConfiguredName(configuredName) {
      return configuredName
    }
    return defaultName(for: rootURL)
  }

  nonisolated static func directoryName(for rootURL: URL, configuredName: String?) -> String {
    guard
      let configuredName = normalizedConfiguredName(configuredName),
      isValidDirectoryName(configuredName)
    else {
      return defaultName(for: rootURL)
    }
    return configuredName
  }

  nonisolated static func normalizedConfiguredName(_ configuredName: String?) -> String? {
    guard let configuredName else { return nil }
    let trimmed = configuredName.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  nonisolated static func isValidDirectoryName(_ name: String) -> Bool {
    guard name != ".", name != ".." else {
      return false
    }
    guard !name.contains("/") else {
      return false
    }
    guard !name.contains("\\") else {
      return false
    }
    guard !name.contains(":") else {
      return false
    }
    return !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
  }

  nonisolated static func defaultName(for rootURL: URL) -> String {
    let name = rootURL.lastPathComponent
    if name.isEmpty {
      return rootURL.path(percentEncoded: false)
    }
    return name
  }

  nonisolated static func initials(from name: String) -> String {
    var parts: [String] = []
    var current = ""
    for character in name {
      if character.isLetter || character.isNumber {
        current.append(character)
      } else if !current.isEmpty {
        parts.append(current)
        current = ""
      }
    }
    if !current.isEmpty {
      parts.append(current)
    }
    let initials: String
    if parts.count >= 2 {
      let first = parts[0].prefix(1)
      let second = parts[1].prefix(1)
      initials = String(first + second)
    } else if let part = parts.first {
      initials = String(part.prefix(2))
    } else {
      initials = String(name.prefix(2))
    }
    return initials.uppercased()
  }
}
