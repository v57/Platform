import Foundation

#if os(macOS)
import IOKit.pwr_mgt
#elseif os(iOS) || os(visionOS)
import UIKit
#endif

/// Keeps the device from sleeping while it's held: an IOKit power assertion on macOS, the idle timer on iOS, a logind
/// inhibitor lock (`systemd-inhibit`) on Linux. Releasing it (or `release()`) lets the device sleep again.
///
///     let awake = SleepAssertion(.idleSleep, reason: "Sharing this Mac's internet")
///     ...
///     awake?.release()
@MainActor public final class SleepAssertion {
  public enum Kind: Sendable {
    /// The system doesn't sleep when idle; the display may
    case idleSleep
    /// Neither the system nor the display sleeps when idle
    case displaySleep
  }

  public let kind: Kind
  public let reason: String
  private var cleanup: Cleanup?
  #if os(iOS) || os(visionOS)
  private static var holders = 0
  #endif

  /// Takes the assertion; `nil` when the system refuses it or has no way to (no logind on Linux, Windows for now).
  public init?(_ kind: Kind, reason: String) {
    self.kind = kind
    self.reason = reason
    #if os(macOS)
    let type = kind == .idleSleep ? kIOPMAssertPreventUserIdleSystemSleep : kIOPMAssertPreventUserIdleDisplaySleep
    var id: IOPMAssertionID = 0
    guard
      IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id)
        == kIOReturnSuccess
    else { return nil }
    cleanup = Cleanup { IOPMAssertionRelease(id) }
    #elseif os(iOS) || os(visionOS)
    // iOS has one switch for the app: on while any assertion holds it.
    Self.holders += 1
    UIApplication.shared.isIdleTimerDisabled = true
    cleanup = Cleanup {
      Self.holders -= 1
      if Self.holders == 0 { UIApplication.shared.isIdleTimerDisabled = false }
    }
    #elseif os(Linux)
    guard let process = Self.inhibit(kind, reason: reason) else { return nil }
    cleanup = Cleanup { process.terminate() }
    #else
    return nil
    #endif
  }

  /// Lets the device sleep again (also when the assertion is released).
  public func release() {
    cleanup?.run()
  }

  deinit {
    cleanup?.runOnMain()
  }

  #if os(Linux)
  /// logind holds an inhibitor lock while `systemd-inhibit` runs its command: here `tail --pid` on this process, so the
  /// lock also ends when the app quits or crashes. `nil` without systemd-inhibit (no systemd) or when it exits at once.
  private static func inhibit(_ kind: Kind, reason: String) -> Process? {
    let path = ["/usr/bin/systemd-inhibit", "/bin/systemd-inhibit"].first { FileManager.default.isExecutableFile(atPath: $0) }
    guard let path else { return nil }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    let who = ProcessInfo.processInfo.processName
    process.arguments = [
      "--what=\(kind == .idleSleep ? "sleep:idle" : "sleep:idle:handle-lid-switch")", "--who=\(who)", "--why=\(reason)",
      "--mode=block", "tail", "--pid=\(ProcessInfo.processInfo.processIdentifier)", "-f", "/dev/null",
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    // A refused lock (no logind, polkit says no) ends systemd-inhibit right away.
    usleep(100_000)
    return process.isRunning ? process : nil
  }
  #endif
}
