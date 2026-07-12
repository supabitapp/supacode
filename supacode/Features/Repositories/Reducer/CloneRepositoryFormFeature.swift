import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

/// Add form for cloning a remote repository into a local folder. Clones in-feature
/// so progress streams into the sheet and failures keep it open; on success it
/// delegates the resolved directory for the parent to register.
@Reducer
struct CloneRepositoryFormFeature {
  @ObservableState
  struct State: Equatable {
    var repositoryURL: String
    var cloneLocationPath: String
    /// Optional override for the destination leaf; empty means use the name
    /// derived from the url so the field's placeholder is the live default.
    var folderName: String
    var branch: String
    var depth: String
    var showAdvancedOptions: Bool
    // `progressLine` / `isCloning` / `cloneFailureMessage` are one editing ->
    // cloning -> failed state machine kept consistent by the handlers below.
    var progressLine: String?
    var isCloning: Bool
    var cloneFailureMessage: String?

    init(
      repositoryURL: String = "",
      cloneLocationPath: String = "",
      folderName: String = "",
      branch: String = "",
      depth: String = ""
    ) {
      self.repositoryURL = repositoryURL
      self.cloneLocationPath = cloneLocationPath
      self.folderName = folderName
      self.branch = branch
      self.depth = depth
      self.showAdvancedOptions = false
      self.progressLine = nil
      self.isCloning = false
      self.cloneFailureMessage = nil
    }

    var trimmedURL: String { repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedLocation: String { cloneLocationPath.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedFolderName: String { folderName.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedBranch: String { branch.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedDepth: String { depth.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The url-derived leaf, shown as the folder field's placeholder.
    var derivedFolderName: String { GitClient.humanishName(forCloneURL: trimmedURL) }
    var effectiveFolderName: String { trimmedFolderName.isEmpty ? derivedFolderName : trimmedFolderName }

    var parsedDepth: Int? { Int(trimmedDepth) }
    var isDepthValid: Bool { trimmedDepth.isEmpty || (parsedDepth ?? 0) > 0 }
    var depthValidationMessage: String? {
      guard !trimmedDepth.isEmpty, !isDepthValid else { return nil }
      return "Depth must be a positive whole number."
    }

    /// `<location>/<name>`; nil until both a location and a leaf are known.
    var destinationURL: URL? {
      guard !trimmedLocation.isEmpty, !effectiveFolderName.isEmpty else { return nil }
      return URL(fileURLWithPath: trimmedLocation)
        .appending(path: effectiveFolderName)
        .standardizedFileURL
    }

    /// Phase plus percentage from the latest progress line for the cramped status
    /// bar (git appends a verbose count / size / speed tail that just truncates);
    /// the full line is shown on hover. Falls back to the whole line with no `%`.
    var compactProgressLine: String? {
      guard let progressLine, !progressLine.isEmpty else { return nil }
      guard let percent = progressLine.firstRange(of: /\d+%/) else { return progressLine }
      return String(progressLine[..<percent.upperBound])
    }

    /// The error shown in the footer: a clone failure takes priority over the
    /// live depth hint.
    var footerMessage: String? { cloneFailureMessage ?? depthValidationMessage }
    var canSubmit: Bool { !trimmedURL.isEmpty && destinationURL != nil && isDepthValid && !isCloning }
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case locationSelected(URL)
    case submitButtonTapped
    case cancelButtonTapped
    case cloneProgress(String)
    case cloneSucceeded(URL)
    case cloneFailed(String)
    case delegate(Delegate)

    enum Delegate: Equatable {
      /// The resolved clone directory; the parent registers and dismisses.
      case cloned(URL)
      case cancel
    }
  }

  private nonisolated enum CancelID: Hashable, Sendable { case clone }

  @Dependency(GitClientDependency.self) private var gitClient

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        // Any edit clears the last clone failure so a stale message doesn't linger.
        state.cloneFailureMessage = nil
        return .none

      case .locationSelected(let url):
        state.cloneLocationPath = url.path(percentEncoded: false)
        state.cloneFailureMessage = nil
        return .none

      case .cancelButtonTapped:
        return .send(.delegate(.cancel))

      case .submitButtonTapped:
        guard state.canSubmit, let destination = state.destinationURL else { return .none }
        let url = state.trimmedURL
        let branch = state.trimmedBranch.isEmpty ? nil : state.trimmedBranch
        let depth = state.parsedDepth
        state.isCloning = true
        state.cloneFailureMessage = nil
        state.progressLine = nil
        let cloneStream = gitClient.cloneStream
        return .run { send in
          var throttle = WorktreeCreationProgressUpdateThrottle(stride: 4)
          var lastProgress: String?
          do {
            for try await event in cloneStream(url, destination, branch, depth) {
              switch event {
              case .outputLine(let line):
                let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                lastProgress = text
                if throttle.recordLine() {
                  await send(.cloneProgress(text))
                }
              case .finished(let directory):
                // Surface the final throttled line so the last percentage isn't dropped.
                if let lastProgress, throttle.flush() {
                  await send(.cloneProgress(lastProgress))
                }
                await send(.cloneSucceeded(directory))
                return
              }
            }
            await send(.cloneFailed("Clone produced no output."))
          } catch is CancellationError {
            // The sheet was dismissed; the effect is being torn down, no message.
          } catch {
            await send(.cloneFailed(error.localizedDescription))
          }
        }
        .cancellable(id: CancelID.clone, cancelInFlight: true)

      case .cloneProgress(let line):
        state.progressLine = line
        return .none

      case .cloneSucceeded(let directory):
        return .send(.delegate(.cloned(directory)))

      case .cloneFailed(let message):
        state.isCloning = false
        state.progressLine = nil
        state.cloneFailureMessage = message
        return .none

      case .delegate:
        return .none
      }
    }
  }
}
