import ComposableArchitecture
import Foundation

/// Process-wide memory-pressure warnings, as a stream the hibernation policy
/// subscribes to once. Injected so a test can drive pressure without the kernel.
struct MemoryPressureClient {
  var warnings: @Sendable () -> AsyncStream<Void>
}

extension MemoryPressureClient: DependencyKey {
  static let liveValue = MemoryPressureClient(
    warnings: {
      AsyncStream { continuation in
        let source = DispatchSource.makeMemoryPressureSource(
          eventMask: [.warning, .critical],
          queue: .main
        )
        source.setEventHandler { continuation.yield() }
        continuation.onTermination = { _ in source.cancel() }
        source.resume()
      }
    }
  )

  // Silent by default: only a test that opts in should see pressure.
  static let testValue = MemoryPressureClient(warnings: { AsyncStream { $0.finish() } })
}
