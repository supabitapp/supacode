import Foundation

/// Matches GraphQL validation errors that reject a selected field as unknown on older servers.
nonisolated enum GraphQLFieldRejection {
  /// Names from `fields` that a "Field 'X' doesn't exist" (or "doesn't accept argument") message rejects.
  static func rejectedFields(_ fields: [String], in message: String) -> Set<String> {
    let lowered = message.lowercased()
    var rejected: Set<String> = []
    for field in fields {
      // The verdict must follow the name, or another error's rejection would match a merely echoed field.
      let prefix = "field '\(field.lowercased())' doesn't"
      guard lowered.contains("\(prefix) exist") || lowered.contains("\(prefix) accept") else { continue }
      rejected.insert(field)
    }
    return rejected
  }
}
