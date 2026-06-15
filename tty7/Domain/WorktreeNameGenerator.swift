import Foundation

enum WorktreeNameGenerator {
  static let adjectives: [String] = [
    "bold",
    "bright",
    "brisk",
    "calm",
    "clever",
    "curious",
    "daring",
    "eager",
    "gentle",
    "happy",
    "jolly",
    "keen",
    "lively",
    "mighty",
    "nimble",
    "noble",
    "playful",
    "proud",
    "quick",
    "quiet",
    "rapid",
    "shy",
    "smart",
    "steady",
    "sunny",
    "swift",
    "witty",
    "zesty",
  ]

  static let animals: [String] = [
    "cat",
    "dog",
    "fox",
    "bear",
    "wolf",
    "lion",
    "tiger",
    "leopard",
    "cheetah",
    "horse",
    "cow",
    "pig",
    "sheep",
    "goat",
    "deer",
    "moose",
    "rabbit",
    "hare",
    "squirrel",
    "otter",
    "beaver",
    "badger",
    "raccoon",
    "panda",
    "koala",
    "kangaroo",
    "monkey",
    "gorilla",
    "lemur",
    "owl",
    "eagle",
    "hawk",
    "falcon",
    "raven",
    "crow",
    "duck",
    "goose",
    "swan",
    "penguin",
    "seal",
    "dolphin",
    "whale",
    "shark",
    "turtle",
    "frog",
    "lizard",
    "octopus",
    "squid",
    "crab",
    "lobster",
    "bee",
    "ant",
    "butterfly",
  ]

  static func nextName(excluding existing: Set<String>) -> String? {
    let normalized = Set(existing.map { $0.lowercased() })
    let randomSuffix = Int.random(in: 0...999)
      .formatted(
        .number
          .grouping(.never)
          .precision(.integerLength(3))
      )
    let available = adjectives.flatMap { adjective in
      animals.map { "\(adjective)-\($0)-\(randomSuffix)" }
    }.filter { !normalized.contains($0) }
    return available.randomElement()
  }
}
