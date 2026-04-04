import ComposableArchitecture
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
      case .commandFailed(let message):
        state = .error(message)
      }
    } catch {
      state = .error(error.localizedDescription)
    }
  }
}

struct GithubSettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>
  @State private var viewModel = GithubSettingsViewModel()

  var body: some View {
    Form {
      Section {
        Toggle(isOn: $store.githubIntegrationEnabled) {
          Text("Enable GitHub Integration")
          Text("Pull request checks and merge actions in the command palette.")
        }
      }
      Section("GitHub CLI") {
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
                .font(.callout)
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
                .font(.callout)
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
                .font(.callout)
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
                .font(.callout)
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
      Section("Pull Requests") {
        Picker(selection: $store.pullRequestMergeStrategy) {
          ForEach(PullRequestMergeStrategy.allCases) { strategy in
            Text(strategy.title)
              .tag(strategy)
          }
        } label: {
          Text("Merge strategy")
          Text("Default strategy when merging PRs from the command palette.")
        }
        Picker(selection: $store.mergedWorktreeAction) {
          Text("Do nothing").tag(MergedWorktreeAction?.none)
          ForEach(MergedWorktreeAction.allCases) { action in
            Text(action.title).tag(MergedWorktreeAction?.some(action))
          }
        } label: {
          Text("When a pull request is merged")
          switch store.mergedWorktreeAction {
          case .archive:
            Text("Archives the worktree when its pull request is merged.")
          case .delete:
            Text("Follows the \"Delete local branch with worktree\" option in Worktrees settings.")
          case nil:
            EmptyView()
          }
        }
      }
    }
    .formStyle(.grouped)
    .padding(.top, -20)
    .padding(.leading, -8)
    .padding(.trailing, -6)
    .navigationTitle("GitHub")
    .task {
      await viewModel.load()
    }
    .onChange(of: store.githubIntegrationEnabled) { _, _ in
      Task {
        await viewModel.load()
      }
    }
  }
}
