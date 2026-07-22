import ConcurrencyExtras
import Darwin
import Dependencies
import Foundation
import SupacodeSettingsShared

nonisolated private let watcherLogger = SupaLogger("ZmxSessionWatcher")

/// A passive tail reader over one dormant session's zmx socket. Lifecycle is
/// main-actor; the blocking socket read runs on a dedicated thread that never
/// retains the owner. Single-use: once stopped it stays stopped.
@MainActor
protocol ZmxSessionWatching: AnyObject {
  func start()
  func stop()
}

/// Watches one dormant zmx session for OSC signals its surface can no longer
/// parse. A passive client that never sends `.Init` (no screen replay), it
/// feeds framed `.Output` to an OSC scanner and reconnects with bounded backoff.
@MainActor
final class ZmxSessionWatcher: ZmxSessionWatching {
  /// Reconnect / backoff budget for the reader thread. Injectable so tests
  /// drive give-up deterministically without real backoff sleeps.
  nonisolated struct Tuning: Sendable {
    /// Failed cycles (bad connect or a read cycle that made no progress) before
    /// the watcher gives up; a live dormant daemon never trips this.
    var maxConnectAttempts: Int
    var baseBackoffMilliseconds: UInt32
    var maxBackoffMilliseconds: UInt32
    /// Poll timeout. `stop()` never blocks; this only bounds how long the reader
    /// thread takes to notice the stop flag and close the socket.
    var pollTimeoutMilliseconds: Int32
    /// A read cycle that delivered no frame but stayed connected at least this
    /// long still counts as healthy and resets the budget.
    var minHealthyConnectionMilliseconds: UInt64

    static let live = Tuning(
      maxConnectAttempts: 6,
      baseBackoffMilliseconds: 200,
      maxBackoffMilliseconds: 5000,
      pollTimeoutMilliseconds: 200,
      minHealthyConnectionMilliseconds: 1000
    )
  }

  let surfaceID: UUID
  private let socketPath: String
  private let tuning: Tuning
  private let onSequences: @Sendable ([ZmxOSCSequence]) -> Void
  /// Fired on the reader thread when it exits (give-up or stop). Test seam for
  /// observing give-up deterministically.
  private let onReaderFinished: (@Sendable () -> Void)?
  /// Shared by reference so the reader thread never retains `self`.
  private let stopped = LockIsolated(false)
  private var thread: Thread?

  init(
    surfaceID: UUID,
    socketPath: String,
    tuning: Tuning = .live,
    onReaderFinished: (@Sendable () -> Void)? = nil,
    onSequences: @escaping @Sendable ([ZmxOSCSequence]) -> Void
  ) {
    self.surfaceID = surfaceID
    self.socketPath = socketPath
    self.tuning = tuning
    self.onReaderFinished = onReaderFinished
    self.onSequences = onSequences
  }

  func start() {
    guard !stopped.value else {
      watcherLogger.debug("Ignoring start() on a stopped zmx watcher; create a new instance to restart")
      return
    }
    guard thread == nil else { return }
    let stopped = self.stopped
    let socketPath = self.socketPath
    let tuning = self.tuning
    let onSequences = self.onSequences
    let onReaderFinished = self.onReaderFinished
    let thread = Thread {
      Self.run(
        socketPath: socketPath,
        tuning: tuning,
        stopped: stopped,
        onSequences: onSequences,
        onReaderFinished: onReaderFinished
      )
    }
    thread.name = "supacode.zmx-watcher"
    self.thread = thread
    thread.start()
  }

  func stop() {
    stopped.setValue(true)
    thread = nil
  }

  isolated deinit {
    guard !stopped.value else { return }
    stop()
  }

  // MARK: - Reader thread (nonisolated).

  /// Outcome of one connected read cycle, deciding whether the reconnect budget
  /// resets or is charged. `.failed` covers a decoder desync (even after frames),
  /// a poll / read error, or a connection that closed before delivering anything.
  private enum CycleOutcome {
    case progressed
    case cleanEnd
    case failed
  }

  private nonisolated static func run(
    socketPath: String,
    tuning: Tuning,
    stopped: LockIsolated<Bool>,
    onSequences: @Sendable ([ZmxOSCSequence]) -> Void,
    onReaderFinished: (@Sendable () -> Void)?
  ) {
    defer { onReaderFinished?() }
    var attempt = 0
    var lastConnectErrno: Int32 = 0
    while !stopped.value {
      guard let socketFD = connect(to: socketPath, lastConnectErrno: &lastConnectErrno) else {
        guard
          advanceFailureBudget(
            attempt: &attempt, socketPath: socketPath, tuning: tuning, stopped: stopped,
            lastConnectErrno: lastConnectErrno)
        else { return }
        continue
      }
      // A successful connect invalidates any earlier connect errno; a later
      // read-failure give-up must not report it as the cause.
      lastConnectErrno = 0
      let outcome = readUntilClosed(
        socketFD: socketFD, tuning: tuning, stopped: stopped, onSequences: onSequences)
      close(socketFD)
      if stopped.value { return }
      switch outcome {
      case .progressed, .cleanEnd:
        // A healthy cycle resets the budget, but still backs off so no reconnect
        // path is a tight loop.
        attempt = 0
        sleepInterruptibly(tuning.baseBackoffMilliseconds, stopped: stopped)
      case .failed:
        guard
          advanceFailureBudget(
            attempt: &attempt, socketPath: socketPath, tuning: tuning, stopped: stopped,
            lastConnectErrno: lastConnectErrno)
        else { return }
      }
    }
  }

  /// Advances the shared reconnect budget after a cycle that made no progress
  /// and sleeps the backoff. Returns false once the budget is exhausted and the
  /// watcher must give up.
  private nonisolated static func advanceFailureBudget(
    attempt: inout Int,
    socketPath: String,
    tuning: Tuning,
    stopped: LockIsolated<Bool>,
    lastConnectErrno: Int32
  ) -> Bool {
    attempt += 1
    guard attempt < tuning.maxConnectAttempts else {
      let session = URL(fileURLWithPath: socketPath).lastPathComponent
      // Read and poll failures log their own errno inline; only a connect
      // failure has a cause worth naming here.
      let cause = lastConnectErrno == 0 ? "" : " (last connect errno \(lastConnectErrno))"
      watcherLogger.warning("Stopped watching \(session) after \(attempt) failed cycles\(cause)")
      return false
    }
    sleepInterruptibly(backoffMilliseconds(attempt, tuning: tuning), stopped: stopped)
    return true
  }

  /// Connects a blocking AF_UNIX stream socket to the session path. Returns nil
  /// on any failure (missing socket file, no listener); the caller retries.
  /// Captures the failing errno so the give-up log can name the cause.
  private nonisolated static func connect(to path: String, lastConnectErrno: inout Int32) -> Int32? {
    let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
    guard socketFD >= 0 else {
      lastConnectErrno = errno
      return nil
    }
    setCloseOnExec(socketFD)
    var noSIGPIPE: Int32 = 1
    _ = setsockopt(
      socketFD, SOL_SOCKET, SO_NOSIGPIPE, &noSIGPIPE, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = path.utf8CString
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
      watcherLogger.warning("Socket path too long: \(path)")
      close(socketFD)
      return nil
    }
    _ = withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
      pathBytes.withUnsafeBufferPointer { buffer in
        memcpy(sunPath, buffer.baseAddress!, buffer.count)
      }
    }
    let addrLen = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
    let result = withUnsafePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
        Darwin.connect(socketFD, sockaddrPtr, addrLen)
      }
    }
    guard result == 0 else {
      lastConnectErrno = errno
      close(socketFD)
      return nil
    }
    return socketFD
  }

  /// Reads framed `.Output` until EOF, a fatal desync, or `stop()`, polling
  /// every `pollTimeoutMilliseconds` so the stop flag is honored promptly.
  /// Returns the cycle outcome so the caller resets or charges the reconnect budget.
  private nonisolated static func readUntilClosed(
    socketFD: Int32,
    tuning: Tuning,
    stopped: LockIsolated<Bool>,
    onSequences: @Sendable ([ZmxOSCSequence]) -> Void
  ) -> CycleOutcome {
    var decoder = ZmxIPCFrameDecoder()
    var scanner = ZmxOSCScanner()
    var buffer = [UInt8](repeating: 0, count: 4096)
    var deliveredFrame = false
    let startedAt = DispatchTime.now().uptimeNanoseconds
    while !stopped.value {
      var pollFD = pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0)
      // Clamp to at least 1ms so a degenerate hand-built Tuning can't make the
      // reader block forever and ignore stop().
      let ready = poll(&pollFD, 1, max(1, tuning.pollTimeoutMilliseconds))
      if ready < 0 {
        if errno == EINTR { continue }
        watcherLogger.warning("zmx watcher poll error on fd \(socketFD): errno \(errno)")
        return .failed
      }
      guard ready > 0 else { continue }
      if pollFD.revents & Int16(POLLNVAL) != 0 { return .failed }

      let bytesRead = buffer.withUnsafeMutableBytes { raw in
        Darwin.read(socketFD, raw.baseAddress, raw.count)
      }
      if bytesRead < 0 {
        if errno == EINTR { continue }
        watcherLogger.warning("zmx watcher read error on fd \(socketFD): errno \(errno)")
        return .failed
      }
      // EOF: the daemon closed (shell exited). A cycle that delivered frames or
      // stayed connected long enough is a healthy session ending, not a failure.
      if bytesRead == 0 {
        if deliveredFrame { return .progressed }
        let elapsed = DispatchTime.now().uptimeNanoseconds &- startedAt
        return elapsed >= tuning.minHealthyConnectionMilliseconds &* 1_000_000 ? .cleanEnd : .failed
      }

      let chunk = Array(buffer[0..<bytesRead])
      let frames: [ZmxIPCFrame]
      do {
        frames = try decoder.decode(chunk)
      } catch {
        // A desync charges the budget even when earlier reads delivered frames,
        // so a chatty-but-corrupt daemon can't reset it and reconnect forever.
        watcherLogger.warning("Dropping desynced zmx stream on fd \(socketFD): \(error)")
        return .failed
      }
      if !frames.isEmpty { deliveredFrame = true }
      var sequences: [ZmxOSCSequence] = []
      for frame in frames where frame.tag == ZmxIPCTag.output {
        sequences.append(contentsOf: scanner.scan(frame.payload))
      }
      guard !sequences.isEmpty else { continue }
      onSequences(sequences)
    }
    // Stopped mid-cycle: the caller returns before charging, so the value is moot.
    return .cleanEnd
  }

  private nonisolated static func setCloseOnExec(_ socketFD: Int32) {
    let flags = fcntl(socketFD, F_GETFD)
    guard flags != -1 else { return }
    _ = fcntl(socketFD, F_SETFD, flags | FD_CLOEXEC)
  }

  /// Exponential backoff in milliseconds, capped, for the Nth consecutive
  /// failed cycle (attempt is 1-based).
  nonisolated static func backoffMilliseconds(_ attempt: Int, tuning: Tuning = .live) -> UInt32 {
    let shift = min(attempt - 1, 5)
    let scaled = tuning.baseBackoffMilliseconds &* (UInt32(1) << UInt32(shift))
    return min(scaled, tuning.maxBackoffMilliseconds)
  }

  /// Sleeps in short steps so a `stop()` mid-backoff is honored quickly.
  private nonisolated static func sleepInterruptibly(
    _ milliseconds: UInt32,
    stopped: LockIsolated<Bool>
  ) {
    var remaining = milliseconds
    while remaining > 0, !stopped.value {
      let step = min(UInt32(50), remaining)
      usleep(step &* 1000)
      remaining -= step
    }
  }
}

/// A no-op watcher for the test-value dependency, so integration tests exercise
/// the registry's start / stop bookkeeping without a real socket-reading thread.
@MainActor
final class InertZmxSessionWatcher: ZmxSessionWatching {
  func start() {}
  func stop() {}
}

/// Builds a `ZmxSessionWatching` for a dormant session. Injected so tests
/// substitute an inert watcher; the live value builds the real tail reader.
struct ZmxSessionWatcherClient: Sendable {
  var makeWatcher:
    @MainActor @Sendable (
      _ surfaceID: UUID,
      _ socketPath: String,
      _ onSequences: @escaping @Sendable ([ZmxOSCSequence]) -> Void
    ) -> ZmxSessionWatching
}

extension ZmxSessionWatcherClient: DependencyKey {
  nonisolated static let liveValue = ZmxSessionWatcherClient { surfaceID, socketPath, onSequences in
    ZmxSessionWatcher(surfaceID: surfaceID, socketPath: socketPath, onSequences: onSequences)
  }

  nonisolated static let testValue = ZmxSessionWatcherClient { _, _, _ in
    InertZmxSessionWatcher()
  }
}

extension DependencyValues {
  nonisolated var zmxSessionWatcherClient: ZmxSessionWatcherClient {
    get { self[ZmxSessionWatcherClient.self] }
    set { self[ZmxSessionWatcherClient.self] = newValue }
  }
}

/// Owns the passive watchers 1:1 with dormant leaf surfaces; the invariant
/// `watchedSurfaceIDs == dormant leaf surface ids` is held by `reconcile(dormantSurfaceIDs:)`.
/// Stopping a watcher closes its socket, so on an explicit close reconcile must
/// run before the session kill.
@MainActor
final class ZmxSessionWatcherRegistry {
  /// Delivered on the main actor when a watched dormant session emits an OSC
  /// sequence. Nil until the owner installs a sink; unrouted sequences are
  /// dropped.
  var onOSCSequence: ((UUID, ZmxOSCSequence) -> Void)?

  private var watchers: [UUID: ZmxSessionWatching] = [:]
  private let socketDirectory: String
  private let client: ZmxSessionWatcherClient

  init(socketDirectory: String = ZmxSocketBudget.socketDir()) {
    @Dependency(\.zmxSessionWatcherClient) var client
    self.client = client
    self.socketDirectory = socketDirectory
  }

  /// Test seam for the `watched == dormant leaves` invariant.
  var watchedSurfaceIDs: Set<UUID> { Set(watchers.keys) }

  func reconcile(dormantSurfaceIDs: Set<UUID>) {
    for surfaceID in watchers.keys where !dormantSurfaceIDs.contains(surfaceID) {
      watchers.removeValue(forKey: surfaceID)?.stop()
    }
    for surfaceID in dormantSurfaceIDs where watchers[surfaceID] == nil {
      startWatcher(for: surfaceID)
    }
  }

  func stopAll() {
    for watcher in watchers.values { watcher.stop() }
    watchers.removeAll()
  }

  isolated deinit { stopAll() }

  private func startWatcher(for surfaceID: UUID) {
    let socketPath = "\(socketDirectory)/\(ZmxSessionID.make(surfaceID: surfaceID))"
    let watcher = client.makeWatcher(surfaceID, socketPath) { [weak self] sequences in
      Task { @MainActor [weak self] in
        guard let self else { return }
        for sequence in sequences {
          self.deliver(surfaceID: surfaceID, sequence: sequence)
        }
      }
    }
    watchers[surfaceID] = watcher
    watcher.start()
  }

  private func deliver(surfaceID: UUID, sequence: ZmxOSCSequence) {
    guard let onOSCSequence else {
      watcherLogger.debug("OSC \(sequence.code) from dormant \(surfaceID) dropped: no sink installed")
      return
    }
    onOSCSequence(surfaceID, sequence)
  }
}
