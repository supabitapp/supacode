import ComposableArchitecture
import SwiftUI

struct TaskCreationSheet: View {
  @Bindable var store: StoreOf<RepositoriesFeature>
  let repositoryID: Repository.ID
  @State private var taskName = ""
  @State private var initialPrompt = ""
  @State private var autoApprove = false
  @State private var baseBranch = ""
  @State private var selectedAgentIDs: Set<String> = ["claude"]
  @State private var agentRunCounts: [String: Int] = [:]

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("New Task")
        .font(.headline)

      TextField("Task name", text: $taskName)
        .textFieldStyle(.roundedBorder)

      VStack(alignment: .leading, spacing: 8) {
        Text("Agents")
          .font(.subheadline)
          .foregroundStyle(.secondary)
        ForEach(AgentProvider.registry) { agent in
          HStack {
            Toggle(isOn: Binding(
              get: { selectedAgentIDs.contains(agent.id) },
              set: { isOn in
                if isOn {
                  selectedAgentIDs.insert(agent.id)
                } else {
                  selectedAgentIDs.remove(agent.id)
                }
              }
            )) {
              Label(agent.name, systemImage: agent.icon)
            }
            Spacer()
            if selectedAgentIDs.contains(agent.id) {
              Stepper(
                value: Binding(
                  get: { agentRunCounts[agent.id, default: 1] },
                  set: { agentRunCounts[agent.id] = $0 }
                ),
                in: 1...4
              ) {
                Text("x\(agentRunCounts[agent.id, default: 1])")
                  .font(.body.monospaced())
                  .frame(minWidth: 24)
              }
            }
          }
        }
      }

      VStack(alignment: .leading, spacing: 4) {
        Text("Initial prompt")
          .font(.subheadline)
          .foregroundStyle(.secondary)
        TextEditor(text: $initialPrompt)
          .font(.body.monospaced())
          .frame(minHeight: 60, maxHeight: 120)
          .overlay(
            RoundedRectangle(cornerRadius: 6)
              .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
          )
      }

      Toggle("Auto-approve agent actions", isOn: $autoApprove)

      TextField("Base branch (optional)", text: $baseBranch)
        .textFieldStyle(.roundedBorder)

      HStack {
        Spacer()
        Button("Cancel") {
          store.send(.dismissTaskCreationSheet)
        }
        .keyboardShortcut(.cancelAction)
        .help("Cancel")
        Button("Create") {
          createTask()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(taskName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedAgentIDs.isEmpty)
        .help("Create task")
      }
    }
    .padding(20)
    .frame(width: 440)
    .onAppear {
      if let repoName = store.state.repositoryName(for: repositoryID) {
        let _ = repoName
      }
    }
  }

  private func createTask() {
    let trimmedName = taskName
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacing(/[^a-z0-9-]/, with: "-")
      .replacing(/--+/, with: "-")
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    guard !trimmedName.isEmpty else { return }

    let agentRuns = selectedAgentIDs.sorted().map { agentID in
      RepositoriesFeature.TaskCreationConfig.AgentRun(
        agentID: agentID,
        count: agentRunCounts[agentID, default: 1]
      )
    }

    store.send(.createTaskWithConfig(
      RepositoriesFeature.TaskCreationConfig(
        repositoryID: repositoryID,
        name: trimmedName,
        initialPrompt: initialPrompt,
        autoApprove: autoApprove,
        baseBranch: baseBranch,
        agentRuns: agentRuns
      )
    ))
  }
}
