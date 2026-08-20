import ComposableArchitecture
import SupacodeSettingsFeature
import SupacodeSettingsShared
import SwiftUI

@MainActor @Observable
final class GithubSettingsViewModel {
  enum State: Equatable {
    case loading
    case unavailable
    case outdated
    case notAuthenticated
    case authenticated(username: String, host: String)
    case error(String)
  }

  var state: State = .loading

  @ObservationIgnored
  @Dependency(GithubIntegrationClient.self) private var githubIntegration

  @ObservationIgnored
  @Dependency(GithubCLIClient.self) private var githubCLI

  func load() async {
    state = .loading
    let isAvailable = await githubIntegration.isAvailable()
    guard isAvailable else {
      state = .unavailable
      return
    }

    do {
      if let status = try await githubCLI.authStatus() {
        state = .authenticated(username: status.username, host: status.host)
      } else {
        state = .notAuthenticated
      }
    } catch let error as GithubCLIError {
      switch error {
      case .outdated:
        state = .outdated
      case .unavailable:
        state = .unavailable
      case .gatewayTimeout:
        state = .error(error.localizedDescription)
      case .commandFailed(let message):
        state = .error(message)
      }
    } catch {
      state = .error(error.localizedDescription)
    }
  }
}


@MainActor @Observable
final class GitLabSettingsViewModel {
  enum State: Equatable {
    case loading
    case unavailable
    case notAuthenticated
    case authenticated(hosts: [String])
  }

  var state: State = .loading

  @ObservationIgnored
  @Dependency(GitLabCLIClient.self) private var gitlabCLI

  func load() async {
    state = .loading
    guard await gitlabCLI.isAvailable() else {
      state = .unavailable
      return
    }
    let hosts = await gitlabCLI.authenticatedHosts().sorted()
    state = hosts.isEmpty ? .notAuthenticated : .authenticated(hosts: hosts)
  }
}

struct ForgesSettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>
  @State private var viewModel = GithubSettingsViewModel()
  @State private var gitlabViewModel = GitLabSettingsViewModel()

  var body: some View {
    Form {
      Section("GitHub") {
        Toggle(isOn: $store.githubIntegrationEnabled) {
          Text("Enable GitHub Integration")
          Text("Pull request checks and merge actions in the command palette.")
        }
        switch viewModel.state {
        case .loading:
          LabeledContent("Checking GitHub CLI…") {
            ProgressView().controlSize(.small)
          }

        case .unavailable:
          Label {
            VStack(alignment: .leading, spacing: 2) {
              Text("GitHub CLI not found")
              Text("Install `gh` to enable pull request checks.")
                .foregroundStyle(.secondary)
                .appFont(.callout)
            }
          } icon: {
            Image(systemName: "xmark.circle")
              .foregroundStyle(.red)
              .accessibilityHidden(true)
          }

        case .notAuthenticated:
          Label {
            VStack(alignment: .leading, spacing: 2) {
              Text("Not authenticated")
              Text("Run `gh auth login` in a terminal to authenticate.")
                .foregroundStyle(.secondary)
                .appFont(.callout)
            }
          } icon: {
            Image(systemName: "exclamationmark.triangle")
              .foregroundStyle(.orange)
              .accessibilityHidden(true)
          }

        case .outdated:
          Label {
            VStack(alignment: .leading, spacing: 2) {
              Text("GitHub CLI outdated")
              Text("Update to the latest version for full support.")
                .foregroundStyle(.secondary)
                .appFont(.callout)
            }
          } icon: {
            Image(systemName: "exclamationmark.triangle")
              .foregroundStyle(.orange)
              .accessibilityHidden(true)
          }

        case .authenticated(let username, let host):
          LabeledContent("Signed in as") {
            Text(username)
          }
          LabeledContent("Host") {
            Text(host)
          }

        case .error(let message):
          Label {
            VStack(alignment: .leading, spacing: 2) {
              Text("Error checking status")
              Text(message)
                .foregroundStyle(.secondary)
                .appFont(.callout)
            }
          } icon: {
            Image(systemName: "exclamationmark.triangle")
              .foregroundStyle(.red)
              .accessibilityHidden(true)
          }
        }

        switch viewModel.state {
        case .unavailable:
          Button("Get GitHub CLI") {
            NSWorkspace.shared.open(URL(string: "https://cli.github.com")!)
          }
        case .outdated:
          Button("Update GitHub CLI") {
            NSWorkspace.shared.open(URL(string: "https://cli.github.com")!)
          }
        default:
          EmptyView()
        }
      }
      Section("GitLab") {
        Toggle(isOn: $store.gitlabIntegrationEnabled) {
          Text("Enable GitLab Integration")
          Text("Merge request data and actions for repositories on GitLab.")
        }
        switch gitlabViewModel.state {
        case .loading:
          LabeledContent("Checking GitLab CLI\u{2026}") {
            ProgressView().controlSize(.small)
          }

        case .unavailable:
          Label {
            VStack(alignment: .leading, spacing: 2) {
              Text("GitLab CLI not found")
              Text("Install `glab` to enable merge request data.")
                .foregroundStyle(.secondary)
                .appFont(.callout)
            }
          } icon: {
            Image(systemName: "xmark.circle")
              .foregroundStyle(.red)
              .accessibilityHidden(true)
          }

        case .notAuthenticated:
          Label {
            VStack(alignment: .leading, spacing: 2) {
              Text("Not authenticated")
              Text("Run `glab auth login --hostname <host>` in a terminal to authenticate.")
                .foregroundStyle(.secondary)
                .appFont(.callout)
            }
          } icon: {
            Image(systemName: "exclamationmark.triangle")
              .foregroundStyle(.orange)
              .accessibilityHidden(true)
          }

        case .authenticated(let hosts):
          ForEach(hosts, id: \.self) { host in
            LabeledContent("Signed in") {
              Text(host)
            }
          }
        }

        if gitlabViewModel.state == .unavailable {
          Button("Get GitLab CLI") {
            NSWorkspace.shared.open(URL(string: "https://gitlab.com/gitlab-org/cli")!)
          }
        }
      }
      Section {
        Picker(selection: $store.pullRequestMergeStrategy) {
          ForEach(ForgeCapabilities.github.mergeStrategies, id: \.self) { strategy in
            Text(strategy.title)
              .tag(strategy)
          }
        } label: {
          Text("Merge strategy")
          Text("Default strategy when merging PRs from the command palette.")
        }
        Picker(selection: $store.mergedWorktreeAction) {
          ForEach(MergedWorktreeAction.allCases) { action in
            Text(action.title).tag(action)
          }
        } label: {
          Text("When a pull request is merged")
          Text("Archive or delete a worktree when its pull request is merged.")
        }
      } header: {
        Text("Pull Requests")
      } footer: {
        Text("Worktree merge actions only affect pre-existing local worktrees.")
      }
    }
    .formStyle(.grouped)
    .contentMargins(.trailing, 6, for: .scrollIndicators)
    .padding(.top, -20)
    .padding(.leading, -8)
    .padding(.trailing, -6)
    .navigationTitle("Git Forges")
    .task {
      await viewModel.load()
      await gitlabViewModel.load()
    }
    .onChange(of: store.githubIntegrationEnabled) { _, _ in
      Task {
        await viewModel.load()
      }
    }
  }
}
