import Foundation

#if canImport(UserNotifications) && !os(tvOS)
import UserNotifications
#endif

/// A notification this device shows by itself, with no push service: the app (or one of its extensions) posts it when
/// something it follows happens. UserNotifications on macOS, iOS and visionOS; not on Linux, Windows or Android yet
/// (`isSupported` is false there and `post` throws).
public struct UserNotification: Sendable, Hashable {
  /// Posting again with the same id replaces the one shown
  public var id: String
  public var title: String
  public var subtitle: String?
  public var body: String
  /// Notifications with the same thread are grouped (one camera's alerts)
  public var thread: String?
  /// A JPEG shown with it, such as a camera's picture
  public var image: Data?
  /// Comes back to `onOpen` when the user opens it
  public var info: [String: String]

  public init(
    id: String, title: String, subtitle: String? = nil, body: String, thread: String? = nil, image: Data? = nil,
    info: [String: String] = [:]
  ) {
    self.id = id
    self.title = title
    self.subtitle = subtitle
    self.body = body
    self.thread = thread
    self.image = image
    self.info = info
  }
}

public enum NotificationPermission: Sendable, Hashable {
  /// Not asked yet
  case notAsked
  case allowed
  /// Turned off in the system's settings, or this platform can't show them
  case denied
}

public enum UserNotificationError: Error, LocalizedError {
  case unsupported

  public var errorDescription: String? {
    switch self {
    case .unsupported: "This device can’t show notifications yet."
    }
  }
}

public enum UserNotifications {
  public static var isSupported: Bool {
    #if canImport(UserNotifications) && !os(tvOS)
    true
    #else
    false
    #endif
  }

  /// Whether the user allowed notifications, without asking
  public static func permission() async -> NotificationPermission {
    #if canImport(UserNotifications) && !os(tvOS)
    let settings = await UNUserNotificationCenter.current().notificationSettings()
    switch settings.authorizationStatus {
    case .notDetermined: return .notAsked
    case .denied: return .denied
    default: return .allowed
    }
    #else
    return .denied
    #endif
  }

  /// Asks the user once (the system shows its prompt only the first time) and answers whether they're allowed. Ask right
  /// before turning on something that notifies, never at launch.
  @discardableResult
  public static func requestPermission() async -> Bool {
    #if canImport(UserNotifications) && !os(tvOS)
    (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    #else
    false
    #endif
  }

  /// Shows `notification` now. Works from an app extension too (a packet tunnel), with the app's permission.
  public static func post(_ notification: UserNotification) async throws {
    #if canImport(UserNotifications) && !os(tvOS)
    let content = UNMutableNotificationContent()
    content.title = notification.title
    if let subtitle = notification.subtitle { content.subtitle = subtitle }
    content.body = notification.body
    content.sound = .default
    if let thread = notification.thread { content.threadIdentifier = thread }
    content.userInfo = notification.info
    if let image = notification.image, let attachment = attachment(image, id: notification.id) {
      content.attachments = [attachment]
    }
    let request = UNNotificationRequest(identifier: notification.id, content: content, trigger: nil)
    try await UNUserNotificationCenter.current().add(request)
    #else
    throw UserNotificationError.unsupported
    #endif
  }

  /// Calls `handler` with a notification's `info` when the user opens it, and shows notifications while the app is in
  /// front too (the system hides them otherwise). Set it once, early at launch, so a notification that launched the app
  /// arrives.
  @MainActor
  public static func onOpen(_ handler: @escaping @MainActor ([String: String]) -> Void) {
    #if canImport(UserNotifications) && !os(tvOS)
    Delegate.shared.open = handler
    UNUserNotificationCenter.current().delegate = Delegate.shared
    #endif
  }

  #if canImport(UserNotifications) && !os(tvOS)
  /// The system moves the file into its own store, so each image gets a file of its own
  private static func attachment(_ jpeg: Data, id: String) -> UNNotificationAttachment? {
    let url = FileManager.default.temporaryDirectory.appending(path: "notification-\(UUID().uuidString).jpg")
    guard (try? jpeg.write(to: url)) != nil else { return nil }
    return try? UNNotificationAttachment(identifier: id, url: url, options: nil)
  }

  private final class Delegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = Delegate()
    @MainActor var open: (([String: String]) -> Void)?

    func userNotificationCenter(
      _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
      [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
      guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
      var info: [String: String] = [:]
      for (key, value) in response.notification.request.content.userInfo {
        if let key = key as? String, let value = value as? String { info[key] = value }
      }
      let received = info
      await MainActor.run { open?(received) }
    }
  }
  #endif
}
