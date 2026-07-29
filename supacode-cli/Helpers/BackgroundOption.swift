import ArgumentParser

/// Shared `--background` opt-out for the commands that otherwise focus their target.
/// No short form: `-b` is unused today but `-f` already means "focused only" on the
/// `list` commands, and a second focus-adjacent letter would read as its inverse.
struct BackgroundOption: ParsableArguments {
  @Flag(
    name: .customLong("background"),
    help: """
      Leave the sidebar selection and keyboard focus where they are. \
      Anything created lands in the background instead of becoming active.
      """
  )
  var background = false

  /// Appends `background=true` only when suppressing, so every focusing URL stays
  /// byte-identical to what the app parsed before the flag existed.
  func applied(to url: String) -> String {
    guard background else { return url }
    return url + (url.contains("?") ? "&" : "?") + "background=true"
  }
}
