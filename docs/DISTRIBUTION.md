# ShotMark Distribution

## Current Trust State

Development DMGs are signed with `ShotMark Local Developer`. This keeps macOS
privacy permissions stable on the development Mac, but it is not an Apple
Developer ID identity and is not suitable for a paid public release.

The application can safely discover new versions from the official GitHub
Release feed. Automatic replacement installation is intentionally disabled
until Developer ID signing, notarization and a Sparkle EdDSA key are available.

## One-Time Apple Setup

1. Enroll the release owner in the Apple Developer Program.
2. Create and install a `Developer ID Application` certificate and private key.
3. Decide the permanent production bundle identifier before shipping paid
   builds. Changing it later resets macOS privacy permissions for users.
4. Store notarization credentials in the login Keychain. Do not put the Apple
   password or API private key in this repository:

```bash
xcrun notarytool store-credentials "shotmark-notary" \
  --apple-id "APPLE_ID" \
  --team-id "TEAM_ID" \
  --password "APP_SPECIFIC_PASSWORD"
```

API-key authentication may be used instead. The resulting keychain profile is
referenced by name only.

## Public Release

Commit the version change and release notes, push `main`, then run:

```bash
export DEVELOPER_ID_APPLICATION="Developer ID Application: Name (TEAM_ID)"
export NOTARY_PROFILE="shotmark-notary"

scripts/release_readiness.sh
scripts/publish_public_release.sh /absolute/path/to/release-notes.md
```

The process refuses to publish unless all of these are true:

- The version uses `x.y.z` and is newer than the current GitHub Release.
- The worktree is clean and local `main` equals `origin/main`.
- The Developer ID identity exists in the current Keychain.
- The notary profile authenticates successfully.
- The app uses Hardened Runtime and passes strict code-signature validation.
- The DMG is notarized, stapled and accepted by Gatekeeper.
- The uploaded DMG digest matches the local SHA-256 digest.

## Secure Automatic Installation

The next distribution milestone is Sparkle 2 integration. Before enabling it:

1. Generate the Sparkle EdDSA key once with `generate_keys`.
2. Store only the public `SUPublicEDKey` in the app. Keep the private key in the
   release Keychain and encrypted CI secrets.
3. Host the appcast over HTTPS and sign every update archive.
4. Verify updates with a production Developer ID build, including rollback,
   interrupted downloads and key-rotation recovery.
5. Keep `CFBundleVersion` monotonically increasing.

Official references:

- [Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Sparkle setup](https://sparkle-project.org/documentation/)
- [Sparkle publishing](https://sparkle-project.org/documentation/publishing/)
- [Sparkle sandboxing and signing](https://sparkle-project.org/documentation/sandboxing/)
