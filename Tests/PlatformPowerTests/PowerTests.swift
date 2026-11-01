import Foundation
import PlatformPower
import Testing

@MainActor @Test func batteryLevelIsAFraction() {
  // A desktop or a VM has none; a laptop reports 0...1.
  if let battery = Battery.current {
    #expect((0...1).contains(battery.level))
  }
}

@MainActor @Test func sleepAssertionReleases() {
  // CI and containers may have no logind: then there's nothing to hold.
  guard let assertion = SleepAssertion(.idleSleep, reason: "PlatformPower tests") else { return }
  #expect(assertion.kind == .idleSleep)
  assertion.release()
  assertion.release()
}

@Test func presenceIsAwayWhenLockedAsleepOrIdle() {
  #expect(!UserPresence(idle: 10).isAway(after: 300))
  #expect(UserPresence(idle: 301).isAway(after: 300))
  #expect(UserPresence(idle: 0, isLocked: true).isAway(after: 300))
  #expect(UserPresence(idle: 0, isAsleep: true).isAway(after: 300))
  // A device that can't tell is never away
  #expect(!UserPresence().isAway(after: 300))
}

@MainActor @Test func presenceObservationReportsAtOnce() {
  var reports = 0
  let observation = UserPresence.observe { _ in reports += 1 }
  #expect(reports == 1)
  if UserPresence.isSupported {
    #expect(observation.presence.idle != nil)
    #expect(observation.presence.isLocked == false)
  }
  observation.cancel()
}
