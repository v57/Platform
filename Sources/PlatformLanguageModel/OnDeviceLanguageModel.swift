import Foundation

#if canImport(FoundationModels)
  import FoundationModels
#endif

/// The system's own language model, on the device: no key, no network, no rate budget. Apple's Foundation Models
/// (macOS 26, iOS 26 with Apple Intelligence on); no system has one elsewhere yet, so `unavailableReason` says so.
///
/// ```swift
/// if OnDeviceLanguageModel.unavailableReason == nil {
///   let answer = try await OnDeviceLanguageModel.respond(to: prompt, instructions: rules)
/// }
/// ```
public nonisolated enum OnDeviceLanguageModel {
  /// nil when the model can answer right now, else why it cannot, in the user's terms.
  public static var unavailableReason: String? {
    #if canImport(FoundationModels)
      guard #available(macOS 26, iOS 26, visionOS 26, *) else { return "the on-device model needs macOS 26" }
      if case .unavailable(let reason) = SystemLanguageModel.default.availability {
        return text(for: reason)
      }
      return nil
    #else
      return "this system has no on-device model"
    #endif
  }

  /// Whether the model can answer right now.
  public static var isAvailable: Bool { unavailableReason == nil }

  /// One answer to `prompt` in a session of its own that follows `instructions`. Throws `Unavailable` when there is
  /// no model, and the model's own errors when it refuses or fails.
  public static func respond(to prompt: String, instructions: String) async throws -> String {
    #if canImport(FoundationModels)
      guard #available(macOS 26, iOS 26, visionOS 26, *) else { throw Unavailable() }
      let session = LanguageModelSession(model: .default, instructions: instructions)
      return try await session.respond(to: prompt).content
    #else
      throw Unavailable()
    #endif
  }

  /// Thrown by `respond` where there is no model.
  public struct Unavailable: LocalizedError {
    public var errorDescription: String? { OnDeviceLanguageModel.unavailableReason }
  }

  #if canImport(FoundationModels)
    /// Compared rather than switched: the framework's reason enum is not frozen.
    @available(macOS 26, iOS 26, visionOS 26, *)
    private static func text(for reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
      if reason == .deviceNotEligible {
        return "this Mac is not eligible for Apple Intelligence"
      }
      if reason == .appleIntelligenceNotEnabled {
        return "Apple Intelligence is not enabled in System Settings"
      }
      if reason == .modelNotReady {
        return "the on-device model is still downloading"
      }
      return "the on-device model is unavailable"
    }
  #endif
}
