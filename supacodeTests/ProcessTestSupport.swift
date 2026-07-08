import Foundation

extension Process {
  /// Runs and awaits exit without blocking the calling thread; under the test
  /// main serial executor a blocking waitUntilExit() would monopolize main and
  /// stall every concurrently running test.
  func runToExit() async throws {
    let (exited, continuation) = AsyncStream<Void>.makeStream()
    terminationHandler = { _ in continuation.finish() }
    try run()
    for await _ in exited {}
    // Cancellation ends the iteration with the child still alive; reading
    // terminationStatus then would crash the whole test process.
    guard !Task.isCancelled else {
      if isRunning { terminate() }
      throw CancellationError()
    }
  }
}
