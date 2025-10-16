# Nearby

[![CI](https://github.com/abhinit21/nearby/actions/workflows/ci.yml/badge.svg)](https://github.com/abhinit21/nearby/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-254E43.svg)](LICENSE)

Nearby mirrors an Android phone in a native macOS window over Wi-Fi. SwiftUI and
AppKit provide pairing, a proportionally rounded display, a floating Liquid Glass
control dock, text clipboard sharing and file transfers to Downloads.

[Website](https://abhinit21.github.io/nearby/) ·
[Download for Mac](https://github.com/abhinit21/nearby/releases/download/v0.3.3/Nearby-0.3.3-macOS-universal.dmg) ·
[Installation guide](docs/install.md) ·
[Build from source](#build-and-test) ·
[Report an issue](https://github.com/abhinit21/nearby/issues/new/choose) ·
[Contributing](CONTRIBUTING.md)

**Development alpha · 0.3.3.** Download the ready-to-run app for **Apple silicon and
Intel Macs running macOS 26 or later**. The app is ad-hoc signed, without a
Developer ID certificate or Apple notarization, so macOS may block the first launch.
Read the [installation and first-open guide](docs/install.md) before opening it.
An **Android 11+** phone is required; real-device validation has focused on Pixel 9.

## Install on your Mac

1. [Download Nearby 0.3.3 for Mac](https://github.com/abhinit21/nearby/releases/download/v0.3.3/Nearby-0.3.3-macOS-universal.dmg).
2. Open the DMG and drag **Nearby** into **Applications**. Eject the disk image.
3. Open **Nearby** from Applications. If macOS blocks this unnotarized alpha, follow
   the [first-open instructions](docs/install.md#first-open-and-macos-security) only
   if you trust this release.

No Xcode, source build, or separate Android tools installation is needed.
[Release notes and other assets](https://github.com/abhinit21/nearby/releases/tag/v0.3.3)
are available on GitHub.

## Features

- Pair through Android Wireless debugging using a QR code or six-digit code.
- Mirror and control your phone in a native, resizable Mac window.
- Share text clipboards and upload regular files to Android Downloads.
- Adjust stream quality automatically and pace uploads to preserve responsiveness.
- Recover interrupted sessions while retaining the mirror window's position.
- Run over the local network with bundled ADB and scrcpy server components.

## Run and pair

Open Nearby from Applications (or `dist/Nearby.app` after a source build). Nearby requires macOS 26 or later, an Android 11+ phone
with Wireless debugging enabled, and a reachable local network shared by both.
The packaged app includes its Android tools; no separate adb or scrcpy install is
needed. Allow Local Network access when macOS asks.

1. On the phone, open **Settings → System → Developer options → Wireless debugging**.
   If Developer options is hidden, tap **Build number** seven times in About phone.
2. In Nearby, choose **Pair Device**. On the phone, choose **Pair device with QR
   code** inside Wireless debugging and scan Nearby's QR code.
3. When the paired device is available, choose **Mirror**.

Use **Enter Code** with Android's **Pair device with pairing code** screen as an
alternative. Nearby discovers its temporary endpoint. **Connection Help** offers
manual addresses for networks where discovery is blocked. The pairing and
connection ports differ. Existing authorization is retained across launches;
ordinary network interruptions do not require pairing again.

## Mirror and share

The phone keeps its stream aspect ratio and uses smooth continuous corners. The
six dock icons are **Back**, **Home**, **Overview**, **Paste to Pixel**,
**Clipboard & Files**, and **More**. Hover for tooltips. Move and resize handles
appear beside the dock when hovering over the phone or dock, or on keyboard focus,
and remain visible throughout a gesture. The glass controls remain visible while
the mirror is open.

In **Settings → Mirroring**, automatic quality adjustment lowers video quality
when the stream persistently falls behind and cautiously restores it after stable
video. Your chosen quality is the maximum. **Lower Bandwidth** uses up to 30 fps;
Balanced and High Quality use up to 60 fps. Turn automatic adjustment off to keep
a fixed profile. Applying a quality change briefly restarts video and clipboard
sharing, preserving the mirror window and ongoing file uploads.

**Prioritize mirror during file transfers** is enabled by default. It paces
uploads to leave room for video and input, with a smaller upload budget at lower
video quality. Turn it off when unrestricted file-transfer speed matters more.

| Action | Keyboard access |
| --- | --- |
| Focus mirror controls | Option-Command-T or Control-F5 |
| Move between dock icons | Tab / Shift-Tab |
| Return focus to phone | Escape |
| Android Back / Home / Overview | Control-Command-B / H / O |
| Paste text to Pixel | Shift-Command-V; Command-V with the phone view focused |
| Open Clipboard & Files | Shift-Command-F |
| Fit to Screen | Command-0 |
| Take Screenshot | Shift-Command-S |
| Close mirror | Command-W |

Select an Android text field before pasting. Unicode text is supported up to
262,130 UTF-8 bytes; oversized text is rejected without truncation. Android apps
can decline Paste even after acknowledging delivery. Automatic text sharing is
limited to the intended active mirror, its controls or its sharing panel. Text
copied in the background is not replayed later. The sharing panel shows ready,
off, sending, paused, unavailable and failure states. Explicit Paste also works
with automatic sharing off. Clipboard contents stay out of diagnostics.

Drag regular files from Finder onto the phone or the sharing panel, or use
**Choose Files** there. Per-file rows show progress, final names, errors and
cancellation. Duplicate names become `name (2).ext` and are never silently
overwritten. Folders, aliases and symbolic links are rejected. Interrupted files
require explicit retry; completed files remain. If final-save acknowledgement is
lost, check Downloads before retrying. Nearby cleans up only its own incomplete
payloads on the same verified device.

Interrupted mirrors keep their position and size. Nearby rediscovers current
endpoints and verifies the paired phone, with at most six attempts in 90 seconds.
**Cancel Recovery** pauses retries; **Try Again** starts a fresh attempt.
**Disconnect**, closing the mirror or quitting ends the session's recovery intent.
The **Resume interrupted sessions** setting controls automatic recovery.

## Build and test

Use an Xcode toolchain with the macOS 26 SDK and Swift 6 support:

```sh
git clone https://github.com/abhinit21/nearby.git
cd nearby
swift test
./scripts/build-app.sh
./scripts/verify-app.sh
unzip -t dist/Nearby-macOS.zip
open dist/Nearby.app
```

The build creates `dist/Nearby.app` and `dist/Nearby-macOS.zip`, verifies pinned
runtime components and includes their license notices. Generated files and
dependency downloads live under `.build/`. Set `NEARBY_BUILD_CONFIGURATION=debug`
for a debug app bundle. `swift build` also supports ordinary development; use the
packaged app for normal UI and permission behavior.

The default build targets the current Mac architecture and uses local ad-hoc
signatures. The public alpha uses ad-hoc signatures too; Developer ID signing and
Apple notarization are still needed for a standard verified macOS installation. The source
repository includes the pinned runtime binaries and their notices; Git LFS and
separate ADB or scrcpy installations are not required.
Android transfer helpers require Android NDK 28 only when rebuilding
them with `scripts/build-transfer-helper.sh`; normal app builds use pinned copies.

See [release preparation](docs/release.md) for packaging, signing, notarization and
release checks. CI tests and packages the app on a
macOS runner; local signing verification does not establish notarization.

## Privacy and trust

Nearby's mirroring, clipboard and file-transfer paths run over your local network
using Android Wireless debugging. Nearby does not include analytics or an account
service. Pair only with devices and networks you trust: debugging authorization
permits control of the phone. You can revoke it in Android's Wireless debugging
settings. Nearby reuses your local ADB authorization keys and stores known-device
and transfer-recovery state locally.

Clipboard sharing can send new text while the intended mirror or its sharing
controls are active. Turn it off in settings when you do not want automatic text
sharing. See [security reporting](SECURITY.md) before sharing diagnostics; remove
device addresses, names, pairing codes, filenames and other personal information.

## Project layout

- `Sources/Nearby/`: app coordination and native views, grouped by feature.
- `Sources/NearbyCore/`: ADB, discovery, recovery, clipboard policy, transfers,
  mirror geometry and scrcpy transport/decoding.
- `Sources/Nearby/Resources/Runtime/`: pinned tools, integrity manifest and licenses.
- `Tests/`: automated native-sharing, protocol, lifecycle, safety and layout tests.
- `scripts/`: runtime verification, transfer-helper source, icon generation and packaging.
- `site/`: dependency-free marketing site deployed through GitHub Pages.
- `.github/`: automated checks, Pages deployment and issue/PR templates.
- `docs/`: current [architecture](docs/architecture.md), [design](docs/design.md)
  and [verification](docs/verification.md).
- `.build/`: disposable compiler output, dependency cache and generated resources.
- `dist/`: current runnable app and packaged ZIP.

## Practical limits

Wireless debugging must stay enabled; Android can request network confirmation.
Guest networks, access-point isolation or VPN rules can prevent discovery. Secure
Android content may be blank, and authentication must happen on the phone.
Audio and image clipboard sharing are not implemented. File transfer requires
arm64 or x86-64 Android and atomic no-clobber filesystem support.

Nearby reuses the user's ADB authorization while owning a separate tracked,
wireless-only ADB service on a private localhost port. It leaves shared ADB
services and USB devices alone. Runtime versions and provenance are recorded in
`THIRD-PARTY-NOTICES.txt` and the bundled dependency manifest.

## License and credits

Nearby's original source code, artwork and website are available under the
[MIT License](LICENSE). Bundled upstream components retain their own licenses;
see [third-party notices](THIRD-PARTY-NOTICES.txt) and the full license texts in
`Sources/Nearby/Resources/Runtime/Licenses/`.

Nearby uses [Android Debug Bridge](https://android.googlesource.com/platform/packages/modules/adb/)
and the [scrcpy server](https://github.com/Genymobile/scrcpy). Nearby is an
independent project and is not affiliated with Google, Apple or Genymobile.
