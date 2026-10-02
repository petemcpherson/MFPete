# MFPete

A small, free, open-source macOS menu bar app that tidies your files with simple
**When / If / Then** rules. Think of it as a tiny, friendly take on Hazel.

> Status: early development. Not ready for use yet.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 26 to build

## Build

Open `MFPete.xcodeproj` in Xcode and run the `MFPete` scheme.

The rule engine lives in a local Swift package and can be tested on its own:

```sh
cd Packages/MFPeteCore
swift test
```

## Privacy

MFPete works only on your Mac. No accounts, no telemetry, no analytics.

## License

MIT. See [LICENSE](LICENSE).
