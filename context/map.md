# MFPete: Codebase Map

Quick orientation for AI agents. Broad, not deep. Follow the pointers for details.

- **What:** Free, open-source (MIT) macOS menu bar app. Users build **When / If / Then** file rules (a tiny Hazel).
  Example: "When a file is added to Downloads, if its extension is dmg or zip, then move it to the Trash."
- **Status:** v1 code complete (plan Phases 1–7 done). Open items are manual release steps (Sparkle keys, notarized release, Homebrew submission, tag `v1.0.0`).
- **Deeper docs:**
  - `context/spec.md`: product + technical spec. Key decisions D1–D15 in §0. Section refs like "spec §5.3" point here.
  - `context/plan.md`: phase-by-phase plan. Each phase ends with **Implementation notes** (decisions made while coding). Read these before changing behavior.
  - `context/notes.md`: original product idea.
  - `README.md`, `CONTRIBUTING.md`, `docs/RELEASING.md`.

---

## 1. Tech Stack

| Area | Choice |
| --- | --- |
| Platform | macOS 14+ (Sonoma), Xcode 26, Swift 6 toolchain, Swift 5 language mode |
| UI | SwiftUI (`MenuBarExtra`, `Window`, `Settings` scenes) + AppKit where needed |
| Engine | Local SPM package `MFPeteCore` (no SwiftUI/AppKit imports, headless-testable) |
| Concurrency | Engine is an `actor`. App target uses default `MainActor` isolation. Package does not |
| Persistence | Rules: JSON file. Activity log + processed records: SwiftData. Small state: `UserDefaults` |
| File watching | FSEvents (C API) bridged to `AsyncStream` |
| Notifications | `UNUserNotificationCenter` |
| Login item | `SMAppService.mainApp` |
| Updates | Sparkle 2 (only third-party dependency, only network traffic) |
| Distribution | Developer ID signed + notarized DMG/zip on GitHub Releases, Homebrew cask draft |
| Sandbox | **Off** (D2). Hardened Runtime on. TCC prompts still apply for protected folders |
| Bundle ID | `com.mftpete.MFPete`. `LSUIElement = YES` (no Dock icon by default) |

---

## 2. Top-Level Layout

```
MFPete/                     App target (SwiftUI/AppKit UI, lifecycle, windows)
Packages/MFPeteCore/        Engine package: model, storage, evaluation, actions, engine, watching
MFPeteTests/                App unit tests (dashboard query logic, Phase 6 features)
MFPeteUITests/              XCUITests (dashboard, editor, activity, onboarding)
MFPete.xcodeproj/           Xcode project (MFPete/ is a synchronized folder group)
Config/Info.plist           Custom Info.plist keys (SUFeedURL, SUPublicEDKey, category) merged with generated plist
scripts/                    release.sh, make-appcast.sh, ExportOptions.plist
.github/workflows/          ci.yml (tests on push/PR), release.yml (on v* tags)
packaging/homebrew/         mfpete.rb cask draft
docs/RELEASING.md           Signing, notarization, Sparkle keys, GitHub secrets
context/                    spec, plan, notes, this map
```

---

## 3. Architecture in One Picture

```
 ┌───────────────────────── App target (MainActor) ─────────────────────────┐
 │ MFPeteApp (scenes) ── AppDelegate (lifecycle, wake/mount, single instance)│
 │        │                                                                  │
 │     AppState (@Observable) ── owns rules array, RulesStore, updater       │
 │        │                                                                  │
 │     EngineController (@Observable) ── UI state, settings, Run Now,        │
 │        │                              prompts, notifications              │
 └────────┼──────────────────────────────────────────────────────────────────┘
          ▼
 ┌───────────────────────── MFPeteCore (actors) ─────────────────────────────┐
 │ TriggerCoordinator ── FSEventsWatcher → Settler → batches                  │
 │        │            ── schedule timer (Scheduler) + EngineStateStore       │
 │        ▼                                                                  │
 │ RuleEngine ── FolderScanner, IgnoreFilter, ConditionEvaluator,            │
 │        │      ActionExecutor, ConflictResolver, PatternRenderer,          │
 │        │      LoopGuard, SelfChangeTracker, RunPlanner (dry run)          │
 │        ▼                                                                  │
 │ ActivityStore / ProcessedStore (@ModelActor, SwiftData)                   │
 │ RuleEngine.events ──► EngineEvent stream ──► EngineController             │
 └───────────────────────────────────────────────────────────────────────────┘
```

**Run flow (spec §2.1):** trigger fires → candidate files (event batch or full folder scan) → ignore filter → processed-record check → conditions → actions in order (serial per file, max 4 files in parallel) → activity entries + processed record → `RunSummary` → notification policy.

**Boundary rule:** AppKit-only operations (Open, Reveal in Finder, notifications) go through protocols in `Actions/Services.swift` (`WorkspaceService`, `NotificationService`). The app target implements them (`Services/AppWorkspaceService.swift`, `Services/RunNotifier.swift`).

---

## 4. Data Model (`Packages/MFPeteCore/Sources/MFPeteCore/Model/`)

All types are `Codable, Hashable, Sendable`. Enums with associated values use **explicit JSON coding** with a `"type"` discriminator (format must stay stable for import/export). Unknown cases decode to `.unknown(JSONValue)`; such rules import **disabled**.

```swift
struct Rule {                      // Model/Rule.swift
  id: UUID; name: String; isEnabled: Bool
  order: Int                       // dashboard order = run order when rules share a file (D5)
  scope: [FolderRef]               // watched folders; tilde paths in JSON
  trigger: Trigger
  conditions: ConditionGroup
  actions: [Action]
  options: RuleOptions             // includeSubfolders, includeHidden, stopOtherRules, notifyEachRun
  notes: String; createdAt, modifiedAt: Date
}
// Run stats (last run, file count, last error) are NOT stored. They come from the activity log.

enum Trigger                       // Model/Trigger.swift
  fileAdded | fileModified | fileRemoved
  interval(minutes) | daily(hour, minute) | weekly(weekdays: Set<Int>, hour, minute)

struct ConditionGroup { match: Match (.all/.any); items: [ConditionItem] }   // Model/Condition.swift
enum ConditionItem   condition(Condition) | group(ConditionGroup) | unknown(JSONValue)
struct Condition     { attribute: Attribute; operator: Operator; value: ConditionValue; caseSensitive }
enum Attribute       name, fullName, extension, kind, size, dateAdded, dateCreated, dateModified,
                     tags, downloadedFrom, anyFile
enum Operator        is, isNot, contains, doesNotContain, startsWith, endsWith, matchesPattern, isAnyOf,
                     greaterThan, lessThan, inTheLast, notInTheLast, before, after,
                     containsTag, doesNotContainTag, hasNoTags, always
enum ConditionValue  none | text | size(Double, SizeUnit) | duration(Int, DurationUnit) | date | kind(FileKind) | tags
enum FileKind        folder, image, movie, audio, pdf, text, document, archive, diskImage, application, alias, other
// Data model allows any nesting depth. UI allows one nested group (D12).
// Valid operators per attribute: validity table in Condition.swift.

enum Action                        // Model/Action.swift
  move(to, onConflict) | copy(to, onConflict) | rename(pattern, onConflict) | changeExtension(String)
  trash | sortIntoSubfolder(base, pattern) | addTags([String]) | removeTags([String])
  unarchive(destination?, trashArchive) | open(withApp?) | revealInFinder | notify(message) | unknown
enum ConflictPolicy  keepBoth | replace (trashes existing, never overwrites) | skip
```

- `Model/FolderRef.swift`: path wrapper, tilde abbreviate/expand.
- `Model/EditorChoices.swift`: UI popup enums (`TriggerType`, `ActionType`) and display labels. In core so they are unit tested.
- `Support/JSONValue.swift`: raw JSON holder for unknown cases.
- Fixture that locks the JSON format: `Packages/MFPeteCore/Tests/MFPeteCoreTests/Fixtures/rules-v1.json`.

**Name pattern tokens** (`Actions/PatternRenderer.swift`): `{name} {extension} {fullname} {date-added} {date-created} {date-modified} {year} {month} {day} {today} {time} {counter} {folder} {kind}`. `/` in sort patterns makes nested folders. Unknown tokens render literally.

### Engine value types (`Engine/RunTypes.swift`, `Engine/EngineEvents.swift`)
- `RunTrigger`: `fileEvent | scheduled | scheduledLate | manual | applyExisting`.
- `RunSummary`: per-run counts (acted, skipped processed, skipped other, failed), dominant verb, note.
- `RunNowResult`: `completed | alreadyRunning | ruleNotFound | notAvailableForFileRemoved | unsupportedElements | needsApproval`.
- `RuleStatus`: `ok | folderMissing | noPermission | folderUnavailable | error`.
- `PlannedFileResult` / `PlannedStep`: dry-run output for Preview.
- `EngineEvent`: `runFinished | bulkApprovalRequested | applyExistingRequested | loopDetected`.

---

## 5. Persistence

| What | Where | Code |
| --- | --- | --- |
| Rules | `~/Library/Application Support/MFPete/rules.json` (`{ "version": 1, "rules": [...] }`) | `Storage/RulesStore.swift`, `Storage/RulesFile.swift` |
| Rules backup | `rules.json.bak`; corrupt file renamed `rules.corrupt-<timestamp>.json` | `RulesStore` |
| Activity log | SwiftData `MFPete.store`, `@Model ActivityEntry` | `Storage/DataStore.swift`, `Storage/ActivityStore.swift` |
| Processed records | SwiftData `@Model ProcessedRecord` (unique `ruleID`+`fileKey`, `modifiedAt`) | `Storage/ProcessedStore.swift` |
| Engine state | `UserDefaults`: `engine.lastFSEventID`, `engine.lastScheduledRuns` | `Storage/EngineStateStore.swift` |
| App settings | `UserDefaults`: `isPaused`, `notificationLevel`, `settleDelay`, `bulkThreshold`, `showDockIcon`, `hasCompletedOnboarding`, `explainedProtectedLocations` | `EngineController`, `AppState` |
| Paths | `Storage/AppPaths.swift` | |

- `ActivityEntry`: one row per action per file (or rule-level error). Fields: timestamp, ruleID, ruleName snapshot, action, sourcePath, destinationPath, resultKind (`success/skipped/failed`), message, detail, runTrigger. Retention fixed: 30 days / 10,000 rows.
- `ProcessedRecord` (D6): file is skipped if a record exists with `modifiedAt >= file's modification date`. "Run Again on All Files" deletes a rule's records.
- File key = volume UUID + inode (`fileIdentifierKey`), path fallback (`Evaluation/FileSnapshot.swift`).
- `ActivityStore`/`ProcessedStore` are `@ModelActor`. Never pass `@Model` objects across actors. Pass IDs or value copies.
- Migration hook: `RulesFile` `migrate(from:)`. Import: `Storage/RuleImporter.swift` (new IDs, append, import disabled, report unknowns).

---

## 6. MFPeteCore Folder Guide (`Packages/MFPeteCore/Sources/MFPeteCore/`)

| Folder | Key files | Purpose |
| --- | --- | --- |
| `Model/` | `Rule`, `Trigger`, `Condition`, `Action`, `FolderRef`, `EditorChoices` | Data model (section 4) |
| `Storage/` | `RulesStore`, `RulesFile`, `DataStore`, `ActivityStore`, `ProcessedStore`, `EngineStateStore`, `RuleImporter`, `AppPaths` | Persistence (section 5) |
| `Evaluation/` | `FileSnapshot`, `ConditionEvaluator`, `KindClassifier` | Read file metadata (incl. `kMDItemWhereFroms` xattr), match conditions, map UTType to `FileKind` (order matters: PDF before Document, App before Folder) |
| `Actions/` | `ActionExecutor`, `ConflictResolver`, `PatternRenderer`, `Unarchiver`, `Services` | Perform actions. Unarchive = `.zip` only via `/usr/bin/ditto`. Finder-style " 2" suffixes for Keep both |
| `Engine/` | `RuleEngine` (+`+Triggers`), `TriggerCoordinator`, `RunPlanner`, `FolderScanner`, `LoopGuard`, `SelfChangeTracker`, `RunTypes`, `EngineEvents` | Run pipeline, trigger routing, safety guards, dry run |
| `Watching/` | `FSEventsWatcher`, `Settler`, `FileEvent`, `IgnoreFilter` | FSEvents stream, wait-until-settled, ignored names / in-progress downloads |
| `Scheduling/` | `Scheduler` | Next fire date for interval/daily/weekly (DST-safe) |
| `Summary/` | `RuleSummarizer` | Rule as sentence ("When…, if…, then…") and 2-line dashboard form |
| `Validation/` | `RuleValidator` | Returns `RuleIssue` errors/warnings for the editor |
| `Notifications/` | `NotificationPolicy` | `shouldNotify` table, `RunNotificationText`, `NotificationCoalescer` (5 s window) |
| `Templates/` | `RuleTemplate` | 6 starter templates (3 featured) as factory functions |
| `Support/` | `JSONValue`, `Localization`, `ProtectedLocation` | Helpers. `ProtectedLocation` = TCC folders (Desktop, Documents, Downloads, iCloud, volumes) |
| `Resources/` | `Localizable.xcstrings` | Core string catalog |

### Key engine entry points
- `RuleEngine.runNow(ruleID:)`: manual run. Works on disabled rules and while paused. Rejects File removed rules.
- `RuleEngine.scanAndRun(_:reason:)`: full scan (scheduled, Run Now, apply-existing).
- `RuleEngine.run(rules:candidates:reason:)`: file-event path, multi-rule ordering (D5).
- `RuleEngine.plan(rule:)`: dry run for Preview and live match count.
- `RuleEngine.resolveBulkApproval(_:approve:)`, `TriggerCoordinator.resolveApplyExisting(ruleID:apply:)`.
- `TriggerCoordinator`: `start/stop`, `setRules`, `setPaused`, `setSettleDelay`, `handleWake`, `handleVolumeMounted/Unmounted`, `checkSchedules`, `scanFileEventRules`.

### Engine behaviors worth knowing
- **Settling:** file is ready when size + mtime stay unchanged for the settle delay (default 2 s, 1–30). Settled files within 0.25 s run as one batch.
- **Event replay:** stream starts from the stored FSEvents ID. Dropped events or a DB reset fall back to a full scan.
- **Self-change tracking:** files the engine creates are suppressed for the producing rule only (10 s TTL). Other rules see them as added (chaining).
- **Loop guard:** more than 10 runs per file chain in 60 s stops the chain, logs, and notifies. Disables nothing.
- **Bulk guard:** a run over the threshold (default 50) pauses and emits `bulkApprovalRequested`.
- **Apply-to-existing:** enabling a file-event rule marks current matches processed ("Only new files" default) and emits `applyExistingRequested`.
- **File removed rules:** name-only snapshot, only Show notification actions run.
- **Missed schedules:** run once on launch/wake, logged as "Ran late". No backlog.
- **Failures:** failed files are not marked processed, so they retry. A failed or skipped action stops that file's chain.

---

## 7. App Target (`MFPete/`)

| Folder | Files | What |
| --- | --- | --- |
| `App/` | `MFPeteApp` | Scenes: `MenuBarExtra(.menu)`, `Window("Rules")`, `Window("Activity")`, onboarding `Window`, `Settings` |
| | `AppDelegate` | Keep running with no windows, single instance, wake/mount forwarding, Sparkle start, clean quit (`.terminateLater`) |
| | `AppState` | `@Observable` root: rules array (add/update/delete/reorder via `RulesStore`), `engineController`, `updater`, `showDockIcon`, `pendingTemplate`, `showActivity(ruleID:)` |
| | `EngineController` | Owns `RuleEngine` + `TriggerCoordinator`. Exposes paused state, per-rule status/isRunning/stats, recent activity, pending prompts, settings, `runNow`. Refreshes on engine events (no polling) |
| | `LaunchAlerts` | Corrupt rules file alert, unknown-parts notice |
| | `UITestingFixture` | `--ui-testing`, `--ui-testing-empty`, `--ui-testing-onboarding` launch args: isolated stores |
| `MenuBar/` | `MenuBarContent` | Header, recent activity, Pause (⌘P), Run rule ▸, Open Rules (⌘R), Settings, Check for Updates, Quit. Icon: `tray.and.arrow.down`, paused/error variants |
| `Dashboard/` | `RulesWindow`, `RuleRow`, `RuleListQuery` | Rule list: toggle, summary, last run, count, badges, Run Now, `⋯` menu, drag reorder, search/filter/sort (pure logic in `RuleListQuery`), empty state, bulk/apply prompts |
| `Editor/` | `RuleEditorSheet`, `WhenCard`, `IfCard`, `ThenCard`, `EditorControls`, `PreviewSheet` | When/If/Then editor on a draft copy. Live summary, live match count (400 ms debounced `plan`), pattern previews, validation, TCC explainer (`FolderGate`), Save & Run. `PreviewSheet` reused by Preview Matches and both prompts |
| `Activity/` | `ActivityWindow` | `Table` of log entries, rule filter, Errors only, reveal/copy path, Clear log. Reloads on `activityRevision` |
| `Settings/` | `SettingsView` | Tabs: General (login item, Dock icon, notification level), Folders (status per folder), Advanced (settle delay, bulk threshold, import/export, reset history), About (version, Sparkle) |
| `Onboarding/` | `OnboardingWindow`, `MenuBarHint` | 3-step first launch, then a borderless hint panel under the status item |
| `Services/` | `AppWorkspaceService` | `WorkspaceService` impl (NSWorkspace) |
| | `RunNotifier` | `SummaryNotifier`, `NotificationPoster`, `UserNotificationPoster`, `NotificationClickHandler` (click opens Activity for rule) |
| | `RuleExporter` | Export one/all rules via `NSSavePanel` |
| | `SystemSettings` | Login item (`SMAppService`), open Privacy & Security |
| | `UpdaterService` | Sparkle `SPUStandardUpdaterController` wrapper. Off when `SUPublicEDKey` empty or under tests |
| Root | `Localizable.xcstrings`, `Assets.xcassets` | App strings (all UI strings use `String(localized:)`), icons |

---

## 8. Features → Where to Look

| Feature | Spec | Core | App UI |
| --- | --- | --- | --- |
| Triggers (file events, schedules) | §3 | `Engine/TriggerCoordinator`, `Watching/*`, `Scheduling/Scheduler` | `Editor/WhenCard` |
| Conditions | §4 | `Evaluation/ConditionEvaluator`, `Model/Condition` | `Editor/IfCard` |
| Actions | §6 | `Actions/*`, `Model/Action` | `Editor/ThenCard` |
| Run Now (D14) | §3.3 | `RuleEngine.runNow` | `EngineController.runNow`, row button, menu bar, editor Save & Run |
| Preview / dry run | §8.3 | `Engine/RunPlanner` | `Editor/PreviewSheet` |
| Rule sentence | D11 | `Summary/RuleSummarizer` | editor header, dashboard rows |
| Validation | §8.3 | `Validation/RuleValidator` | `RuleEditorSheet` |
| Templates | §8.6 | `Templates/RuleTemplate` | dashboard empty state, `+` menu, onboarding |
| Safety guards | §5.6 | `Engine/LoopGuard`, bulk guard in `RuleEngine` | prompts in `RulesWindow` |
| Activity log | §8.4 | `Storage/ActivityStore` | `Activity/ActivityWindow` |
| Notifications (D15) | §8.8 | `Notifications/NotificationPolicy` | `Services/RunNotifier` |
| Import / export | §9 | `Storage/RuleImporter`, `RulesFile` | `Services/RuleExporter`, Settings › Advanced |
| Folder health / TCC | §10 | `FolderStatusChecker` (in `Storage/RuleImporter.swift`), `Support/ProtectedLocation` | Settings › Folders, editor `FolderGate` |
| Updates | D10 | — | `Services/UpdaterService`, Settings › About |

---

## 9. Testing

- **Core:** `cd Packages/MFPeteCore && swift test`. Tests in `Tests/MFPeteCoreTests/` per area (`ModelTests`, `CodingTests`, `EvaluationTests`, `ActionTests`, `PatternAndConflictTests`, `EngineTests`, `TriggerTests`, `WatcherIntegrationTests` (real FSEvents), `SchedulerTests`, `NotificationTests`, `ValidationTests`, `TemplateTests`, `SummaryTests`, `StorageTests`, `ImportAndActivityTests`, `PerformanceTests`). Shared helpers: `EngineTestSupport.swift`.
- **App unit:** `xcodebuild test -project MFPete.xcodeproj -scheme MFPete -destination 'platform=macOS' -only-testing:MFPeteTests`.
- **UI:** `MFPeteUITests/` (uses `--ui-testing` fixture). Some may time out enabling automation mode in headless environments.
- CI: `.github/workflows/ci.yml` runs core + app unit tests on macos-26.

---

## 10. Build & Release

- Dev: open `MFPete.xcodeproj`, run `MFPete` scheme. SPM fetches Sparkle. Dev builds have no Sparkle key, so updates are off.
- Release: `scripts/release.sh` (archive, Developer ID export, notarize, staple, DMG + Sparkle zip in `build/release/`; `SKIP_NOTARIZE=1` for local). `scripts/make-appcast.sh` signs zip and writes `appcast.xml`.
- Feed: `https://github.com/petemcpherson/MFPete/releases/latest/download/appcast.xml` (release asset).
- Tag `v*` triggers `.github/workflows/release.yml`. Secrets listed in `docs/RELEASING.md`.

---

## 11. Conventions & Gotchas

- Keep file-system work in `MFPeteCore`. App target defaults to MainActor, so engine code there would run on the main thread.
- No SwiftUI/AppKit imports in `MFPeteCore`. Add a protocol in `Actions/Services.swift` instead.
- Keep enum JSON coding explicit and stable. Update `rules-v1.json` fixture tests when the format changes, and bump `RulesFile` version with a migration.
- New user-facing strings: `String(localized:)` and the right `Localizable.xcstrings` (app or core).
- Files go to Trash. Never delete permanently. Replace policy trashes the existing item first.
- Size units use 1000 (Finder style). Size conditions never match folders.
- Template 1 ("Clean up Downloads") is a daily schedule rule, not file-added (age conditions make sense only on schedules).
- `context/plan.md` implementation notes record many edge-case decisions. Check there before "fixing" surprising behavior.
