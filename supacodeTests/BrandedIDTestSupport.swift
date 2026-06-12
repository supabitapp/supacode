@testable import supacode

// String-literal + Comparable ergonomics for the branded id types, scoped to the
// test target. The app target deliberately omits these conformances: on the
// branded structs they add overload candidates that push `RepositoriesFeature`'s
// reducer closures over the Swift type-checker's complexity limit. Tests don't
// have that closure, so they can keep writing `id: "…"` and sorting ids.

extension RepositoryID: @retroactive ExpressibleByStringLiteral {
  public init(stringLiteral value: String) { self.init(value) }
}

extension WorktreeID: @retroactive ExpressibleByStringLiteral {
  public init(stringLiteral value: String) { self.init(value) }
}

extension RepositoryID: @retroactive Comparable {
  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

extension WorktreeID: @retroactive Comparable {
  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
