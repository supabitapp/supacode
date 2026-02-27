import AppKit
import ComposableArchitecture
import Foundation
import UserNotifications

private final class ForegroundSystemNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.badge, .sound, .banner])
  }
}

@MainActor
private let foregroundSystemNotificationDelegate = ForegroundSystemNotificationDelegate()

@MainActor
private func configuredNotificationCenter() -> UNUserNotificationCenter {
  let center = UNUserNotificationCenter.current()
  if center.delegate !== foregroundSystemNotificationDelegate {
    center.delegate = foregroundSystemNotificationDelegate
  }
  return center
}

struct SystemNotificationClient {
  struct AuthorizationRequestResult: Equatable {
    let granted: Bool
    let errorMessage: String?
  }

  enum AuthorizationStatus: Equatable {
    case authorized
    case denied
    case notDetermined
  }

  var authorizationStatus: @MainActor @Sendable () async -> AuthorizationStatus
  var requestAuthorization: @MainActor @Sendable () async -> AuthorizationRequestResult
  var send: @MainActor @Sendable (_ title: String, _ body: String) async -> Void
  var openSettings: @MainActor @Sendable () async -> Void
}

extension SystemNotificationClient: DependencyKey {
  static let liveValue = SystemNotificationClient(
    authorizationStatus: {
      let center = configuredNotificationCenter()
      let settings = await center.notificationSettings()
      switch settings.authorizationStatus {
      case .authorized, .provisional:
        return .authorized
      case .denied:
        return .denied
      case .notDetermined:
        return .notDetermined
      @unknown default:
        return .denied
      }
    },
    requestAuthorization: {
      let center = configuredNotificationCenter()
      do {
        let granted = try await center.requestAuthorization(
          options: [.alert, .badge, .sound]
        )
        return AuthorizationRequestResult(granted: granted, errorMessage: nil)
      } catch {
        return AuthorizationRequestResult(
          granted: false,
          errorMessage: error.localizedDescription
        )
      }
    },
    send: { title, body in
      let center = configuredNotificationCenter()
      let content = UNMutableNotificationContent()
      content.title = title
      content.body = body
      content.sound = .default
      let request = UNNotificationRequest(
        identifier: UUID().uuidString,
        content: content,
        trigger: nil
      )
      try? await center.add(request)
    },
    openSettings: {
      guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else {
        return
      }
      _ = NSWorkspace.shared.open(url)
    }
  )

  static let testValue = SystemNotificationClient(
    authorizationStatus: { .notDetermined },
    requestAuthorization: { AuthorizationRequestResult(granted: false, errorMessage: nil) },
    send: { _, _ in },
    openSettings: {}
  )
}

extension DependencyValues {
  var systemNotificationClient: SystemNotificationClient {
    get { self[SystemNotificationClient.self] }
    set { self[SystemNotificationClient.self] = newValue }
  }
}
