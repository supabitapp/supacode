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
  var githubDesktopURLSchemeHandler: GitHubDesktopURLSchemeHandler?
  var githubDesktopURLSchemeError: String?
  var githubDesktopOAuthError: String?

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

  @discardableResult
  func authorizeGitHubDesktopOAuth(host: String) -> Bool {
    githubDesktopOAuthError = nil
    let state = GitHubDesktopOAuth.makeState(host: host)
    guard let url = GitHubDesktopOAuth.authorizationURL(host: host, state: state) else {
      githubDesktopOAuthError = "Invalid GitHub host."
      return false
    }
    NSWorkspace.shared.open(url)
    return true
  }

  func signOut(_ account: GitHubDesktopAccount) async {
    await GitHubDesktopOAuth.signOut(account)
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

private struct GitHubDesktopAccountGroup<Content: View>: View {
  let title: String
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title)
        .font(.headline)
      content()
    }
  }
}

private struct GitHubDesktopAccountRow: View {
  let account: GitHubDesktopAccount
  let onSignOut: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      GitHubDesktopAccountAvatar(account: account)
      VStack(alignment: .leading, spacing: 2) {
        if account.isDotCom {
          Text(account.displayName)
            .font(.headline)
          Text("@\(account.login)")
            .foregroundStyle(.secondary)
        } else {
          Text(account.name == account.login ? "@\(account.login)" : "@\(account.login) (\(account.name))")
            .font(.headline)
          Text(account.htmlURL)
            .foregroundStyle(.secondary)
        }
      }
      Spacer()
      Button("Sign Out", action: onSignOut)
        .help("Sign out of this GitHub Desktop account.")
    }
  }
}

private struct GitHubDesktopAccountAvatar: View {
  let account: GitHubDesktopAccount
  @State private var image: NSImage?

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image)
          .resizable()
          .scaledToFill()
      } else {
        placeholder
      }
    }
    .frame(width: 36, height: 36)
    .clipShape(Circle())
    .accessibilityHidden(true)
    .task(id: account) {
      await loadImage()
    }
  }

  private var placeholder: some View {
    Image(systemName: "person.crop.circle.fill")
      .resizable()
      .foregroundStyle(.secondary)
      .accessibilityHidden(true)
  }

  @MainActor
  private func loadImage() async {
    image = nil
    guard let request = GitHubDesktopOAuth.avatarRequest(for: account, size: 72) else { return }

    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard !Task.isCancelled, (response as? HTTPURLResponse)?.statusCode == 200 else { return }
      image = NSImage(data: data)
    } catch {
      image = nil
    }
  }
}

private struct GitHubDesktopSignInCallToAction: View {
  let text: String
  let buttonTitle: String
  let isEnabled: Bool
  let action: () -> Void

  var body: some View {
    HStack {
      Text(text)
        .foregroundStyle(.secondary)
      Spacer()
      Button(buttonTitle, action: action)
        .disabled(!isEnabled)
    }
  }
}

struct GithubSettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>
  @State private var viewModel = GithubSettingsViewModel()
  @State private var isAddingEnterpriseAccount = false
  @State private var enterpriseHost = ""

  private var dotComAccount: GitHubDesktopAccount? {
    store.githubDesktopAccounts.first(where: \.isDotCom)
  }

  private var enterpriseAccounts: [GitHubDesktopAccount] {
    store.githubDesktopAccounts.filter { !$0.isDotCom }
  }

  var body: some View {
    Form {
      Section {
        Toggle(isOn: $store.githubIntegrationEnabled) {
          Text("Enable GitHub Integration")
          Text("Pull request checks and merge actions in command palette.")
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
      }

      Section("GitHub Desktop Accounts") {
        GitHubDesktopAccountGroup(title: "GitHub.com") {
          if let dotComAccount {
            accountRow(dotComAccount)
          } else {
            GitHubDesktopSignInCallToAction(
              text: "Sign in to your GitHub.com account to access your repositories.",
              buttonTitle: "Sign Into GitHub.com",
              isEnabled: store.githubDesktopCloneLinksEnabled
            ) {
              viewModel.authorizeGitHubDesktopOAuth(host: "github.com")
            }
          }
        }

        GitHubDesktopAccountGroup(title: "GitHub Enterprise") {
          ForEach(enterpriseAccounts, id: \.endpoint) { account in
            accountRow(account)
          }

          if isAddingEnterpriseAccount {
            HStack {
              TextField("https://github.example.com", text: $enterpriseHost)
                .textFieldStyle(.roundedBorder)
              Button("Sign In") {
                let didOpen = viewModel.authorizeGitHubDesktopOAuth(host: enterpriseHost)
                if didOpen {
                  enterpriseHost = ""
                  isAddingEnterpriseAccount = false
                }
              }
              .disabled(
                !store.githubDesktopCloneLinksEnabled
                  || enterpriseHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
              Button("Cancel") {
                enterpriseHost = ""
                isAddingEnterpriseAccount = false
              }
            }
          } else {
            Button(
              enterpriseAccounts.isEmpty ? "Sign Into GitHub Enterprise" : "Add GitHub Enterprise account"
            ) {
              isAddingEnterpriseAccount = true
            }
            .disabled(!store.githubDesktopCloneLinksEnabled)
          }
        }

        if let message = viewModel.githubDesktopOAuthError {
          Text(message)
            .foregroundStyle(.red)
        }
      }

      githubCLISection

      Section("Pull Requests") {
        Picker(selection: $store.pullRequestMergeStrategy) {
          ForEach(PullRequestMergeStrategy.allCases, id: \.self) { strategy in
            Text(strategy.title).tag(strategy)
          }
        } label: {
          Text("Merge strategy")
          Text("Default strategy when merging PRs from the command palette.")
        }

        Picker(selection: $store.mergedWorktreeAction) {
          Text("Do nothing").tag(MergedWorktreeAction?.none)
          ForEach(MergedWorktreeAction.allCases, id: \.self) { action in
            Text(action.title).tag(MergedWorktreeAction?.some(action))
          }
        } label: {
          Text("Merged worktree action")
          Text("What to do after a pull request has been merged.")
        }
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .padding(.top, -20)
    .padding(.leading, -8)
    .padding(.trailing, -6)
    .navigationTitle("GitHub")
    .task {
      await viewModel.load()
      await viewModel.loadGithubDesktopURLSchemeHandler()
    }
    .onChange(of: store.githubIntegrationEnabled) { _, _ in
      Task { await viewModel.load() }
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

  private func accountRow(_ account: GitHubDesktopAccount) -> some View {
    GitHubDesktopAccountRow(account: account) {
      Task {
        store.send(.removeGitHubDesktopAccount(endpoint: account.endpoint))
        await viewModel.signOut(account)
      }
    }
  }

  @ViewBuilder
  private var githubCLISection: some View {
    Section("GitHub CLI") {
      switch viewModel.state {
      case .loading:
        LabeledContent("Checking GitHub CLI...") {
          ProgressView()
            .controlSize(.small)
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
            Text("Run `gh auth login` in terminal to authenticate.")
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
  }
}
