import Testing

@testable import tty7

struct WorktreeProgressThrottleTests {
  @Test func recordLineEmitsFirstThenEveryStride() {
    var throttle = WorktreeCreationProgressUpdateThrottle(stride: 20)

    var didEmit = throttle.recordLine()
    #expect(didEmit)
    for _ in 0..<19 {
      didEmit = throttle.recordLine()
      #expect(!didEmit)
    }
    didEmit = throttle.recordLine()
    #expect(didEmit)
    let didFlush = throttle.flush()
    #expect(!didFlush)
  }

  @Test func flushEmitsPendingLinesOnce() {
    var throttle = WorktreeCreationProgressUpdateThrottle(stride: 20)

    var didEmit = throttle.recordLine()
    #expect(didEmit)
    didEmit = throttle.recordLine()
    #expect(!didEmit)
    didEmit = throttle.recordLine()
    #expect(!didEmit)
    var didFlush = throttle.flush()
    #expect(didFlush)
    didFlush = throttle.flush()
    #expect(!didFlush)
  }
}
