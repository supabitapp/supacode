import ComposableArchitecture
import SwiftUI

@MainActor @Observable
final class CodingAgentsSettingsViewModel {
  var status: CodingAgentIntegrationStatus = .disabled
  var isLoading = false
  var errorMessage: String?

  @ObservationIgnored
  @Dependency(CodingAgentIntegrationClient.self) private var integrationClient

  func load() async {
    isLoading = true
    defer { isLoading = false }
    do {
      status = try await integrationClient.status()
      errorMessage = nil
    } catch {
      status = .disabled
      errorMessage = error.localizedDescription
    }
  }

  func setEnabled(_ agent: CodingAgent, enabled: Bool) async {
    let previous = status
    status.setEnabled(enabled, for: agent)
    do {
      try await integrationClient.setEnabled(agent, enabled)
      status = try await integrationClient.status()
      errorMessage = nil
    } catch {
      status = previous
      errorMessage = error.localizedDescription
    }
  }
}

struct CodingAgentsSettingsView: View {
  @State private var viewModel = CodingAgentsSettingsViewModel()

  var body: some View {
    VStack(alignment: .leading) {
      Form {
        Section("Integration") {
          if viewModel.isLoading {
            HStack(spacing: 8) {
              ProgressView()
                .controlSize(.small)
              Text("Checking integration status...")
                .foregroundStyle(.secondary)
            }
          } else {
            LabeledContent("Status") {
              Text(viewModel.status.isEnabled ? "On" : "Off")
                .foregroundStyle(viewModel.status.isEnabled ? .green : .secondary)
            }
          }
        }
        Section("Agents") {
          Toggle(
            "Claude Code",
            isOn: binding(for: .claude)
          )
          .disabled(viewModel.isLoading)
          .help("Configure Claude Code hooks for worktree progress status")
          Toggle(
            "Codex",
            isOn: binding(for: .codex)
          )
          .disabled(viewModel.isLoading)
          .help("Configure Codex notify hook for worktree progress status")
        }
        if let errorMessage = viewModel.errorMessage {
          Section {
            Text(errorMessage)
              .foregroundStyle(.red)
          }
        }
        Section("Notes") {
          Text("Open a new terminal tab after changing these settings so PATH updates are applied.")
            .foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .task {
      await viewModel.load()
    }
  }

  private func binding(for agent: CodingAgent) -> Binding<Bool> {
    Binding(
      get: {
        viewModel.status.isEnabled(for: agent)
      },
      set: { enabled in
        Task {
          await viewModel.setEnabled(agent, enabled: enabled)
        }
      }
    )
  }
}
