//
//  ContentView.swift
//  supacode
//
//  Created by khoi on 20/1/26.
//

import ComposableArchitecture
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
  @Bindable var store: StoreOf<AppFeature>
  @Bindable var repositoriesStore: StoreOf<RepositoriesFeature>
  let terminalManager: WorktreeTerminalManager
  @Environment(\.scenePhase) private var scenePhase
  @Environment(GhosttyShortcutManager.self) private var ghosttyShortcuts
  @State private var leftSidebarVisibility: NavigationSplitViewVisibility = .all

  init(store: StoreOf<AppFeature>, terminalManager: WorktreeTerminalManager) {
    self.store = store
    repositoriesStore = store.scope(state: \.repositories, action: \.repositories)
    self.terminalManager = terminalManager
  }

  var body: some View {
    let isRunScriptPromptPresented = Binding(
      get: { store.isRunScriptPromptPresented },
      set: { store.send(.runScriptPromptPresented($0)) }
    )
    let runScriptDraft = Binding(
      get: { store.runScriptDraft },
      set: { store.send(.runScriptDraftChanged($0)) }
    )
    Group {
      if store.repositories.isInitialLoadComplete {
        NavigationSplitView(columnVisibility: $leftSidebarVisibility) {
          SidebarView(store: repositoriesStore, terminalManager: terminalManager)
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
          WorktreeDetailView(store: store, terminalManager: terminalManager)
        }
        .navigationSplitViewStyle(.automatic)
      } else {
        AppLoadingView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(.background)
      }
    }
    .environment(\.surfaceBackgroundOpacity, terminalManager.surfaceBackgroundOpacity())
    .onChange(of: scenePhase) { _, newValue in
      store.send(.scenePhaseChanged(newValue))
    }
    .fileImporter(
      isPresented: $repositoriesStore.isOpenPanelPresented.sending(\.setOpenPanelPresented),
      allowedContentTypes: [.folder],
      allowsMultipleSelection: true
    ) { result in
      switch result {
      case .success(let urls):
        store.send(.repositories(.openRepositories(urls)))
      case .failure:
        store.send(
          .repositories(
            .presentAlert(
              title: "Unable to open folders",
              message: "Supacode could not read the selected folders."
            )
          )
        )
      }
    }
    .alert(store: repositoriesStore.scope(state: \.$alert, action: \.alert))
    .alert(store: store.scope(state: \.$alert, action: \.alert))
    .sheet(
      store: store.scope(state: \.$deeplinkInputConfirmation, action: \.deeplinkInputConfirmation)
    ) { confirmationStore in
      DeeplinkInputConfirmationView(store: confirmationStore)
    }
    .sheet(
      store: repositoriesStore.scope(state: \.$worktreeCreationPrompt, action: \.worktreeCreationPrompt)
    ) { promptStore in
      WorktreeCreationPromptView(store: promptStore)
    }
    .sheet(isPresented: isRunScriptPromptPresented) {
      RunScriptPromptView(
        script: runScriptDraft,
        onCancel: {
          store.send(.runScriptPromptPresented(false))
        },
        onSaveAndRun: {
          store.send(.saveRunScriptAndRun)
        }
      )
    }
    .focusedSceneValue(\.toggleLeftSidebarAction, toggleLeftSidebar)
    .focusedSceneValue(\.revealInSidebarAction, revealInSidebarAction)
    .overlay {
      CommandPaletteOverlayView(
        store: store.scope(state: \.commandPalette, action: \.commandPalette),
        items: CommandPaletteFeature.commandPaletteItems(
          from: store.repositories,
          ghosttyCommands: ghosttyShortcuts.commandPaletteEntries
        )
      )
    }
    .background(WindowTabbingDisabler())
  }

  private func toggleLeftSidebar() {
    withAnimation(.easeOut(duration: 0.2)) {
      leftSidebarVisibility = leftSidebarVisibility == .detailOnly ? .all : .detailOnly
    }
  }

  private var revealInSidebarAction: (() -> Void)? {
    guard store.repositories.selectedWorktreeID != nil else { return nil }
    return { revealInSidebar() }
  }

  private func revealInSidebar() {
    withAnimation(.easeOut(duration: 0.2)) {
      leftSidebarVisibility = .all
    }
    store.send(.repositories(.revealSelectedWorktreeInSidebar))
  }

}

private struct SurfaceBackgroundOpacityKey: EnvironmentKey {
  static let defaultValue: Double = 1
}

extension EnvironmentValues {
  var surfaceBackgroundOpacity: Double {
    get { self[SurfaceBackgroundOpacityKey.self] }
    set { self[SurfaceBackgroundOpacityKey.self] = newValue }
  }

  var surfaceTopChromeBackgroundOpacity: Double {
    get {
      if surfaceBackgroundOpacity < 1 {
        let proportionalOpacity = surfaceBackgroundOpacity * 0.56
        return min(max(proportionalOpacity, 0.36), 0.62)
      }
      return 1
    }
    set {
      surfaceBackgroundOpacity = newValue
    }
  }

  var surfaceBottomChromeBackgroundOpacity: Double {
    get {
      if surfaceBackgroundOpacity < 1 {
        let proportionalOpacity = surfaceBackgroundOpacity * 0.78
        return min(max(proportionalOpacity, 0.52), 0.82)
      }
      return 1
    }
    set {
      surfaceBackgroundOpacity = newValue
    }
  }
}

private struct RunScriptPromptView: View {
  @Binding var script: String
  let onCancel: () -> Void
  let onSaveAndRun: () -> Void

  private var canSave: Bool {
    !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Run")
          .font(.title3)
        Text("Enter a command to run in this worktree. It will be saved to repository settings.")
          .foregroundStyle(.secondary)
      }

      ZStack(alignment: .topLeading) {
        PlainTextEditor(
          text: $script,
          isMonospaced: true
        )
        .frame(minHeight: 160)
        if script.isEmpty {
          Text("npm run dev")
            .foregroundStyle(.secondary)
            .padding(.leading, 6)
            .font(.body.monospaced())
            .allowsHitTesting(false)
        }
      }

      HStack {
        Spacer()
        Button("Cancel") {
          onCancel()
        }
        .keyboardShortcut(.cancelAction)
        .help("Cancel (Esc)")

        Button("Save and Run") {
          onSaveAndRun()
        }
        .keyboardShortcut(.defaultAction)
        .help("Save and Run (↩)")
        .disabled(!canSave)
      }
    }
    .padding(20)
    .frame(minWidth: 520)
  }
}
