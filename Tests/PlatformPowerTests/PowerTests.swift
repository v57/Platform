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
