// swift-tools-version: 6.0
import PackageDescription

#if TUIST
import ProjectDescription

let packageSettings = PackageSettings(
  productTypes: [
    "Sparkle": .framework,
  ]
)
#endif

let package = Package(
  name: "supacode",
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.7.1"),
    .package(url: "https://github.com/apple/swift-collections", exact: "1.3.0"),
    .package(url: "https://github.com/onevcat/Kingfisher.git", exact: "8.8.0"),
    .package(url: "https://github.com/PostHog/posthog-ios.git", exact: "3.38.0"),
    .package(url: "https://github.com/getsentry/sentry-cocoa/", exact: "9.3.0"),
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.0-beta.2"),
    .package(url: "https://github.com/pointfreeco/swift-case-paths", exact: "1.7.2"),
    .package(url: "https://github.com/pointfreeco/swift-clocks", exact: "1.0.6"),
    .package(url: "https://github.com/pointfreeco/swift-composable-architecture", exact: "1.23.1"),
    .package(url: "https://github.com/pointfreeco/swift-concurrency-extras", exact: "1.3.2"),
    .package(url: "https://github.com/pointfreeco/swift-custom-dump", exact: "1.3.4"),
    .package(url: "https://github.com/pointfreeco/swift-dependencies", exact: "1.10.1"),
    .package(url: "https://github.com/pointfreeco/swift-identified-collections", exact: "1.1.1"),
    .package(url: "https://github.com/pointfreeco/swift-navigation", exact: "2.7.0"),
    .package(url: "https://github.com/pointfreeco/swift-perception", exact: "2.0.9"),
    .package(url: "https://github.com/pointfreeco/swift-sharing", exact: "2.7.4"),
    .package(url: "https://github.com/pointfreeco/xctest-dynamic-overlay", exact: "1.8.1"),
  ]
)
