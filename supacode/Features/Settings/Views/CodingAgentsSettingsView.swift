import ComposableArchitecture
import SwiftUI

struct CodingAgentsSettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>
  @State private var pendingEnable: PendingEnable?

  private enum PendingEnable: String, Identifiable {
    case claude
    case codex

    var id: String { rawValue }

    var title: String {
      switch self {
      case .claude:
        return "Enable Claude Code integration?"
      case .codex:
        return "Enable Codex integration?"
      }
    }
  }

  var body: some View {
    Form {
      Section("Integrations") {
        Toggle(
          "Enable Claude Code integration",
          isOn: claudeEnabledBinding
        )
        .help("Enable Claude Code integration")

        Toggle(
          "Enable Codex integration",
          isOn: codexEnabledBinding
        )
        .help("Enable Codex integration")
      }

      Section("Behavior") {
        Text(
          "Supacode injects wrapper scripts into terminal PATH to detect working and idle states."
        )
        .foregroundStyle(.secondary)
        .font(.callout)

        Text("Only new terminal sessions are affected.")
          .foregroundStyle(.secondary)
          .font(.callout)
      }
    }
    .formStyle(.grouped)
    .alert(
      pendingEnable?.title ?? "",
      isPresented: isAlertPresented,
      presenting: pendingEnable
    ) { integration in
      Button("Cancel", role: .cancel) {
        pendingEnable = nil
      }
      Button("Enable") {
        setEnabled(integration, true)
        pendingEnable = nil
      }
    } message: { _ in
      Text("Supacode will inject a wrapper script into terminal PATH to detect activity.")
    }
  }

  private var isAlertPresented: Binding<Bool> {
    Binding(
      get: { pendingEnable != nil },
      set: { isPresented in
        if !isPresented {
          pendingEnable = nil
        }
      }
    )
  }

  private var claudeEnabledBinding: Binding<Bool> {
    Binding(
      get: { store.claudeCodeIntegrationEnabled },
      set: { isEnabled in
        if isEnabled {
          if !store.claudeCodeIntegrationEnabled {
            pendingEnable = .claude
          }
          return
        }
        setEnabled(.claude, false)
      }
    )
  }

  private var codexEnabledBinding: Binding<Bool> {
    Binding(
      get: { store.codexIntegrationEnabled },
      set: { isEnabled in
        if isEnabled {
          if !store.codexIntegrationEnabled {
            pendingEnable = .codex
          }
          return
        }
        setEnabled(.codex, false)
      }
    )
  }

  private func setEnabled(_ integration: PendingEnable, _ isEnabled: Bool) {
    switch integration {
    case .claude:
      store.send(.binding(.set(\.claudeCodeIntegrationEnabled, isEnabled)))
    case .codex:
      store.send(.binding(.set(\.codexIntegrationEnabled, isEnabled)))
    }
  }
}
