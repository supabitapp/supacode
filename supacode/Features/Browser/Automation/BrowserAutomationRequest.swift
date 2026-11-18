import Foundation

nonisolated struct BrowserAutomationStep: Decodable, Equatable, Sendable {
  enum Verb: String, Decodable, Equatable, Sendable {
    case navigate
    case snapshot
    case click
    case fill
    case select
    case press
    case wait
  }

  var verb: Verb
  var target: String?
  var text: String?
  var url: String?
  var key: String?
  var option: String?
  var full: Bool?
  var scope: String?
  var hidden: Bool?
  var timeout: Double?

  static let maximumTimeoutSeconds = 600.0

  var boundedTimeout: Duration? {
    timeout.map { .seconds(min(max($0, 0), Self.maximumTimeoutSeconds)) }
  }
}

nonisolated struct BrowserAutomationRequest: Decodable, Equatable, Sendable {
  struct NewTab: Decodable, Equatable, Sendable {
    var url: String?
    var background: Bool?
  }

  var tabID: String?
  var newTab: NewTab?
  var steps: [BrowserAutomationStep]
  var quiet: Bool

  private enum CodingKeys: String, CodingKey {
    case tabID
    case newTab
    case steps
    case quiet
  }

  init(json: String) throws {
    self = try JSONDecoder().decode(Self.self, from: Data(json.utf8))
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    tabID = try container.decodeIfPresent(String.self, forKey: .tabID)
    newTab = try container.decodeIfPresent(NewTab.self, forKey: .newTab)
    steps = try container.decodeIfPresent([BrowserAutomationStep].self, forKey: .steps) ?? []
    quiet = try container.decodeIfPresent(Bool.self, forKey: .quiet) ?? false
  }

  init(
    tabID: String? = nil,
    newTab: NewTab? = nil,
    steps: [BrowserAutomationStep] = [],
    quiet: Bool = false
  ) {
    self.tabID = tabID
    self.newTab = newTab
    self.steps = steps
    self.quiet = quiet
  }
}

nonisolated struct BrowserAutomationResult: Equatable, Sendable {
  var lines: [String] = []
  var failure: String?
  var refusal: String?
  var createdTabID: String?

  func response(nonce: String) -> [String: String] {
    var fields: [String: String] = [:]
    fields["id"] = createdTabID
    var body = lines
    if let failure {
      body.append("failed: \(failure)")
      fields["error"] = "The browser command failed. The reason is in the page output."
    }
    if !body.isEmpty {
      fields["output"] = (["--- page \(nonce) ---"] + body + ["--- end \(nonce) ---"]).joined(separator: "\n")
    }
    if let refusal {
      fields["error"] = refusal
    }
    return fields
  }
}
