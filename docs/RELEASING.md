# Releasing MFPete

Releases are signed with a Developer ID, notarized, and published on GitHub
Releases. Sparkle reads `appcast.xml` from the latest release
(`SUFeedURL` = `https://github.com/petemcpherson/MFPete/releases/latest/download/appcast.xml`).

## One-time setup

### 1. Sparkle EdDSA keys

Build the app once in Xcode so Swift Package Manager downloads Sparkle, then:

```sh
BIN=$(ls -d ~/Library/Developer/Xcode/DerivedData/MFPete-*/SourcePackages/artifacts/sparkle/Sparkle/bin | head -1)
"$BIN/generate_keys"            # stores the private key in your login keychain, prints the public key
"$BIN/generate_keys" -x sparkle_private_key.txt   # export for the GitHub secret
```

- Put the public key in `Config/Info.plist` under `SUPublicEDKey` and commit it.
  Until this key is set, the updater stays off and Settings › About says
  "Updates are turned off in this build."
- Add the contents of `sparkle_private_key.txt` as the `SPARKLE_PRIVATE_KEY`
  repository secret, then delete the file.
- Never lose the private key. Without it, existing users cannot get updates.

### 2. Signing certificate

Export the "Developer ID Application" certificate and its private key from
Keychain Access as a `.p12`, then add the secrets:

- `DEVELOPER_ID_P12`: `base64 -i cert.p12 | pbcopy`
- `DEVELOPER_ID_P12_PASSWORD`

### 3. Notarization

Create an App Store Connect API key (Users and Access › Integrations › Team Keys,
role "Developer") and add:

- `NOTARY_KEY_P8`: `base64 -i AuthKey_XXXX.p8 | pbcopy`
- `NOTARY_KEY_ID`
- `NOTARY_ISSUER`

For local releases, store the same credentials once:

```sh
xcrun notarytool store-credentials mfpete-notary \
  --key AuthKey_XXXX.p8 --key-id XXXX --issuer YYYY
```

## Cutting a release

1. Update `MARKETING_VERSION` in the project if needed (the release workflow
   also sets it from the tag).
2. Tag and push:

   ```sh
   git tag v1.0.0
   git push origin v1.0.0
   ```

3. The **Release** workflow archives, notarizes, staples, builds the `.dmg` and
   `.zip`, writes a signed `appcast.xml`, and creates the GitHub Release.

The build number (`CFBundleVersion`) is the git commit count, so it always goes up.
Sparkle uses it to decide whether an update is newer.

### Local release (without CI)

Until the CI secrets exist, the Release workflow skips and releases are cut
locally. Any notary profile for team `A2T9Q78M27` works (for example the
`petekm-notary` profile).

```sh
V=1.0.1
NOTARY_PROFILE=petekm-notary MARKETING_VERSION=$V scripts/release.sh
spctl -a -t open --context context:primary-signature -v build/release/MFPete-$V.dmg   # "accepted"
git tag v$V && git push origin v$V
gh release create v$V build/release/MFPete-$V.dmg build/release/MFPete-$V.zip \
  --title "MFPete $V" --notes "What changed."
```

Once Sparkle keys exist, also run `scripts/make-appcast.sh` (uses the private
key in your login keychain) and upload `build/release/appcast.xml` to the same
release.

Then update the Homebrew cask (below).

`SKIP_NOTARIZE=1 scripts/release.sh` makes a signed but not notarized build for
local testing.

## Homebrew

The cask lives in this repo at `Casks/mfpete.rb`, so no separate tap repo is
needed. Users install with:

```sh
brew tap petemcpherson/mfpete https://github.com/petemcpherson/MFPete
brew install --cask petemcpherson/mfpete/mfpete
```

The fully qualified name matters: Homebrew refuses casks from untrusted
third-party taps when installed by the bare token.

After every release:

1. `shasum -a 256 build/release/MFPete-<version>.dmg`
2. Set `version` and `sha256` in `Casks/mfpete.rb`. Commit and push to `main`.
   From then on, `brew upgrade` delivers the release.
3. Verify:

   ```sh
   brew update && brew upgrade --cask mfpete      # upgrade path
   brew audit --cask --strict petemcpherson/mfpete/mfpete
   ```

The tag must be `v<version>` and the asset must be `MFPete-<version>.dmg`, or the
cask URL 404s.

When Sparkle goes live (public key set), add `auto_updates true` to the cask so
Homebrew leaves updates to Sparkle.

Later, once the project meets Homebrew's notability bar, the cask can be
submitted to `homebrew/cask` and `Casks/` deleted from this repo.

## Release log

| Version | Build | Date | Notes |
| --- | --- | --- | --- |
| 1.0.0 | 12 | 2026-10-12 | First public release. Local build, Homebrew tap. Sparkle off. |

## Release checklist

- [ ] CI is green on `main`.
- [ ] `swift test` passes, including `PerformanceTests` (5,000-item scan under 2 s).
- [ ] Instruments: idle CPU about 0%, under 60 MB resident with 20 rules.
- [ ] Clean machine on macOS 14 and on the current macOS: install from DMG,
      Gatekeeper opens it without warnings, onboarding works, TCC prompts appear.
- [ ] Update from the previous version through Sparkle works.
