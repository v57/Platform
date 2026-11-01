import Foundation

#if os(macOS)
import AppKit
import CoreGraphics
#endif

/// Whether someone is using the device: how long since the last keyboard, mouse or trackpad input, the lock screen,
/// and sleep. macOS: CGEventSource's combined session state (no permission needed), the `com.apple.screenIsLocked` /
/// `screenIsUnlocked` distributed notifications (and the session dictionary at the start), NSWorkspace's sleep and
/// screens-sleep notifications. Elsewhere it doesn't know: `idle` is nil and it's never locked or asleep. Nothing
/// leaves the device.
///
///     let presence = UserPresence.observe { presence in
///       recordsClips = presence.isAway(after: 5 * 60)
///     }
public struct UserPresence: Sendable, Hashable {
  /// Seconds since the last keyboard, mouse or trackpad input; nil where the device can't tell
  public var idle: Double?
  /// The lock screen is up (or the login window, after switching users)
  public var isLocked: Bool
  /// The system or its displays sleep
  public var isAsleep: Bool

  public init(idle: Double? = nil, isLocked: Bool = false, isAsleep: Bool = false) {
    self.idle = idle
    self.isLocked = isLocked
    self.isAsleep = isAsleep
  }

  /// Whether the device tells when someone uses it (macOS)
  public static var isSupported: Bool {
    #if os(macOS)
    true
    #else
    false
    #endif
  }

  /// Nobody is using it: locked, asleep, or no input for `idleLimit` seconds. Never where the device can't tell.
  public func isAway(after idleLimit: Double) -> Bool {
    isLocked || isAsleep || (idle ?? 0) >= idleLimit
  }

  /// Now (not asleep: code that runs sees the system awake; `observe` follows the displays)
  @MainActor public static var current: UserPresence {
    #if os(macOS)
    UserPresence(idle: idleSeconds(), isLocked: sessionIsLocked())
    #else
    UserPresence()
    #endif
  }

  /// Calls `change` on the main actor with the presence now, then every `interval` seconds and whenever the lock
  /// screen or sleep changes, until the observation is released or cancelled.
  @MainActor public static func observe(
    every interval: Double = 1, _ change: @escaping @MainActor (UserPresence) -> Void
  ) -> UserPresenceObservation {
    UserPresenceObservation(interval: interval, change)
  }

  #if os(macOS)
  static func idleSeconds() -> Double {
    // kCGAnyInputEventType: any keyboard, mouse, trackpad or tablet event
    let any = CGEventType(rawValue: ~0)!
    return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
  }

  static func sessionIsLocked() -> Bool {
    guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    return session["CGSSessionScreenIsLocked"] as? Bool ?? false
      || (session[kCGSessionOnConsoleKey as String] as? Bool) == false
  }
  #endif
}

/// A running presence observation; releasing it stops it.
@MainActor public final class UserPresenceObservation {
  private let change: @MainActor (UserPresence) -> Void
  public private(set) var presence: UserPresence
  private var cleanup: Cleanup?

  init(interval: Double, _ change: @escaping @MainActor (UserPresence) -> Void) {
    self.change = change
    presence = UserPresence.current
    #if os(macOS)
    var observers: [(NotificationCenter, NSObjectProtocol)] = []
    func on(_ center: NotificationCenter, _ name: Notification.Name, _ update: @escaping @MainActor (inout UserPresence) -> Void) {
      let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          update(&self.presence)
          self.check()
        }
      }
      observers.append((center, observer))
    }
    let distributed = DistributedNotificationCenter.default()
    on(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.isLocked = true }
    on(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.isLocked = false }
    let workspace = NSWorkspace.shared.notificationCenter
    on(workspace, NSWorkspace.willSleepNotification) { $0.isAsleep = true }
    on(workspace, NSWorkspace.screensDidSleepNotification) { $0.isAsleep = true }
    on(workspace, NSWorkspace.didWakeNotification) { $0.isAsleep = false }
    on(workspace, NSWorkspace.screensDidWakeNotification) { $0.isAsleep = false }
    on(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.isLocked = true }
    on(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.isLocked = UserPresence.sessionIsLocked() }
    let timer = Timer(fire: Date(timeIntervalSinceNow: interval), interval: interval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.check() }
    }
    RunLoop.main.add(timer, forMode: .common)
    cleanup = Cleanup {
      timer.invalidate()
      for (center, observer) in observers { center.removeObserver(observer) }
    }
    #endif
    change(presence)
  }

  private func check() {
    #if os(macOS)
    presence.idle = UserPresence.idleSeconds()
    #endif
    change(presence)
  }

  /// Stops the observation (also when it's released).
  public func cancel() {
    cleanup?.run()
  }

  deinit {
    cleanup?.runOnMain()
  }
}
