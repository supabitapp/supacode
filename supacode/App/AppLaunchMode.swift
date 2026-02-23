import Foundation

enum AppLaunchMode: Sendable {
  case normal
  case testing

  static func detect(environment: [String: String], processName: String) -> Self {
    if environment["XCTestConfigurationFilePath"] != nil {
      return .testing
    }
    if processName.lowercased().contains("xctest") {
      return .testing
    }
    return .normal
  }
}
