# Contributing to MFPete

Thanks for helping! MFPete aims to stay small and friendly, so please open an issue
to talk about a new feature before you build it.

## Reporting bugs

Use the **Bug report** issue template. Please include:

- macOS version and MFPete version (Settings › About)
- The rule involved. Use **Export…** from the rule's `⋯` menu and paste the JSON.
- What you expected and what happened
- Matching lines from the Activity window, if any

## Development setup

1. Install Xcode 26.
2. Open `MFPete.xcodeproj` and run the `MFPete` scheme.
3. Run the tests before you open a pull request:

   ```sh
   (cd Packages/MFPeteCore && swift test)
   xcodebuild test -project MFPete.xcodeproj -scheme MFPete \
     -destination 'platform=macOS' -only-testing:MFPeteTests
   ```

## Project layout

- `MFPete/`: the app (SwiftUI and AppKit). Windows, menu bar, settings, and services.
- `Packages/MFPeteCore/`: the rule engine, storage, file watching, and scheduling.
  It does not import SwiftUI or AppKit, so its tests run headless.
- `context/`: the product spec and implementation plan.

## Guidelines

- Engine logic goes in `MFPeteCore` with tests. Keep file work off the main actor.
- Put every user-facing string through `String(localized:)` or a SwiftUI text literal
  so it lands in the String Catalog.
- Use semantic colors and add VoiceOver labels to custom controls.
- Keep the rules JSON format stable. Format changes need a version bump and a
  migration in `RulesStore`.
- No new network calls, analytics, or telemetry.
- New dependencies must use an MIT, BSD, or Apache 2.0 license.

## Pull requests

- Keep each pull request focused on one change.
- Describe what changed and how you tested it.
- CI must pass.

By contributing, you agree that your contributions are licensed under the MIT License.
