//
//  ContentView.swift
//  supacode
//
//  Created by khoi on 20/1/26.
//

import ComposableArchitecture
import SupacodeSettingsShared
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
    NavigationSplitView(columnVisibility: $leftSidebarVisibility) {
      SidebarView(store: repositoriesStore, terminalManager: terminalManager)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
    } detail: {
      WorktreeDetailView(store: store, terminalManager: terminalManager)
    }
    .navigationSplitViewStyle(.automatic)
    .disabled(!store.repositories.isInitialLoadComplete)
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
    .sheet(
      store: repositoriesStore.scope(
        state: \.$repositoryCustomization,
        action: \.repositoryCustomization
      )
    ) { customizationStore in
      RepositoryCustomizationView(store: customizationStore)
    }
    .focusedSceneValue(\.toggleLeftSidebarAction, toggleLeftSidebar)
    .focusedSceneValue(\.revealInSidebarAction, revealInSidebarAction)
    .overlay {
      CommandPaletteOverlayView(
        store: store.scope(state: \.commandPalette, action: \.commandPalette),
        items: CommandPaletteFeature.commandPaletteItems(
          from: store.repositories,
          ghosttyCommands: ghosttyShortcuts.commandPaletteEntries,
          scripts: store.scripts,
          runningScriptIDs: store.runningScriptIDs
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
      guard surfaceBackgroundOpacity < 1 else { return 1 }
      let proportionalOpacity = surfaceBackgroundOpacity * 0.56
      return max(0.36, min(proportionalOpacity, 0.62))
    }
    set {
      surfaceBackgroundOpacity = newValue
    }
  }

  var surfaceBottomChromeBackgroundOpacity: Double {
    get {
      guard surfaceBackgroundOpacity < 1 else { return 1 }
      let proportionalOpacity = surfaceBackgroundOpacity * 0.78
      return max(0.52, min(proportionalOpacity, 0.82))
    }
    set {
      surfaceBackgroundOpacity = newValue
    }
  }
}
