import SwiftUI

/// A live, observable toolbar a content docks at the top of its tab's content
/// region: a URL bar for a browser, a find bar for a terminal. Owned by the
/// content so content-specific state never leaks into the layout reducer; the
/// host reads it as an observable leaf, bounding invalidation to one tab. A
/// `nil` view reserves no space, so a transient bar can come and go.
@MainActor
protocol TabContentToolbar: AnyObject {
  /// The docked bar, or nil when the content shows none right now.
  var view: AnyView? { get }
}
