# Releases

Nearby offers an **unsigned alpha** download for macOS 26 or later on Apple
silicon and Intel Macs. The universal app bundles its Android tools; users do not
need Xcode, Homebrew, ADB or a source checkout. The alpha uses ad-hoc code
signatures for bundle integrity. It has **no Developer ID signature and is not
notarized by Apple**, so macOS may block the first launch.

## Install the alpha

Download from the [official v0.3.3 release](https://github.com/abhinit21/nearby/releases/tag/v0.3.3):

| Asset | Purpose |
| --- | --- |
| `Nearby-0.3.3-macOS-universal.dmg` | Recommended: open the disk image and drag `Nearby.app` into Applications |
| `Nearby-0.3.3-macOS-universal.zip` | Alternative: expand the archive and move `Nearby.app` into Applications |
| `SHA256SUMS.txt` | SHA-256 hashes of both downloads |
| `BUILD-INFO.txt` | Source commit, architecture, toolchain and signing status |

Quit any running copy of Nearby before replacing it. Eject the disk image after
copying the app, then open **Applications → Nearby**. If macOS blocks it because
the developer cannot be verified or Apple cannot check it, proceed only if you
trust this release: open **System Settings → Privacy & Security**, find the
Nearby notice, choose **Open Anyway**, and confirm **Open**. This is Apple's
[documented per-app exception](https://support.apple.com/en-us/102445).

If macOS reports malware, a damaged app or revoked authorization, stop and report
the message; do not disable Gatekeeper. Managed Macs may prevent exceptions.
Allow Local Network access when requested so Nearby can discover your phone.
Enable Wireless debugging on an Android 11 or later phone, connect it to the same
trusted network, and follow Nearby's pairing flow. Alpha limitations and known
issues are listed with the release.

For an optional integrity check, download `SHA256SUMS.txt` alongside the DMG or ZIP
and run the matching command in that download directory:

```sh
shasum -a 256 Nearby-0.3.3-macOS-universal.dmg
# Or, for the ZIP:
shasum -a 256 Nearby-0.3.3-macOS-universal.zip
```

Compare the full hash with the matching filename in `SHA256SUMS.txt`. A checksum
detects changed download bytes; it does not identify an Apple-verified developer
or replace notarization. The source archives GitHub generates are for developers
and are not installable Mac apps.

## Validate a source release

On macOS 26 or later, use an Xcode toolchain with Swift 6 and the macOS 26 SDK:

```sh
./scripts/prepare-runtime.sh
swift test
./scripts/build-app.sh
./scripts/verify-app.sh
unzip -t dist/Nearby-macOS.zip
shasum -a 256 dist/Nearby-macOS.zip
```

The last command records the exact generated archive. Ad-hoc signing, timestamps
and toolchain differences mean identical source is not a promise of bit-identical
ZIP output. Runtime checksums in the dependency manifest identify the original
files before macOS code signing changes their signature metadata.

To inspect a new package without replacing an existing `dist/Nearby.app`, select
a separate output directory. Relative output paths resolve from the project root:

```sh
NEARBY_DIST_DIR=.build/nearby/release-check ./scripts/build-app.sh
./scripts/verify-app.sh .build/nearby/release-check/Nearby.app
unzip -t .build/nearby/release-check/Nearby-macOS.zip
```

Before tagging, check the app version in `Info.plist`, update user-facing docs,
review the staged diff for private data, and run relevant real-device checks.
Record the source commit, Xcode/macOS versions, test results and manual limits in
release notes. [verification.md](verification.md) contains historical baseline
results; local QA logs referenced there are not included in the repository.

Keep `.build/`, `dist/`, signing credentials, ADB authorization keys, pairing
records, user preferences and diagnostic logs out of Git. Review screenshots and
media for private phone content and confirm asset licenses before publishing.

## Runtime updates

`scripts/prepare-runtime.sh` verifies the checked-in runtime. It can re-fetch pinned
upstream ADB and scrcpy files if needed, and rejects downloads with mismatched
SHA-256 values. It does not silently rebuild or accept changed transfer helpers.

Update source URLs, version numbers, hashes, licenses and checks in
`Sources/Nearby/Resources/Runtime/dependency-manifest.json`,
`scripts/prepare-runtime.sh`, `scripts/verify-app.sh` and
`THIRD-PARTY-NOTICES.txt` together. Rebuild Android helpers from
`scripts/nearby-transfer.c` using the documented NDK version and check the source
and both output hashes. Preserve the complete upstream notice files.

## Publish an unsigned alpha

The public alpha is a GitHub **prerelease**, built from its version tag using the
release workflow on `macos-26` with Xcode 26.6. Use this toolchain to validate the
declared macOS 26 minimum rather than distributing a local build that depends on
a newer SDK. The app version is `0.3.3`, build `12`, for tag `v0.3.3`.

The release package must contain both `arm64` and `x86_64` slices in the Nearby
executable and every bundled macOS ADB copy. Inspect the Mach-O deployment targets
and linked libraries, verify nested signatures and pinned Android payloads, and
preserve the original license texts. Check the DMG and ZIP after packaging and
generate `SHA256SUMS.txt` from those final files. Do not mutate assets after
generating their hashes.

Publish only the versioned DMG, ZIP, checksum and build-information files listed above. The app
contains the project MIT license and third-party notices. Build directories,
pairing records, personal diagnostics and credentials do not belong in release
assets. Verify published hashes and URLs before enabling website download links.
Record automated test results honestly; a universal build alone does not establish
that Intel hardware, clean-Mac first launch or physical phone flows were tested.

Keep the prerelease and its installation instructions visibly labeled unsigned
alpha. Upgrades are manual: download a newer release, quit Nearby and replace the
app in Applications. The alpha does not include an automatic updater.

## Future Developer ID distribution

A release intended to open without this alpha's per-app exception needs a
Developer ID process: sign the app and all nested macOS executables with the
intended hardened-runtime settings, submit to Apple's notary service, and staple
the accepted ticket to the app and distributable disk image as appropriate.
Verify Gatekeeper assessment and installation of the downloaded package on a
clean Mac. Keep signing certificates and notarization credentials in a private
secret store. An Apple Development certificate or an ad-hoc signature does not
provide Developer ID distribution or notarization.

## GitHub Pages

The `Deploy landing page` workflow uploads only `site/` and deploys through the
`github-pages` environment. Enable **Settings → Pages → Build and deployment →
GitHub Actions**. A push to `main` that changes `site/` or the Pages workflow, or a
manual workflow run, deploys the page to `https://abhinit21.github.io/nearby/`.

Preview with `python3 -m http.server 8000 --directory site`. Check the page at
mobile and desktop widths, keyboard navigation, links and assets before merging.
The website links to a specific published alpha DMG and provides first-launch
instructions, requirements and a link to release notes. Update these links only
after the matching assets are available; GitHub's `releases/latest` URL may skip
prereleases.

## Workflow maintenance

GitHub Actions are pinned to full commit SHAs. Dependabot checks them monthly;
review upstream release notes and the changed SHA before merging updates. CI uses
the `macos-26` runner with Xcode 26.6 selected explicitly. GitHub refreshes its
runner images, so this choice fixes the toolchain selection without freezing the
entire build environment. Current upstream references:

- [Checkout release](https://github.com/actions/checkout/releases/tag/v7.0.1)
- [macOS 26 runner inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)
- [Pages configuration release](https://github.com/actions/configure-pages/releases/tag/v6.0.0)
- [Pages upload release](https://github.com/actions/upload-pages-artifact/releases/tag/v5.0.0)
- [Pages deployment release](https://github.com/actions/deploy-pages/releases/tag/v5.0.1)
