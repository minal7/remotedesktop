# Local remote-desktop latency probe

Runs two native WebRTC peers on the same Mac and presents an animated source
pattern plus a local Metal viewer. The full main display travels through the
repository's `ScreenCapture.swift`, `DesktopVideoQuality.swift`, H.264 codecs,
and sender policy. The current installed host app is not replaced or restarted.

```sh
LATENCY_SECONDS=60 LATENCY_OUTPUT=/tmp/latency-run-1.json \
  ./script/latency/run_local_latency.sh
python3 ./script/latency/summarize_latency.py /tmp/latency-run-1.json
```

The invoking terminal/task must already have Screen Recording permission. The
probe checks permission and fails without changing macOS privacy settings.
It uses the selected Xcode installation by default; set `DEVELOPER_DIR`
for another Xcode installation. `WEBRTC_FRAMEWORK_DIR` can select the parent
of a cached macOS `LiveKitWebRTC.framework` from the project's pinned package.
The standalone bundle runs as a diagnostic child of the invoking terminal so
it uses that process's existing capture authorization. No desktop pixels are
saved, and no input is injected. Two temporary floating windows close at exit.

## What is measured

- **Software compositor-to-compositor latency:** a 16-bit counter and its
  bitwise complement appear in 32 black/white cells, changing approximately
  10 times per second. A second ScreenCaptureKit stream observes the source
  and the rendered viewer in each frame. Matching first appearances of the
  same counter yields a display-to-display software proxy. Both timestamps
  come from `SCStreamFrameInfo.displayTime` in one WindowServer clock domain.
- **Capture PTS to decoded-frame callback:** the first production-capture
  sample carrying each counter is matched to its first decoded appearance.
- **Decoded-frame callback to viewer compositor:** the remaining time until
  that counter first appears in the captured Metal viewer.
- **WebRTC stages:** differences of cumulative statistics across the measured
  interval provide average encoder time, decoder time, and jitter-buffer time.

There is a five-second warm-up **after the first decoded frame**. Raw JSON
contains every source marker, including any that never arrive, for explicit
coverage checks. Percentiles use the nearest-rank convention. No RTT/2 estimate
is substituted for a video measurement.

The report also includes outbound bitrate over the second after the first
second of decoded video, and mean local 8×8-block luma SSIM for a fixed 12 pt
synthetic text area, two seconds after the animation stops. Only that synthetic
crop is held in memory for the comparison; no pixels are written to disk.
`LATENCY_BUILD_ONLY=1` compiles without starting capture.

## Interpretation

This is **not an optical glass-to-glass measurement**. It stops at WindowServer
presentation, before physical scanout and pixel response. It exercises a local
Mac receiver; it does not establish iOS, Wi-Fi, WAN, or input-to-photon latency.
Both peers, animated source, mirrored desktop, and observation stream share the
same CPU/GPU. Audio and CloudKit signaling are outside the benchmark. The
viewer appears inside the captured desktop, so the workload includes recursive
mirror content. Other visible desktop activity can affect encoding complexity.

`LATENCY_OBSERVER_FPS` defaults to 120; the actual interval distribution is saved.
Each first-seen event is quantized to an observation frame. An individual
latency therefore has uncertainty on the order of an observation interval,
which must be taken from the result rather than assuming a perfect 120 Hz.
A lower observer rate can be used to check measurement-load sensitivity.

Apple defines `displayTime` as when WindowServer displays a frame:
[Apple documentation](https://developer.apple.com/documentation/screencapturekit/scstreamframeinfo/displaytime).
WebRTC buffer and codec statistics are defined in the
[W3C statistics specification](https://www.w3.org/TR/webrtc-stats/).
