import Testing

@testable import supacode

struct NotificationTextNormalizerTests {
  @Test func stripsInlineMarkdownFormatting() {
    let input = "**Build** finished in `42s`. See [logs](https://example.com)."

    #expect(NotificationTextNormalizer.normalize(input) == "Build finished in 42s. See logs.")
  }

  @Test func stripsBlockMarkdownFormatting() {
    let input = """
      ### Build Status
      - [x] **Done**
      > _Ready_
      ```
      npm test
      ```
      """

    #expect(NotificationTextNormalizer.normalize(input) == "Build Status Done Ready npm test")
  }

  @Test func keepsPlainTextUnchanged() {
    let input = "Build succeeded"

    #expect(NotificationTextNormalizer.normalize(input) == "Build succeeded")
  }
}
