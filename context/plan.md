# MFPete: Implementation Plan

> Source: `context/spec.md` (Final v1.1, 2026-10-01; adds D14 manual Run Now and D15 notifications + simple log)
> Scope: v1 (MVP) as defined in spec §16. v1.x and v2 items are out of scope.

## Progress

- [x] Phase 1: Project foundation and data layer
- [x] Phase 2: Rule engine core (conditions, actions, run pipeline)
- [x] Phase 3: Triggers, file watching, and engine safety
- [x] Phase 4: Menu bar and dashboard UI
- [x] Phase 5: Rule editor, preview, and templates
- [ ] Phase 6: Activity log, settings, onboarding, and permissions
- [ ] Phase 7: Distribution, updates, and release

---

## Architecture Overview

```
MFPete.xcodeproj
├── MFPete (app target)            SwiftUI + AppKit. @MainActor UI, app lifecycle, windows.
│   ├── App/                        MFPeteApp, AppDelegate, AppState, activation policy
│   ├── MenuBar/                    MenuBarExtra content
│   ├── Dashboard/                  Rules list window
│   ├── Editor/                     Rule editor sheet, condition/action rows, preview
│   ├── Activity/                   Activity log window
│   ├── Settings/                   Settings scene tabs
│   ├── Onboarding/                 First-launch window
│   └── Services/                   Notifications, login item, Sparkle, permissions UI glue
├── Packages/MFPeteCore (local SPM)  No SwiftUI/AppKit imports. Headless-testable (spec §15).
│   ├── Model/                      Rule, Trigger, ConditionGroup, Action, RuleOptions, FolderRef
│   ├── Storage/                    RulesStore (JSON), ActivityStore + ProcessedStore (SwiftData)
│   ├── Evaluation/                 FileSnapshot, ConditionEvaluator, KindClassifier
│   ├── Actions/                    ActionExecutor, ConflictResolver, PatternRenderer, Unarchiver
│   ├── Engine/                     RuleEngine actor, RunPlanner, LoopGuard, BulkGuard
│   ├── Watching/                   FSEventsWatcher, Settler, IgnoreFilter
│   ├── Scheduling/                 Scheduler, next-fire calculation
│   └── Summary/                    RuleSummarizer (sentence text, used by UI)
├── MFPeteTests                     App-level tests
└── MFPeteUITests                   UI tests (spec §15)
```

Key principles:
- The engine lives in a local Swift package (`MFPeteCore`) so it has no SwiftUI/AppKit dependency and tests run headless. Exception: `NSWorkspace` calls (Open, Reveal, wake/mount notifications) go behind a protocol the app target implements.
- The app target uses `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (template default). The package does **not** set default MainActor isolation; the engine is an `actor` (D13).
- Swift 5 language mode in both targets (D13).
- All user-facing strings use `String(localized:)` and a String Catalog from day one (spec §14).

---

## Phase 1: Project foundation and data layer [COMPLETED]

Goal: a menu bar app shell that launches with no dock icon, loads and saves rules from JSON, and has the SwiftData store ready. No engine yet.

### 1.1 Project settings
- [x] Set `ENABLE_APP_SANDBOX = NO` and remove the App Sandbox capability / entitlements entry (D2). Keep Hardened Runtime on.
- [x] Set `MACOSX_DEPLOYMENT_TARGET = 14.0` for all targets (D3). Currently 26.2.
- [x] Confirm `SWIFT_VERSION = 5.0` (D13) and Swift 6 toolchain.
- [x] Add `LSUIElement = YES` to Info.plist (spec §11).
- [x] Confirm bundle ID `com.mftpete.MFPete` (D1).
- [x] Add `LICENSE` (MIT) at repo root and a stub `README.md`.
- [x] Add a String Catalog (`Localizable.xcstrings`) to the app target.
- [x] Delete template files `Item.swift` and the template `ContentView.swift` content.

### 1.2 Create `MFPeteCore` local package
- [x] Create `Packages/MFPeteCore` with a library target and a test target. Platform `.macOS(.v14)`, Swift 5 language mode.
- [x] Add the package to the Xcode project and link it to the app target.
- [x] Verify `swift test` runs from the package folder with no app dependency.

### 1.3 Data model (spec §9)
- [x] `Rule`, `FolderRef`, `Trigger`, `ConditionGroup`, `ConditionItem`, `Condition`, `Action`, `RuleOptions` as `Codable`, `Hashable`, `Sendable`.
- [x] `Attribute`, `Operator`, `ConditionValue` (text, number+unit, relative duration, absolute date, kind enum, tag list), `Match` (`.all`/`.any`), `ConflictPolicy` (`.keepBoth`/`.replace`/`.skip`), `SizeUnit`, `DurationUnit`, `FileKind`.
- [x] Stable, explicit JSON coding for enums with associated values (a `"type"` discriminator plus fields). Do not rely on Swift's synthesized enum coding: the format must stay stable for export/import.
- [x] Unknown-case decoding: decode unknown action/attribute types into an `.unknown(rawJSON)` placeholder so the rule can import as disabled with a warning (spec §9).
- [x] Operator validity table: which operators each attribute allows (spec §4.2). Used by evaluator, editor, and validation.
- [x] `FolderRef` helpers: tilde-abbreviation for display and export, expansion on import.
- [x] Auto-generated rule name ("Downloads: Move to Trash") per spec §7.

### 1.4 Rules storage (D4)
- [x] `RulesFile { version: Int; rules: [Rule] }` with `"version": 1`.
- [x] `RulesStore`: loads/saves `~/Library/Application Support/MFPete/rules.json`. Creates folder on first run.
- [x] Atomic save: write `rules.json.bak` copy of the current file, then write new file atomically (spec §13).
- [x] Corrupt-file recovery: try `rules.json`, then `.bak`; if both fail, rename corrupt file to `rules.corrupt-<timestamp>.json`, start empty, and surface an alert flag to the UI.
- [x] Migration hook: `migrate(from version:)` pipeline (empty for v1, but tested).

### 1.5 SwiftData store (D4)
- [x] `@Model ActivityEntry` (spec §9 fields, plus `resultKind` enum raw value and `message` for failures, and `detail` string).
- [x] `@Model ProcessedRecord` with a unique compound key (`ruleID` + `fileKey`) and `modifiedAt`.
- [x] `ModelContainer` at `~/Library/Application Support/MFPete/MFPete.store`.
- [x] `ActivityStore` and `ProcessedStore` as `@ModelActor` types so the engine actor can write off the main thread. UI reads through a main-context `@Query`.
- [x] Retention pruning: delete entries older than 30 days or beyond 10,000 (fixed in v1, D15).

### 1.6 App shell
- [x] `MFPeteApp` with `MenuBarExtra(.menu)` showing placeholder items and Quit.
- [x] `Window("Rules", id: "rules")` scene and `Settings` scene (empty tabs for now).
- [x] `AppState` (`@Observable`, `@MainActor`) owning the loaded rules array and exposing add/update/delete/reorder that persist through `RulesStore`.
- [x] `AppDelegate` via `@NSApplicationDelegateAdaptor`: closing the last window does not quit (`applicationShouldTerminateAfterLastWindowClosed` → `false`).
- [x] Single instance: on second launch, activate the running instance and open the Rules window (check `NSRunningApplication` with the same bundle ID, send a distributed notification, then terminate).
- [x] Activation helper: when opening a window in accessory mode, call `NSApp.activate()` so the window comes to front.

### 1.7 Tests
- [x] JSON round-trip for every `Trigger`, `Action`, `ConditionValue` case.
- [x] Decoding a fixture `rules.json` (checked into the test bundle) to lock the format.
- [x] Unknown action type imports as `.unknown` and marks the rule disabled.
- [x] Corrupt file → backup load → empty-start path.

**Done when:** app launches into the menu bar with no dock icon, rules persist across relaunch, `swift test` passes in `MFPeteCore`.

---

## Phase 2: Rule engine core (conditions, actions, run pipeline) [COMPLETED]

Goal: given a rule and a list of candidate files, the engine evaluates conditions and performs actions correctly, logging results. Triggered only by "Run Now" in this phase.

### 2.1 File snapshot
- [x] `FileSnapshot` struct built from `URL.resourceValues(forKeys:)`: name, extension, full name, isDirectory, isPackage, isSymlink/alias, `contentType` (UTType), `fileSize`, `totalFileAllocatedSize`, `addedToDirectoryDate`, `creationDate`, `contentModificationDate`, `tagNames`, `fileIdentifier` / volume UUID, ubiquitous/dataless status.
- [x] `Downloaded from`: read `com.apple.metadata:kMDItemWhereFroms` xattr with `getxattr`, decode binary plist into `[String]`.
- [x] `FileKey` builder: volume UUID + `fileIdentifierKey` (inode), path as fallback (spec §5.5).

### 2.2 Kind classification
- [x] `KindClassifier` maps `UTType` conformance to `FileKind`: Folder, Image, Movie, Audio, PDF, Text, Document, Archive, Disk Image, Application, Alias/Symlink, Other (spec §4.2).
- [x] Order matters (PDF before Document, Application before Folder for `.app` bundles). Document and test the precedence.

### 2.3 Condition evaluation (spec §4)
- [x] `ConditionEvaluator.matches(_ group: ConditionGroup, snapshot:, now:) -> Bool`, recursive for any depth (D12: data model allows any depth).
- [x] Empty group = match all. `.all` = AND, `.any` = OR.
- [x] Text ops: is, is not, contains, does not contain, starts with, ends with, matches pattern (`*`, `?` wildcard via `fnmatch` or a small hand-written matcher). Case-insensitive by default.
- [x] Extension ops: is, is not, is any of (comma list, trimmed, dot stripped, lowercased).
- [x] Kind ops: is, is not.
- [x] Size ops: greater than / less than with KB/MB/GB (decide 1000 vs 1024: use 1000 to match Finder, document it).
- [x] Date ops: in the last N (min/hours/days/weeks/months), not in the last N, before date, after date. Use `Calendar` for months/weeks.
- [x] Tag ops: contains tag, does not contain tag, has no tags.
- [x] Downloaded from ops: contains, does not contain, is.
- [x] Any file: always true.

### 2.4 Name patterns (spec §6.2)
- [x] `PatternRenderer.render(_ pattern: String, snapshot:, now:, counter:) -> String`.
- [x] Tokens: `{name}`, `{extension}`, `{fullname}`, `{date-added}`, `{date-created}`, `{date-modified}`, `{year}`, `{month}`, `{day}`, `{today}`, `{time}`, `{counter}`, `{folder}`, `{kind}`.
- [x] Replace `:` and `/` with `-` in rendered file names. For Sort into subfolder, split the pattern on `/` first so `{year}/{month}` creates nested folders, then sanitize each segment.
- [x] Unknown tokens render literally (and the editor flags them in Phase 5).

### 2.5 Conflict resolution (spec §6.3)
- [x] `ConflictResolver.resolve(destination:, policy:) -> Resolution` (`.proceed(URL)`, `.replaceAfterTrashing(URL)`, `.skip`).
- [x] Keep both: Finder-style ` 2`, ` 3` before the extension. Handle names with no extension and multi-dot names (`archive.tar.gz` → treat last extension only, matching Finder).
- [x] Replace: trash the existing item first, never overwrite.
- [x] `{counter}` in a rename pattern takes priority over Keep both suffixing.

### 2.6 Action execution (spec §6.1)
- [x] `ActionExecutor` protocol-based, one handler per action. Each returns `ActionOutcome { newURL?, destinationPath?, result }`.
- [x] Move to folder, Copy to folder (later actions keep the original), Rename, Change extension, Move to Trash (`FileManager.trashItem`), Sort into subfolder (create missing subfolders), Add tags / Remove tags (`URLResourceValues.tagNames`).
- [x] Unarchive (`.zip` only): run `/usr/bin/ditto -x -k <zip> <tempDir>` via `Process`, then move results into destination with conflict handling (Keep both). Optional trash of archive. Report extracted paths so Phase 3 can treat them as "added" files.
- [x] Open, Reveal in Finder, Show notification: go through a `WorkspaceService` / `NotificationService` protocol injected by the app target (keeps the package AppKit-free).
- [x] Wrap writes in `NSFileCoordinator` where another app might be writing (spec §5.7).
- [x] Missing destination folder → fail with clear message (auto-create is v1.x, spec §13). Exception: Sort into subfolder creates subfolders under an existing base.
- [x] Map errors: file vanished → `skipped`; permission denied → `failed` + rule marked "No permission"; disk full → `failed`.

### 2.7 Run pipeline (spec §2.1)
- [x] `RuleEngine` actor with `run(rule:, candidates:, reason:)`. `reason` is a `RunTrigger` (`fileEvent`, `scheduled`, `scheduledLate`, `manual`, `applyExisting`).
- [x] Add `runTrigger` (raw `String`, default `"fileEvent"`) to the `ActivityEntry` model and `ActivityRecord` value copy. Every entry records why its run happened (D15).
- [x] `runNow(ruleID:)` entry point (D14): full scan of scope, same path as a scheduled run, `reason: .manual`. Runs on disabled rules and while paused. Respects processed records. Rejects "File removed" rules. If the rule is already running, return `.alreadyRunning` (no queue).
- [x] `RunSummary` returned from every run: counts of files acted on, skipped (already processed), skipped (other), failed, plus the dominant action verb for notification text ("moved to Trash"). Manual run with zero matches writes one "No matching files" entry.
- [x] Candidate listing for full scans: direct children by default, recursive with "Include subfolders" (do not descend into packages; spec §5.2). Use `FileManager.enumerator` with `.skipsPackageDescendants` and prefetching resource keys.
- [x] `IgnoreFilter`: hidden files, `.DS_Store`, `Icon\r`, `.localized`, in-progress download patterns (spec §5.3, §5.4). Respect "Include hidden files".
- [x] Processed-record check (D6): skip a file if a record exists with `modifiedAt >= current contentModificationDate`. Write the record after the actions finish.
- [x] Multi-rule ordering (D5): when several rules share a candidate, run them in dashboard order. If a rule moved or trashed the file, later rules for that folder skip it. Honor "Stop processing other rules for matched files".
- [x] Per-file action chain: serial. If an action fails, stop remaining actions for that file and log.
- [x] Parallelism across files: `TaskGroup` with max 4 concurrent files (spec §5.7).
- [x] Self-change tracking: record paths the engine just created/modified with a short TTL so Phase 3 can suppress events for the producing rule (spec §5.4, §5.5).
- [x] Write one `ActivityEntry` per action, plus rule-level error entries.
- [x] Rule stats (last run, lifetime file count, last error) computed from activity log queries, not stored in JSON (spec §9).
- [x] Folder health check before each run: exists and readable, else mark rule "Folder missing" / "No permission" (spec §10).

### 2.8 Dry run (for Preview)
- [x] `RuleEngine.plan(rule:)` returns `[PlannedFileResult { file, steps: [PlannedStep] }]` with predicted destination paths. No file system changes. Reuses evaluator, pattern renderer, and conflict resolver in simulation mode.

### 2.9 Rule summary sentence (D11)
- [x] `RuleSummarizer.sentence(for: rule)` → "When a file is added to Downloads, if its extension is dmg or zip, then move it to the Trash."
- [x] Short form for dashboard rows (two lines: trigger + conditions, actions).
- [x] Put this in `MFPeteCore` so it is unit tested; use `String(localized:)` for fragments.

### 2.10 Tests (spec §15)
- [x] Every attribute × operator combination, using temp files with set dates/tags/xattrs.
- [x] Nested groups (All containing Any).
- [x] Pattern rendering for every token and sanitization.
- [x] Conflict naming: Keep both, Replace (goes to Trash), Skip; names without extension.
- [x] Each action against a temp directory, including Unarchive of a Finder-style zip and a corrupt zip.
- [x] Once-per-file record: second run does nothing; modifying the file makes it eligible again.
- [x] `runNow` on a disabled rule and while paused still runs; on a "File removed" rule is rejected; `RunSummary` counts and "No matching files" entry are correct.
- [x] D5 ordering and "stop other rules".
- [x] Summary sentence snapshots for each template rule.

**Implementation notes (decisions made in Phase 2):**
- "Contains tag" matches any listed tag; "does not contain tag" matches none of them.
- "Before date" = earlier than the start of that day; "after date" = on or after the start of the next day.
- Size conditions never match folders/packages (folder size is v2).
- `{counter}` starts at 1 and counts up until the name is free; it overrides the conflict policy.
- A skipped action (name exists, file vanished) stops the chain like a failure. Failed files are not marked processed, so they retry next run.
- All activity entries for one file in one rule run share a timestamp; `ActivityStore.stats(ruleID:)` counts files as distinct successful timestamps.
- Rule-level folder errors are logged only when the rule's status changes, to avoid log spam on every scheduled run.
- `RuleEngine.scanAndRun(_:reason:)` is the full-scan entry point Phase 3 scheduled runs and apply-to-existing should reuse; `run(rules:candidates:reason:)` is the file-event entry point (D5 ordering).
- `RuleEngine.selfChangeProducer(of:)` exposes self-change tracking (10 s TTL) for Phase 3.

**Done when:** a headless test can build a rule, point it at a temp folder, call `runNow`, and verify the files moved/renamed/tagged, the activity entries written (with `runTrigger = manual`), and the `RunSummary` returned.

---

## Phase 3: Triggers, file watching, and engine safety [COMPLETED]

Goal: rules fire automatically from file events and schedules, safely, with loop and bulk protection.

### 3.1 FSEvents watcher (spec §5.1)
- [x] `FSEventsWatcher` wrapping `FSEventStreamCreate` with `kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer`, dispatch queue delivery (`FSEventStreamSetDispatchQueue`).
- [x] One stream for the union of enabled rules' scope folders. Rebuild when the set changes (rule add/edit/enable/disable/delete).
- [x] C callback bridges into an `AsyncStream<[FileEvent]>` consumed by the engine actor (D13: keep the C boundary small, mark it `@unchecked Sendable` where needed).
- [x] Map flags to added / modified / removed. Treat rename pairs: item renamed into a scope folder = added, renamed out = removed.
- [x] Persist the last event ID (`UserDefaults`) on a throttle (for example every 5 s and on quit).
- [x] Launch: start from the stored event ID so missed events replay. On `kFSEventStreamEventFlagMustScanSubDirs`, `UserDropped`/`KernelDropped`, or event ID wrap, fall back to a full scan of affected folders compared against the processed-file record.
- [x] Filter events to direct children unless "Include subfolders" is on.

### 3.2 Settling (spec §5.3)
- [x] `Settler` actor: per-path timer. A file becomes ready when size and modification date are unchanged for the settle delay (default 2 s, range 1–30 s).
- [x] Skip known in-progress names (`*.crdownload`, `*.download`, `*.part`, `*.partial`, `*.tmp`, `*.opdownload`, `.com.google.Chrome.*`). When the final name appears, it arrives as a new event.
- [x] Dataless cloud placeholders: if the action set needs file contents (Copy, Unarchive), wait until the file is downloaded; never trigger a download during scheduled scans unless an action needs contents (spec §12).
- [x] If the file disappears before settling, drop it silently.

### 3.3 Trigger routing
- [x] File added → candidates from added events after settling.
- [x] File modified → debounced (reuse settle delay). Ignore modifications the engine itself made (self-change tracking from Phase 2.7).
- [x] File removed → no settle, no snapshot from disk. Evaluate name/extension/path conditions only; allow only Notify-style actions (editor enforces in Phase 5; engine also guards).
- [x] Chaining: items the engine creates/moves into a watched folder are suppressed for the producing rule only. Other rules see them as added (spec §5.4). Unarchive outputs count as added.

### 3.4 Scheduler (spec §3.2)
- [x] `Scheduler` computes `nextFireDate(after:)` for interval (min 5 min), daily, and weekly triggers using `Calendar.current` (handles DST).
- [x] Single timer for the soonest next fire; recompute after each fire and on rule change.
- [x] Persist `lastScheduledRun` per rule (small JSON or `UserDefaults` keyed by rule ID).
- [x] Missed schedules: on launch and on wake, if a scheduled time passed while asleep/closed, run once and log "Ran late (missed 09:00)". No backlog.
- [x] Scheduled run = full scan of scope folders (same as Run Now).

### 3.5 Lifecycle hooks (spec §11)
- [x] App target forwards `NSWorkspace.didWakeNotification` → engine: run missed schedules, restart stream if needed.
- [x] `didMountNotification` / `didUnmountNotification` → rules on that volume go "Folder unavailable" without error spam, resume on mount, rebuild stream.
- [x] Clean shutdown: flush event ID, stop stream.

### 3.6 Safety
- [x] Loop guard (spec §5.6): track runs per file key over 60 s. Over 10 runs → stop the chain, log "Possible rule loop between Rule A and Rule B", send notification. Disable nothing.
- [x] Bulk guard: if one run would act on more than the threshold (default 50), pause and emit a `BulkApprovalRequest` to the UI (Preview / Run / Cancel). Not applied to the first-enable prompt.
- [x] Global pause: engine flag. Events received while paused are discarded. On resume, UI offers "Scan now" for file-event rules. Manual `runNow` ignores the pause flag (D14).
- [x] Bulk guard also applies to manual runs.
- [x] Manual runs do not touch `lastScheduledRun` or the next fire date.
- [x] Apply-to-existing on enable (spec §3.4): when a file-event rule is created or enabled, engine counts current matches and emits a request to the UI (Preview / Apply / Only new files, default Only new files). "Only new files" writes processed records for current files so they are skipped.
- [x] "Run Again on All Files" per rule: delete that rule's processed records (D6).

### 3.7 Tests (spec §15)
- [x] Integration tests with temp directories and a real FSEvents stream: add/modify/remove, settling (write a file in chunks), chaining across two rules, loop guard trips, bulk guard trips, pause discards.
- [x] Event ID replay: stop watcher, add files, restart from stored ID, verify catch-up.
- [x] Scheduler next-fire tests across DST transitions and weekday sets; missed-schedule logic with an injected clock.

**Implementation notes (decisions made in Phase 3):**
- `TriggerCoordinator` (actor in `MFPeteCore`) owns the `FSEventsWatcher`, `Settler`, schedule timer, and `EngineStateStore`; it routes triggers to `RuleEngine`. The app keeps one in `AppState` and forwards wake/mount/unmount and quit (`applicationShouldTerminate` → `.terminateLater` until `stop()` saves the event ID).
- UI-facing results go out on `RuleEngine.events` (`EngineEvent`: `runFinished`, `bulkApprovalRequested`, `applyExistingRequested`, `loopDetected`). Only automatic runs that matched files or hit errors emit `runFinished`; runs the user started (Run Now, Apply, approved bulk) return their summary to the caller. Until Phase 4, `AppState` only logs these events.
- FSEvents keeps the "created" flag on later writes to a recently created file. A created-and-changed event on an item born more than 2 s ago counts as modified (live events only, never during history replay; renames always count as added).
- The stream always starts from an explicit event ID (stored, or the current one), so a rebuild never misses events. If the stored ID is newer than the system's current ID (FSEvents database reset), all "File added" rules get a fallback full scan.
- Settled files arriving within 0.25 s run as one batch, so the bulk guard sees a large drop as one run. Bulk counts only files that match and are not already processed.
- Loop guard chains follow the file key across moves, and engine-made copies inherit their source's chain (60 s), so copy ping-pong between two rules also trips it. Trips log one "Loop guard" failed entry and emit `loopDetected`; nothing is disabled.
- Apply-to-existing: on create/enable, the engine immediately marks current matches processed (the "Only new files" default) and emits the request. "Apply" forgets those records and runs with `reason: .applyExisting`, skipping the bulk guard. Rules loaded at launch never prompt.
- Newly enabled schedule rules start their clock at enable time (no catch-up for time spent disabled). Schedule fires while paused pass without a run and without later catch-up.
- "Ran late (missed 9:00 AM)" is stored in each activity entry's `detail` and in `RunSummary.note`, not as a separate entry (keeps file-count stats exact).
- Unmounted volumes: `FolderHealth.unavailable` / `RuleStatus.folderUnavailable` (not an error badge, no log entries).
- "File removed" rules build a name-only snapshot; only Show notification actions run, others log as skipped. No processed records.
- Settings keys read at launch: `settleDelay`, `bulkGuardThreshold` (UI in Phase 6).

**Done when:** dropping a `.zip` into a watched folder with an Unarchive rule extracts it within ~3 seconds, and a daily rule runs once after wake if missed.

---

## Phase 4: Menu bar and dashboard UI [COMPLETED]

Goal: the user can see, toggle, reorder, search, run, duplicate, and delete rules, and the menu bar reflects live state.

### 4.1 App ↔ engine bridge
- [x] `EngineController` (`@MainActor @Observable`) owns the `RuleEngine` actor, pushes rule changes to it, and exposes UI state: paused, per-rule status (OK / error / folder missing / no permission), per-rule `isRunning`, pending bulk/apply requests, recent activity.
- [x] `EngineController.runNow(_ ruleID:)` used by every Run Now entry point (row button, row menu, menu bar submenu, editor Save & Run). Hands the `RunSummary` to `NotificationService` (Phase 6.2).
- [x] Error badge clears on the next successful run or when the user opens the rule (spec §13).

### 4.2 Menu bar extra (spec §8.1)
- [x] Header: "MFPete — N rules active" (disabled item).
- [x] Recent activity: last 3–5 entries with relative time; click reveals in Finder.
- [x] Pause all rules (⌘P), Run rule ▸ submenu, Open Rules… (⌘R), Settings… (⌘,), Quit (⌘Q).
- [x] Run rule ▸ lists all rules, including disabled ones (D14). "File removed" rules show disabled. Feedback comes from the summary notification, since no window is open.
- [x] Icon: template SF Symbol `tray.and.arrow.down`; paused variant; badge dot when any rule has an unresolved error.
- [x] Opening a window from the menu activates the app (accessory mode).

### 4.3 Dashboard window (spec §8.2)
- [x] Single `List` with custom rows: toggle, name, summary (2 lines from `RuleSummarizer`), last run, lifetime file count, error badge.
- [x] Run Now button on every row (D14, spec §3.3): `play.fill` borderless button, always visible, left of `⋯`. Shows a `ProgressView` spinner while `isRunning`. Disabled with tooltip for "File removed" rules. VoiceOver label "Run <rule name> now". "Last run" updates when the run finishes.
- [x] Row `⋯` menu: Edit, Run Now, Preview Matches, Duplicate, Export…, Show Activity, Run Again on All Files, Delete (confirm).
- [x] Double-click / Return opens editor (editor itself comes in Phase 5; stub sheet for now).
- [x] Drag to reorder (`.onMove`) updates `order` and persists (D5).
- [x] Toolbar: search field (rule name + folder name), Filter menu (Enabled / Disabled / Has errors; Trigger type; Folder), Sort menu (Manual, Name, Last run, Date created; non-manual disables drag and shows a hint), Activity button, `+` menu (New rule, New from template ▸).
- [x] Empty state: short message, 3 template buttons, "Create blank rule".
- [x] Bulk guard and apply-to-existing prompts presented as alerts/sheets from `EngineController` requests.
- [x] Keyboard navigation and VoiceOver labels on rows and controls.

### 4.4 Tests
- [x] UI test: toggle a rule, reorder, delete with confirmation, click Run Now and see "Last run" update.
- [x] Unit tests for search/filter/sort logic (pure functions in a view model).

**Implementation notes (decisions made in Phase 4):**
- `EngineController` (in `AppState.engineController`) now owns `RuleEngine` and `TriggerCoordinator`; `AppState` pushes rules through it. It refreshes statuses, stats, and the last 5 activity entries after every engine event and every run it starts, and when the Rules window appears (no polling).
- Global pause is persisted in `UserDefaults` (`isPaused`) and applied at launch. Resuming with an enabled "File added" rule shows a "Scan Now" banner in the dashboard and a menu bar item.
- Run results go to a `RunNotifier` protocol; `LoggingRunNotifier` only logs until Phase 6.2 adds real notifications. Bulk and apply-to-existing prompts open the Rules window if it is closed.
- Duplicate inserts a disabled copy ("Name copy") directly below the original. "Run Again on All Files" resets processed records, then starts a Run Now (bulk guard applies).
- Export… (one rule) is already wired with `NSSavePanel` (Phase 6.4 adds Export all / Import). "Show Activity" and the toolbar Activity button are present but disabled until the Activity window (Phase 6.1).
- Drag reorder works only in Manual sort with no search or filter; otherwise a hint shows below the list.
- `RuleTemplate` (6 templates, 3 featured) moved forward into `MFPeteCore` for the empty state and `+` menu. Templates without an obvious folder leave folder fields empty for the Phase 5 editor. Phase 5.7 only needs to wire them into the real editor.
- `RuleEditorSheet` is a stub (name, enabled, summary sentence, Cancel / Save & Run / Save Rule, ⌘S, Esc). `PreviewSheet` is a working dry-run list reused by Preview Matches and both prompts; Phase 5.6 can refine it.
- Menu bar icon is a template `NSImage`: dimmed with pause bars when paused, with a dot when any rule has an error status.
- `--ui-testing` launch argument (`UITestingFixture`) gives the app isolated rules, an in-memory data store, a separate defaults suite, and opens the Rules window. App unit tests also use isolated stores now.

**Done when:** user manages rules entirely from the dashboard and menu bar (except editing), and state survives relaunch.

---

## Phase 5: Rule editor, preview, and templates [COMPLETED]

Goal: the When / If / Then editor (D11) with live summary, live match count, preview, validation, and starter templates.

### 5.1 Editor structure (spec §8.3)
- [x] Sheet over the dashboard. Works on a draft copy of the rule; Save writes back; Cancel discards (confirm if dirty). ⌘S saves, Esc cancels.
- [x] Header: name field (auto-generated until the user edits it) + live summary sentence.
- [x] Footer: "More options" disclosure (stop other rules, notify on each run, notes), Cancel, Save & Run, Save Rule.
- [x] Save & Run (D14): validate, save, close the sheet, then call `EngineController.runNow`. Disabled for "File removed" rules.

### 5.2 WHEN card
- [x] Trigger popup: File added (default), Schedule options, and "More triggers" disclosure for File modified / File removed (spec §3.1).
- [x] Schedule controls: interval (number + minutes/hours, min 5 min), daily time picker, weekly day toggles + time.
- [x] Folder list: folder picker via `NSOpenPanel` (can choose directories only), drag-in from Finder (`.dropDestination(for: URL.self)`), path display tilde-abbreviated, `[+ folder]`.
- [x] TCC explainer: the first time the user picks Desktop, Documents, Downloads, iCloud Drive, or a removable/network volume, show a short explainer before touching the folder (spec §10).
- [x] Options disclosure: Include subfolders, Include hidden files.

### 5.3 IF card
- [x] Top-level All/Any popup.
- [x] Condition row: attribute popup → operator popup (filtered by validity table) → value control by type (text field, extension list, kind popup, number + unit, number + duration unit, date picker, tag token field, none for Any file). Remove / add buttons.
- [x] Add group: one nested level in the UI (D12). Nested group has its own All/Any popup.
- [x] Empty conditions hint: "Matches all files in this folder" (warning style).
- [x] Age-condition hint on file-event rules (spec §4.2 notes).
- [x] Live match count: debounced (~400 ms) background `plan(rule:)` call against current scope; "Matches N files right now" + Preview button.

### 5.4 THEN card
- [x] Ordered action list with drag handle `≡` and remove button.
- [x] Action popup + per-action parameters: folder picker, conflict policy popup, pattern field with token chips and live preview against a sample file from scope, tag field, unarchive options, app picker for Open, message template.
- [x] File removed trigger: only Notify-style actions selectable (spec §3.1).

### 5.5 Validation (spec §8.3)
- [x] At least one folder; at least one action; all required parameters set; trigger/action compatibility; Move destination equals source → warning (not error) if a Rename comes first.
- [x] Destructive warning banner when actions include Move to Trash or Replace policy and conditions are empty.
- [x] Unknown tokens in patterns flagged.
- [x] Validation logic lives in `MFPeteCore` (`RuleValidator`) and is unit tested.

### 5.6 Preview
- [x] Preview sheet listing matching files and each planned step ("invoice.pdf → Documents/pdf/invoice.pdf"). No changes made.
- [x] Reused for dashboard "Preview Matches", bulk guard "Preview", and apply-to-existing "Preview".

### 5.7 Templates (spec §8.6)
- [x] Define the 6 templates as factory functions in `MFPeteCore` (folders left empty or pre-set to standard paths where obvious, like `~/Downloads`).
- [x] Note: template 1 mixes "file added" with a daily schedule in the spec; implement it as a **daily schedule** rule on Downloads (age condition only makes sense on schedules, spec §4.2).
- [x] Wire into empty state and `+` menu "New from template ▸". Template opens the editor pre-filled; user confirms folders and saves.

### 5.8 Tests
- [x] UI tests: create rule from template, edit and save, preview shows expected files (spec §15).
- [x] `RuleValidator` unit tests for each rule.
- [ ] Measure goal: "clean my Downloads" rule from launch in under 60 s (manual check, spec §1.1). Not yet timed by hand.

**Implementation notes (decisions made in Phase 5):**
- Editor files live in `MFPete/Editor/` (`RuleEditorSheet`, `WhenCard`, `IfCard`, `ThenCard`, `EditorControls`, `PreviewSheet`). Popup choices and labels (`TriggerType`, `ActionType`, `Attribute`/`Operator` display names, `Condition.changingAttribute/Operator`) live in `MFPeteCore` (`Model/EditorChoices.swift`) so they are unit tested.
- `RuleValidator` returns `RuleIssue`s (error / warning, a `Code`, a message, and an optional action index). Errors block Save and appear after the first Save attempt; warnings (unknown tokens, move into source after a rename, destructive banner) show right away.
- Move into a scope folder is an error unless a Rename or Change extension comes first (then a warning).
- "More triggers" is a link button that adds File modified / File removed to the trigger popup; it stays open when the rule already uses one.
- Tag fields are comma-separated text fields, not `NSTokenField`.
- Age hint covers only relative dates ("in the last" / "not in the last") on file-event rules.
- TCC explainer: `FolderGate` shows a one-time alert per `ProtectedLocation` (Desktop, Documents, Downloads, iCloud Drive, removable/network volumes) before the folder is used. Shown locations are stored in `UserDefaults` (`explainedProtectedLocations`).
- Live match count and pattern previews: a 400 ms debounced `plan(rule:)` on scope/trigger/conditions/options changes; the sample file is the first file (not folder) in scope.
- Actions reorder by dragging the `≡` handle onto another row; VoiceOver gets Move Up / Move Down actions.
- Templates were already factory functions in `MFPeteCore` (Phase 4). `AppState.templateHome` expands their `~` paths; UI tests point it at a temporary folder. `--ui-testing-empty` starts the fixture with no rules.

**Done when:** a new user can build any v1 rule in the editor, see what it will do, and save it.

---

## Phase 6: Activity log, settings, onboarding, and permissions

Goal: complete the remaining v1 surfaces so the app is trustworthy and self-explanatory.

### 6.1 Activity log window (spec §8.4, D15: keep it simple)
- [ ] `Window("Activity", id: "activity")` with a `Table`, newest first: Time, Rule, Trigger (File event / Scheduled / Ran late / Manual), Action, File, Result (✓ / ⚠︎ / ✕). Failure/skip message as a second line under the file name.
- [ ] Filters: Rule popup (All rules / one rule) and an "Errors only" toggle. Opening from a rule's "Show Activity" or from a notification click pre-selects the rule.
- [ ] Row context menu: Reveal in Finder (if file exists), Copy path.
- [ ] "Clear log" (confirm). Retention is fixed (30 days / 10,000 entries); pruning runs at launch and daily.
- [ ] Efficient queries with `FetchDescriptor` limits and sort by timestamp (10,000 rows max).

### 6.2 Notifications (spec §8.8, D15)
- [ ] `NotificationService` using `UNUserNotificationCenter`. Takes `RunSummary` values from `EngineController`.
- [ ] One summary per run, never per file ("Clean Downloads: 3 files moved to Trash", "Sort by type: 5 files processed, 1 failed", "…: No matching files" for manual runs).
- [ ] `NotificationPolicy.shouldNotify(level:, rule:, summary:) -> Bool` as a pure function in `MFPeteCore`, implementing the spec §8.8 table (Off / Errors only / Every run × automatic / manual / error). Automatic runs with 0 files acted on never notify.
- [ ] Coalescing: merge file-event summaries for the same rule within a 5 s window into one notification (sum the counts). Same for errors.
- [ ] Per-rule "Notify on each run" forces summaries under "Errors only".
- [ ] "Show notification" action fires at every level, including Off.
- [ ] Loop-guard alert, disk-full and missing-destination errors go through the same error path.
- [ ] Notification click (`UNUserNotificationCenterDelegate`) opens the Activity window filtered to that rule (rule ID in `userInfo`).
- [ ] App works fully without notification permission.
- [ ] Unit tests: every row of the policy table, coalescing window, summary text.

### 6.3 Settings scene (spec §8.5)
- [ ] **General:** Launch at login (`SMAppService.mainApp.register()/unregister()`, reflect real status including "Requires approval"); Show icon in Dock (`NSApp.setActivationPolicy(.regular/.accessory)`, persisted, applied at launch); Notifications level.
- [ ] **Folders:** list of all scope folders, the rules using each, status (OK / missing / no permission / unavailable), Reveal in Finder, "Open Privacy & Security" button (`x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders`).
- [ ] **Advanced:** settle delay (1–30 s), bulk guard threshold, Export all rules, Import rules, Reset processed-file history (confirm). No log retention setting in v1 (D15).
- [ ] **About:** version, MIT license, GitHub link. Sparkle controls come in Phase 7 (leave a placeholder).

### 6.4 Import / export (spec §9)
- [ ] Export one rule (dashboard `⋯`) or all rules (Settings) via `NSSavePanel` to `.json` with the `rules.json` schema, paths tilde-abbreviated.
- [ ] Import via `NSOpenPanel`: migrate older versions, assign new IDs to avoid collisions, append at end of order, import **disabled**. Unknown types → disabled with warning. Missing folders show "Folder missing".

### 6.5 Onboarding (spec §8.7)
- [ ] First-launch window with three steps: what MFPete does (When/If/Then picture), Launch at login toggle (default on) + notification permission request, "Create your first rule" templates or Skip.
- [ ] After closing: one-time popover/hint pointing at the menu bar icon (a small borderless panel anchored near the status item is acceptable, since `MenuBarExtra` exposes no anchor).
- [ ] Store `hasCompletedOnboarding`.

### 6.6 Permissions and error states (spec §10, §13)
- [ ] Central folder-status checker used by engine, dashboard badges, menu bar dot, and Settings › Folders.
- [ ] Error table from spec §13 fully covered: destination missing, permission denied, vanished file, disk full, unarchive failure, loop detected, corrupt rules file alert.
- [ ] Corrupt rules file alert on launch (from Phase 1.4 flag).

### 6.7 Accessibility and polish
- [ ] VoiceOver labels on all custom controls; full keyboard navigation in editor and dashboard.
- [ ] Light/dark mode check on every screen.
- [ ] All strings in the String Catalog.

**Done when:** every v1 bullet in spec §16 except distribution works end to end.

---

## Phase 7: Distribution, updates, and release

Goal: signed, notarized builds on GitHub Releases, Sparkle updates, Homebrew cask, and a release-ready repo (D10, spec §14).

### 7.1 Sparkle 2
- [ ] Add Sparkle 2 via SPM to the app target.
- [ ] Generate EdDSA keys with Sparkle's `generate_keys`; store the private key in the macOS Keychain locally and as a GitHub Actions secret. Put `SUPublicEDKey` and `SUFeedURL` (GitHub-hosted `appcast.xml`) in Info.plist.
- [ ] `SPUStandardUpdaterController` owned by the app; "Check for Updates…" in Settings › About (and optionally in the menu bar menu); "Automatically check for updates" toggle bound to `updater.automaticallyChecksForUpdates` (on by default).
- [ ] Confirm Sparkle works with sandbox off (no XPC installer services needed).

### 7.2 Signing and notarization
- [ ] Apple Developer Program account and Developer ID Application certificate.
- [ ] Hardened Runtime on; no extra entitlements needed (sandbox off).
- [ ] Release build script: `xcodebuild archive` → export with Developer ID → `notarytool submit --wait` → `stapler staple`.
- [ ] Package `.dmg` (manual download) and `.zip` (Sparkle) from the stapled app.

### 7.3 GitHub Actions
- [ ] CI workflow on push/PR: build app, run `MFPeteCore` tests and app unit tests.
- [ ] Release workflow on tag push (`v*`): import signing certificate into a temp keychain, archive, notarize, staple, build `.dmg` + `.zip`, sign the zip with Sparkle's `sign_update`, update `appcast.xml`, create GitHub Release with assets.

### 7.4 Homebrew cask
- [ ] Draft `mfpete.rb` cask (token `mfpete`, `auto_updates true`, `depends_on macos: ">= :sonoma"`, `zap` stanza for `~/Library/Application Support/MFPete` and preferences).
- [ ] Submit to `homebrew/cask` after first public release meets their notability requirements; until then, document direct download.

### 7.5 Repo and docs
- [ ] README: screenshots, what it does, templates, privacy statement (only network traffic is Sparkle update check), install (Homebrew + DMG), build instructions.
- [ ] CONTRIBUTING.md and GitHub issue templates (bug, feature).
- [ ] Verify all dependencies are MIT/BSD/Apache compatible.

### 7.6 Release validation
- [ ] Performance check against spec §5.8: idle CPU ~0%, under 60 MB resident with 20 rules, 5,000-item scan under 2 s (Instruments + a perf test in `MFPeteCore`).
- [ ] Clean-machine test on macOS 14 and current macOS: install from DMG, Gatekeeper passes, onboarding, TCC prompts, update from previous version via Sparkle.
- [ ] Tag `v1.0.0`.

**Done when:** a user can `brew install --cask mfpete` (or download the DMG), launch without Gatekeeper warnings, and receive a Sparkle update.

---

## Open Notes and Risks

- **FSEvents + Swift concurrency:** keep the C callback as a thin bridge into an `AsyncStream`; all state lives in the engine actor (D13).
- **MainActor default isolation:** the app target defaults to MainActor. Engine code must stay in `MFPeteCore` (no default isolation) to avoid accidental main-thread file work.
- **SwiftData from an actor:** use `@ModelActor` for writes; avoid passing `@Model` objects across actors (pass IDs or value snapshots).
- **Template 1 ambiguity:** spec mixes "file added" with a daily schedule. Plan uses a daily schedule rule (Phase 5.7).
- **Homebrew notability:** official `homebrew/cask` may reject a brand-new app. Fallback: a personal tap until notability is met.
- **`fileIdentifierKey` availability:** listed as macOS 13.3+; deployment target 14 covers it.
- **`ActivityEntry.runTrigger` added after Phase 1:** new stored property with a default value, so SwiftData lightweight migration handles existing dev stores. No shipped users yet, so no migration plan needed.
