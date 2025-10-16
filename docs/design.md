# Current design

The mirror is phone content in a transparent borderless window, with smooth,
proportional corners and a persistent detached Liquid Glass dock below it.
Android's own status and navigation areas remain part of the stream.

This document describes pairing, recovery, sharing and presentation. Native
AppKit/SwiftUI appearance is authoritative for real glass, focus and accessibility.
Historical board states and device measurements do not override this specification.

## Display and controls

The display uses a continuous rounded rectangle, with a corner radius of 10% of
its displayed short edge. This is an aesthetic proportion, independent of phone
hardware radius metadata. The same shape clips video, overlays and new pointer
hit tests. Video aspect ratio and rectangular Android input coordinates stay intact.

The visible glass dock is 296 × 56 points with a 16-point gap below the video.
It sits within a transparent 376 × 56-point controls container that reserves room
for manipulation handles. Six 44 × 44-point icon targets stay visible:

| Action | Native symbol |
| --- | --- |
| Back | `chevron.backward` |
| Home | `house` |
| Overview | `rectangle.stack` |
| Paste to Pixel | `doc.on.clipboard` |
| Clipboard & Files | `folder` |
| More | `ellipsis` |

Buttons have accessible names and tooltips. Action text belongs in tooltips and
menus rather than occupying the dock. Navigation and paste availability reflect
the session state. More retains appropriate Mac-side window and recovery actions.

Move and resize handles appear beside the glass dock when hovering over the phone
or dock, or when the dock has keyboard focus. A 280 ms exit delay bridges the gap
from phone to controls.
They remain present during a pointer gesture or keyboard interaction and then
hide when no longer needed. Revealing them does not shift the dock or resize the
video. Move operates on the phone and controls together; resize preserves aspect
ratio. Manipulation targets remain outside the Android touch area.

Option-Command-T and Control-F5 focus the controls. Tab and Shift-Tab move between
enabled icons even when macOS limits ordinary Tab navigation to text fields.
Escape returns to the phone.
Native menus and keyboard equivalents provide the same actions. Fitting and
restoring frames reserve space for controls and keep them reachable on the current
screen, including displays with negative coordinates.

## Connection and sharing states

Recovery appears inside the retained display bounds. It distinguishes connecting,
recovering with bounded progress, waiting for network, sleeping, paused and failed.
Cancel Recovery, Try Again and Connection Help explain the next action. Manual
close ends recovery intent. Never label a black frame as a locked phone without
positive evidence.

Clipboard & Files uses a native panel. It shows a sharing toggle, textual status,
explicit Paste, a clear file-drop area and per-file rows. Status is understandable
without color: off, ready, sending, paused, unavailable and failed. Rows retain
names, progress, saved names, cancellation and retry/error explanations. Duplicate
names explain keep-both behavior. Completed items remain when another is cancelled.
The panel preserves valid placement and fits its complete frame to a current screen.

Use semantic system colors and system typography: 17-point state headings,
13-point body/controls and 12-point secondary information. Respect Reduce Motion,
Reduce Transparency and Increase Contrast. Preserve readable failure and recovery
text; icon-only dock actions do not require icon-only instructions or status.
