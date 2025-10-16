# Nearby network bandwidth and performance research

16 October 2026. RAM throughput samples were collected at 16:15 IST. The reviewed runtime is scrcpy server 3.3.4 with Android Platform Tools 37.0.1. The connected phone reported Pixel 9, Android 17, API 37.

This report records the baseline before the performance implementation. Nearby 0.3.2 implements adaptive profiles, video processing off the UI thread, a bounded decoded-frame mailbox, and upload pacing. See the [current architecture](architecture.md#video-performance) and [verification](verification.md) for their behavior and validation. The baseline measurements below remain historical observations rather than measurements of that implementation.

Nearby has no architectural bandwidth ceiling of 8 or 12 Mbps. Those numbers are encoder targets selected by the UI. The strongest observed constraint is the current local wireless path: both endpoints were using 2.4 GHz 802.11n, the phone reported a 28 Mbps transmit PHY rate, and local round trips varied substantially. The app also has several opportunities to control latency and share that path more effectively.

The recommended direction is to keep ADB for the next iteration, improve network conditions, instrument frame and control latency, bound presentation queues, add adaptive video profiles, and pace file uploads. Compressed file transfer and an optional HEVC decoder are useful follow-ups. A custom transport is a larger investment whose benefit should be established by comparison measurements.

## Current architecture

| Flow | Implementation | Bandwidth implication |
| --- | --- | --- |
| Screen video | Android screen capture and MediaCodec H.264 encoding → scrcpy local socket → adbd → wireless ADB → app-owned Mac ADB server → loopback TCP → VideoToolbox → native display layer | Only compressed video crosses Wi-Fi. Decode and display costs occur on the Mac. |
| Input and clipboard | A separate scrcpy control socket, forwarded by the same ADB service and device transport | A separate local socket does not provide a separate wireless connection or bandwidth reservation. |
| Files | Mac file → native SYNC v1 uploader → the same device transport → owned staging file in Downloads → helper finalization | Uploads compete for radio airtime and ADB scheduling with the mirror. |
| Discovery and health | Bonjour discovery, a four-second refresh loop, and a bounded identity heartbeat | Small background traffic; useful for reachability, but it does not measure available bandwidth or frame latency. |

The live socket inventory showed one remote TCP connection from Nearby's private ADB server to the phone. Android's wireless-debugging transport uses TLS. ADB multiplexes logical streams onto a byte stream; the app's separate video, control, and file sockets therefore share the device connection. [ADB internals](https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/docs/dev/internals.md), [wireless ADB architecture](https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/docs/dev/adb_wifi.md).

The loopback TCP connection terminates on the Mac. This is not two independent long-distance TCP retransmission layers nested across the wireless link. Its relevant costs are local copying, buffering, scheduling, and the ADB protocol above the network connection.

The current coordinator presents one intended mirror session. Multiple simultaneous mirrors would require a separate capacity and decoder-resource budget; current measurements cover one phone.

## Measured connection

| Observation | Result | Interpretation |
| --- | --- | --- |
| Active stream launch | H.264, maximum edge 1920, target 8,000,000 bits/s, maximum 60 fps, audio disabled | Confirms the Balanced profile was running. These are requested settings, not observed frame rate or actual bitrate. |
| Phone Wi-Fi | 802.11n, 2442 MHz, RSSI −54 dBm initially and −53 dBm after RAM tests | The phone was connected on 2.4 GHz despite having a reasonably strong reported signal. |
| Phone reported PHY rates | Transmit 28 Mbps; receive 130 Mbps | Phone transmit is the direction most directly relevant to video. PHY rates vary and exceed application payload goodput. |
| Mac Wi-Fi | 802.11n, channel 7, 20 MHz, reported transmit rate 144 Mbps, signal −40 dBm | The Mac also used 2.4 GHz. The Mac's faster reported rate does not eliminate a slower phone uplink. |
| Local ICMP round trips | 15 probes; minimum 7.031 ms, average 68.567 ms, maximum 222.797 ms, standard deviation 60.013 ms | Large timing variation on the local path. This sample cannot identify whether contention, power management, retries, or other scheduling caused it. |
| ICMP sample loss | 0 of 15 probes | Too small a sample to establish a loss-free connection. |
| Negotiated ADB capabilities | SYNC v2 plus Brotli, LZ4, and Zstd present | Compression can be implemented without replacing the ADB transport. |
| Burst mode capability in active negotiation | No delayed_ack in host or negotiated feature lists | Burst mode was not negotiated on the observed connection. Device compatibility with an enabled host still needs testing. |

Three verified 4 MiB RAM transfers were run sequentially in each direction through the existing owned ADB server. The mirror remained open. The source service generated bytes in RAM; the sink service discarded bytes in RAM. No phone files were created. Source byte counts were verified; sink completion waited for remote closure after the exact payload was sent. Timings include service setup.

| Direction | Run 1 | Run 2 | Run 3 | Median |
| --- | --- | --- | --- | --- |
| Phone to Mac | 12.576 Mbps | 9.507 Mbps | 11.639 Mbps | **11.639 Mbps** |
| Mac to phone | 14.648 Mbps | 13.845 Mbps | 14.632 Mbps | **14.632 Mbps** |

These are short ADB RAM-stream goodput measurements alongside an uncontrolled mirror workload, not the total link capacity, actual mirror bitrate, sustained file-write speed, or a maximum supported frame rate. ADB RAM services also produce different packet patterns from video. The two directions were tested separately and their medians must not be added to estimate simultaneous capacity. The upstream ADB benchmark uses these same source and sink service types. [ADB benchmark source](https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/benchmark_device.py).

An earlier passive observation of the owned ADB process showed about 1.00 MB received over eleven nominal one-second intervals, roughly 0.73 Mbps. That includes all its wireless traffic and reflects the screen activity during that window. It is not a capacity measurement. Scrcpy's capture rate varies with screen changes, so a 60 fps setting does not require 60 frames every second. [Scrcpy video behavior](https://github.com/Genymobile/scrcpy/blob/v3.3.4/doc/video.md#frame-rate).

The successful RAM measurements and sanitized observation data are preserved in [network performance measurements][measurements]. The current app does not expose the timestamps needed to establish absolute input-to-display or capture-to-display latency.

## Bandwidth budget and practical limits

The UI currently selects these profiles in [AppModel][stream-options]:

| Profile | Maximum image edge | Encoder target | Maximum frame rate | Video payload at target |
| --- | --- | --- | --- | --- |
| Lower Bandwidth | 1280 pixels | 4 Mbps | 60 fps | 0.5 MB/s; 1.8 GB/hour |
| Balanced | 1920 pixels | 8 Mbps | 60 fps | 1.0 MB/s; 3.6 GB/hour |
| High Quality | 2560 pixels | 12 Mbps | 60 fps | 1.5 MB/s; 5.4 GB/hour |

All units here are decimal: 8 bits make one byte. The hourly figures assume constant operation at the target, exclude protocol overhead, and represent local network traffic. Nearby's media path does not depend on an internet service's advertised download speed.

Maximum size is the longest image edge, not a declaration of 1920 × 1080 output. The observed Pixel reports 1080 × 2424 physical pixels. Balanced scales that aspect ratio down; High Quality can retain its native size rather than upscaling to a 2560-pixel edge. Window resizing changes presentation geometry without changing the capture profile.

An encoder target is not a strict network shaper. Actual traffic depends on content, encoder behavior, and bursts such as keyframes. Audio consumes no bandwidth in this build because playback is explicitly disabled in [session startup][session-startup]. Settings changes apply to new sessions, as [SettingsView][settings] states.

Using the 11.639 Mbps median RAM goodput only as a reference, the 4, 8, and 12 Mbps video targets are approximately 34%, 69%, and 103% of that reference. These percentages are not measured utilization: the test ran as an additional logical stream and did not control video content. They nevertheless justify testing the lower profile on this network and treating 12 Mbps as an aggressive setting. Under the slowest observed 9.507 Mbps RAM result, an 8 Mbps target leaves particularly little nominal margin for bursts.

The achievable rate for any workload is bounded by the slowest applicable stage: wireless payload capacity, ADB flow control, Android encoding or storage, and the Mac's receive/decode/presentation processing. Increasing one buffer or target does not improve all those stages.

If two clients communicate through the same access point on the same radio, each payload needs a client-to-AP transmission and an AP-to-client transmission. Airtime, acknowledgements, contention, and retries further reduce payload capacity. The observations establish a shared channel, but the AP topology and radio counters were not inspected. Cisco's throughput guidance distinguishes link rates from actual throughput and explains that clients share the wireless medium. [Cisco wireless throughput guidance](https://www.cisco.com/c/en/us/support/docs/wireless-mobility/wireless-lan-wlan/212892-802-11ac-wireless-throughput-testing-and.html).

## Limits in the current implementation

| Finding | Evidence | Consequence |
| --- | --- | --- |
| Profiles remain fixed during a session | [Profile selection][stream-options] and [server launch arguments][session-startup] | A stream cannot respond to changing network conditions by lowering its target or frame rate. |
| Lower Bandwidth still permits 60 fps | [Profile selection][stream-options] | It reduces resolution and target bitrate, but does not directly reduce the maximum frame-processing frequency. |
| Decode submission crosses the main actor for every packet | The reader awaits the main-actor decode method in [ScrcpySession][video-reader]; [VideoDecoder][decoder] then parses and submits that packet | UI activity can delay reading and processing. This is a code-level exposure, not a measured CPU bottleneck in the idle session. |
| Decoded frame delivery has no explicit bound before the main actor | Every decoder callback schedules a Task; [receive][presentation] flushes a congested renderer only after that task runs | Renderer flushing does not bound decoded frames already waiting in actor tasks. Old frames can increase apparent latency. |
| The decoder requests BGRA output | [Decoder configuration][decoder-config] | Potential additional color conversion and memory traffic compared with a supported native YUV output. |
| Uploads run without a rate budget | [SYNC upload loop][sync-upload] | One file at a time can still saturate available airtime. Serializing files does not protect the mirror from a single large upload. |
| Files use uncompressed SYNC v1 | SEND, DATA, DONE in [ADBSyncUpload][sync-upload] | The app does not use the compression already supported by this host and phone. |
| Small files incur repeated helper setup | [prepare and cleanup][file-transport] both install the helper | A normal successful file uses ten ADB command executions, including two helper pushes, plus its native SYNC connection. Setup latency can dominate small files. |
| Control writes form an unbounded serial queue | [ScrcpySocket.send][control-queue] and [input/clipboard methods][clipboard-send] | A large clipboard message or queued pointer events can delay later input on that control stream. |

### Shared transport and reliability

ADB's multiplexing does not reserve capacity by feature. Mac-to-phone file data and input can queue in the same transport direction. Phone-to-Mac video and clipboard replies can queue in the reverse direction. Missing TCP bytes block later bytes in that direction until recovery. A loss in one direction does not directly stop the other direction's TCP delivery, although shared airtime and delayed reverse ADB acknowledgements can still affect it. [ADB internals](https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/docs/dev/internals.md), [TCP specification](https://www.rfc-editor.org/rfc/rfc9293.html).

The existing queue, staging markers, atomic no-clobber rename, cancellation, and device identity checks protect file correctness. Their costs should be measured and optimized while retaining those guarantees. Finalization also calls fsync before rename, so a delay at the final stage may be storage latency rather than network latency. See [the transfer helper][transfer-helper].

### Packet size and overhead

The uploader's 65,536-byte DATA chunks are a SYNC framing limit. It streams those chunks without waiting for a per-DATA success reply; completion requires the final OKAY. The chunk size is therefore not itself a stop-and-wait bandwidth ceiling. Current ADB source defines SYNC_DATA_MAX as 64 KiB and a separate transport MAX_PAYLOAD of 1 MiB. The actual transport limit is negotiated. Older prose in ADB's protocol document contains historical maximum values, so those should not be treated as the current binary's negotiated value. [SYNC protocol definitions](https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/file_sync_protocol.h), [ADB transport constants](https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/adb.h).

The SYNC header adds eight bytes per full DATA chunk, approximately 0.012%. Scrcpy's twelve-byte packet header at sixty video packets a second adds about 5,760 bits/s, or 0.072% of an 8 Mbps target, excluding configuration packets. These small headers are unlikely to be the main issue. Wireless airtime, protocol acknowledgements, buffering, and retransmissions deserve priority.

The 16 MiB video-packet guard in the client's frame parser limits allocation and malformed inputs. It is not a bandwidth rate limit. Descriptor leases in ScrcpySocket protect against stale descriptor reuse and should not be removed merely to reduce a few local syscalls.

## Recommended improvements

### Improve the current wireless path

Use an existing 5 GHz network on the same LAN for a comparison run; use 6 GHz where both endpoints, the access point, and local availability support it. An Ethernet-connected Mac is another useful comparison because it removes the Mac's wireless hop. Repeat the same workload rather than assuming a particular speedup.

For the current connection, the existing Lower Bandwidth profile is the first application setting to try on a new session. An additional 1280-edge, 30 fps, 3–4 Mbps profile would be a sensible app experiment. Moving from 1920/60 to 1280/30 reduces the theoretical pixel-processing rate by about 77.8% at the same aspect ratio. That is not a measured CPU reduction. A frame-rate reduction alone does not guarantee lower network traffic when the encoder target stays fixed.

Keep WMM enabled and compare channel conditions. Apple recommends 20 MHz on 2.4 GHz and automatic channel selection; simply widening the existing 2.4 GHz channel can make interference worse. [Apple router settings](https://support.apple.com/en-us/102766).

### Add latency and bandwidth telemetry

Record encoded payload bytes per interval, received/decoded/submitted frame counts, frame sizes, decode duration, the age and count of pending decoded frames, renderer flushes, file source bytes, file wire bytes when available, and clipboard acknowledgement duration. Use monotonic clocks and bounded aggregates, without recording screen or clipboard content.

Keep ICMP RTT, control acknowledgement RTT, local decode delay, and absolute input-to-display latency distinct. Android presentation timestamps and the Mac clock do not share a proven origin. Their relative progression can reveal increasing backlog after a baseline, but direct subtraction does not establish absolute latency. Measure input-to-display latency with a controlled visual response and an external timing reference, or introduce an explicitly synchronized instrumentation protocol.

A low bitrate on an unchanged screen does not establish spare capacity. An estimator must distinguish low demand from congestion and combine workload information with queue and acknowledgement signals.

### Move packet processing off the main actor and bound decoded delivery

Give the socket reader, Annex-B parser, sample construction, and decoder submission one serialized worker outside the main actor. Preserve session-generation checks, decoder invalidation ordering, and endpoint leases. Deliver only the newest decoded frame through a bounded mailbox with at most one pending UI drain. This targets responsiveness and frame age, while avoiding a task for every frame when the UI is busy.

Dropping already-decoded presentation frames can keep the display current. Randomly discarding compressed H.264 frames can break reference dependencies. Decoder state and configuration packets still need correct handling. A bounded presentation queue also does not reduce bytes already sent over Wi-Fi; sender adaptation remains necessary.

The current display-immediately policy is appropriate to an interactive mirror. A fixed jitter buffer may improve smoothness but adds that delay to interaction. Make any added buffering an explicit measured tradeoff.

### Add adaptive profiles and upload pacing

Expose frame-rate selection and use a few coarse capture profiles with hysteresis: reduce load after sustained rising delay or backlog, then increase it cautiously after stability. A first version can restart the encoder/session with preserved window state and a clear setting application path. Avoid reacting to every resize or small network fluctuation.

True live bitrate adjustment needs Android server work. MediaCodec supports changing an encoder's target bitrate using setParameters and PARAMETER_KEY_VIDEO_BITRATE, but scrcpy 3.3.4's control protocol has no bitrate-change message. Its reset-video command does not add new option values. A server extension requires a separately versioned client/server contract and updated runtime integrity metadata. [MediaCodec bitrate parameter](https://developer.android.com/reference/android/media/MediaCodec#PARAMETER_KEY_VIDEO_BITRATE), [pinned control-message definitions](https://github.com/Genymobile/scrcpy/blob/v3.3.4/server/src/main/java/com/genymobile/scrcpy/control/ControlMessage.java).

Add a token bucket to the uploader, with a small burst allowance and a conservative starting rate while mirroring. Adjust it using changes in frame backlog and control acknowledgement latency. Offer a transfer-focused mode if users prefer faster files. Separate directional RAM results cannot simply be subtracted from each other to set this budget because Wi-Fi airtime is shared. Merely lowering the upload worker's CPU priority or setting a priority on its loopback socket does not reserve wireless capacity inside the shared ADB transport.

### Use compression and reduce file setup work

Negotiate SYNC v2 and select a fast compression method such as LZ4 or Zstd when content benefits. Use an uncompressed fallback for JPEG, HEIC, MP4, ZIP, and other files that typically compress little, based on a sample or actual compression ratio. Compression improves a network-bound transfer when saved bytes outweigh encoding and decoding costs. It should not be applied around the existing H.264 stream.

Keep separate counters for source progress, bytes transmitted, and final remote acknowledgement. Preserve early remote failures, cancellation, source-change detection, staging ownership, and atomic finalization. Existing compatibility should fall back to v1 when features are unavailable.

Cache the verified ABI and install a versioned helper once per verified session instead of twice per file. Revalidate or reinstall after recovery and retain safe ownership of the cached helper path. Small-file gains should be measured as end-to-end saved files per second, including preparation and finalization.

The measured 14.632 Mbps RAM median corresponds to about 1.83 MB/s. A decimal 1 GB payload would take approximately 9.1 minutes at that rate before storage and setup costs. This is an illustration of the measured path, not a prediction of the app's file-transfer performance.

### Evaluate native YUV output and codec options

Test supported bi-planar YUV output through VideoToolbox and the native renderer before forcing BGRA. At a reference 1080 × 1920 and 60 fps, BGRA represents about 498 MB/s of pixel bytes, while eight-bit NV12 represents about 187 MB/s before stride, reads, writes, or conversion work. The theoretical 62.5% difference is a raw pixel-storage calculation, not a demonstrated memory-bandwidth or network saving. Verify color range, rotation, screenshots, and display compatibility. Apple exposes supported pixel formats ordered by performance. [VideoToolbox pixel-format guidance](https://developer.apple.com/documentation/videotoolbox/kvtdecompressionpropertykey_supportedpixelformatsorderedbyperformance).

The app already sets the realtime decoder property. Passing a nil decoder specification does not establish software decoding: the installed Apple SDK explicitly states that hardware decoding is enabled by default on macOS 10.15 and later. Query UsingHardwareAcceleratedVideoDecoder to record what was actually selected. The temporal-processing flag permits delayed callbacks for display ordering; benchmark its necessity for this bitstream rather than removing it without checking frame dependencies. [Apple decoder selection](https://developer.apple.com/documentation/videotoolbox/kvtvideodecoderspecification_enablehardwareacceleratedvideodecoder), [hardware-decoder status](https://developer.apple.com/documentation/videotoolbox/kvtdecompressionpropertykey_usinghardwareacceleratedvideodecoder).

Add HEVC as an optional quality-per-bit experiment with automatic H.264 fallback. This needs a codec option, the correct codec metadata check, HEVC VPS/SPS/PPS handling, and an HEVC format description in the Mac decoder. Changing the launch argument alone will fail the current H.264 checks. Compare similar visual quality at different bitrates and measure interaction latency and thermal behavior. Upstream notes that H.265 may improve quality while H.264 should provide lower latency; a fixed percentage saving is not established for this app. [Scrcpy codec guidance](https://github.com/Genymobile/scrcpy/blob/v3.3.4/doc/video.md#codec).

### Bound control traffic

Coalesce redundant pending pointer-move events while preserving down/up ordering and accumulated scroll intent. The native UI currently sends each drag event directly. Keep the control queue bounded and instrument oldest-event age.

A maximum-size clipboard payload is about 262 KB. At an effective 2 Mbps it takes roughly 1.05 seconds of payload transmission alone; later input on that same byte stream cannot overtake it. A clipboard message cannot be interrupted by inserting another control message halfway through its bytes. For automatic sharing, consider deferring unusually large text while interactive input is active. Preserve explicit paste and the existing acknowledgement semantics.

## ADB burst mode

Without the negotiated delayed-ack feature, ADB acknowledges each logical stream's WRTE before sending its next one. An approximate upper bound is in-flight payload bytes divided by acknowledgement round-trip time; serialization and processing lower the achievable rate further. For illustration only, a 64 KiB window and a 68.567 ms round trip imply about 7.65 Mbps, whereas a 1 MiB window at that round trip implies about 122 Mbps before other limits. The uploader's 64 KiB SYNC chunks and ICMP RTT are not measurements of that window or of ADB acknowledgement timing.

ADB_BURST_MODE=1 allows a supporting host and device to negotiate a larger byte window. Nearby's owned-server setup provides a contained place for an experimental opt-in, set before starting that child. Feature negotiation must determine compatibility. The app currently does not set this option, and the observed feature lists confirmed that it was not active. [ADB burst-mode design](https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/docs/dev/delayed_ack.md), [feature gating in ADB](https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/transport.cpp).

The upstream document's roughly 70% improvement was a USB 3 file-push result. It is not a projected Wi-Fi or mirror improvement. A larger window can also permit more bulk data to queue, so test frame and control latency as well as throughput. Combine this experiment with upload pacing; keep it disabled if the gains are unreliable or interaction gets worse. It was not enabled during this research.

## Architecture alternatives

| Option | Potential benefit | Cost and decision |
| --- | --- | --- |
| Improve the existing Wi-Fi path and retain ADB | More usable airtime and more stable local timing, with the existing pairing and permission model | First comparison to run. Existing 5 GHz service or a wired Mac can be tested before purchasing hardware. |
| Optimize current native ADB client | Better responsiveness, controlled sharing, smaller file payloads, and reduced setup delay | Recommended next implementation scope. |
| Separate direct authenticated transports after ADB bootstrap | Could remove ADB per-stream acknowledgement limits and isolate bulk transfers from input at the transport level | Requires Android server changes, authentication, encryption, lifecycle handling, and a versioned protocol. It still shares radio airtime and needs congestion control. Benchmark only after lower-cost changes. |
| QUIC or a realtime media transport | QUIC can avoid transport head-of-line blocking between separate streams; datagrams or a realtime media stack allow deadline-oriented delivery designs | A reliable single QUIC video stream still waits for missing bytes within that stream. Real gains require framing, loss handling, feedback, encoder recovery, and Android/Mac implementations. This is not a switch supported by the bundled scrcpy server. [QUIC stream behavior](https://www.rfc-editor.org/rfc/rfc9000.html#section-13). |
| Optional USB transport | Removes the Wi-Fi radio bottleneck and provides a useful performance baseline | Requires explicit product support: Nearby currently filters out USB discovery. Actual throughput depends on the phone, port, cable, and protocol; nominal USB link rates are not file or video goodput. |

## Implementation order and validation

1. Establish a controlled baseline on the current network and an existing 5 GHz path or wired Mac. Compare the current 4/8/12 Mbps settings with sustained scrolling, a known animation, and an unchanged screen. Keep all non-network variables fixed.
2. Add telemetry, move packet processing off the main actor, and introduce a bounded decoded-frame mailbox. Use the same workload to identify whether frame age and UI stalls improve.
3. Add a 30 fps profile, coarse adaptive quality, and upload pacing. Compare mirror-only operation with concurrent large-file upload. Optimize for latency and correct completion rather than maximum bulk rate alone.
4. Add negotiated compressed SYNC and session helper caching. Compare compressible data, already compressed media, and batches of small files, including preparation, finalization, cancellation, and early storage failures.
5. A/B test optional burst mode, native YUV output, and HEVC separately. Promote each only when its benefit exceeds normal measurement variation and correctness remains intact.
6. Consider a new transport if controlled measurements still identify ADB acknowledgement behavior or shared transport queueing as a material residual bottleneck.

Collect multiple longer repetitions, median and tail frame/control latency, dropped presentation frames, encoded and file bytes per second, CPU/memory, and phone thermal state. A useful engineering target is that concurrent uploads produce little additional frame backlog or control-delay increase relative to mirror-only operation; the exact threshold should be chosen from those baseline measurements. End-to-end display timing needs its own measurement, not an assumed half of ping RTT.

Regression coverage should preserve the existing socket-lifetime, session-replacement, clipboard foreground/acknowledgement, cancellation, early/late storage failure, helper ownership, and no-overwrite guarantees. The short live measurements above establish a current-network reference. They do not validate sustained 60 fps, HEVC, burst mode, a replacement transport, or storage throughput.

Source links below point to the current files. The measurement JSON records hashes
of the historical source snapshot reviewed for this report.

[measurements]: network-performance-measurements.json
[stream-options]: ../Sources/Nearby/App/AppModel.swift
[settings]: ../Sources/Nearby/Settings/SettingsView.swift
[session-startup]: ../Sources/NearbyCore/Scrcpy/ScrcpySession.swift
[video-reader]: ../Sources/NearbyCore/Scrcpy/ScrcpySession.swift
[presentation]: ../Sources/NearbyCore/Scrcpy/ScrcpySession.swift
[decoder]: ../Sources/NearbyCore/Scrcpy/VideoDecoder.swift
[decoder-config]: ../Sources/NearbyCore/Scrcpy/VideoDecoder.swift
[sync-upload]: ../Sources/NearbyCore/Transfer/ADBSyncUpload.swift
[file-transport]: ../Sources/NearbyCore/Transfer/FileTransfer.swift
[control-queue]: ../Sources/NearbyCore/Scrcpy/ScrcpyTransport.swift
[clipboard-send]: ../Sources/NearbyCore/Scrcpy/ScrcpySession.swift
[transfer-helper]: ../scripts/nearby-transfer.c
