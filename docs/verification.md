# Verification

16 October 2026. Nearby **0.3.2 (11)** adds adaptive video quality, processing off
the UI thread, bounded decoded delivery and file-upload pacing. Results distinguish
the new automated performance/lifecycle checks from prior native Pixel inspection.

This document records development checks performed before the initial public
source release. Build outputs, screenshots, raw QA logs and private historical
archives are excluded from the repository. The tables preserve recorded results;
they do not represent a hosted CI run or a public binary release. Run the commands
below to validate your checkout and consult GitHub Actions for subsequent CI runs.

## Performance verification

| Check | Result |
| --- | --- |
| Full automated regression suite | 181 passed: 108 core XCTest, 26 app XCTest, 47 Swift Testing |
| Adaptive quality | Warmup, dwell, user ceiling, idle screens, pressure, active-video recovery and failed-upgrade backoff passed |
| Video and control pipeline | Off-main processing, synchronous decode/sample preparation, single-slot mailbox, ordered ACK burst and stale worker replacement passed |
| Shutdown | UI stop stays nonblocking; owned ADB cleanup runs before a cancellation-aware native join; short quit-deadline test passed |
| Video quality changes | Settings coalesce, stale completions cannot reopen a closed/replacement session, and real recovery retains the selected profile |
| Sharing across video restarts | A gated upload survives pause/resume without rebinding; true inactivity still cancels and cleans; clipboard baselines and late acknowledgements passed |
| Upload pacing | Sustained token budget, bounded burst, dynamic limit removal, cancellation and early fragmented storage failure passed |
| Release build, pinned runtime, signatures, plist and ZIP | Passed for the local 0.3.2 (11) development bundle; ad-hoc signing only |
| Independent source review | Queue, clipboard, transfer binding and recovery stability findings addressed; final regression suite passed |

The recorded suite ran from an isolated SwiftPM build directory using
`swift test --scratch-path .build/nearby/performance-validation`. Tests use synthetic TCP peers, a real
native decoder, named pasteboards and owned temporary files. They do not change
the running phone, general clipboard, preferences or shared ADB services.

The recorded local output was `dist/Nearby.app` and `dist/Nearby-macOS.zip`. ZIP SHA-256:
`09807c353056a8016e676ae32f2711495af448f6c467b0dfdb83749364d9659e`.
That hash identifies a historical development archive, which is not published
here. A fresh build will generate its own app and ZIP under `dist/`; signing and
packaging can change the archive hash.

No measured end-to-end speedup or updated real-device throughput is claimed.
Automatic profile changes briefly restart video using the pinned server protocol;
ongoing file transfers retain their verified binding. New settings and the quality
adjustment overlay have source/build coverage; direct native inspection below
predates these performance changes.

## Presentation baseline

Nearby **0.3.1 (10)** completed the following checks before the performance changes.

| Check | Result |
| --- | --- |
| Continuous mask and corner hit tests | Automated pass at portrait, landscape and small sizes; identical clipping/hit path |
| Dock layout and transient handle behavior | Automated pass: six nonoverlapping 44-point targets, fixed positions, hover/focus/gesture reveal and cancellation-safe delayed hiding |
| Full automated regression suite | 135 passed: 74 core XCTest, 14 app XCTest, 47 Swift Testing |
| Final presentation follow-up | 8 focused checks passed after the hover cancellation guard |
| Release build, pinned runtime, signatures, plist and ZIP | Passed |
| Native appearance and keyboard access | Live Pixel corners and icon dock inspected; Tab advanced Back to Home, Shift-Tab reversed dock navigation, and Escape returned phone focus |
| Handle discoverability and moving | User confirmed the new glass-backed handle is visible and dragging works |
| Independent source and structure review | Closed; no unresolved actionable finding |

The glass backing fixes the low-contrast move dots shown in the user's screenshot.
Hovering over the phone or dock reveals both handles; a 280 ms exit delay bridges
the gap. Their hit targets and icon positions stay fixed. Current resize geometry
and gesture code have automated coverage; a new physical resize gesture was not
independently verified. Pointer automation still reports `noWindowsAvailable` for
dragging; current move verification is explicitly user-assisted.

The existing pairing was retained. The packaged app opened the paired Pixel's
live stream, and the Files icon opened the native Clipboard & Files panel in
Ready state. Clipboard and transfer protocols were not changed by this refinement;
the prior physical coverage below remains the baseline for those behaviors.

The presentation baseline ZIP SHA-256 was:
`d09d8cbc797a7982e724eeee683d90a21b10cb64316c5848ed9a7bf5cc8ddb02`.
Temporary command output was retained locally under `.build/nearby/` and is not
included in this repository.

Repeatable commands:

```sh
swift test
./scripts/build-app.sh
./scripts/verify-app.sh
unzip -t dist/Nearby-macOS.zip
```

Automated checks use local protocol peers, named pasteboards and temporary source
files. They should not require a phone, read the user's general clipboard or stop
an existing shared ADB service. Store temporary output under `.build/nearby/`.
Keep this report current rather than adding chronological QA journals.

## Prior real-device baseline

Nearby **0.3.0 (9)** passed 131 automated checks plus release, signature, resource,
runtime, helper-source and archive checks. Independent review found no blocking
issue in that release. These results establish the baseline, not a pass for the
new corner and dock design.

Harmless owned samples were exercised with a paired Pixel 9:

- Unicode inserted once through Command-V, Shift-Command-V and the panel action
  into Files search. Automatic sharing worked in both directions; background and
  non-session copies were not replayed on return, with positive controls.
- Native Choose Files and user-assisted Finder drops reached Saved with Unicode
  names, byte progress and keep-both duplicates. Remote hashes matched. Native
  cancellation, interrupted sending, owned partial cleanup and explicit retry
  passed. Exact hash-verified sample outputs were removed.
- Deliberate close prevented rediscovery from reopening a mirror. Manual recovery
  cancellation and Try Again worked. Sleep/wake, Pixel Wi-Fi off/on and a changed
  wireless-debugging listener port recovered automatically. Pairing remained;
  observed mirror geometry was preserved across the scoped recovery checks.
- The previous move and proportional resize controls worked by user confirmation.
  That result does not establish the usability of this revision's transient handles.

The original baseline app, ZIP, source snapshot and detailed QA evidence were
retained in a private local archive outside this repository. Its recorded ZIP
SHA-256 was `5536a2cfcf658cc6c43551002487da2d2f2cdd0ab629ed6bfc874d107f98ff28`.
Pairing and application support data are excluded from public source.

## Explicit limits

- Physical DHCP IP-address rotation was not induced. Automated changed-address
  recovery tests and real changed-port recovery cover distinct parts of this behavior.
- Actual phone storage exhaustion during a write was not induced. Synthetic early
  and late ENOSPC cases and harmless physical insufficient-storage preflight passed.
- Current hover/move and previous drop/resize confirmation were user-assisted.
  Current resize has automated geometry coverage. Full cursor and accessibility
  navigation were not exhaustively verified. Capture automation intermittently
  failed; successful native checks and manual scope are distinguished above.
- An unplanned bounded recovery completed during prior QA; its physical cause was
  not established.
- Text clipboard only, up to 262,130 UTF-8 bytes. Android apps can reject Paste.
  Files require supported Android architectures and atomic no-clobber storage;
  interrupted transfers require explicit retry.
- The app uses local ad-hoc signing and is not Developer ID notarized.
