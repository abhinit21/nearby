# Install Nearby on Mac

[Download Nearby 0.3.3 for Mac](https://github.com/abhinit21/nearby/releases/download/v0.3.3/Nearby-0.3.3-macOS-universal.dmg)

Nearby is a development alpha. This release is **ad-hoc signed** and **has not
been notarized by Apple**. It does not have a Developer ID certificate. macOS may
block the first launch because it cannot verify the developer or check this app
through notarization. Install and open it only if you trust this release.

## Requirements

- An Apple silicon or Intel Mac running **macOS 26 or later**. One universal DMG
  supports both architectures.
- An **Android 11+** phone with Wireless debugging enabled.
- Both devices on the same reachable local network.

Nearby includes its Android tools. You do not need Xcode, ADB, scrcpy, or a source
build to use the downloaded app.

## Install

1. Download `Nearby-0.3.3-macOS-universal.dmg` from the link above or the
   [official GitHub release](https://github.com/abhinit21/nearby/releases/tag/v0.3.3).
2. Open the DMG in Finder.
3. Drag **Nearby** onto the **Applications** shortcut in the disk image.
4. Eject the Nearby disk image, then open **Nearby** from Applications.
5. Allow **Local Network** access when macOS asks, so Nearby can discover and
   connect to your phone.

## First open and macOS security

This alpha is distributed without Apple notarization. An ad-hoc signature does
not identify its publisher or provide Apple's notarization checks.

If macOS blocks Nearby and you trust the downloaded release:

1. Attempt to open **Nearby** from Applications, then dismiss the blocked-app alert.
2. Open **Apple menu → System Settings → Privacy & Security**.
3. Scroll to the Security section. If an **Open Anyway** button appears for Nearby,
   select it and confirm that you want to open Nearby. macOS may ask you to
   authenticate.

This creates an exception for this app. Follow
[Apple's guidance on safely opening apps](https://support.apple.com/en-us/102445)
and review the alert before proceeding. If macOS reports malware, damage, or a
different security issue, stop and report the exact message in a
[GitHub issue](https://github.com/abhinit21/nearby/issues/new/choose). Do not disable
Gatekeeper or remove quarantine attributes to force the app to run. On a managed
Mac, your organization's settings may prevent an exception.

## Pair your phone

1. On Android, open **Settings → System → Developer options → Wireless debugging**.
   If Developer options is hidden, tap **Build number** seven times in About phone.
   The exact menu names can vary by phone.
2. In Nearby, choose **Pair Device**. On the phone, choose **Pair device with QR
   code** and scan the QR code shown on your Mac.
3. Choose **Mirror** once the paired phone is available.

You can also use **Enter Code** with Android's **Pair device with pairing code**
screen. **Connection Help** supports manual addresses when local discovery is
blocked. Keep Wireless debugging enabled while using Nearby; guest networks,
network isolation, and VPN rules can prevent a connection.

See the [README](../README.md#mirror-and-share) for mirroring, clipboard sharing,
file transfers, and keyboard shortcuts.

## Update or uninstall

Nearby does not include an automatic updater. Quit Nearby before replacing the
app in Applications with a newer release. Check its release notes for changes and
installation requirements.

To uninstall, quit Nearby and move it from Applications to the Trash. Revoke the
Mac's pairing in Android's Wireless debugging settings if you no longer want it
to control the phone. Deleting the app does not revoke that phone authorization
or remove files already sent to Android Downloads.
