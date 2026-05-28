import ComposableArchitecture
import SupacodeSettingsFeature
import SupacodeSettingsShared
import SwiftUI

@MainActor @Observable
final class ForgesSettingsViewModel {
  enum Status: Equatable {
    case loading
    case unavailable
    case outdated
    case notAuthenticated
    case authenticated(username: String, host: String)
    case error(String)
  }

  var statuses: [Forge: Status] = [.github: .loading, .gitlab: .loading]

  @ObservationIgnored @Dependency(GithubIntegrationClient.self) private var githubIntegration
  @ObservationIgnored @Dependency(GithubCLIClient.self) private var githubCLI
  @ObservationIgnored @Dependency(GitLabIntegrationClient.self) private var gitlabIntegration
  @ObservationIgnored @Dependency(GitLabCLIClient.self) private var gitlabCLI

  func loadAll() async {
    statuses[.github] = await githubStatus()
    statuses[.gitlab] = await gitlabStatus()
  }

  func reload(_ forge: Forge) async {
    statuses[forge] = .loading
    switch forge {
    case .github: statuses[.github] = await githubStatus()
    case .gitlab: statuses[.gitlab] = await gitlabStatus()
    }
  }

  private func githubStatus() async -> Status {
    guard await githubIntegration.isAvailable() else { return .unavailable }
    do {
      if let status = try await githubCLI.authStatus() {
        return .authenticated(username: status.username, host: status.host)
      }
      return .notAuthenticated
    } catch let error as GithubCLIError {
      switch error {
      case .outdated: return .outdated
      case .unavailable: return .unavailable
      case .gatewayTimeout: return .error(error.errorDescription ?? "GitHub returned a gateway timeout.")
      case .commandFailed(let message): return .error(message)
      }
    } catch {
      return .error(error.localizedDescription)
    }
  }

  private func gitlabStatus() async -> Status {
    guard await gitlabIntegration.isAvailable() else { return .unavailable }
    do {
      if let status = try await gitlabCLI.authStatus() {
        return .authenticated(username: status.username, host: status.host)
      }
      return .notAuthenticated
    } catch let error as GitLabCLIError {
      switch error {
      case .unavailable: return .unavailable
      case .commandFailed(let message): return .error(message)
      }
    } catch {
      return .error(error.localizedDescription)
    }
  }
}

struct ForgesSettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>
  @State private var viewModel = ForgesSettingsViewModel()

  var body: some View {
    Form {
      Section {
        ForgeIntegrationRow(
          forge: .github,
          enabled: $store.githubIntegrationEnabled,
          status: viewModel.statuses[.github] ?? .loading
        )
        ForgeIntegrationRow(
          forge: .gitlab,
          enabled: $store.gitlabIntegrationEnabled,
          status: viewModel.statuses[.gitlab] ?? .loading
        )
      } header: {
        Text("Forges")
      } footer: {
        Text("Each forge surfaces pull/merge request status for worktrees on its remotes. The CLI must be installed and authenticated.")
      }

      Section {
        Picker(selection: $store.pullRequestMergeStrategy) {
          ForEach(PullRequestMergeStrategy.allCases) { strategy in
            Text(strategy.title)
              .tag(strategy)
          }
        } label: {
          Text("Merge strategy")
          Text("Default strategy when merging pull requests from the command palette.")
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
      } header: {
        Text("Pull Requests")
      } footer: {
        Text("Merge actions are available for GitHub today; GitLab merge request actions are coming in a future release.")
      }
    }
    .formStyle(.grouped)
    .padding(.top, -20)
    .padding(.leading, -8)
    .padding(.trailing, -6)
    .navigationTitle("Forges")
    .task {
      await viewModel.loadAll()
    }
    .onChange(of: store.githubIntegrationEnabled) { _, _ in
      Task { await viewModel.reload(.github) }
    }
    .onChange(of: store.gitlabIntegrationEnabled) { _, _ in
      Task { await viewModel.reload(.gitlab) }
    }
  }
}

private struct ForgeIntegrationRow: View {
  let forge: Forge
  @Binding var enabled: Bool
  let status: ForgesSettingsViewModel.Status

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Toggle(isOn: $enabled) {
        Text(forge.displayName)
        Text("Enable \(forge.displayName) integration.")
      }
      statusContent
        .font(.callout)
    }
  }

  @ViewBuilder
  private var statusContent: some View {
    switch status {
    case .loading:
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text("Checking \(forge.cliName)\u{2026}").foregroundStyle(.secondary)
      }

    case .unavailable:
      HStack(spacing: 6) {
        Label("\(forge.cliName) not found", systemImage: "xmark.circle")
          .foregroundStyle(.secondary)
        Button("Get \(forge.cliName) \u{2197}") {
          NSWorkspace.shared.open(forge.cliInstallURL)
        }
        .buttonStyle(.link)
      }

    case .outdated:
      HStack(spacing: 6) {
        Label("\(forge.cliName) is outdated", systemImage: "exclamationmark.triangle")
          .foregroundStyle(.secondary)
        Button("Update \(forge.cliName) \u{2197}") {
          NSWorkspace.shared.open(forge.cliInstallURL)
        }
        .buttonStyle(.link)
      }

    case .notAuthenticated:
      Label("Not authenticated \u{2014} run `\(forge.authLoginCommand)`", systemImage: "exclamationmark.triangle")
        .foregroundStyle(.secondary)

    case .authenticated(let username, let host):
      Label("Signed in as \(username) \u{00B7} \(host)", systemImage: "checkmark.circle")
        .foregroundStyle(.secondary)

    case .error(let message):
      Label(message, systemImage: "exclamationmark.triangle")
        .foregroundStyle(.red)
    }
  }
}

private extension Forge {
  var displayName: String {
    switch self {
    case .github: return "GitHub"
    case .gitlab: return "GitLab"
    }
  }

  var cliName: String {
    switch self {
    case .github: return "gh"
    case .gitlab: return "glab"
    }
  }

  var authLoginCommand: String {
    switch self {
    case .github: return "gh auth login"
    case .gitlab: return "glab auth login"
    }
  }

  var cliInstallURL: URL {
    switch self {
    case .github: return URL(string: "https://cli.github.com")!
    case .gitlab: return URL(string: "https://gitlab.com/gitlab-org/cli")!
    }
  }
}
