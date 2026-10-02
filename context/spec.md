# MFPete: Product & Technical Spec

> Status: Final v1.1 (2026-10-01). v1.1 adds D14 (manual Run Now) and D15 (notifications and simple activity log).
> Source: `context/notes.md`
> Scope: what the app is and how it should behave. No implementation plan yet.

---

## 0. Key Decisions (final)

These decisions are settled. The rest of the spec reflects them.

| # | Topic | Decision | Why |
|---|---|---|---|
| D1 | App name | Ship as **MFPete**. Bundle ID `com.mftpete.MFPete`. Homebrew cask token `mfpete`. | Already the project name. No rename work. |
| D2 | App Sandbox | **Off.** Remove the App Sandbox capability (`ENABLE_APP_SANDBOX = NO`). Keep Hardened Runtime on (required for notarization). | Users can watch any folder by path, no per-folder grant dance, no security-scoped bookmarks. Leaves room for script/Shortcut actions later. Same model as Hazel. |
| D3 | Minimum macOS | **macOS 14 (Sonoma).** | All needed APIs exist there (SwiftData, `@Observable`, `MenuBarExtra`, `SMAppService`, `fileIdentifierKey`). Reaches far more users than 26.2. |
| D4 | Storage | **Rules:** one Codable JSON file, `~/Library/Application Support/MFPete/rules.json`. **Activity log and processed-file records:** SwiftData store in the same folder. | JSON makes export/import and backup trivial. SwiftData is already in the template and handles high-volume, queryable log data. |
| D5 | Several rules match one file | **All matching rules run, in dashboard order.** Once a rule moves or trashes the file, later rules for that folder skip it. Per-rule option "Stop processing other rules for matched files" (off by default). | Predictable, matches Hazel. Order = drag order in the list. |
| D6 | Repeat runs | **Each rule runs once per file until the file changes.** "Run Again on All Files" command per rule resets that rule's record. | Prevents loops and repeated work without user effort. |
| D7 | Undo | **No undo in v1.** Detailed activity log with Reveal in Finder. Log stores source and destination paths so undo can come in v1.x. | Trash is already recoverable. Undo is costly to do right. |
| D8 | Permanent delete | **Not offered.** Only Move to Trash. | Safety. Trash covers every use case in the notes. |
| D9 | Script / Shortcut actions | **Not in v1.** "Run Shortcut" first in v2, then "Run shell script". | Keeps v1 small. Sandbox off (D2) means both are possible later with no architecture change. |
| D10 | Distribution and updates | **Developer ID signed + notarized** builds on GitHub Releases (`.dmg` for manual download, `.zip` for Sparkle), cask in official `homebrew/cask`, **Sparkle 2** for in-app updates, cask marked `auto_updates true`. | Homebrew removed unsigned casks in September 2026, so notarization is required anyway. Sparkle serves users who did not install via Homebrew. Needs Apple Developer Program ($99/year). |
| D11 | Rule editor | **Form cards (When / If / Then)** with popup menus, plus a **live sentence summary** at the top of the editor and in each dashboard row. | Cards scale to many conditions and are standard SwiftUI controls. The sentence gives the IFTTT feel. |
| D12 | Condition nesting | **Top-level All/Any group plus one level of sub-groups** in the UI. Data model allows any depth. | Covers real use. Deeper nesting is rare and costly in UI. |
| D13 | Swift language mode | **Swift 5 language mode** (template default) with Swift 6 compiler. Engine isolated in an `actor`; UI on `@MainActor`. | FSEvents and other C callback APIs fight Swift 6 strict concurrency. The actor design still gives safe concurrency. Migrate to Swift 6 mode later. |
| D14 | Manual run | **Run Now button on every dashboard row**, plus the row menu, the menu bar "Run rule ▸" submenu, and "Save & Run" in the editor. Works for any trigger type, on disabled rules, and while all rules are paused. Same scan as a scheduled run (§3.3). | One-off runs at the click of a button. An explicit user action should always work. |
| D15 | Notifications and log | **One summary notification per run, never per file.** Default level "Errors only". Activity log stays a single simple table with fixed retention (30 days / 10,000 entries). | Gives feedback when a rule runs without notification spam or a log UI to maintain. |

---

## 1. Overview

MFPete is a small, free, open-source (MIT) macOS menu bar utility that automates file management on the local Mac. The user creates **rules**. Each rule has:

1. **Trigger:** what starts it (a file event in a folder, or a schedule).
2. **Conditions:** which files it applies to (if / and / or).
3. **Actions:** what happens to each matching file.

Inspiration: [Hazel](https://www.noodlesoft.com/). The difference: far smaller feature set, dead simple UI, IFTTT-style "When / If / Then" mental model, free and open source.

### 1.1 Goals
- Dead simple. A new user creates a working "clean my Downloads" rule in under 60 seconds.
- Trustworthy. The user always sees what a rule did and what it will do. Nothing is destroyed without a recoverable path.
- Light. Near-zero CPU at idle. No dock icon by default. Runs from the menu bar.
- Local only. No network calls, no accounts, no telemetry.

### 1.2 Non-goals (v1)
- Cloud APIs (Google Drive API, Dropbox API, S3, SFTP). See §12 for how cloud folders still work.
- Content-based conditions (OCR, text inside PDFs, Spotlight content search).
- Scripting, Shortcuts, AppleScript actions (D9).
- Photos import, DMG install, app "last opened" tracking (Hazel features from the notes; candidates for later).
- Sync of rules across Macs.
- Windows/Linux.

### 1.3 Target user
Mac users who want a tidy Downloads/Desktop/Screenshots folder without learning a power tool. Secondary: Hazel users who only use 1–3 rules and want a free alternative.

---

## 2. Core Concepts

| Term | Meaning |
|---|---|
| **Rule** | A named automation: trigger + scope + conditions + actions + options. Can be enabled or disabled. |
| **Scope** | The folder(s) a rule watches or scans. Each rule has one or more folders. |
| **Trigger** | The event that makes the engine evaluate the rule: a file event or a schedule. |
| **Condition** | A test against one file attribute (example: "Extension is `zip`"). |
| **Condition group** | A list of conditions combined with **All** (AND) or **Any** (OR). Groups can nest one level (D12). |
| **Action** | One operation on a matching file (move, rename, tag…). A rule runs its actions in order. |
| **Run** | One evaluation of a rule: list candidate files, test conditions, run actions on matches. |
| **Activity** | A logged record of one action on one file, or of a rule error. |

### 2.1 How a run works
1. Trigger fires.
2. Engine collects **candidate files**:
   - File-event trigger: the files from the event(s).
   - Schedule trigger: all items in scope folders (respecting subfolder option).
3. Engine filters out ignored items (§5.4).
4. Engine tests each candidate against the condition group.
5. For each match, engine runs actions in order. If an action fails, remaining actions for that file stop and the failure is logged.
6. Engine records results in the activity log and updates the rule's "last run" and counters.

---

## 3. Triggers

A rule has exactly one trigger.

### 3.1 File event triggers
| Trigger | Fires when | Notes |
|---|---|---|
| **File added** | A new item appears in a scope folder (created, moved in, downloaded). | Most common trigger. Waits for the file to finish writing (§5.3). |
| **File modified** | An existing item's contents or metadata change. | Debounced. Changes the app itself makes do not re-fire rules (§5.5). |
| **File removed** | An item is deleted or moved out of a scope folder. | The file no longer exists, so only name/extension/path conditions work, and only "Notify" / "Log" style actions are valid. The editor enforces this. |

"File added" is the v1 default. "File modified" and "File removed" ship in v1 but appear under an "More triggers" disclosure to keep the first view simple.

### 3.2 Schedule triggers
| Schedule | Example |
|---|---|
| **Every N minutes/hours** | Every 30 minutes. Minimum 5 minutes. |
| **Daily at time** | Every day at 9:00. |
| **Weekly on days at time** | Mon, Wed, Fri at 18:00. |

A scheduled run scans all items in the scope folders and applies conditions. Typical use: age-based cleanup ("Screenshots older than 3 days, move to Archive").

**Missed schedules:** If the Mac was asleep or the app was not running at the scheduled time, the engine runs the rule **once** on next wake/launch (no backlog of multiple runs). Logged as "Ran late (missed 09:00)".

### 3.3 Manual run (Run Now, D14)
Every rule has a **Run Now** command for one-off runs, whatever its trigger.

Where:
- A visible **Run Now button** (`play.fill` icon) on each dashboard row (§8.2). Always shown, not only on hover.
- Dashboard row `⋯` menu, and menu bar **Run rule ▸** submenu (§8.1).
- Editor footer: **Save & Run** (saves the rule, closes the editor, then runs it).

Behavior:
- Scans all items in the scope folders and tests conditions, same as a scheduled run.
- Respects the processed-file record (D6). Files this rule already processed and that have not changed are skipped. The result says so ("2 files skipped: already processed") and points to **Run Again on All Files** for a full rerun.
- Bulk guard (§5.6) applies.
- Works on disabled rules and while all rules are paused. A click is an explicit request.
- Does not change the rule's schedule. The next scheduled run still happens at its normal time.
- If the rule is already running, the button shows a spinner and is disabled. No queue.
- Not available for "File removed" rules (no files to scan). The button is disabled with a tooltip.

Feedback:
- The dashboard row shows a spinner during the run, then updates "Last run".
- A manual run always posts a summary notification, unless notifications are Off (§8.5). A run that matched no files says "No matching files".
- The activity log records the run with trigger "Manual" (§8.4).

### 3.4 Apply to existing files on enable
When the user creates or enables a file-event rule, the app asks once: "Apply this rule to the N files already in Downloads that match?" with **Preview**, **Apply**, **Only new files**. Default selection: **Only new files** (safe).

---

## 4. Conditions

### 4.1 Structure
- Top-level group: **All** / **Any** of the following.
- Rows: a condition or a nested group (one nested level in v1 UI).
- An empty condition list means "every file" (the editor shows "Matches all files in this folder" as a warning-styled hint).

### 4.2 Attributes and operators (v1)

| Attribute | Type | Operators | Source |
|---|---|---|---|
| Name | text | is, is not, contains, does not contain, starts with, ends with, matches pattern (wildcard `*`, `?`) | file name without extension |
| Full name | text | same as Name | name with extension |
| Extension | text | is, is not, is any of (comma list) | case-insensitive, no dot |
| Kind | enum | is, is not | UTType conformance: Folder, Image, Movie, Audio, PDF, Text, Document, Archive, Disk Image, Application, Alias/Symlink, Other |
| Size | number + unit (KB/MB/GB) | is greater than, is less than | `fileSizeKey` / `totalFileAllocatedSizeKey` for folders/packages (folders: v2) |
| Date added | date | is in the last N (min/hours/days/weeks/months), is not in the last N, is before date, is after date | `addedToDirectoryDateKey` |
| Date created | date | same as Date added | `creationDateKey` |
| Date modified | date | same as Date added | `contentModificationDateKey` |
| Tags | tag list | contains tag, does not contain tag, has no tags | `tagNamesKey` |
| Downloaded from | text | contains, does not contain, is | `com.apple.metadata:kMDItemWhereFroms` xattr (URL / domain) |
| Any file | — | (always true) | for "match everything" explicitly |

Notes:
- "Is in the last N days" uses the current time at evaluation. File-event rules evaluate at event time. Age conditions ("older than 3 days") only make sense with schedule triggers; the editor shows a hint when an age condition sits on a file-event rule.
- Text comparisons are case-insensitive by default, with a per-condition "Match case" option (v1.x).
- Regex: v2. Wildcards cover the v1 need.

### 4.3 Later attributes (not v1)
Date last opened (`kMDItemLastUsedDate`, via Spotlight), contents contain text, image dimensions, Spotlight metadata, label color (legacy, prefer tags), source app.

---

## 5. File Watching & Engine Behavior

### 5.1 Watching
- Use **FSEvents** (`FSEventStreamCreate` with `kFSEventStreamCreateFlagFileEvents` and `kFSEventStreamCreateFlagUseCFTypes`) on the union of enabled rules' scope folders.
- One stream for all paths, rebuilt when the set of watched folders changes.
- Persist the last FSEvents event ID. On launch, start the stream from that ID so events that happened while the app was closed replay ("File added" rules catch up on files downloaded while the app was off). If the ID is too old or history was purged (`kFSEventStreamEventFlagHistoryDone` / `MustScanSubDirs`), fall back to a full scan compared against the processed-files record.

### 5.2 Subfolders
Per-rule option: **Include subfolders** (off by default). When off, only direct children of the scope folder are candidates. Packages (`.app`, `.bundle`, `.photoslibrary`) are always treated as single items, never descended into.

### 5.3 Settling (wait for files to finish writing)
A file is ready only when:
- Its size and modification date are unchanged for **2 seconds** (configurable 1–30s in Advanced settings), and
- Its name is not a known in-progress pattern: `*.crdownload`, `*.download` (Safari bundle), `*.part`, `*.partial`, `*.tmp`, `*.opdownload`, `.com.google.Chrome.*`, and
- It is not a dataless cloud placeholder that the action would need to read (§12).

The rule evaluates once the file settles. If the file disappears before settling, nothing happens.

### 5.4 Ignored by default
- Hidden files (name starts with `.`) and `.DS_Store`, `Icon\r`, `.localized`.
- Items inside a scope folder's own subfolders when "Include subfolders" is off.
- Items the engine itself just created/moved into a watched folder, for the rule that produced them (prevents loops). Other rules watching that destination still see the item as "added". This is how chaining works ("Downloads → Images folder → tag").
- Per-rule option "Include hidden files" (off).

### 5.5 Processed-file record (D6)
- Key: rule ID + file identity (`fileResourceIdentifierKey` is not stable across launches, so use volume UUID + inode (`fileIdentifierKey` on macOS 13.3+) + path as fallback).
- Value: content modification date at time of processing.
- A file is eligible for a rule if no record exists, or its modification date is newer than the record.
- Records for files that no longer exist are pruned on scan.

### 5.6 Loop and runaway protection
- Max chain depth: a single file passes through at most **10** rule runs within 60 seconds; beyond that the engine stops and logs "Possible rule loop between Rule A and Rule B" and shows a notification.
- **Bulk guard:** if one run would act on more than **50** files (configurable), the engine pauses that run and asks: "Rule 'Clean Downloads' wants to act on 312 files. Preview / Run / Cancel." Not applied to the first-run prompt in §3.4, which already asks.
- **Global pause:** menu bar toggle stops all rule evaluation. Events received while paused are discarded; on resume, the app offers "Scan now" for file-event rules.

### 5.7 Concurrency
- Rule runs execute off the main thread in a dedicated actor.
- Actions on a single file run serially. Different files can process in parallel with a small limit (4).
- File operations use `FileManager` and `NSFileCoordinator` where other apps might be writing.

### 5.8 Performance targets
- Idle CPU: ~0% (FSEvents is push based; no polling).
- Memory: under 60 MB resident with 20 rules.
- Scheduled scan of a 5,000-item folder: under 2 seconds.

---

## 6. Actions

A rule has one or more actions, run in order on each matching file. If an action moves/renames the file, later actions use the new location.

### 6.1 v1 actions

| Action | Parameters | Notes |
|---|---|---|
| **Move to folder** | destination folder; conflict policy | |
| **Copy to folder** | destination folder; conflict policy | Later actions keep working on the original. |
| **Rename** | name pattern (§6.2); conflict policy | Can change extension. |
| **Change extension** | new extension | Shortcut for the common "txt → md" case from the notes. |
| **Move to Trash** | — | `FileManager.trashItem`, recoverable via Finder "Put Back". |
| **Sort into subfolder** | base folder, subfolder pattern (§6.2) | Example: `Documents/{extension}` or `Archive/{year}/{month}`. Creates missing subfolders. Covers "sort Documents by extension". |
| **Add tags** / **Remove tags** | tag names | Finder tags via `URLResourceValues.tagNames`. |
| **Unarchive** | delete archive after: none / trash; destination: same folder / chosen folder | v1 formats: `.zip`. Later: `.tar`, `.tar.gz`, `.7z`, `.rar`. Extract with `/usr/bin/ditto -x -k` (preserves macOS metadata and handles Finder-made zips). Extracted items are "added" files for other rules. |
| **Open** | with: default app / chosen app | `NSWorkspace.open`. |
| **Reveal in Finder** | — | |
| **Show notification** | message template (§6.2) | Local `UNUserNotificationCenter` notification. |

### 6.2 Name patterns / tokens
Used in Rename, Sort into subfolder, and notification text. Shown as insertable chips in the editor with a live preview against a sample file.

| Token | Value |
|---|---|
| `{name}` | name without extension |
| `{extension}` | extension without dot |
| `{fullname}` | name with extension |
| `{date-added}` / `{date-created}` / `{date-modified}` | `yyyy-MM-dd` |
| `{year}` `{month}` `{day}` | of date added |
| `{today}` | current date `yyyy-MM-dd` |
| `{time}` | current time `HHmmss` |
| `{counter}` | incrementing number when needed to avoid conflicts |
| `{folder}` | parent folder name |
| `{kind}` | Kind attribute value (Image, PDF…) |

Invalid filename characters (`:` and `/`) are replaced with `-`.

### 6.3 Conflict policy (when destination name exists)
- **Keep both** (default): append ` 2`, ` 3`, … before the extension (Finder style).
- **Replace:** move existing file to Trash, then place the new one. Never permanently overwrite.
- **Skip:** leave the file, log "Skipped: name exists".

### 6.4 Later actions (not v1)
Run Shortcut and Run shell script (v2, D9), Import to Photos (PhotoKit), Mount DMG and install app, Compress (zip), Convert image format/resize, Set color label, Make alias, Upload via cloud API.

---

## 7. Rule Options

| Option | Default | Notes |
|---|---|---|
| Enabled | on | Toggle in dashboard. |
| Name | auto-generated from trigger + first action ("Downloads: Move to Trash") | User-editable. |
| Scope folders | required, ≥1 | Picked through Open panel or dragged in from Finder. Stored as absolute paths. |
| Include subfolders | off | §5.2 |
| Include hidden files | off | §5.4 |
| Stop processing other rules for matched files | off | See D5. |
| Notify on each run | off | Summary notification after every run of this rule, even when the global level is "Errors only" (§8.5, §8.8). |
| Notes | empty | Free text, for the user. |

---

## 8. User Interface

Design principle: **fewer choices on screen**. Advanced settings hide behind disclosures. Native SwiftUI controls, system fonts, SF Symbols, standard macOS look. Supports light/dark mode, Dynamic Type where macOS allows, full keyboard navigation, VoiceOver labels.

### 8.1 Menu bar extra (always present)
`MenuBarExtra` with `.menu` style (plain native menu) for speed:

```
● MFPete — 4 rules active
──────────────
Recent activity
  Moved invoice.pdf → Documents/pdf      2m ago
  Trashed Setup.dmg                        1h ago
  Unarchived assets.zip                    1h ago
──────────────
Pause all rules            ⌘P
Run rule ▸                 (submenu of rules, D14)
──────────────
Open Rules…                ⌘R
Settings…                  ⌘,
──────────────
Quit MFPete                ⌘Q
```

- Icon: monochrome template SF Symbol (`tray.and.arrow.down`; custom glyph can replace it later). Shows a "paused" variant when paused and a badge dot when a rule has an unresolved error.
- Clicking a recent activity item reveals the file in Finder.

### 8.2 Dashboard (Rules window)
Single window, opened from the menu bar. `LSUIElement`-style accessory app: no dock icon by default (Settings toggle, §8.5). When the window is open and "show dock icon" is off, the app still activates so the window comes to front.

Layout: a single list, not a split view.

```
┌───────────────────────────────────────────────────────────────┐
│  Rules                           [Search……]  [Filter ▾]  [ + ] │
├───────────────────────────────────────────────────────────────┤
│ [●] Clean Downloads                                [▶]  [ ⋯ ] │
│     When file added to Downloads · if extension is dmg, zip   │
│     → Move to Trash            Last run 2m ago · 128 files    │
├───────────────────────────────────────────────────────────────┤
│ [●] Archive old screenshots                        [▶]  [ ⋯ ] │
│     Daily at 09:00 in Screenshots · if date added > 3 days    │
│     → Move to Archive          Last run today 09:00 · 12 files│
├───────────────────────────────────────────────────────────────┤
│ [○] Sort Documents (disabled)                      [▶]  [ ⋯ ] │
│     ...                                                        │
└───────────────────────────────────────────────────────────────┘
```

Row contents:
- Enable/disable toggle (switch).
- **Run Now button** (`play.fill`, D14). Spinner while the rule runs.
- Rule name.
- One-line sentence summary generated from the rule (D11).
- Last run time, files processed count (lifetime), error badge if last run failed.
- `⋯` menu: Edit, Run Now, Preview Matches, Duplicate, Export…, Show Activity, Delete.

Behavior:
- Double-click or Return opens the editor.
- Drag to reorder (order sets run order, D5).
- **Search:** filters by rule name and folder name.
- **Filter menu:** Enabled / Disabled / Has errors; Trigger: File event / Schedule; Folder: (list of scope folders).
- **Sort menu:** Manual (default, drag order), Name, Last run, Date created. Non-manual sort disables drag reorder and shows a hint.
- Empty state: friendly illustration-free message + 3 template buttons (§8.6) + "Create blank rule".
- Toolbar also has an **Activity** button (§8.4).

### 8.3 Rule editor
Opens as a sheet over the dashboard. Three stacked cards plus a summary header.

```
┌───────────────────────────────────────────────────────────┐
│ Name: [Clean Downloads                          ]          │
│ "When a file is added to Downloads, if its extension is   │
│  dmg or zip, then move it to the Trash."                  │
├─ WHEN ────────────────────────────────────────────────────┤
│ [A file is added ▾] to [Downloads ▾] [+ folder]           │
│ ▸ Options (subfolders, hidden files)                      │
├─ IF ──────────────────────────────────────────────────────┤
│ [All ▾] of the following are true:                        │
│ [Extension ▾] [is any of ▾] [dmg, zip        ]   [–][+]   │
│ [+ Add condition] [+ Add group]                           │
│ Matches 4 files right now  [Preview]                      │
├─ THEN ────────────────────────────────────────────────────┤
│ 1. [Move to Trash ▾]                              [–] [≡] │
│ [+ Add action]                                             │
├───────────────────────────────────────────────────────────┤
│ ▸ More options          [Cancel] [Save & Run] [Save Rule] │
└───────────────────────────────────────────────────────────┘
```

- Popups change their trailing controls by type (date attribute shows number + unit popup; Kind shows enum popup; folder fields show a folder picker button with path control).
- Live summary sentence updates as the user edits.
- **Live match count** for the current scope ("Matches 4 files right now"), computed debounced in the background. **Preview** opens a list of matching files with what each action would do ("invoice.pdf → Documents/pdf/invoice.pdf"). No changes are made.
- Validation before save: at least one folder, at least one action, all required parameters set, trigger/action compatibility (§3.1 removed-file limits), destination not equal to source for Move (warning, not error, if a Rename comes first).
- Destructive action hint: if actions include Move to Trash or Replace conflict policy and conditions are empty, show a warning banner: "This rule will trash every file added to Downloads."
- Cmd-S saves, Esc cancels (confirm if dirty).
- **Save & Run** validates, saves, closes the editor, then starts a manual run (§3.3). Disabled for "File removed" rules.

### 8.4 Activity log (D15)
Kept deliberately simple: one window, one table, newest first.

- Opened from the dashboard toolbar, the menu bar, a rule's "Show Activity", or by clicking a notification.
- Table columns: Time, Rule, Trigger (File event / Scheduled / Ran late / Manual), Action, File, Result (✓ / ⚠︎ / ✕). Failure or skip reason shows as a second line under the file name.
- Filters: a Rule popup (All rules or one rule) and an "Errors only" toggle. Nothing else.
- Row actions (context menu): Reveal in Finder (if the file still exists), Copy path.
- Entries: one per action per file, plus rule-level errors. A manual run that matched no files writes one "No matching files" entry so the user sees it ran. Other runs with no matches write nothing.
- Retention: fixed at last 30 days or 10,000 entries, whichever is smaller. Not configurable in v1.
- "Clear log" button (confirm).

### 8.5 Settings
Standard `Settings` scene, tabs:

- **General**
  - Launch at login (`SMAppService.mainApp`), default on after onboarding asks.
  - Show icon in Dock (off default; switches `NSApp.setActivationPolicy(.regular/.accessory)`).
  - Notifications: Off / Errors only (default) / Every run (§8.8).
- **Folders:** read-only list of all folders used by rules, which rules use each, and status (OK / missing / no permission). "Reveal in Finder" per folder. "Open Privacy & Security" button if any folder shows "no permission".
- **Advanced**
  - File settle delay (2s).
  - Bulk guard threshold (50).
  - Export all rules / Import rules (JSON).
  - Reset processed-file history (makes all rules re-evaluate existing files on next run; confirm).
- **About**: version, MIT license, GitHub link, "Check for Updates…" (Sparkle) and "Automatically check for updates" toggle (on by default).

### 8.6 Templates (starter rules)
Shown in empty state and in the `+` menu ("New from template ▸"). Each creates a pre-filled rule in the editor; user picks folders and saves.

1. **Clean up Downloads:** When file added to Downloads, if Kind is Disk Image or Archive and date added older than 7 days (schedule daily) → Move to Trash.
2. **Unzip downloads:** When file added to Downloads, if extension is `zip` → Unarchive, trash archive.
3. **Archive old screenshots:** Daily, in Screenshots folder, if name starts with "Screenshot" and date added not in last 3 days → Move to `Screenshots/Archive`.
4. **Keep Desktop clean:** When file added to Desktop, if Kind is not Alias → Move to `~/Desktop Inbox`.
5. **Sort by type:** When file added to a folder → Sort into subfolder `{extension}`.
6. **Text to Markdown:** When file added to folder, if extension is `txt` → Change extension to `md` → Move to folder (e.g. Obsidian vault).

### 8.7 Onboarding (first launch only)
Three short steps in one window:
1. What MFPete does (one sentence + the When/If/Then picture).
2. Launch at login toggle + notifications permission request.
3. "Create your first rule" with template buttons, or "Skip".

After onboarding the window closes and the app lives in the menu bar. A one-time popover points at the menu bar icon.

### 8.8 Notifications (D15)
Local notifications through `UNUserNotificationCenter`. No sounds by default.

**One summary per run, never one per file.** Examples:
- "Clean Downloads: 3 files moved to Trash"
- "Sort by type: 5 files processed, 1 failed"
- "Archive old screenshots: No matching files" (manual runs only)

When a summary is posted:

| Level (Settings › General) | Automatic runs | Manual runs (D14) | Errors | "Show notification" action |
|---|---|---|---|---|
| Off | never | never | never | yes |
| Errors only (default) | only if the rule has "Notify on each run" | yes | yes | yes |
| Every run | yes, if the run acted on at least 1 file | yes | yes | yes |

Rules:
- Automatic runs that act on 0 files never notify.
- **Coalescing:** file-event runs of the same rule within 5 seconds merge into one summary. Dropping 20 files into Downloads gives one notification, not 20.
- Errors (failed actions, loop guard, missing folder, disk full) post one notification per rule per run, merged the same way.
- The "Show notification" action (§6.1) is an explicit user choice, so it fires at every level, including Off.
- Clicking a notification opens the Activity log filtered to that rule.
- If the user denied notification permission, everything still works. The activity log is the record.

---

## 9. Data Model (conceptual)

Swift-shaped sketch. `Rule` and nested types are Codable and live in `rules.json`. `ActivityEntry` and `ProcessedRecord` are SwiftData `@Model` types (D4).

```swift
struct Rule: Identifiable, Codable {
    var id: UUID
    var name: String
    var isEnabled: Bool
    var order: Int
    var scope: [FolderRef]           // ≥1
    var trigger: Trigger
    var conditions: ConditionGroup
    var actions: [Action]            // ≥1, ordered
    var options: RuleOptions
    var notes: String
    var createdAt: Date
    var modifiedAt: Date
    // run stats (last run, file count, last error) are derived from the activity log, not stored in rules.json
}

struct FolderRef: Codable {
    var path: String                 // absolute, tilde-abbreviated in UI ("~/Downloads")
}

enum Trigger: Codable {
    case fileAdded, fileModified, fileRemoved
    case interval(minutes: Int)
    case daily(hour: Int, minute: Int)
    case weekly(weekdays: Set<Int>, hour: Int, minute: Int)
}

struct ConditionGroup: Codable {
    var match: Match                 // .all | .any
    var items: [ConditionItem]       // empty = matches all
}
enum ConditionItem: Codable {
    case condition(Condition)
    case group(ConditionGroup)
}
struct Condition: Codable {
    var attribute: Attribute         // name, fullName, extension, kind, size, dateAdded, ...
    var op: Operator
    var value: ConditionValue        // text, number+unit, relative duration, date, enum, tag list
    var caseSensitive: Bool
}

enum Action: Codable {
    case move(to: FolderRef, onConflict: ConflictPolicy)
    case copy(to: FolderRef, onConflict: ConflictPolicy)
    case rename(pattern: String, onConflict: ConflictPolicy)
    case changeExtension(String)
    case trash
    case sortIntoSubfolder(base: FolderRef, pattern: String)
    case addTags([String]), removeTags([String])
    case unarchive(destination: FolderRef?, trashArchive: Bool)
    case open(withApp: URL?)
    case revealInFinder
    case notify(message: String)
}

struct RuleOptions: Codable {
    var includeSubfolders = false
    var includeHidden = false
    var stopOtherRules = false
    var notifyEachRun = false
}

struct ActivityEntry {
    var id: UUID
    var timestamp: Date
    var ruleID: UUID
    var ruleName: String             // snapshot, survives rule rename/delete
    var action: String
    var sourcePath: String
    var destinationPath: String?     // enables future undo (D7)
    var result: Result               // success | skipped | failed(message)
    var runTrigger: RunTrigger       // fileEvent | scheduled | scheduledLate | manual | applyExisting (D14, D15)
}

struct ProcessedRecord {
    var ruleID: UUID
    var fileKey: String              // volume + file identifier, path fallback
    var modifiedAt: Date
}
```

**Schema versioning:** rules file has a top-level `"version": 1`. Import accepts older versions and migrates. Unknown action/attribute types on import: rule imports as disabled with a warning.

**Export format:** `.json` file containing one or more rules, same schema as `rules.json`. Paths export with `~` for the home folder so rules move between Macs. Imported rules arrive **disabled**; any rule whose folders do not exist shows "Folder missing" until the user edits it.

---

## 10. Permissions & Security

- **No App Sandbox (D2).** The app reads and writes any path the user's account and macOS privacy (TCC) rules allow. Hardened Runtime stays on.
- **Folder access:** folders are stored as plain paths. On launch and on each run, the engine checks each scope folder exists and is readable. Failures mark affected rules "Folder missing" or "No permission" (error badge, menu bar dot, Settings › Folders).
- **TCC:** macOS asks once per protected location (Desktop, Documents, Downloads, iCloud Drive, removable volumes, network volumes) the first time the app touches it. The rule editor shows a short explainer the first time the user picks one of these folders, before the system prompt appears. If the user denies, the rule shows "No permission" with a button that opens System Settings › Privacy & Security › Files and Folders. Full Disk Access is not required and not requested.
- **Notifications:** request authorization during onboarding; app works fully without it.
- **Network:** the only network traffic is Sparkle's update check against the GitHub-hosted appcast (signed with an EdDSA key). Users can turn automatic checks off. README states this.
- **Safety defaults:** Trash only, no permanent delete (D8); Replace conflict policy trashes rather than overwrites; bulk guard (§5.6); first-run "only new files" default (§3.4).
- **No telemetry, no analytics, no crash reporting service.** Crash logs stay in macOS's own diagnostics.

---

## 11. App Lifecycle

- **Activation policy:** accessory (no dock icon, no app menu) unless "Show icon in Dock" is on. Set `LSUIElement = YES` in Info.plist to avoid dock flash at launch; switch to `.regular` at runtime only when the setting is on.
- **Closing the last window does not quit.** Only "Quit" in the menu bar menu quits.
- **Launch at login** via `SMAppService.mainApp.register()`. Settings reflects real status (user may disable in System Settings › Login Items; show "Requires approval" state).
- **Sleep/wake:** listen for `NSWorkspace.didWakeNotification` to run missed schedules (§3.2) and restart FSEvents stream if needed.
- **Volume mount/unmount:** rules with scope on an external volume go "Folder unavailable" (no error spam) while unmounted and resume on mount (`NSWorkspace.didMountNotification`).
- **Single instance:** second launch activates the existing instance and opens the Rules window.

---

## 12. Cloud Storage (scope clarification)

The notes ask whether iCloud counts as local. Answer: on macOS, these all appear as **local folders**, so v1 rules can watch them and use them as destinations with no API work:

- iCloud Drive: `~/Library/Mobile Documents/com~apple~CloudDocs` (Finder "iCloud Drive").
- Dropbox, Google Drive, OneDrive, Box (modern clients): File Provider folders under `~/Library/CloudStorage/`.

Caveats to handle:
- **Dataless (online-only) files:** the file exists as a placeholder. Reading attributes is fine; reading contents (Unarchive, Copy) triggers a download. Engine should treat download-in-progress as "not settled" and should not trigger downloads during scheduled scans unless an action needs contents.
- **Sync conflicts / temp files:** sync clients create temporary names; settling (§5.3) and ignore patterns cover the common ones.
- FSEvents works on these folders; remote changes synced down appear as normal file events.

Direct cloud API uploads (Drive API, Dropbox API, S3) stay a non-goal (§1.2).

---

## 13. Error Handling

| Situation | Behavior |
|---|---|
| Destination folder missing | Action fails, logged. Rule shows error badge. Notification if "Errors only" enabled. Auto-create of missing folders comes in v1.x. |
| Permission denied (TCC or POSIX) | Rule marked "No permission". Engine skips rule until a later check succeeds. |
| File vanished mid-run | Logged as skipped, not error. |
| Disk full | Action fails, logged, notification. |
| Unarchive fails (corrupt/encrypted zip) | Logged as failed; archive left in place; later actions for that file do not run. |
| Rule loop detected | Engine stops chain, disables nothing automatically, notifies (§5.6). |
| Corrupt rules file | Load backup (`rules.json.bak`, written before each save); if both fail, start empty and keep the corrupt file renamed for recovery; alert user. |

Error badge clears on the next successful run or when the user opens the rule.

---

## 14. Distribution, Licensing, Project

- **License:** MIT. `LICENSE` file at repo root. All dependencies must be MIT/BSD/Apache-compatible.
- **Dependencies:** Sparkle 2 only, via Swift Package Manager (MIT). Prefer Apple frameworks for everything else (FSEvents/CoreServices, UniformTypeIdentifiers, AppleArchive, UserNotifications, ServiceManagement).
- **Distribution:** signed + notarized build on GitHub Releases; Homebrew cask in `homebrew/cask` with `auto_updates true` (D10). Notarization runs in GitHub Actions on tag push.
- **Repo:** README with screenshots, template rules, privacy statement ("no network"), build instructions; CONTRIBUTING; issue templates.
- **Localization:** English only in v1; use `String(localized:)` / String Catalogs from the start so translations can come later.

---

## 15. Testing Strategy (requirements, not plan)

- **Unit tests:** condition evaluation (every attribute/operator), name pattern rendering, conflict naming, schedule next-fire calculation (DST changes, missed schedules), rules JSON encode/decode + migration.
- **Engine integration tests:** run against temp directories: add/modify/remove files, verify settling, chaining, loop guard, once-per-file record, bulk guard.
- **UI tests:** create rule from template, toggle enable, edit/save, preview shows expected files, Run Now button runs a rule.
- **Notification policy tests:** level × trigger × result table (§8.8) as a pure function, plus coalescing window.
- Engine logic lives in a module with no SwiftUI/AppKit dependency so it is testable headless.

---

## 16. Release Scope Summary

### v1 (MVP)
- Menu bar app, no dock icon, launch at login, onboarding.
- Dashboard: list, toggle, Run Now button, search, filter, sort, reorder, duplicate, delete.
- Editor: When / If / Then cards, sentence summary, live match count, preview.
- Triggers: file added, file modified, file removed, interval, daily, weekly, manual.
- Conditions: §4.2 set, All/Any + one nesting level.
- Actions: §6.1 set.
- Run Now button for one-off manual runs (D14).
- Simple activity log and per-run summary notifications (D15), global pause, bulk guard, loop guard.
- Templates (§8.6), rule export/import.
- Signed, notarized, Homebrew cask, Sparkle updates.

### v1.x
- Undo from activity log.
- More archive formats.
- Case-sensitive text matching, regex.
- Auto-create missing destination folders.

### v2+
- Run Shortcut, then Run shell script.
- Import to Photos, DMG install, compress, image convert.
- Date last opened, contents conditions.
- Cloud API destinations.
