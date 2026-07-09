import AppKit
import ComposableArchitecture
import OrderedCollections
import Sharing
import SupacodeSettingsShared
import SwiftUI

struct SidebarListView: View {
  @Bindable var store: StoreOf<RepositoriesFeature>
  let terminalManager: WorktreeTerminalManager
  @FocusState private var isSidebarFocused: Bool
  @Environment(CommandKeyObserver.self) private var commandKeyObserver
  @Shared(.settingsFile) private var settingsFile
  /// Read here purely so SwiftUI re-runs the body (and fires the `.onChange`
  /// below) when the menu writes a new value. The structure compute itself
  /// reads the toggles via local `@Shared` inside the reducer.
  @Shared(.sidebarGroupPinnedRows) private var groupPinnedRows: Bool
  @Shared(.sidebarGroupActiveRows) private var groupActiveRows: Bool
  @Shared(.sidebarNestWorktreesByBranch) private var nestWorktreesByBranch: Bool

  var body: some View {
    let state = store.state
    let structure = state.sidebarStructure
    let selectedWorktreeIDs = state.sidebarSelectedWorktreeIDs
    let currentSelections = state.sidebarSelections
    let selection = Binding<Set<SidebarSelection>>(
      get: { currentSelections },
      set: { newValue in
        guard newValue != currentSelections else { return }
        store.send(.selectionChanged(newValue, focusTerminal: true))
      }
    )
    let pendingSidebarReveal = state.pendingSidebarReveal

    // The only legal view-side computation: a trivial join from the
    // reducer-derived `slotByID` against the Cmd state + shortcut overrides.
    // Gated on `isPressed` so the dict is empty when no hints are visible.
    let shortcutHintByID: [Worktree.ID: String]
    if commandKeyObserver.isPressed {
      let overrides = settingsFile.global.shortcutOverrides
      shortcutHintByID = structure.slotByID.compactMapValues { index in
        AppShortcuts.worktreeSelectionShortcutDisplay(atSlot: index, overrides: overrides)
      }
    } else {
      shortcutHintByID = [:]
    }

    return ScrollViewReader { scrollProxy in
      List(selection: selection) {
        ForEach(structure.sections) { section in
          SidebarSectionDispatcher(
            section: section,
            structure: structure,
            shortcutHintByID: shortcutHintByID,
            selectedWorktreeIDs: selectedWorktreeIDs,
            store: store,
            terminalManager: terminalManager
          )
        }
        .onMove { offsets, destination in
          handleRepositoryMove(
            offsets: offsets,
            destination: destination,
            structure: structure
          )
        }
      }
      .listStyle(.sidebar)
      .focused($isSidebarFocused)
      .frame(minWidth: 220)
      .onChange(of: groupPinnedRows, initial: false) { _, _ in
        store.send(.sidebarGroupingTogglesChanged)
      }
      .onChange(of: groupActiveRows, initial: false) { _, _ in
        store.send(.sidebarGroupingTogglesChanged)
      }
      .onChange(of: nestWorktreesByBranch, initial: false) { _, _ in
        store.send(.sidebarNestByBranchChanged)
      }
      .dropDestination(for: URL.self) { urls, _ in
        let fileURLs = urls.filter(\.isFileURL)
        guard !fileURLs.isEmpty else { return false }
        store.send(.openRepositories(fileURLs))
        return true
      }
      .onKeyPress { keyPress in
        guard !keyPress.characters.isEmpty else { return .ignored }
        let navigationKeys: Set<KeyEquivalent> = [
          .upArrow, .downArrow, .leftArrow, .rightArrow,
          .home, .end, .pageUp, .pageDown,
        ]
        guard !navigationKeys.contains(keyPress.key) else { return .ignored }
        let hasCommandModifier = keyPress.modifiers.contains(.command)
        if hasCommandModifier { return .ignored }
        guard let worktreeID = store.selectedWorktreeID,
          state.sidebarSelectedWorktreeIDs.count == 1,
          state.sidebarSelectedWorktreeIDs.contains(worktreeID),
          let terminalState = terminalManager.stateIfExists(for: worktreeID)
        else { return .ignored }
        terminalState.focusAndInsertText(keyPress.characters)
        return .handled
      }
      .background(
        // NSOutlineView consumes arrow keys before SwiftUI `onKeyPress` runs.
        SidebarRightArrowMonitor(isSidebarFocused: isSidebarFocused) {
          guard let worktreeID = store.selectedWorktreeID,
            state.sidebarSelectedWorktreeIDs.count == 1,
            state.sidebarSelectedWorktreeIDs.contains(worktreeID),
            let terminalState = terminalManager.stateIfExists(for: worktreeID)
          else { return false }
          terminalState.focusSelectedTab()
          return true
        }
      )
      .task(id: pendingSidebarReveal?.id) {
        await revealPendingSidebarWorktree(pendingSidebarReveal, with: scrollProxy)
      }
    }
  }

  /// SwiftUI's `.onMove` reports offsets in the flat ForEach data array. The
  /// structure exposes `reorderableRepositoryIDs` so we can translate a flat
  /// move into the repository index space the `.repositoriesMoved` reducer
  /// expects. Non-repo sections carry `.moveDisabled(true)` so they can't be
  /// sources of a drag; the destination clamps below.
  private func handleRepositoryMove(
    offsets: IndexSet,
    destination: Int,
    structure: SidebarStructure
  ) {
    let repoIDs = structure.reorderableRepositoryIDs
    guard !repoIDs.isEmpty else { return }
    let sourceFlat = offsets.sorted()
    let sectionsCount = structure.sections.count
    // Map flat section indices to repo indices via SectionID matching. Skip
    // any flat offset that doesn't correspond to a reorderable repo section.
    var repoOffsets = IndexSet()
    for index in sourceFlat where index < sectionsCount {
      let section = structure.sections[index]
      switch section {
      case .repository(let repositoryID, _),
        .folder(let repositoryID, _),
        .failedRepository(let repositoryID, _, _, _, _),
        .environmentBlockedRepository(let repositoryID, _, _, _):
        if let repoIndex = repoIDs.firstIndex(of: repositoryID) {
          repoOffsets.insert(repoIndex)
        }
      case .highlight, .placeholder:
        continue
      }
    }
    guard !repoOffsets.isEmpty else { return }
    let clampedDestination = min(max(destination, 0), sectionsCount)
    let repoDestination: Int
    if clampedDestination >= sectionsCount {
      repoDestination = repoIDs.count
    } else {
      let section = structure.sections[clampedDestination]
      switch section {
      case .repository(let repositoryID, _),
        .folder(let repositoryID, _),
        .failedRepository(let repositoryID, _, _, _, _),
        .environmentBlockedRepository(let repositoryID, _, _, _):
        repoDestination = repoIDs.firstIndex(of: repositoryID) ?? repoIDs.count
      case .highlight, .placeholder:
        // Dropping above the highlight prefix collapses to "before the first repo".
        repoDestination = 0
      }
    }
    store.send(.repositoriesMoved(repoOffsets, repoDestination))
  }

  @MainActor
  private func revealPendingSidebarWorktree(
    _ pendingSidebarReveal: RepositoriesFeature.PendingSidebarReveal?,
    with scrollProxy: ScrollViewProxy
  ) async {
    guard let pendingSidebarReveal else { return }
    // Give SwiftUI time to materialize newly expanded section rows before scrolling.
    await Task.yield()
    await Task.yield()
    isSidebarFocused = true
    withAnimation(.easeOut(duration: 0.2)) {
      scrollProxy.scrollTo(pendingSidebarReveal.worktreeID, anchor: .center)
    }
    store.send(.consumePendingSidebarReveal(pendingSidebarReveal.id))
  }
}

/// Single switch that turns one `SidebarStructure.Section` into the right
/// SwiftUI view. The view has no other dispatch: the structure already
/// answered "what kind of section, what rows, in what order".
private struct SidebarSectionDispatcher: View {
  let section: SidebarStructure.Section
  let structure: SidebarStructure
  let shortcutHintByID: [Worktree.ID: String]
  let selectedWorktreeIDs: Set<Worktree.ID>
  @Bindable var store: StoreOf<RepositoriesFeature>
  let terminalManager: WorktreeTerminalManager

  var body: some View {
    switch section {
    case .placeholder:
      SidebarPlaceholderView()
        .moveDisabled(true)
    case .highlight(let kind, let rowIDs):
      SidebarHighlightSection(
        kind: kind,
        rowIDs: rowIDs,
        store: store,
        terminalManager: terminalManager,
        selectedWorktreeIDs: selectedWorktreeIDs,
        repositoryHighlightByID: structure.repositoryHighlightByID,
        shortcutHintByID: shortcutHintByID
      )
      .moveDisabled(true)
    case .failedRepository(let repositoryID, let rootURL, let customTitle, let color, let isRemote):
      SidebarFailedRepositorySection(
        repositoryID: repositoryID,
        rootURL: rootURL,
        customTitle: customTitle,
        color: color,
        isRemote: isRemote,
        store: store
      )
    case .environmentBlockedRepository(let repositoryID, let rootURL, let customTitle, let color):
      SidebarBlockedRepositorySection(
        repositoryID: repositoryID,
        rootURL: rootURL,
        customTitle: customTitle,
        color: color,
        store: store
      )
    case .folder(let repositoryID, let rowID):
      if let repository = store.state.repositories[id: repositoryID] {
        // Empty header keeps `.listStyle(.sidebar)` from merging two
        // consecutive folder repos visually.
        Section {
          SidebarFolderRow(
            repository: repository,
            rowID: rowID,
            shortcutHint: shortcutHintByID[rowID],
            selectedWorktreeIDs: selectedWorktreeIDs,
            store: store,
            terminalManager: terminalManager
          )
        } header: {
          EmptyView()
        }
      }
    case .repository(let repositoryID, let groups):
      if let repository = store.state.repositories[id: repositoryID] {
        SidebarGitRepositorySection(
          repository: repository,
          groups: groups,
          hoistSummary: structure.hoistSummaryByRepositoryID[repositoryID],
          shortcutHintByID: shortcutHintByID,
          selectedWorktreeIDs: selectedWorktreeIDs,
          store: store,
          terminalManager: terminalManager
        )
      }
    }
  }
}

private struct SidebarGitRepositorySection: View {
  let repository: Repository
  let groups: [SidebarItemGroup]
  /// Non-nil when one or more of this repo's rows were hoisted into the
  /// highlight sections; rendered as a muted summary line under the rows.
  let hoistSummary: SidebarHoistSummary?
  let shortcutHintByID: [Worktree.ID: String]
  let selectedWorktreeIDs: Set<Worktree.ID>
  @Bindable var store: StoreOf<RepositoriesFeature>
  let terminalManager: WorktreeTerminalManager
  var body: some View {
    let isRemovingRepository = store.state.isRemovingRepository(repository)
    let isResolvingRemote = store.state.resolvingRemoteRepositoryIDs.contains(repository.id)
    let section = store.state.sidebar.sections[repository.id]
    Section(isExpanded: repositoryExpansionBinding) {
      SidebarItemsView(
        repository: repository,
        groups: groups,
        shortcutHintByID: shortcutHintByID,
        selectedWorktreeIDs: selectedWorktreeIDs,
        store: store,
        terminalManager: terminalManager
      )
      if let hoistSummary {
        SidebarHoistSummaryRow(
          repositoryName: Repository.sidebarDisplayName(custom: section?.title, fallback: repository.name),
          summary: hoistSummary,
          store: store
        )
      }
    } header: {
      RepoSectionHeaderView(
        name: repository.name,
        customTitle: section?.title,
        color: section?.color,
        isRemoving: isRemovingRepository,
        hostInfo: repository.host?.displayAuthority,
        isResolving: isResolvingRemote
      )
    }
    .sectionActions {
      SidebarSectionActionsView(
        repositoryID: repository.id,
        isRemovingRepository: isRemovingRepository,
        isRemote: repository.host != nil,
        store: store
      )
    }
  }

  private var repositoryExpansionBinding: Binding<Bool> {
    Binding(
      get: { store.state.isRepositoryExpanded(repository.id) },
      set: { isExpanded in
        store.send(.repositoryExpansionChanged(repository.id, isExpanded: isExpanded))
      }
    )
  }
}

/// Muted, unselectable line under a repo's rows summarizing how many were
/// hoisted into the Pinned / Active sections, with a click that scrolls up to
/// them. Carries no `.tag`, so it stays out of selection and arrow-key
/// navigation; lives inside the `Section` body so it folds away when the repo
/// section is collapsed.
private struct SidebarHoistSummaryRow: View {
  let repositoryName: String
  let summary: SidebarHoistSummary
  let store: StoreOf<RepositoriesFeature>

  var body: some View {
    Button {
      store.send(.revealHoistedWorktreeInSidebar(summary.revealTarget))
    } label: {
      HStack(spacing: 8) {
        if summary.pinnedCount > 0 {
          SidebarHoistSummarySegment(kind: .pinned, count: summary.pinnedCount)
        }
        if summary.activeCount > 0 {
          SidebarHoistSummarySegment(kind: .active, count: summary.activeCount)
        }
        Spacer(minLength: 0)
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .contentShape(.interaction, .rect)
    }
    .buttonStyle(.plain)
    .listRowInsets(.leading, 0)
    .listRowInsets(.trailing, 4)
    .listRowInsets(.vertical, 4)
    .moveDisabled(true)
    .help("Show \(repositoryName)'s pinned and active worktrees")
    .accessibilityLabel("\(summary.label) above. Scroll to them.")
  }
}

/// One bucket of the hoist summary: its count followed by the same colored dot
/// the matching highlight section header shows.
private struct SidebarHoistSummarySegment: View {
  let kind: SidebarStructure.HighlightKind
  let count: Int

  var body: some View {
    HStack(spacing: 4) {
      Text("+\(count) \(kind.summaryNoun)")
      SidebarHighlightHeaderDot(color: kind.indicatorColor)
    }
  }
}

private struct SidebarSectionActionsView: View {
  let repositoryID: Repository.ID
  let isRemovingRepository: Bool
  /// Remote (SSH) repositories hide the local-only "Repository Settings…" and
  /// route Remove to `removeRemoteRepository` (drops the config; remote files
  /// untouched). Worktree creation (`+`) works for remote repos too.
  var isRemote: Bool = false
  let store: StoreOf<RepositoriesFeature>

  var body: some View {
    Menu {
      Button("Customize Appearance…", systemImage: "paintbrush") {
        store.send(.requestCustomizeRepository(repositoryID))
      }
      .help("Set a custom title or color")
      .disabled(isRemovingRepository)
      if isRemote {
        Button("Edit Connection…", systemImage: "wifi") {
          store.send(.requestEditRemoteRepository(repositoryID))
        }
        .help("Edit the SSH server, port, user, or path")
        .disabled(isRemovingRepository)
      } else {
        Button("Repository Settings…", systemImage: "gear") {
          store.send(.openRepositorySettings(repositoryID))
        }
        .help("Repository Settings")
      }
      Divider()
      Button(
        isRemote ? "Remove Remote Repository…" : "Remove Repository…",
        systemImage: "folder.badge.minus",
        role: .destructive
      ) {
        store.send(.requestDeleteRepository(repositoryID))
      }
      .help(isRemote ? "Remove this remote repository (remote files are untouched)" : "Remove Repository")
      .disabled(isRemovingRepository)
    } label: {
      Image(systemName: "ellipsis")
        .accessibilityLabel("Options")
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
    }
    .menuStyle(.secondaryToolbar)

    Button {
      store.send(.createRandomWorktreeInRepository(repositoryID))
    } label: {
      Image(systemName: "plus")
        .accessibilityLabel("New Worktree")
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(isRemovingRepository)
    .foregroundStyle(.secondary)
    .help("New Worktree")
    .padding(.trailing, 4)
  }
}

private struct SidebarFailedRepositorySection: View {
  let repositoryID: Repository.ID
  let rootURL: URL
  let customTitle: String?
  let color: RepositoryColor?
  /// A disconnected SSH repo: route Remove to the remote config store and offer
  /// "Edit Connection…" to fix a bad host/path, rather than the local-roots flow.
  let isRemote: Bool
  let store: StoreOf<RepositoriesFeature>

  private func removeFailedRepository() {
    store.send(isRemote ? .requestDeleteRepository(repositoryID) : .requestRemoveFailedRepository(repositoryID))
  }

  var body: some View {
    let standardizedRootURL = rootURL.standardizedFileURL
    let fallbackName = Repository.name(for: standardizedRootURL)
    let displayName = Repository.sidebarDisplayName(custom: customTitle, fallback: fallbackName)
    let path = standardizedRootURL.path(percentEncoded: false)
    Section {
      FailedRepositoryRow(
        name: displayName,
        path: path,
        removeRepository: removeFailedRepository
      )
      .tag(SidebarSelection.failedRepository(repositoryID))
      .moveDisabled(true)
    } header: {
      RepoSectionHeaderView(
        name: fallbackName,
        customTitle: customTitle,
        color: color,
        isRemoving: false,
        hostInfo: store.state.repositories[id: repositoryID]?.host?.displayAuthority
      )
    }
    .sectionActions {
      // No `+`: the repo isn't loadable, so worktree create is meaningless.
      Menu {
        if isRemote {
          Button("Edit Connection…", systemImage: "wifi") {
            store.send(.requestEditRemoteRepository(repositoryID))
          }
          .help("Edit the SSH server, port, user, or path")
        }
        Button(
          isRemote ? "Remove Remote Repository…" : "Remove Repository…",
          systemImage: "folder.badge.minus",
          role: .destructive
        ) {
          removeFailedRepository()
        }
        .help(
          isRemote
            ? "Remove this remote repository (remote files are untouched)"
            : "Remove this repository from Supacode. Files on disk are untouched."
        )
      } label: {
        Image(systemName: "ellipsis")
          .accessibilityLabel("Options")
          .frame(maxHeight: .infinity)
          .contentShape(Rectangle())
      }
      .menuStyle(.secondaryToolbar)
    }
  }
}

/// A git repo hidden behind an environment block (unaccepted license / missing
/// tools). Renders a non-selectable warning row so the repo stays visible; the
/// bottom banner owns the remedy, so there's no per-row action here.
private struct SidebarBlockedRepositorySection: View {
  let repositoryID: Repository.ID
  let rootURL: URL
  let customTitle: String?
  let color: RepositoryColor?
  let store: StoreOf<RepositoriesFeature>

  var body: some View {
    let standardizedRootURL = rootURL.standardizedFileURL
    let fallbackName = Repository.name(for: standardizedRootURL)
    let displayName = Repository.sidebarDisplayName(custom: customTitle, fallback: fallbackName)
    let path = standardizedRootURL.path(percentEncoded: false)
    Section {
      EnvironmentBlockedRepositoryRow(
        name: displayName,
        path: path,
        // Path-based removal, so it works even though the blocked root has no
        // `loadFailuresByID` entry to key on.
        removeRepository: { store.send(.requestRemoveFailedRepository(repositoryID)) }
      )
      .moveDisabled(true)
    } header: {
      RepoSectionHeaderView(
        name: fallbackName,
        customTitle: customTitle,
        color: color,
        isRemoving: false,
        hostInfo: nil
      )
    }
  }
}

// MARK: - Sidebar placeholder.

private struct SidebarPlaceholderView: View {
  var body: some View {
    ForEach(0..<2, id: \.self) { section in
      Section {
        ForEach(0..<3, id: \.self) { _ in
          Label {
            VStack(alignment: .leading, spacing: 2) {
              Text("placeholder-branch")
                .font(.body)
                .lineLimit(1)
                .redacted(reason: .placeholder)
                .shimmer(isActive: true)
              Text("placeholder")
                .font(.footnote)
                .lineLimit(1)
                .redacted(reason: .placeholder)
                .shimmer(isActive: true)
            }
          } icon: {
            Image(systemName: "arrow.triangle.branch")
              .accessibilityHidden(true)
              .foregroundStyle(.secondary)
              .redacted(reason: .placeholder)
              .shimmer(isActive: true)
          }
        }
      } header: {
        Text(section == 0 ? "repository" : "second-repo")
          .foregroundStyle(.secondary)
          .redacted(reason: .placeholder)
          .shimmer(isActive: true)
      }
    }
  }
}

private struct SidebarRightArrowMonitor: NSViewRepresentable {
  let isSidebarFocused: Bool
  let handle: () -> Bool

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    context.coordinator.update(isSidebarFocused: isSidebarFocused, handle: handle)
    context.coordinator.install(host: view)
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.update(isSidebarFocused: isSidebarFocused, handle: handle)
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.uninstall()
  }

  @MainActor
  final class Coordinator {
    private var isSidebarFocused = false
    private var handle: () -> Bool = { false }
    private var monitor: Any?

    func update(isSidebarFocused: Bool, handle: @escaping () -> Bool) {
      self.isSidebarFocused = isSidebarFocused
      self.handle = handle
    }

    func install(host: NSView) {
      guard monitor == nil else { return }
      // Local monitors are process-global; scope to the host's window so a
      // stale `@FocusState` in another window can't steal the keystroke.
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak host] event in
        guard event.specialKey == .rightArrow else { return event }
        let userModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        guard event.modifierFlags.isDisjoint(with: userModifiers) else { return event }
        guard let host, event.window === host.window else { return event }
        let consumed = MainActor.assumeIsolated {
          (self?.isSidebarFocused ?? false) && (self?.handle() ?? false)
        }
        return consumed ? nil : event
      }
    }

    func uninstall() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }
  }
}
