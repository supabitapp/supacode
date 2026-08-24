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

/// One status detail line under a forge row's subtitle; `tint` nil renders secondary.
private struct ForgeStatusLine: View {
  let text: Text
  var tint: Color?

  var body: some View {
    text
      .appFont(.subheadline)
      .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
  }
}

extension ForgeCapabilities {
  fileprivate var features: [FeatureCapability] {
    [
      FeatureCapability(name: "Sidebar \(vocabulary.abbreviation) icons", isSupported: true),
      FeatureCapability(name: "Inspector details", isSupported: true),
      FeatureCapability(name: "Command palette actions", isSupported: true),
      FeatureCapability(name: "Auto-archive merged worktrees", isSupported: true),
      FeatureCapability(name: "Squash merges", isSupported: mergeStrategies.contains(.squash)),
      FeatureCapability(name: "Rebase merges", isSupported: mergeStrategies.contains(.rebase)),
      FeatureCapability(name: "Mark ready for review", isSupported: canMarkReady),
      FeatureCapability(
        name: "Re-run failed \(vocabulary.ciNoun.lowercased())", isSupported: canRerunChecks),
      FeatureCapability(name: "Copy failure logs", isSupported: canCopyCIFailureLogs),
    ]
  }
}

/// One forge row: service icon, title, status detail, and the enable switch.
private struct ForgeRow<Detail: View>: View {
  let title: String
  let assetName: String
  let capabilities: ForgeCapabilities
  var isBeta = false
  @Binding var isEnabled: Bool
  @ViewBuilder var detail: Detail

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Image(assetName)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: 18, height: 18)
        .foregroundStyle(.primary)
        // Image has no native baseline; nudge so its visual center sits near the title baseline.
        .alignmentGuide(.firstTextBaseline) { dimension in dimension[.bottom] - 5 }
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(title)
          isBeta ? BetaBadge() : nil
        }
        detail
        FeatureCapabilityGrid(capabilities: capabilities.features)
      }
      Spacer()
      Toggle(title, isOn: $isEnabled)
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.small)
        .help("Enable or disable the \(title) integration.")
    }
  }
}

private struct GithubForgeStatusView: View {
  let state: GithubSettingsViewModel.State

  var body: some View {
    switch state {
    case .loading:
      ForgeStatusLine(text: Text("Checking GitHub CLI…"))
    case .unavailable:
      HStack(spacing: 6) {
        ForgeStatusLine(text: Text("GitHub CLI not found"), tint: .red)
        Divider()
        ForgeStatusLine(text: Text("[Install `gh` \u{2197}](https://cli.github.com)"))
      }
    case .outdated:
      HStack(spacing: 6) {
        ForgeStatusLine(text: Text("GitHub CLI outdated"), tint: .orange)
        Divider()
        ForgeStatusLine(text: Text("[Update \u{2197}](https://cli.github.com)"))
      }
    case .notAuthenticated:
      ForgeStatusLine(
        text: Text("Not authenticated. Run `gh auth login` in a terminal to authenticate."),
        tint: .orange
      )
    case .authenticated(let username, let host):
      HStack(spacing: 6) {
        ForgeStatusLine(text: Text("Signed in as \(Text(username).bold())"))
        Divider()
        ForgeStatusLine(text: Text(host).bold())
      }
    case .error(let message):
      ForgeStatusLine(text: Text(message), tint: .red)
    }
  }
}

private struct GitLabForgeStatusView: View {
  let state: GitLabSettingsViewModel.State

  var body: some View {
    switch state {
    case .loading:
      ForgeStatusLine(text: Text("Checking GitLab CLI…"))
    case .unavailable:
      HStack(spacing: 6) {
        ForgeStatusLine(text: Text("GitLab CLI not found"), tint: .red)
        Divider()
        ForgeStatusLine(text: Text("[Install `glab` \u{2197}](https://gitlab.com/gitlab-org/cli)"))
      }
    case .notAuthenticated:
      ForgeStatusLine(
        text: Text("Not authenticated. Run `glab auth login --hostname <host>` in a terminal to authenticate."),
        tint: .orange
      )
    case .authenticated(let hosts):
      HStack(spacing: 6) {
        if let first = hosts.first {
          ForgeStatusLine(text: Text("Signed in on \(Text(first).bold())"))
        }
        ForEach(hosts.dropFirst(), id: \.self) { host in
          Divider()
          ForgeStatusLine(text: Text(host).bold())
        }
      }
    }
  }
}

struct ForgesSettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>
  @State private var viewModel = GithubSettingsViewModel()
  @State private var gitlabViewModel = GitLabSettingsViewModel()

  var body: some View {
    Form {
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
      } footer: {
        Text("Worktree merge actions only affect pre-existing local worktrees.")
      }
      Section {
        ForgeRow(
          title: "GitHub",
          assetName: "github-mark",
          capabilities: .github,
          isEnabled: $store.githubIntegrationEnabled
        ) {
          GithubForgeStatusView(state: viewModel.state)
        }
        ForgeRow(
          title: "GitLab",
          assetName: "gitlab-mark",
          capabilities: .gitlab,
          isBeta: true,
          isEnabled: $store.gitlabIntegrationEnabled
        ) {
          GitLabForgeStatusView(state: gitlabViewModel.state)
        }
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
    .onChange(of: store.gitlabIntegrationEnabled) { _, _ in
      Task {
        await gitlabViewModel.load()
      }
    }
  }
}
