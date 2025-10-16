# Contributing to Nearby

Bug reports and focused pull requests are welcome. Check existing issues before
starting a larger change, and describe the user problem you want to solve.

## Development

Use a Mac running macOS 26 or later and an Xcode toolchain with the macOS 26 SDK
and Swift 6 support. CI currently uses the `macos-26` runner and Xcode 26.6. The
package has no external Swift package dependencies. Pinned Android runtime tools
and their complete notices are checked into `Sources/Nearby/Resources/Runtime/`.

```sh
./scripts/prepare-runtime.sh
swift test
./scripts/build-app.sh
./scripts/verify-app.sh
unzip -t dist/Nearby-macOS.zip
open dist/Nearby.app
```

Tests use local protocol peers, named pasteboards and owned temporary files. A
phone is needed for manual pairing, mirroring and sharing checks. Use a test phone
and harmless sample files; record what you actually exercised. See
[verification](docs/verification.md) for existing coverage and limits.

The default app build targets the current Mac architecture and uses ad-hoc
signing for local development. Public alpha packages are universal builds for
Apple silicon and Intel on macOS 26 or later, published as GitHub prereleases
with DMG, ZIP and SHA-256 assets. They are not Developer ID signed or notarized.
See [releases](docs/release.md) for the installation and release process. Keep
build output under `.build/` or `dist/`; both are ignored by Git.

## Changes and review

Keep changes scoped and explain their purpose. Follow existing Swift 6 concurrency
boundaries, resource ownership and cancellation behavior. Add or update meaningful
tests when changing protocol, recovery, clipboard or transfer behavior. Describe
manual UI checks for presentation changes. Review [architecture](docs/architecture.md)
and [design](docs/design.md) for the current structure and interaction rules.

Do not include pairing codes, ADB keys, device identifiers, clipboard contents,
personal file paths or unredacted screenshots in issues, commits or test fixtures.
Report suspected vulnerabilities using [SECURITY.md](SECURITY.md).

When changing bundled runtime components, preserve upstream license texts and
update the version, source URL and SHA-256 values together in the runtime manifest
and verification scripts. The Android helper source must match its pinned binary
hashes. Rebuilding it requires Android NDK `28.0.12674087`:

```sh
NEARBY_ANDROID_NDK=/path/to/android-ndk ./scripts/build-transfer-helper.sh
```

Review the printed hashes before updating pins. Never bypass a failed checksum.
The project's license covers original project contributions; third-party tools
retain their own licenses and notices.

## Landing page

The GitHub Pages site is plain static content under `site/`. Preview it locally
with `python3 -m http.server 8000 --directory site`, then open
`http://localhost:8000`. Use relative asset paths so the site works at the
repository's `/nearby/` Pages path. Changes to `site/` on `main` trigger deployment.
Run `python3 site/validate-site.py` to check markup and local references. The
`Landing page checks` workflow runs the same validation for site pull requests.
