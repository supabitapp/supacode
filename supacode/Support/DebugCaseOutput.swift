import ComposableArchitecture
import CustomDump
import Foundation
import Sentry
import SupacodeSettingsShared

extension Reducer where State: Equatable {
  @ReducerBuilder<State, Action>
  func logActions() -> some Reducer<State, Action> {
    LogActionsReducer(base: self)
  }
}

#if DEBUG
  private enum ActionLogging {
    // Opt-in: the per-action state copy, reflective diff, and print are the
    // single largest debug-build cost on the terminal hot path. Enable by
    // setting SUPACODE_LOG_ACTIONS to a truthy value (1); a falsy or unset value
    // leaves the wrapper a passthrough.
    static let isEnabled: Bool = {
      guard let value = ProcessInfo.processInfo.environment["SUPACODE_LOG_ACTIONS"] else {
        return false
      }
      return !["", "0", "false", "no"].contains(value.lowercased())
    }()
  }
#endif

struct LogActionsReducer<Base: Reducer>: Reducer where Base.State: Equatable {
  let base: Base

  #if DEBUG
    private let logger = SupaLogger("TCA")
  #endif

  func reduce(into state: inout Base.State, action: Base.Action) -> Effect<Base.Action> {
    #if DEBUG
      guard ActionLogging.isEnabled else {
        return base.reduce(into: &state, action: action)
      }
      let actionLabel = debugCaseOutput(action)
      logger.debug("Action: \(actionLabel)")
      let previousState = state
      let effects = base.reduce(into: &state, action: action)
      if previousState != state, let diff = CustomDump.diff(previousState, state) {
        print(diff)
      }
      return effects
    #else
      let actionLabel = debugCaseOutput(action)
      SentrySDK.logger.info("Action: \(actionLabel)")
      let breadcrumb = Breadcrumb(level: .debug, category: "action")
      breadcrumb.message = actionLabel
      SentrySDK.addBreadcrumb(breadcrumb)
      return base.reduce(into: &state, action: action)
    #endif
  }
}

func debugCaseOutput(
  _ value: Any,
  abbreviated: Bool = false
) -> String {
  func debugCaseOutputHelp(_ value: Any) -> String {
    let mirror = Mirror(reflecting: value)
    switch mirror.displayStyle {
    case .enum:
      guard let child = mirror.children.first else {
        let childOutput = "\(value)"
        return childOutput == "\(typeName(type(of: value)))" ? "" : ".\(childOutput)"
      }
      let childOutput = debugCaseOutputHelp(child.value)
      return ".\(child.label ?? "")\(childOutput.isEmpty ? "" : "(\(childOutput))")"
    case .tuple:
      return mirror.children.map { label, value in
        let childOutput = debugCaseOutputHelp(value)
        let labelValue = label.map { isUnlabeledArgument($0) ? "_:" : "\($0):" } ?? ""
        let suffix = childOutput.isEmpty ? "" : " \(childOutput)"
        return "\(labelValue)\(suffix)"
      }
      .joined(separator: ", ")
    default:
      return ""
    }
  }

  return (value as? any CustomDebugStringConvertible)?.debugDescription
    ?? "\(abbreviated ? "" : typeName(type(of: value)))\(debugCaseOutputHelp(value))"
}

private func isUnlabeledArgument(_ label: String) -> Bool {
  label.firstIndex(where: { $0 != "." && !$0.isNumber }) == nil
}

private func typeName(
  _ type: Any.Type,
  qualified: Bool = true,
  genericsAbbreviated: Bool = true
) -> String {
  var name = _typeName(type, qualified: qualified)
    .replacing(#/\(unknown context at \$[0-9A-Fa-f]+\)\./#, with: "")
  for _ in 1...10 {
    let abbreviated =
      name
      .replacing(#/\bSwift\.Optional<([^><]+)>/#) { match in
        "\(match.1)?"
      }
      .replacing(#/\bSwift\.Array<([^><]+)>/#) { match in
        "[\(match.1)]"
      }
      .replacing(#/\bSwift\.Dictionary<([^,<]+), ([^><]+)>/#) { match in
        "[\(match.1): \(match.2)]"
      }
    if abbreviated == name { break }
    name = abbreviated
  }
  name = name.replacing(#/\w+\.([\w.]+)/#) { match in
    "\(match.1)"
  }
  if genericsAbbreviated {
    name = name.replacing(#/<.+>/#, with: "")
  }
  return name
}
