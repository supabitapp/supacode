import AppKit
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

  @ObservationIgnored
  @Dependency(GitHubDesktopURLSchemeClient.self) private var githubDesktopURLScheme

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
        if githubDesktopOAuthHost == "github.com" {
          githubDesktopOAuthHost = status.host
        }
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

  var githubDesktopURLSchemeHandler: GitHubDesktopURLSchemeHandler?
  var githubDesktopURLSchemeError: String?
  var githubDesktopOAuthHost = "github.com"
  var githubDesktopOAuthError: String?

  func loadGithubDesktopURLSchemeHandler() async {
    githubDesktopURLSchemeError = nil
    githubDesktopURLSchemeHandler = await githubDesktopURLScheme.currentHandler()
  }

  func claimGithubDesktopURLScheme() async {
    do {
      try await githubDesktopURLScheme.claim()
      await loadGithubDesktopURLSchemeHandler()
    } catch {
      githubDesktopURLSchemeError = error.localizedDescription
      githubDesktopURLSchemeHandler = await githubDesktopURLScheme.currentHandler()
    }
  }

  func authorizeGitHubDesktopOAuth() {
    githubDesktopOAuthError = nil
    let state = GitHubDesktopOAuth.makeState(host: githubDesktopOAuthHost)
    guard let url = GitHubDesktopOAuth.authorizationURL(host: githubDesktopOAuthHost, state: state) else {
      githubDesktopOAuthError = "Invalid GitHub host."
      return
    }
    NSWorkspace.shared.open(url)
  }
}

private struct GitHubDesktopURLSchemeHandlerView: View {
  let handler: GitHubDesktopURLSchemeHandler?
  let supacodeBundleIdentifier: String?

  var body: some View {
    if let handler {
      if handler.bundleIdentifier == supacodeBundleIdentifier {
        Text("Supacode")
      } else {
        HStack(spacing: 6) {
          if let applicationURL = handler.applicationURL {
            Image(nsImage: NSWorkspace.shared.icon(forFile: applicationURL.path(percentEncoded: false)))
              .resizable()
              .frame(width: 16, height: 16)
              .accessibilityHidden(true)
          }
          Text(handler.applicationName)
        }
      }
    } else {
      Text("No application")
        .foregroundStyle(.secondary)
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
        Toggle(isOn: $store.githubDesktopCloneLinksEnabled) {
          Text("Handle GitHub Desktop clone links")
          Text("Open GitHub Desktop repository links in Supacode's clone window.")
        }
        LabeledContent("Current clone link handler") {
          GitHubDesktopURLSchemeHandlerView(
            handler: viewModel.githubDesktopURLSchemeHandler,
            supacodeBundleIdentifier: Bundle.main.bundleIdentifier
          )
        }
        if let message = viewModel.githubDesktopURLSchemeError {
          Text(message)
            .foregroundStyle(.red)
        }
        LabeledContent("Desktop OAuth host") {
          TextField(
            "github.com",
            text: Binding(
              get: { viewModel.githubDesktopOAuthHost },
              set: { viewModel.githubDesktopOAuthHost = $0 }
            )
          )
          .textFieldStyle(.roundedBorder)
          .frame(maxWidth: 260)
        }
        Button("Authorize GitHub Desktop") {
          viewModel.authorizeGitHubDesktopOAuth()
        }
        .disabled(!store.githubDesktopCloneLinksEnabled)
        .help("Open GitHub Desktop authorization for the selected host.")
        Text("Experimental GitHub Desktop OAuth compatibility.")
          .font(.callout)
          .foregroundStyle(.secondary)
        if let message = viewModel.githubDesktopOAuthError {
          Text(message)
            .foregroundStyle(.red)
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
      await viewModel.loadGithubDesktopURLSchemeHandler()
    }
    .onChange(of: store.githubIntegrationEnabled) { _, _ in
      Task {
        await viewModel.load()
      }
    }
    .onChange(of: store.githubDesktopCloneLinksEnabled) { _, isEnabled in
      Task {
        if isEnabled {
          await viewModel.claimGithubDesktopURLScheme()
        } else {
          await viewModel.loadGithubDesktopURLSchemeHandler()
        }
      }
    }
  }
}
