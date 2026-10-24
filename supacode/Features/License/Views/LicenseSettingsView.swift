import ComposableArchitecture
import SwiftUI

struct LicenseSettingsView: View {
  let store: StoreOf<LicenseFeature>

  var body: some View {
    let snapshot = store.snapshot
    let isActivated = snapshot.entitlement?.status == .active
    Form {
      Section {
        LicenseStatusRow(status: snapshot.displayStatus, errorMessage: store.errorMessage)
        if isActivated, let updatesThrough = snapshot.entitlement?.updatesThrough {
          LabeledContent("Updates through", value: updatesThrough.formatted())
        }
        if !snapshot.ownsCurrentRelease, !snapshot.isDevelopmentBuild {
          LabeledContent {
            Text("\(snapshot.remainingCreations) of \(LicenseSnapshot.freeCreationLimit)")
              .monospacedDigit()
          } label: {
            Text("Free local worktrees")
            Text("Worktrees on SSH hosts are always free.")
          }
        }
      } footer: {
        isActivated
          ? Text("Owned versions work offline. Transfers and refunds apply after this Mac next refreshes its license.")
          : nil
      }
      if isActivated {
        LicenseManageSection(store: store)
      } else {
        LicenseActivateSection(store: store)
      }
      Section {
        LabeledContent {
          Button("Buy\u{2026}") { store.send(.buy) }
            .help("Open the Supacode checkout in your browser.")
        } label: {
          Text("Buy Supacode")
          Text("Purchase a license in your browser.")
        }
        LabeledContent {
          Button("Open Portal") { store.send(.portal) }
            .help("Open the license portal in your browser.")
        } label: {
          Text("License portal")
          Text("Recover your key, renew updates, or manage your license.")
        }
      }
    }
    .formStyle(.grouped)
    .contentMargins(.trailing, 6, for: .scrollIndicators)
    .padding(.top, -20)
    .padding(.leading, -8)
    .padding(.trailing, -6)
    .navigationTitle("License")
  }
}

private struct LicenseStatusRow: View {
  let status: LicenseDisplayStatus
  let errorMessage: String?

  var body: some View {
    LabeledContent {
      Label {
        Text(title)
      } icon: {
        Image(systemName: systemImage)
          .foregroundStyle(tint)
          .accessibilityHidden(true)
      }
    } label: {
      Text("Status")
      if let errorMessage {
        Text(errorMessage)
          .foregroundStyle(.red)
      } else if let subtitle {
        Text(subtitle)
      }
    }
  }

  private var title: String {
    switch status {
    case .developmentBuild: "Development build"
    case .notActivated: "Not activated"
    case .active: "Active"
    case .updatesExpired: "Updates expired"
    case .deactivated: "Deactivated"
    case .revoked: "Revoked"
    case .transferred: "Transferred"
    }
  }

  private var subtitle: String? {
    switch status {
    case .developmentBuild:
      "Licensing is not enforced in development builds."
    case .notActivated:
      "Activate a license key to keep creating local worktrees."
    case .active:
      nil
    case .updatesExpired:
      "Your updates don't cover this version. Renew them in the license portal."
    case .deactivated:
      "This Mac was deactivated. Activate your key again to use it here."
    case .revoked(let reason):
      reason ?? "This license was revoked."
    case .transferred:
      "This license moved to another Mac. Activate it again to use it here."
    }
  }

  private var systemImage: String {
    switch status {
    case .active: "checkmark.seal.fill"
    case .updatesExpired: "exclamationmark.triangle.fill"
    case .revoked, .transferred, .deactivated: "xmark.seal.fill"
    case .developmentBuild: "hammer.fill"
    case .notActivated: "key.fill"
    }
  }

  private var tint: Color {
    switch status {
    case .active: .green
    case .updatesExpired: .orange
    case .revoked, .transferred, .deactivated: .red
    case .developmentBuild, .notActivated: .secondary
    }
  }
}

private struct LicenseManageSection: View {
  let store: StoreOf<LicenseFeature>

  var body: some View {
    Section {
      LabeledContent {
        Button("Refresh") { store.send(.refresh) }
          .disabled(store.isBusy)
          .help("Check the license server for renewed updates or license changes.")
      } label: {
        Text("Refresh license")
        Text("Supacode checks for license changes once a day.")
      }
      LabeledContent {
        HStack {
          if store.isBusy {
            ProgressView()
              .controlSize(.small)
              .accessibilityLabel("Deactivating")
          }
          Button("Deactivate\u{2026}", role: .destructive) { store.send(.deactivateButtonTapped) }
            .disabled(store.isBusy)
            .help("Deactivate this Mac so you can activate your license on another Mac.")
        }
      } label: {
        Text("Deactivate this Mac")
        Text("Lets you activate your license on another Mac.")
      }
    }
  }
}

private struct LicenseActivateSection: View {
  @Bindable var store: StoreOf<LicenseFeature>

  var body: some View {
    Section("Activate") {
      TextField("License key", text: $store.keyInput, prompt: Text("SUPACODE-\u{2026}"))
        .monospaced()
        .lineLimit(1)
        .truncationMode(.middle)
        .onSubmit { store.send(.activate) }
      LabeledContent {
        HStack {
          if store.isBusy {
            ProgressView()
              .controlSize(.small)
              .accessibilityLabel("Activating")
          }
          Button("Activate") { store.send(.activate) }
            .keyboardShortcut(.defaultAction)
            .disabled(store.isBusy || store.isKeyInputEmpty)
            .help("Activate your license on this Mac (Return)")
        }
      } label: {
        Text("Activate this Mac")
        Text("Lost your key? Recover it from the license portal.")
      }
    }
  }
}
