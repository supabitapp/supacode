import ComposableArchitecture
import Foundation

@Reducer
struct RepositorySettingsFeature {
  @ObservableState
  struct State: Equatable {
    var rootURL: URL
    var settings: RepositorySettings
    var repositoryNameDraft = ""
    var repositoryNameValidationMessage: String?
    var isBareRepository = false
    var branchOptions: [String] = []
    var defaultWorktreeBaseRef = "origin/main"
    var isBranchDataLoaded = false
  }

  enum Action: BindableAction {
    case task
    case settingsLoaded(RepositorySettings, isBareRepository: Bool)
    case branchDataLoaded([String], defaultBaseRef: String)
    case repositoryNameDraftChanged(String)
    case applyRepositoryName
    case resetRepositoryNameToDefault
    case delegate(Delegate)
    case binding(BindingAction<State>)
  }

  @CasePathable
  enum Delegate: Equatable {
    case settingsChanged(URL)
    case repositoryNameChanged(URL)
  }

  @Dependency(GitClientDependency.self) private var gitClient

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .task:
        let rootURL = state.rootURL
        @Shared(.repositorySettings(rootURL)) var repositorySettings
        let settings = repositorySettings
        let gitClient = gitClient
        return .run { send in
          let isBareRepository = (try? await gitClient.isBareRepository(rootURL)) ?? false
          await send(.settingsLoaded(settings, isBareRepository: isBareRepository))
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

      case .settingsLoaded(let settings, let isBareRepository):
        var updatedSettings = settings
        if isBareRepository {
          updatedSettings.copyIgnoredOnWorktreeCreate = false
          updatedSettings.copyUntrackedOnWorktreeCreate = false
        }
        state.settings = updatedSettings
        state.repositoryNameDraft = Repository.name(
          for: state.rootURL,
          configuredName: updatedSettings.repositoryName
        )
        state.repositoryNameValidationMessage = nil
        state.isBareRepository = isBareRepository
        guard isBareRepository, updatedSettings != settings else { return .none }
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

      case .repositoryNameDraftChanged(let draft):
        state.repositoryNameDraft = draft
        state.repositoryNameValidationMessage = nil
        return .none

      case .applyRepositoryName:
        let rootURL = state.rootURL.standardizedFileURL
        let rootID = rootURL.path(percentEncoded: false)
        let normalizedName = Repository.normalizedConfiguredName(state.repositoryNameDraft)
        let defaultName = Repository.defaultName(for: rootURL)
        let configuredName = normalizedName == defaultName ? nil : normalizedName
        if let configuredName, !Repository.isValidDirectoryName(configuredName) {
          state.repositoryNameValidationMessage = "Repository name contains unsupported characters."
          return .none
        }
        let effectiveName = Repository.directoryName(for: rootURL, configuredName: configuredName)
        @Shared(.settingsFile) var settingsFile
        let duplicateRootID: String? = $settingsFile.withLock { settings in
          let rootIDs = RepositoryPathNormalizer.normalize(settings.repositoryRoots)
          for candidateRootID in rootIDs where candidateRootID != rootID {
            let candidateRootURL = URL(fileURLWithPath: candidateRootID).standardizedFileURL
            let candidateName = Repository.directoryName(
              for: candidateRootURL,
              configuredName: settings.repositories[candidateRootID]?.repositoryName
            )
            if candidateName.lowercased() == effectiveName.lowercased() {
              return candidateRootID
            }
          }
          return nil
        }
        guard duplicateRootID == nil else {
          state.repositoryNameValidationMessage = "Repository name must be unique."
          return .none
        }
        guard state.settings.repositoryName != configuredName else {
          state.repositoryNameDraft = Repository.name(for: rootURL, configuredName: configuredName)
          return .none
        }
        state.settings.repositoryName = configuredName
        state.repositoryNameValidationMessage = nil
        state.repositoryNameDraft = Repository.name(for: rootURL, configuredName: configuredName)
        @Shared(.repositorySettings(rootURL)) var repositorySettings
        $repositorySettings.withLock { $0 = state.settings }
        return .send(.delegate(.repositoryNameChanged(rootURL)))

      case .resetRepositoryNameToDefault:
        state.repositoryNameValidationMessage = nil
        let rootURL = state.rootURL.standardizedFileURL
        let defaultName = Repository.defaultName(for: rootURL)
        state.repositoryNameDraft = defaultName
        guard state.settings.repositoryName != nil else {
          return .none
        }
        state.settings.repositoryName = nil
        @Shared(.repositorySettings(rootURL)) var repositorySettings
        $repositorySettings.withLock { $0 = state.settings }
        return .send(.delegate(.repositoryNameChanged(rootURL)))

      case .binding:
        if state.isBareRepository {
          state.settings.copyIgnoredOnWorktreeCreate = false
          state.settings.copyUntrackedOnWorktreeCreate = false
        }
        let rootURL = state.rootURL
        @Shared(.repositorySettings(rootURL)) var repositorySettings
        $repositorySettings.withLock { $0 = state.settings }
        return .send(.delegate(.settingsChanged(rootURL)))

      case .delegate:
        return .none
      }
    }
  }
}
