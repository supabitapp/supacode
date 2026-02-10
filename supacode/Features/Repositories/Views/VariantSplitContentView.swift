import SwiftUI

struct VariantSplitContentView: View {
  let variants: [(variant: TaskVariant, worktree: Worktree)]
  let ratios: [CGFloat]
  let focusedVariantID: TaskVariant.ID?
  let terminalManager: WorktreeTerminalManager
  let onSelectVariant: (TaskVariant.ID) -> Void
  let onSetRatio: (Int, CGFloat) -> Void
  let createTab: () -> Void

  var body: some View {
    if variants.isEmpty {
      EmptyTerminalPaneView(message: "No active variants")
    } else {
      buildSplit(from: 0, to: variants.count - 1, ratioOffset: 0)
    }
  }

  private func buildSplit(from start: Int, to end: Int, ratioOffset: Int) -> AnyView {
    if start == end {
      return AnyView(paneView(for: variants[start]))
    }
    let ratioIndex = ratioOffset
    let ratio = ratioIndex < ratios.count ? ratios[ratioIndex] : 0.5
    return AnyView(
      SplitView(
        .horizontal,
        Binding(
          get: { ratio },
          set: { onSetRatio(ratioIndex, $0) }
        ),
        dividerColor: Color(nsColor: .separatorColor),
        left: {
          paneView(for: variants[start])
        },
        right: {
          buildSplit(from: start + 1, to: end, ratioOffset: ratioOffset + 1)
        },
        onEqualize: {
          let count = CGFloat(end - start + 1)
          for ratioIdx in ratioOffset ..< ratioOffset + (end - start) {
            onSetRatio(ratioIdx, 1.0 / count)
          }
        }
      )
    )
  }

  @ViewBuilder
  private func paneView(for entry: (variant: TaskVariant, worktree: Worktree)) -> some View {
    let isFocused = entry.variant.id == focusedVariantID
    VStack(spacing: 0) {
      VariantPaneLabelView(
        variant: entry.variant,
        isFocused: isFocused,
        terminalManager: terminalManager
      )
      Divider()
      WorktreeTerminalTabsView(
        worktree: entry.worktree,
        manager: terminalManager,
        shouldRunSetupScript: false,
        forceAutoFocus: false,
        createTab: createTab
      )
      .id(entry.worktree.id)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .overlay(
      RoundedRectangle(cornerRadius: 2)
        .stroke(isFocused ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 2)
    )
    .contentShape(Rectangle())
    .accessibilityAddTraits(.isButton)
    .onTapGesture {
      onSelectVariant(entry.variant.id)
    }
  }
}
