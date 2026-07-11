import Foundation

/// Where a newly created surface lands, independent of what kind of surface it
/// is (`SurfaceSpec`). The creation verb carries spec × placement so "make a
/// new tab" and "split an existing pane" are one operation differing only in
/// destination, and a future surface kind composes with every placement for
/// free.
enum SurfacePlacement: Equatable, Sendable {
  /// A new tab whose single leaf is the new surface.
  case tab
  /// A new sibling pane split off `anchor` in `tabID`. The anchor is an explicit
  /// surface id (not "the focused pane") so CLI/deeplink targeting stays
  /// deterministic; UI call sites resolve focus at dispatch.
  case adjacent(tabID: TerminalTabID, anchor: UUID, direction: Direction)

  /// Full 4-way placement for `.adjacent`. Distinct from the persisted 2-way
  /// `SplitDirection` (axis + child order in snapshots), which stays untouched:
  /// only the command payload needs to say "left" or "up".
  enum Direction: Equatable, Sendable, CaseIterable {
    case right
    case left
    case down
    case up
  }
}
