# Release preparation

The public repository distributes source, documentation, pinned Android runtime
components and a static marketing page. The current build script produces a
development app for the build Mac's architecture with local ad-hoc signatures.
It does not create a Developer ID signed or notarized public download. CI verifies
the bundle locally and does not publish application binaries.

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

## Public app downloads

Before offering a general-use binary, implement and validate a Developer ID
release process that signs the app and its nested macOS executables with the
intended hardened-runtime settings, submits to Apple's notary service and staples
the accepted ticket. Verify the distributed archive on a clean Mac. Keep signing
certificates and notarization credentials in an appropriate private secret store.
Publish clear architecture requirements, checksums and release notes with any
binary release. Do not describe a locally ad-hoc-signed archive as notarized.

## GitHub Pages

The `Deploy landing page` workflow uploads only `site/` and deploys through the
`github-pages` environment. Enable **Settings → Pages → Build and deployment →
GitHub Actions**. A push to `main` that changes `site/` or the Pages workflow, or a
manual workflow run, deploys the page to `https://abhinit21.github.io/nearby/`.

Preview with `python3 -m http.server 8000 --directory site`. Check the page at
mobile and desktop widths, keyboard navigation, links and assets before merging.
The website should direct visitors to source-build instructions until a public
binary release is available.

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
