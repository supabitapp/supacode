import ComposableArchitecture
import Foundation
import Sharing
import SupacodeSettingsShared

@Reducer
public struct RepositorySettingsFeature {
  @ObservableState
  public struct State: Equatable {
    public var rootURL: URL
    public var isGitRepository: Bool
    public var settings: RepositorySettings
    public var globalDefaultWorktreeBaseDirectoryPath: String?
    public var globalCopyIgnoredOnWorktreeCreate: Bool = false
    public var globalCopyUntrackedOnWorktreeCreate: Bool = false
    public var globalPullRequestMergeStrategy: PullRequestMergeStrategy = .merge
    public var isBareRepository = false
    public var branchOptions: [String] = []
    public var defaultWorktreeBaseRef = "origin/main"
    public var isBranchDataLoaded = false

    public var exampleWorktreePath: String {
      SupacodePaths.exampleWorktreePath(
        for: rootURL,
        globalDefaultPath: globalDefaultWorktreeBaseDirectoryPath,
        repositoryOverridePath: settings.worktreeBaseDirectoryPath,
        branchName: "**/*"
      )
    }

    @Presents public var alert: AlertState<Alert>?

    public init(
      rootURL: URL,
      isGitRepository: Bool = true,
      settings: RepositorySettings,
      globalDefaultWorktreeBaseDirectoryPath: String? = nil,
      globalCopyIgnoredOnWorktreeCreate: Bool = false,
      globalCopyUntrackedOnWorktreeCreate: Bool = false,
      globalPullRequestMergeStrategy: PullRequestMergeStrategy = .merge,
      isBareRepository: Bool = false,
      branchOptions: [String] = [],
      defaultWorktreeBaseRef: String = "origin/main",
      isBranchDataLoaded: Bool = false
    ) {
      self.rootURL = rootURL
      self.isGitRepository = isGitRepository
      self.settings = settings
      self.globalDefaultWorktreeBaseDirectoryPath = globalDefaultWorktreeBaseDirectoryPath
      self.globalCopyIgnoredOnWorktreeCreate = globalCopyIgnoredOnWorktreeCreate
      self.globalCopyUntrackedOnWorktreeCreate = globalCopyUntrackedOnWorktreeCreate
      self.globalPullRequestMergeStrategy = globalPullRequestMergeStrategy
      self.isBareRepository = isBareRepository
      self.branchOptions = branchOptions
      self.defaultWorktreeBaseRef = defaultWorktreeBaseRef
      self.isBranchDataLoaded = isBranchDataLoaded
    }
  }

  @CasePathable
  public enum Alert: Equatable {
    case confirmRemoveScript(ScriptDefinition.ID)
  }

  public enum Action: BindableAction {
    case task
    case settingsLoaded(
      RepositorySettings,
      isBareRepository: Bool,
      globalDefaultWorktreeBaseDirectoryPath: String?,
      globalCopyIgnoredOnWorktreeCreate: Bool,
      globalCopyUntrackedOnWorktreeCreate: Bool,
      globalPullRequestMergeStrategy: PullRequestMergeStrategy
    )
    case branchDataLoaded([String], defaultBaseRef: String)
    case addScript(ScriptKind)
    case removeScript(ScriptDefinition.ID)
    case alert(PresentationAction<Alert>)
    case delegate(Delegate)
    case binding(BindingAction<State>)
  }

  @CasePathable
  public enum Delegate: Equatable {
    case settingsChanged(URL)
  }

  @Dependency(RepositorySettingsGitClient.self) private var gitClient

  public init() {}

  public var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .task:
        let rootURL = state.rootURL
        let isGitRepository = state.isGitRepository
        @Shared(.repositorySettings(rootURL)) var repositorySettings
        @Shared(.settingsFile) var settingsFile
        let settings = repositorySettings
        let global = settingsFile.global
        let globalDefaultWorktreeBaseDirectoryPath = global.defaultWorktreeBaseDirectoryPath
        let globalCopyIgnored = global.copyIgnoredOnWorktreeCreate
        let globalCopyUntracked = global.copyUntrackedOnWorktreeCreate
        let globalMergeStrategy = global.pullRequestMergeStrategy
        let gitClient = gitClient
        return .run { send in
          // Folders don't expose the general settings page, so skip
          // the git-only queries (`isBareRepository`, `branchRefs`,
          // `automaticWorktreeBaseRef`) that would otherwise log
          // subprocess warnings against a non-git directory.
          guard isGitRepository else {
            await send(
              .settingsLoaded(
                settings,
                isBareRepository: false,
                globalDefaultWorktreeBaseDirectoryPath: globalDefaultWorktreeBaseDirectoryPath,
                globalCopyIgnoredOnWorktreeCreate: globalCopyIgnored,
                globalCopyUntrackedOnWorktreeCreate: globalCopyUntracked,
                globalPullRequestMergeStrategy: globalMergeStrategy
              )
            )
            await send(.branchDataLoaded([], defaultBaseRef: "HEAD"))
            return
          }
          let isBareRepository = (try? await gitClient.isBareRepository(rootURL)) ?? false
          await send(
            .settingsLoaded(
              settings,
              isBareRepository: isBareRepository,
              globalDefaultWorktreeBaseDirectoryPath: globalDefaultWorktreeBaseDirectoryPath,
              globalCopyIgnoredOnWorktreeCreate: globalCopyIgnored,
              globalCopyUntrackedOnWorktreeCreate: globalCopyUntracked,
              globalPullRequestMergeStrategy: globalMergeStrategy
            )
          )
          let branches: [String]
          do {
            branches = try await gitClient.branchRefs(rootURL)
          } catch {
            let rootPath = rootURL.path(percentEncoded: false)
            SupaLogger("Settings").warning(
              "Branch refs failed for \(rootPath): \(error.localizedDescription)"
            )
            branches = []
          }
          let defaultBaseRef = await gitClient.automaticWorktreeBaseRef(rootURL) ?? "HEAD"
          await send(.branchDataLoaded(branches, defaultBaseRef: defaultBaseRef))
        }

      case .settingsLoaded(
        let settings,
        let isBareRepository,
        let globalDefaultWorktreeBaseDirectoryPath,
        let globalCopyIgnoredOnWorktreeCreate,
        let globalCopyUntrackedOnWorktreeCreate,
        let globalPullRequestMergeStrategy
      ):
        var updatedSettings = settings
        updatedSettings.worktreeBaseDirectoryPath = SupacodePaths.normalizedWorktreeBaseDirectoryPath(
          updatedSettings.worktreeBaseDirectoryPath,
          repositoryRootURL: state.rootURL
        )
        if isBareRepository {
          updatedSettings.copyIgnoredOnWorktreeCreate = nil
          updatedSettings.copyUntrackedOnWorktreeCreate = nil
        }
        state.settings = updatedSettings
        state.globalDefaultWorktreeBaseDirectoryPath =
          SupacodePaths.normalizedWorktreeBaseDirectoryPath(globalDefaultWorktreeBaseDirectoryPath)
        state.globalCopyIgnoredOnWorktreeCreate = globalCopyIgnoredOnWorktreeCreate
        state.globalCopyUntrackedOnWorktreeCreate = globalCopyUntrackedOnWorktreeCreate
        state.globalPullRequestMergeStrategy = globalPullRequestMergeStrategy
        state.isBareRepository = isBareRepository
        guard updatedSettings != settings else { return .none }
        let rootURL = state.rootURL
        @Shared(.repositorySettings(rootURL)) var repositorySettings
        $repositorySettings.withLock { $0 = updatedSettings }
        return .send(.delegate(.settingsChanged(rootURL)))

      case .branchDataLoaded(let branches, let defaultBaseRef):
        state.defaultWorktreeBaseRef = defaultBaseRef
        var options = branches
        if !options.contains(defaultBaseRef) {
          options.append(defaultBaseRef)
        }
        if let selected = state.settings.worktreeBaseRef, !options.contains(selected) {
          options.append(selected)
        }
        state.branchOptions = options
        state.isBranchDataLoaded = true
        return .none

      case .addScript(let kind):
        // Predefined kinds are unique; reject duplicates.
        guard kind == .custom || !state.settings.scripts.contains(where: { $0.kind == kind }) else {
          return .none
        }
        state.settings.scripts.append(ScriptDefinition(kind: kind))
        return persistAndNotify(state: &state)

      case .removeScript(let id):
        guard let script = state.settings.scripts.first(where: { $0.id == id }) else { return .none }
        state.alert = AlertState {
          TextState("Remove \"\(script.displayName)\" script?")
        } actions: {
          ButtonState(role: .destructive, action: .confirmRemoveScript(id)) {
            TextState("Remove")
          }
          ButtonState(role: .cancel) {
            TextState("Cancel")
          }
        } message: {
          TextState("This action cannot be undone.")
        }
        return .none

      case .alert(.presented(.confirmRemoveScript(let id))):
        state.settings.scripts.removeAll { $0.id == id }
        return persistAndNotify(state: &state)

      case .alert:
        return .none

      case .binding:
        if state.isBareRepository {
          state.settings.copyIgnoredOnWorktreeCreate = nil
          state.settings.copyUntrackedOnWorktreeCreate = nil
        }
        return persistAndNotify(state: &state)

      case .delegate:
        return .none
      }
    }
    .ifLet(\.$alert, action: \.alert)
  }

  /// Persists the current settings and notifies the delegate.
  private func persistAndNotify(state: inout State) -> Effect<Action> {
    let rootURL = state.rootURL
    var normalizedSettings = state.settings
    normalizedSettings.worktreeBaseDirectoryPath = SupacodePaths.normalizedWorktreeBaseDirectoryPath(
      normalizedSettings.worktreeBaseDirectoryPath,
      repositoryRootURL: rootURL
    )
    @Shared(.repositorySettings(rootURL)) var repositorySettings
    $repositorySettings.withLock { $0 = normalizedSettings }
    return .send(.delegate(.settingsChanged(rootURL)))
  }
}
