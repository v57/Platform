# PlatformLanguageModel

The system's own on-device language model. Part of [Platform](../README.md).

<!-- platforms: macos ios linux=planned windows=planned android=planned -->

## Purpose

`PlatformLanguageModel` wraps Apple's Foundation Models (`SystemLanguageModel`, `LanguageModelSession`) behind a call
that compiles everywhere: ask whether the model can answer, and get one answer to a prompt with instructions. There is
no key, no network and no rate budget. Where no system model exists it says so in the user's terms.

It is not a chat client or a cloud model API: one prompt, one answer, in a session of its own. There is no streaming,
tool calling or structured output.

## Getting started

```swift
.package(url: "https://github.com/v57/Platform.git", branch: "main"),
// target dependency:
.product(name: "PlatformLanguageModel", package: "Platform"),
```

```swift
import PlatformLanguageModel

func summary(of text: String) async throws -> String? {
  guard OnDeviceLanguageModel.isAvailable else { return nil }   // unavailableReason says why
  return try await OnDeviceLanguageModel.respond(
    to: text, instructions: "Summarize the text in one sentence.")
}
```

## Main API

- `OnDeviceLanguageModel.unavailableReason`: nil when the model can answer now, else why not ("the on-device model
  needs macOS 26", "Apple Intelligence is not enabled in System Settings", "the on-device model is still
  downloading", "this system has no on-device model", ...).
- `OnDeviceLanguageModel.isAvailable`: `unavailableReason == nil`.
- `OnDeviceLanguageModel.respond(to:instructions:) async throws -> String`: one answer in a new session that follows
  `instructions`. Throws `OnDeviceLanguageModel.Unavailable` where there is no model (its `errorDescription` is the
  reason), and the model's own errors when it refuses or fails.

## Platform notes

- **macOS 26, iOS 26, visionOS 26** with Apple Intelligence on: Foundation Models. Earlier versions build and report
  that the model needs a newer system.
- **Linux, Windows, Android**: no system model yet. `unavailableReason` says so and `respond` throws `Unavailable`.

## Testing

The library has no test target. Test app code by checking `isAvailable` first, as the example does.

## Related

- [Platform](../README.md): the library table, one `Platform<Feature>` library per feature.
