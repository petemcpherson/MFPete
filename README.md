# MFPete

A small, free, open-source macOS menu bar app that tidies your files with simple
**When / If / Then** rules. Think of it as a tiny, friendly take on Hazel.

> "When a file is added to Downloads, if its extension is dmg or zip, then move it to the Trash."

## What it does

- **Watches folders** and runs rules when files are added, changed, or removed, or on a
  schedule (every N minutes/hours, daily, or weekly).
- **Checks conditions** on name, extension, kind, size, dates, tags, and where a file was
  downloaded from. Combine them with All / Any, including one nested group.
- **Runs actions** in order: move, copy, rename with patterns like `{date-added} {name}`,
  change extension, sort into subfolders, add or remove tags, unzip, open, reveal in
  Finder, move to Trash, or show a notification.
- **Stays safe:** files go to the Trash, never straight to deletion. A preview shows what
  a rule will do before it runs. Loop and bulk guards stop runaway rules, and every
  action is written to an activity log.
- **Run Now** any rule from the dashboard or the menu bar.

## Starter templates

| Template | What it does |
| --- | --- |
| Clean up Downloads | Every day, moves disk images and archives older than 7 days to the Trash |
| Unzip downloads | Unzips new `.zip` files and moves the archive to the Trash |
| Archive old screenshots | Every evening, moves screenshots older than 3 days to an archive folder |
| Keep Desktop clean | Moves new Desktop items into a "Desktop Inbox" folder |
| Sort by type | Sorts files into subfolders named after their extension |
| Text to Markdown | Changes `.txt` files to `.md` and moves them to a folder you choose |

## Install

Requires macOS 14 (Sonoma) or later.

**Homebrew** (once the cask is published):

```sh
brew install --cask mfpete
```

**Direct download:** get the latest `MFPete-<version>.dmg` from
[GitHub Releases](https://github.com/petemcpherson/MFPete/releases/latest), open it, and
drag MFPete to Applications. Builds are signed with a Developer ID and notarized by Apple.

MFPete updates itself with [Sparkle](https://sparkle-project.org). You can turn off
automatic checks in Settings › About.

## Privacy

MFPete works only on your Mac. No accounts, no telemetry, no analytics, no crash
reporting service.

The **only** network traffic is the Sparkle update check, which downloads
`appcast.xml` from this repository's GitHub Releases. Turn it off in Settings › About.

MFPete is not sandboxed, so it can work in any folder you choose. macOS still asks your
permission the first time it touches Desktop, Documents, Downloads, iCloud Drive, or
external volumes. Full Disk Access is not needed.

## Build

Requires Xcode 26.

Open `MFPete.xcodeproj` in Xcode and run the `MFPete` scheme. Swift Package Manager
fetches Sparkle on first build.

The rule engine lives in a local Swift package and can be tested on its own:

```sh
cd Packages/MFPeteCore
swift test
```

App unit tests:

```sh
xcodebuild test -project MFPete.xcodeproj -scheme MFPete \
  -destination 'platform=macOS' -only-testing:MFPeteTests
```

Development builds have no Sparkle public key, so update checks are off. See
[docs/RELEASING.md](docs/RELEASING.md) for signing, notarization, and releases.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT. See [LICENSE](LICENSE). Sparkle is used under its MIT license.
