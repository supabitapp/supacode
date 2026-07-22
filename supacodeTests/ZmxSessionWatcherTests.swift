import ConcurrencyExtras
import Darwin
import Dependencies
import Foundation
import SupacodeSettingsShared
import Testing

@testable import supacode

/// Byte fixtures mirroring zmx's IPC framing and OSC sequences, built from the
/// wire shapes in `ThirdParty/zmx/src/ipc.zig`.
private enum ZmxWireFixture {
  static let esc: UInt8 = 0x1B
  static let bel: UInt8 = 0x07
  static let backslash: UInt8 = 0x5C
  static let openBracket: UInt8 = 0x5D

  /// An 8-byte header (tag, little-endian u32 length, 3 padding bytes) followed
  /// by the payload, matching `asBytes(&Header)` with `@sizeOf(Header) == 8`.
  static func frame(tag: UInt8, payload: [UInt8]) -> [UInt8] {
    let length = UInt32(payload.count)
    var bytes: [UInt8] = [
      tag,
      UInt8(length & 0xFF),
      UInt8((length >> 8) & 0xFF),
      UInt8((length >> 16) & 0xFF),
      UInt8((length >> 24) & 0xFF),
      0, 0, 0,
    ]
    bytes.append(contentsOf: payload)
    return bytes
  }

  /// A raw 8-byte header with an arbitrary declared length, for the oversized
  /// desync case (no real payload appended).
  static func header(tag: UInt8, declaredLength: UInt32) -> [UInt8] {
    [
      tag,
      UInt8(declaredLength & 0xFF),
      UInt8((declaredLength >> 8) & 0xFF),
      UInt8((declaredLength >> 16) & 0xFF),
      UInt8((declaredLength >> 24) & 0xFF),
      0, 0, 0,
    ]
  }

  static func oscBEL(_ code: Int, _ data: String) -> [UInt8] {
    var bytes: [UInt8] = [esc, openBracket]
    bytes.append(contentsOf: Array("\(code);\(data)".utf8))
    bytes.append(bel)
    return bytes
  }

  static func oscST(_ code: Int, _ data: String) -> [UInt8] {
    var bytes: [UInt8] = [esc, openBracket]
    bytes.append(contentsOf: Array("\(code);\(data)".utf8))
    bytes.append(contentsOf: [esc, backslash])
    return bytes
  }

  static func bytes(_ string: String) -> [UInt8] { Array(string.utf8) }
}

// MARK: - OSC scanner

@Suite(.serialized)
struct ZmxOSCScannerTests {
  @Test func extractsSingleBELTerminatedSequence() {
    var scanner = ZmxOSCScanner()
    let result = scanner.scan(ZmxWireFixture.oscBEL(9, "hello"))
    #expect(result == [ZmxOSCSequence(code: 9, payload: ZmxWireFixture.bytes("hello"))])
  }

  @Test func extractsSTTerminatedSequence() {
    var scanner = ZmxOSCScanner()
    let result = scanner.scan(ZmxWireFixture.oscST(0, "my title"))
    #expect(result == [ZmxOSCSequence(code: 0, payload: ZmxWireFixture.bytes("my title"))])
  }

  @Test func parsesCodeOnlySequenceWithoutSeparator() {
    var scanner = ZmxOSCScanner()
    var seq: [UInt8] = [ZmxWireFixture.esc, ZmxWireFixture.openBracket]
    seq.append(contentsOf: ZmxWireFixture.bytes("112"))
    seq.append(ZmxWireFixture.bel)
    let result = scanner.scan(seq)
    #expect(result == [ZmxOSCSequence(code: 112, payload: [])])
  }

  @Test func reassemblesSequenceSplitByteByByte() {
    var scanner = ZmxOSCScanner()
    var collected: [ZmxOSCSequence] = []
    for byte in ZmxWireFixture.oscBEL(3008, "{\"event\":\"idle\"}") {
      collected.append(contentsOf: scanner.scan([byte]))
    }
    #expect(collected == [ZmxOSCSequence(code: 3008, payload: ZmxWireFixture.bytes("{\"event\":\"idle\"}"))])
  }

  @Test func reassemblesSTTerminatorSplitAcrossReads() {
    var scanner = ZmxOSCScanner()
    // Split between the ESC and the `\` of the ST terminator.
    let full = ZmxWireFixture.oscST(7, "file:///tmp")
    let head = Array(full.dropLast())
    let tail = [full.last!]
    #expect(scanner.scan(head).isEmpty)
    let result = scanner.scan(tail)
    #expect(result == [ZmxOSCSequence(code: 7, payload: ZmxWireFixture.bytes("file:///tmp"))])
  }

  @Test func discardsInterleavedNonOSCBytes() {
    var scanner = ZmxOSCScanner()
    var stream = ZmxWireFixture.bytes("plain shell output\r\n")
    stream.append(contentsOf: ZmxWireFixture.oscBEL(9, "notify"))
    stream.append(contentsOf: ZmxWireFixture.bytes("more output"))
    let result = scanner.scan(stream)
    #expect(result == [ZmxOSCSequence(code: 9, payload: ZmxWireFixture.bytes("notify"))])
  }

  @Test func emitsMultipleSequencesInOneChunk() {
    var scanner = ZmxOSCScanner()
    var stream = ZmxWireFixture.oscBEL(0, "title")
    stream.append(contentsOf: ZmxWireFixture.oscST(3008, "busy"))
    stream.append(contentsOf: ZmxWireFixture.oscBEL(9, "done"))
    let result = scanner.scan(stream)
    #expect(
      result == [
        ZmxOSCSequence(code: 0, payload: ZmxWireFixture.bytes("title")),
        ZmxOSCSequence(code: 3008, payload: ZmxWireFixture.bytes("busy")),
        ZmxOSCSequence(code: 9, payload: ZmxWireFixture.bytes("done")),
      ]
    )
  }

  @Test func dropsOversizedSequenceWithoutLosingTheNextOne() {
    var scanner = ZmxOSCScanner()
    var stream = ZmxWireFixture.oscBEL(9, String(repeating: "x", count: ZmxOSCScanner.maxSequenceLength + 500))
    stream.append(contentsOf: ZmxWireFixture.oscBEL(3008, "ok"))
    let result = scanner.scan(stream)
    #expect(result == [ZmxOSCSequence(code: 3008, payload: ZmxWireFixture.bytes("ok"))])
  }

  @Test func abandonsSequenceOnMalformedInnerEscape() {
    var scanner = ZmxOSCScanner()
    // ESC inside the OSC not followed by `\` abandons the sequence; a fresh
    // ESC ] then opens the next, which is emitted.
    var stream: [UInt8] = [ZmxWireFixture.esc, ZmxWireFixture.openBracket]
    stream.append(contentsOf: ZmxWireFixture.bytes("9;partial"))
    stream.append(ZmxWireFixture.esc)
    stream.append(0x41)  // 'A', not backslash.
    stream.append(contentsOf: ZmxWireFixture.oscBEL(2, "recovered"))
    let result = scanner.scan(stream)
    #expect(result == [ZmxOSCSequence(code: 2, payload: ZmxWireFixture.bytes("recovered"))])
  }

  @Test func dropsNonNumericCode() {
    var scanner = ZmxOSCScanner()
    var seq: [UInt8] = [ZmxWireFixture.esc, ZmxWireFixture.openBracket]
    seq.append(contentsOf: ZmxWireFixture.bytes("L;label"))
    seq.append(ZmxWireFixture.bel)
    #expect(scanner.scan(seq).isEmpty)
  }
}

// MARK: - IPC frame decoder

@Suite(.serialized)
struct ZmxIPCFrameDecoderTests {
  @Test func decodesSingleFrame() throws {
    var decoder = ZmxIPCFrameDecoder()
    let frame = ZmxWireFixture.frame(tag: ZmxIPCTag.output, payload: ZmxWireFixture.bytes("hello"))
    let frames = try decoder.decode(frame)
    #expect(frames == [ZmxIPCFrame(tag: ZmxIPCTag.output, payload: ZmxWireFixture.bytes("hello"))])
  }

  @Test func decodesTwoFramesInOneChunk() throws {
    var decoder = ZmxIPCFrameDecoder()
    var chunk = ZmxWireFixture.frame(tag: ZmxIPCTag.output, payload: ZmxWireFixture.bytes("a"))
    chunk.append(contentsOf: ZmxWireFixture.frame(tag: ZmxIPCTag.output, payload: ZmxWireFixture.bytes("bb")))
    let frames = try decoder.decode(chunk)
    #expect(
      frames == [
        ZmxIPCFrame(tag: ZmxIPCTag.output, payload: ZmxWireFixture.bytes("a")),
        ZmxIPCFrame(tag: ZmxIPCTag.output, payload: ZmxWireFixture.bytes("bb")),
      ]
    )
  }

  @Test func buffersPartialHeaderAcrossReads() throws {
    var decoder = ZmxIPCFrameDecoder()
    let frame = ZmxWireFixture.frame(tag: ZmxIPCTag.output, payload: ZmxWireFixture.bytes("split"))
    #expect(try decoder.decode(Array(frame.prefix(5))).isEmpty)
    let frames = try decoder.decode(Array(frame.dropFirst(5)))
    #expect(frames == [ZmxIPCFrame(tag: ZmxIPCTag.output, payload: ZmxWireFixture.bytes("split"))])
  }

  @Test func buffersPartialPayloadAcrossReads() throws {
    var decoder = ZmxIPCFrameDecoder()
    let frame = ZmxWireFixture.frame(tag: ZmxIPCTag.output, payload: ZmxWireFixture.bytes("payload"))
    // Header plus two payload bytes, then the remainder.
    #expect(try decoder.decode(Array(frame.prefix(ZmxIPCFrameDecoder.headerSize + 2))).isEmpty)
    let frames = try decoder.decode(Array(frame.dropFirst(ZmxIPCFrameDecoder.headerSize + 2)))
    #expect(frames == [ZmxIPCFrame(tag: ZmxIPCTag.output, payload: ZmxWireFixture.bytes("payload"))])
  }

  @Test func yieldsUnknownTagForTheConsumerToSkip() throws {
    var decoder = ZmxIPCFrameDecoder()
    let unknownTag: UInt8 = 99
    let frame = ZmxWireFixture.frame(tag: unknownTag, payload: ZmxWireFixture.bytes("x"))
    let frames = try decoder.decode(frame)
    #expect(frames.count == 1)
    #expect(frames[0].tag == unknownTag)
    // A passive client keeps only `.Output`; the unknown tag is skipped.
    #expect(frames.filter { $0.tag == ZmxIPCTag.output }.isEmpty)
  }

  @Test func skipsEmptyPayloadFrame() throws {
    var decoder = ZmxIPCFrameDecoder()
    // A TaskComplete-style frame carrying a single byte, then an Output frame.
    var chunk = ZmxWireFixture.frame(tag: 13, payload: [7])
    chunk.append(contentsOf: ZmxWireFixture.frame(tag: ZmxIPCTag.output, payload: ZmxWireFixture.bytes("hi")))
    let frames = try decoder.decode(chunk)
    #expect(frames.count == 2)
    #expect(frames[0] == ZmxIPCFrame(tag: 13, payload: [7]))
    #expect(frames[1] == ZmxIPCFrame(tag: ZmxIPCTag.output, payload: ZmxWireFixture.bytes("hi")))
  }

  @Test func throwsOnOversizedDeclaredLength() {
    var decoder = ZmxIPCFrameDecoder()
    let oversized = UInt32(ZmxIPCFrameDecoder.maxPayloadSize + 1)
    let header = ZmxWireFixture.header(tag: ZmxIPCTag.output, declaredLength: oversized)
    #expect(throws: ZmxIPCFrameDecoder.DecodeError.payloadTooLarge(oversized)) {
      _ = try decoder.decode(header)
    }
  }
}

// MARK: - Watcher lifecycle (fake socket server)

/// Minimal AF_UNIX server that accepts one connection, writes canned framed
/// bytes, and holds the connection open so the watcher stays connected until
/// teardown. Deterministic: no real zmx involved.
private final class FakeZmxDaemon {
  let path: String
  private let listenFD: Int32
  private let stopped = LockIsolated(false)

  init?(explicitPath: String? = nil) {
    self.path = explicitPath ?? "/tmp/zmxw-\(UUID().uuidString.prefix(8)).sock"
    unlink(path)
    let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
    guard socketFD >= 0 else { return nil }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = path.utf8CString
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
      close(socketFD)
      return nil
    }
    _ = withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
      pathBytes.withUnsafeBufferPointer { buffer in
        memcpy(sunPath, buffer.baseAddress!, buffer.count)
      }
    }
    let addrLen = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
    let bindResult = withUnsafePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, addrLen) }
    }
    guard bindResult == 0, listen(socketFD, 4) == 0 else {
      close(socketFD)
      return nil
    }
    self.listenFD = socketFD
  }

  /// Accepts one connection, writes `payload`, holds it open until `stop()`.
  func serveOnce(payload: [UInt8]) {
    serve(payload: payload, loop: false, closeAfterWrite: false)
  }

  /// Accepts connections and writes `payload` to each. When `closeAfterWrite`
  /// the client is closed right after the write (the watcher sees EOF or, for a
  /// garbage payload, a desync); otherwise the connection is held open. When
  /// `loop` the daemon keeps accepting so the watcher can reconnect.
  func serve(payload: [UInt8], loop: Bool, closeAfterWrite: Bool) {
    let listenFD = self.listenFD
    let stopped = self.stopped
    let thread = Thread {
      var pollFD = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
      while !stopped.value {
        guard poll(&pollFD, 1, 100) > 0 else { continue }
        let clientFD = accept(listenFD, nil, nil)
        guard clientFD >= 0 else { continue }
        // A reconnecting watcher may close its end mid-write; suppress SIGPIPE
        // so the write just fails instead of killing the test process.
        var noSIGPIPE: Int32 = 1
        _ = setsockopt(
          clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSIGPIPE, socklen_t(MemoryLayout<Int32>.size))
        payload.withUnsafeBytes { raw in
          if let base = raw.baseAddress { _ = write(clientFD, base, raw.count) }
        }
        if closeAfterWrite {
          close(clientFD)
        } else {
          while !stopped.value { usleep(50_000) }
          close(clientFD)
        }
        if !loop { return }
      }
    }
    thread.name = "fake-zmx-daemon"
    thread.start()
  }

  /// Accepts connections and, per connection, writes `prelude`, waits past one
  /// watcher poll so it lands in its own read, then writes `payload` and closes.
  /// Lets the watcher deliver a valid frame before a desyncing garbage header in
  /// the same cycle. `loop` keeps accepting so the watcher can reconnect.
  func serveSplit(prelude: [UInt8], then payload: [UInt8], loop: Bool) {
    let listenFD = self.listenFD
    let stopped = self.stopped
    let thread = Thread {
      var pollFD = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
      while !stopped.value {
        guard poll(&pollFD, 1, 100) > 0 else { continue }
        let clientFD = accept(listenFD, nil, nil)
        guard clientFD >= 0 else { continue }
        var noSIGPIPE: Int32 = 1
        _ = setsockopt(
          clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSIGPIPE, socklen_t(MemoryLayout<Int32>.size))
        prelude.withUnsafeBytes { raw in
          if let base = raw.baseAddress { _ = write(clientFD, base, raw.count) }
        }
        // Longer than the watcher poll timeout so the prelude is read in its own
        // cycle before the garbage arrives.
        usleep(120_000)
        payload.withUnsafeBytes { raw in
          if let base = raw.baseAddress { _ = write(clientFD, base, raw.count) }
        }
        close(clientFD)
        if !loop { return }
      }
    }
    thread.name = "fake-zmx-daemon"
    thread.start()
  }

  func stop() {
    stopped.setValue(true)
    close(listenFD)
    unlink(path)
  }
}

/// Real-time budget for watcher signals delivered off the reader thread.
/// Generous so a saturated CI machine cannot starve a passing run into a
/// timeout; only a failing run ever waits this long.
private enum ZmxTestBudget {
  static let signalTimeout: TimeInterval = 30
}

@MainActor
@Suite(.serialized)
struct ZmxSessionWatcherLifecycleTests {
  /// Tiny backoff so give-up runs in milliseconds without real sleeps.
  private static let fastTuning = ZmxSessionWatcher.Tuning(
    maxConnectAttempts: 6,
    baseBackoffMilliseconds: 1,
    maxBackoffMilliseconds: 5,
    pollTimeoutMilliseconds: 50,
    minHealthyConnectionMilliseconds: 1000
  )

  @Test func connectsReadsAndEmitsOSCSequences() {
    guard let daemon = FakeZmxDaemon() else {
      Issue.record("Failed to bind fake zmx daemon socket")
      return
    }
    defer { daemon.stop() }
    let frame = ZmxWireFixture.frame(
      tag: ZmxIPCTag.output,
      payload: ZmxWireFixture.oscBEL(9, "ping")
    )
    daemon.serveOnce(payload: frame)

    let received = LockIsolated<[ZmxOSCSequence]>([])
    let semaphore = DispatchSemaphore(value: 0)
    let watcher = ZmxSessionWatcher(surfaceID: UUID(), socketPath: daemon.path) { sequences in
      received.withValue { $0.append(contentsOf: sequences) }
      semaphore.signal()
    }
    watcher.start()
    defer { watcher.stop() }

    #expect(semaphore.wait(timeout: .now() + ZmxTestBudget.signalTimeout) == .success)
    #expect(received.value == [ZmxOSCSequence(code: 9, payload: ZmxWireFixture.bytes("ping"))])
  }

  @Test func startsAtMostOneThread() {
    // A double start must not spawn a second reader; stop stays safe to call.
    let watcher = ZmxSessionWatcher(surfaceID: UUID(), socketPath: "/tmp/zmxw-missing.sock") { _ in }
    watcher.start()
    watcher.start()
    watcher.stop()
  }

  @Test func reconnectsAndResumesAfterEOF() {
    guard let daemon = FakeZmxDaemon() else {
      Issue.record("Failed to bind fake zmx daemon socket")
      return
    }
    defer { daemon.stop() }
    let frame = ZmxWireFixture.frame(
      tag: ZmxIPCTag.output,
      payload: ZmxWireFixture.oscBEL(9, "ping")
    )
    // Each accept writes one frame then drops the connection; the watcher must
    // reconnect and keep delivering.
    daemon.serve(payload: frame, loop: true, closeAfterWrite: true)

    let deliveries = LockIsolated(0)
    let resumed = DispatchSemaphore(value: 0)
    let watcher = ZmxSessionWatcher(
      surfaceID: UUID(), socketPath: daemon.path, tuning: Self.fastTuning
    ) { _ in
      let count = deliveries.withValue {
        $0 += 1
        return $0
      }
      if count >= 2 { resumed.signal() }
    }
    watcher.start()
    defer { watcher.stop() }

    #expect(resumed.wait(timeout: .now() + ZmxTestBudget.signalTimeout) == .success)
  }

  @Test func givesUpAfterExhaustingBudgetOnDeadSocket() {
    let finished = DispatchSemaphore(value: 0)
    let delivered = LockIsolated(false)
    let watcher = ZmxSessionWatcher(
      surfaceID: UUID(),
      socketPath: "/tmp/zmxw-nonexistent-\(UUID().uuidString.prefix(8)).sock",
      tuning: Self.fastTuning,
      onReaderFinished: { finished.signal() },
      onSequences: { _ in delivered.setValue(true) }
    )
    watcher.start()
    defer { watcher.stop() }

    #expect(finished.wait(timeout: .now() + ZmxTestBudget.signalTimeout) == .success)
    #expect(delivered.value == false)
  }

  @Test func givesUpWhenDaemonAlwaysDesyncs() {
    guard let daemon = FakeZmxDaemon() else {
      Issue.record("Failed to bind fake zmx daemon socket")
      return
    }
    defer { daemon.stop() }
    // Each cycle delivers a valid frame first, then an 8-byte header declaring an
    // impossible payload length: decode throws `payloadTooLarge`. A desync must
    // charge the budget even after a frame was delivered, so a chatty-but-corrupt
    // daemon still gives up instead of resetting the budget and looping forever.
    let prelude = ZmxWireFixture.frame(
      tag: ZmxIPCTag.output,
      payload: ZmxWireFixture.oscBEL(9, "ping")
    )
    let garbage = ZmxWireFixture.header(
      tag: ZmxIPCTag.output,
      declaredLength: UInt32(ZmxIPCFrameDecoder.maxPayloadSize + 1)
    )
    daemon.serveSplit(prelude: prelude, then: garbage, loop: true)

    let finished = DispatchSemaphore(value: 0)
    let delivered = LockIsolated(false)
    let watcher = ZmxSessionWatcher(
      surfaceID: UUID(), socketPath: daemon.path, tuning: Self.fastTuning,
      onReaderFinished: { finished.signal() },
      onSequences: { _ in delivered.setValue(true) }
    )
    watcher.start()
    defer { watcher.stop() }

    // Gave up despite delivering a valid frame in each cycle before desyncing.
    #expect(finished.wait(timeout: .now() + ZmxTestBudget.signalTimeout) == .success)
    #expect(delivered.value == true)
  }

  @Test func startAfterStopIsANoOp() {
    // Once stopped, start() must not spawn a reader; onReaderFinished never
    // fires because run() never executes.
    let finished = DispatchSemaphore(value: 0)
    let watcher = ZmxSessionWatcher(
      surfaceID: UUID(),
      socketPath: "/tmp/zmxw-nonexistent-\(UUID().uuidString.prefix(8)).sock",
      tuning: Self.fastTuning,
      onReaderFinished: { finished.signal() },
      onSequences: { _ in }
    )
    watcher.stop()
    watcher.start()

    #expect(finished.wait(timeout: .now() + 0.3) == .timedOut)
  }

  @Test func backoffMillisecondsStaysWithinBounds() {
    #expect(ZmxSessionWatcher.backoffMilliseconds(1) == 200)
    #expect(ZmxSessionWatcher.backoffMilliseconds(2) == 400)
    #expect(ZmxSessionWatcher.backoffMilliseconds(3) == 800)
    #expect(ZmxSessionWatcher.backoffMilliseconds(4) == 1600)
    #expect(ZmxSessionWatcher.backoffMilliseconds(5) == 3200)
    // Capped once the exponential exceeds the ceiling.
    #expect(ZmxSessionWatcher.backoffMilliseconds(6) == 5000)
    #expect(ZmxSessionWatcher.backoffMilliseconds(100) == 5000)
  }
}

// MARK: - State registry integration

@MainActor
@Suite(.serialized)
struct ZmxDormantWatcherRegistryTests {
  private func makeWorktree(id: String = "/tmp/repo/wt-watcher") -> Worktree {
    Worktree(
      id: WorktreeID(id),
      name: URL(fileURLWithPath: id).lastPathComponent,
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: id),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
  }

  private func makeState() -> WorktreeTerminalState {
    WorktreeTerminalState(
      runtime: GhosttyRuntime(),
      worktree: makeWorktree(),
      splitPreserveZoomOnNavigation: { false }
    )
  }

  private func firstSurfaceID(_ state: WorktreeTerminalState, tab: TerminalTabID) -> UUID {
    state.splitTree(for: tab).root!.leftmostLeaf().id
  }

  @Test func hibernateStartsWatchersForTabLeaves() {
    let state = makeState()
    let tab = state.createTab(focusing: false)!
    let surface = firstSurfaceID(state, tab: tab)

    state.hibernateTabForTesting(tab)

    #expect(state.watchedDormantSurfaceIDsForTesting == [surface])
  }

  @Test func wakeStopsOnlyTheWokenTabsWatchers() {
    let state = makeState()
    let first = state.createTab(focusing: false)!
    let firstSurface = firstSurfaceID(state, tab: first)
    let second = state.createTab(focusing: false)!
    let secondSurface = firstSurfaceID(state, tab: second)

    state.hibernateTabForTesting(first)
    state.hibernateTabForTesting(second)
    #expect(state.watchedDormantSurfaceIDsForTesting == [firstSurface, secondSurface])

    state.wakeTab(first)
    #expect(state.watchedDormantSurfaceIDsForTesting == [secondSurface])
  }

  @Test func closingDormantTabStopsItsWatchers() {
    let state = makeState()
    let tab = state.createTab(focusing: false)!
    _ = firstSurfaceID(state, tab: tab)

    state.hibernateTabForTesting(tab)
    #expect(!state.watchedDormantSurfaceIDsForTesting.isEmpty)

    state.closeTab(tab)
    #expect(state.watchedDormantSurfaceIDsForTesting.isEmpty)
  }

  @Test func closeAllSurfacesStopsAllWatchers() {
    let state = makeState()
    let first = state.createTab(focusing: false)!
    _ = firstSurfaceID(state, tab: first)
    let second = state.createTab(focusing: false)!
    _ = firstSurfaceID(state, tab: second)

    state.hibernateTabForTesting(first)
    state.hibernateTabForTesting(second)
    #expect(state.watchedDormantSurfaceIDsForTesting.count == 2)

    state.closeAllSurfaces()
    #expect(state.watchedDormantSurfaceIDsForTesting.isEmpty)
  }

  @Test func watchedSetEqualsDormantLeavesAfterEveryMutation() {
    let state = makeState()
    let first = state.createTab(focusing: false)!
    let firstSurface = firstSurfaceID(state, tab: first)
    let second = state.createTab(focusing: false)!
    let secondSurface = firstSurfaceID(state, tab: second)

    func dormantLeaves() -> Set<UUID> {
      Set(state.dormantTabLayouts.values.flatMap { $0.layout.leafSurfaceIDs })
    }

    state.hibernateTabForTesting(first)
    #expect(state.watchedDormantSurfaceIDsForTesting == dormantLeaves())

    state.hibernateTabForTesting(second)
    #expect(state.watchedDormantSurfaceIDsForTesting == dormantLeaves())
    #expect(state.watchedDormantSurfaceIDsForTesting == [firstSurface, secondSurface])

    state.wakeTab(first)
    #expect(state.watchedDormantSurfaceIDsForTesting == dormantLeaves())

    state.closeTab(second)
    #expect(state.watchedDormantSurfaceIDsForTesting == dormantLeaves())
    #expect(state.watchedDormantSurfaceIDsForTesting.isEmpty)
  }
}

// MARK: - Registry delivery (real client end-to-end)

@MainActor
@Suite(.serialized)
struct ZmxSessionWatcherRegistryDeliveryTests {
  @Test func deliversSequenceThroughOnOSCSequenceOnMainActor() async {
    let surfaceID = UUID()
    let socketDir = "/tmp/zmxw-reg-\(UUID().uuidString.prefix(8))"
    try? FileManager.default.createDirectory(atPath: socketDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: socketDir) }
    let socketPath = "\(socketDir)/\(ZmxSessionID.make(surfaceID: surfaceID))"

    guard let daemon = FakeZmxDaemon(explicitPath: socketPath) else {
      Issue.record("Failed to bind fake zmx daemon socket")
      return
    }
    defer { daemon.stop() }
    daemon.serveOnce(
      payload: ZmxWireFixture.frame(
        tag: ZmxIPCTag.output,
        payload: ZmxWireFixture.oscBEL(9, "hi")
      )
    )

    let received = LockIsolated<[(UUID, ZmxOSCSequence)]>([])
    let delivered = DispatchSemaphore(value: 0)
    let registry = withDependencies {
      $0.zmxSessionWatcherClient = .liveValue
    } operation: {
      ZmxSessionWatcherRegistry(socketDirectory: socketDir)
    }
    registry.onOSCSequence = { id, sequence in
      received.withValue { $0.append((id, sequence)) }
      delivered.signal()
    }
    registry.reconcile(dormantSurfaceIDs: [surfaceID])
    defer { registry.stopAll() }

    // Block off the main actor so the registry's MainActor delivery Task can
    // run while we await the signal.
    let result: DispatchTimeoutResult = await withCheckedContinuation { continuation in
      Thread.detachNewThread {
        continuation.resume(returning: delivered.wait(timeout: .now() + ZmxTestBudget.signalTimeout))
      }
    }
    #expect(result == .success)
    #expect(received.value.map(\.0) == [surfaceID])
    #expect(received.value.map(\.1) == [ZmxOSCSequence(code: 9, payload: ZmxWireFixture.bytes("hi"))])
  }
}
