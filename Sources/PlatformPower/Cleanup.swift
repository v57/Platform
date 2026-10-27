import Foundation

/// Work a main-actor object must undo when it's released: a nonisolated deinit can't call main-actor code, so it runs
/// this on the main thread (at once there, else queued). Runs once.
final class Cleanup: @unchecked Sendable {
  private let lock = NSLock()
  private var action: (@MainActor () -> Void)?

  init(_ action: @escaping @MainActor () -> Void) {
    self.action = action
  }

  /// Runs the work now (from main-actor code).
  @MainActor func run() {
    take()?()
  }

  /// From a deinit, on whatever thread it runs.
  func runOnMain() {
    guard let action = take() else { return }
    if Thread.isMainThread {
      MainActor.assumeIsolated { action() }
    } else {
      let work = UncheckedSendable(action)
      DispatchQueue.main.async { MainActor.assumeIsolated { work.value() } }
    }
  }

  private func take() -> (@MainActor () -> Void)? {
    lock.lock()
    defer { lock.unlock() }
    let action = self.action
    self.action = nil
    return action
  }
}

private struct UncheckedSendable<Value>: @unchecked Sendable {
  let value: Value
  init(_ value: Value) { self.value = value }
}
