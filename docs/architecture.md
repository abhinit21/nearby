# Architecture

Nearby is a Swift 6 package with a native macOS executable and a reusable core
library. SwiftUI supplies ordinary application surfaces; AppKit owns native
windows, pointer/input delivery, menus and Liquid Glass controls. VideoToolbox
decodes the Android stream. No web view or companion Android application is needed.

## Modules

| Location | Responsibility |
| --- | --- |
| `Sources/Nearby/App/` | Application lifecycle, menus, session orchestration and saved preferences |
| `Sources/Nearby/Devices/`, `Pairing/`, `Settings/` | Device list, authorization and configuration surfaces |
| `Sources/Nearby/Mirror/` | Borderless mirror, continuous display shape, clipped input, persistent dock and transient manipulation handles |
| `Sources/Nearby/Sharing/` | Native clipboard/file panel, active-session gating and Finder drops |
| `Sources/Nearby/Style/` | Shared native appearance and semantic view components |
| `Sources/NearbyCore/ADB/` | Scoped command execution and owned service lifecycle |
| `Sources/NearbyCore/Discovery/`, `Recovery/` | Bonjour resolution, bounded retry policy and transport identity/liveness checks |
| `Sources/NearbyCore/Clipboard/` | Text limits, status policy, foreground baselines and echo prevention |
| `Sources/NearbyCore/Transfer/` | Sync upload, queue, staging ownership, journal, cancellation and atomic finalization |
| `Sources/NearbyCore/Mirror/` | Aspect-preserving layout, panel placement and resize geometry |
| `Sources/NearbyCore/Scrcpy/` | Pinned wire protocol, socket lifetime, decoder and input/control session |

The app coordinator owns the intended session and mirror controller. Core policies
represent state transitions independently of UI, allowing deterministic tests.
Presentation changes do not change Android coordinates: all touch mapping uses
the actual rectangular video bounds, with the display mask rejecting new corner
touches outside the visible shape.

## Connection boundaries

Nearby starts and tracks its own wireless-only ADB child on a private loopback
port. Commands always address that service. It retains the existing user's ADB
keys and does not kill shared services or compete for USB transports.
Pair-before-connect safeguards prevent probing unrelated discovery results.

An interrupted intended session keeps its mirror controller and saved frame.
Recovery resolves current trusted Bonjour endpoints, verifies hardware identity
and makes at most six attempts within 90 seconds. Sleep pauses recovery time;
network absence and explicit cancellation have distinct visible states. Two
completed identity heartbeat failures can trigger recovery even when the Mac's
network remains available. Static video does not indicate failure.

Session generations reject stale asynchronous results. Deliberate close,
disconnect and quit invalidate recovery intent. Returning discovery results cannot
reopen a mirror after that intent ends. Socket workers retain endpoint leases so
old descriptor activity cannot reach a replacement session.

## Clipboard and files

Clipboard sharing uses scrcpy's UTF-8 text protocol with bounded acknowledgements.
Automatic sharing requires the intended session to be active, with a new baseline
on activation, replacement and preference changes. Remote hashes prevent echoes.
Explicit paste is separately available while automatic sharing is off. Neither
text contents nor pairing secrets belong in diagnostics.

Transfers enter an explicit queue. Each regular source file is uploaded into an
owned private staging directory in Downloads. A journal binds exact staging paths
to the verified phone. The Android helper uses directory descriptors, ownership
markers and no-follow handling; atomic no-replace finalization chooses a free
filename. Cancellation preserves finished files. Cleanup touches only recorded,
owned incomplete payloads on the same phone. Interrupted uploads require user
retry. A lost final acknowledgement can leave a completed file, so the UI asks
the user to check Downloads before retrying.

## Video performance

Each stream owns a dedicated serial video queue for blocking reads, H.264 parsing,
sample construction and decoder submission. VideoToolbox callbacks complete
synchronously on that worker, bounding decoder work to one access unit. All
compressed reference frames are processed. A single-slot mailbox keeps the newest
decoded frame, with at most one outstanding main-queue drain. Display sample
construction also stays on the worker; the main actor updates native presentation
state and enqueues the sample. Stop closes the mailbox and interrupts reads
immediately; decoder invalidation and worker joining happen in asynchronous cleanup.

Two-second performance windows count bytes, frames, mailbox replacements, renderer
flushes and local receive-to-presentation delay. Relative progression of Android
presentation timestamps and Mac monotonic arrival time detects growing backlog;
it does not measure absolute end-to-end latency. Static screens and low content
frame rates are valid and do not imply a failed connection or spare bandwidth.

Adaptive quality is enabled by default and bounded by the user's chosen maximum:
High Quality is 2560/12 Mbps/60 fps, Balanced 1920/8 Mbps/60 fps, Lower Bandwidth
1280/4 Mbps/30 fps, and the automatic minimum 1024/2 Mbps/30 fps. Sustained pressure
lowers one level after warmup and a minimum dwell. Upgrades require sustained
healthy active video; failed upgrade trials back off before trying again.

The pinned scrcpy protocol has no live bitrate-change message. The app serializes
video-only restarts, coalesces preference changes, and rejects stale samples and
completions by session generation. It waits for clipboard acknowledgement work and
held touches before restarting. Connection recovery owns actual failures and its
existing bounded retry budget. Video-only restarts pause and rebaseline clipboard
sharing without replacing the verified file-transfer binding; a genuine interruption
still cancels transfers and requires explicit retry.

An upload token bucket is shared across the file queue. Its maximum burst is 64 KiB
and its source-byte budgets are 500,000 B/s for Balanced/High Quality, 250,000 B/s
for Lower Bandwidth, and 125,000 B/s at the automatic minimum. The preference to
prioritize mirroring can remove this limit dynamically. Pacing polls for cancellation
and early device failures at most every 100 ms. Intentional pacing does not consume
the I/O stall deadline; ownership setup, final acknowledgement and atomic finalization
are not throttled. The wire protocol remains uncompressed SYNC v1 in this iteration.

## Dependencies and development

`Resources/Runtime` remains under the executable target for SwiftPM resources and
bundle lookup. `prepare-runtime.sh` verifies adb, scrcpy, transfer helpers, source
hashes and licenses before packaging. The transfer helper's source remains at
`scripts/nearby-transfer.c`; host safety tests compile that same source.

Use `.build/nearby/` for generated icon resources, dependency caches and temporary
verification output. `dist/` contains only the current app and ZIP. Regression
tests live in `Tests/` and use isolated temporary directories, local peers and
named pasteboards rather than the user's phone or general clipboard.
