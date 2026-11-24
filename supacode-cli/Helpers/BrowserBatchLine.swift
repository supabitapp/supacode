import Foundation

nonisolated enum BrowserBatchLine {
  enum Error: Swift.Error, LocalizedError, Equatable {
    case unterminatedQuote
    case trailingBackslash

    var errorDescription: String? {
      switch self {
      case .unterminatedQuote: "A quote is not closed."
      case .trailingBackslash: "The line ends with a backslash that escapes nothing."
      }
    }
  }

  static func tokens(_ line: String) throws -> [String] {
    var tokens: [String] = []
    var current = ""
    var isInToken = false
    var quote: Character?
    var isEscaped = false
    for character in line {
      if isEscaped {
        current.append(character)
        isEscaped = false
      } else if let open = quote {
        if character == open {
          quote = nil
        } else if character == "\\", open == "\"" {
          isEscaped = true
        } else {
          current.append(character)
        }
      } else if character == "\"" || character == "'" {
        quote = character
        isInToken = true
      } else if character == "\\" {
        isEscaped = true
        isInToken = true
      } else if character == "#", !isInToken {
        break
      } else if character.isWhitespace {
        if isInToken {
          tokens.append(current)
          current = ""
          isInToken = false
        }
      } else {
        current.append(character)
        isInToken = true
      }
    }
    guard quote == nil else { throw Error.unterminatedQuote }
    guard !isEscaped else { throw Error.trailingBackslash }
    if isInToken {
      tokens.append(current)
    }
    return tokens
  }
}
