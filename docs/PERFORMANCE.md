# Local performance checks

These results describe Kampsis 0.4.3 (7) on one Mac17,3 running macOS 27.0.1 (26A434). They do not rank other projects or predict battery life. The preset was Matte: bend 65%, blur 90%, dimming 25%, fade-out angle 75 degrees. The app used its normal launch route

## Repeated use and memory

A fresh app process ran 90 five-second on-screen demos, 30 in each mode, with alternating orders. A generated moving pattern stayed present during a one-minute baseline, all demos and ten minutes of idle recovery. Physical footprint was sampled from the process with the native libproc helper; the plot uses raw samples without smoothing

![Memory during 90 demos and ten minutes idle](../assets/readme/memory.png)

| Measurement | Physical footprint |
|---|---:|
| Baseline median | 86.2 MiB |
| Largest observed sample | 507.5 MiB |
| Median of the final 30 seconds after ten minutes idle | 183.7 MiB |

Memory did not keep increasing during the ten-minute recovery, but it stayed 97.6 MiB above the baseline. The plot does not separate reusable caches from leaks. Idle minute medians were nearly flat: about 183.8 MiB in the first minute and 183.7 MiB in the last. This is an observation from one run, not a guarantee for long sessions, every effect or another Mac

[Numeric trace](../assets/readme/memory-trace.csv) contains elapsed time, phase, trial index and footprint only. No screen pixels, lid readings, process names or absolute timestamps are included. Physical footprint is the OS-reported charge for this app process, not total system RAM or a heap-only leak measurement

## Short demos and estimated power

A separate run used 27 five-second demos, nine per mode, in three alternating orders. The same synthetic content and settings were used throughout. A user-started powermetrics capture collected CPU/GPU power and thermal state; process CPU and rendering timings were collected independently

| Mode | Median app CPU, % of one core | Median estimated CPU+GPU power of the whole Mac | Median presented FPS | GPU command p50 |
|---|---:|---:|---:|---:|
| Live | 12.30% | 3.52 W | 59.59 | 12.95 ms |
| Frozen | 12.14% | 2.26 W | 59.39 | 13.82 ms |
| Snapshot | 12.36% | 2.32 W | 59.59 | 13.85 ms |

Each power value summarizes nine demos, using only complete one-second intervals within the observed demo. The plist timestamps have whole-second precision, so a one-second safety margin excludes intervals near the end. Only two to four power samples remained per demo

The Mac's baseline power medians were 1.93 W before and 1.61 W after the run, with occasional spikes as high as 12.57 W. Their causes were not identified. All sampled thermal states were Nominal. Frozen and Snapshot cannot be reliably ranked from this small, noisy sample

The reported watts estimate CPU/GPU subsystems of the entire Mac, excluding some other consumers such as the display. They are not the app's own watts or a battery-life prediction. GPU command durations cover Kampsis command buffers, not all WindowServer work. Capture, diagnostics and automation have overhead, and other background tasks were not isolated

Individual presentation gaps reached about 50-67 ms despite averages near 60 FPS. Static modes did not reproduce the earlier lower GPU-command timings in this run. First visible demo frames took median 269/255/233 ms for Live/Frozen/Snapshot; these include preparation and do not measure physical sensor-to-photon latency

## What remains unverified

New physical lid sweeps, other Macs, real sleep/lock transitions and external-display transitions remain untested in these checks. Source and permission behavior is described in the README, with hardware limits marked separately. No third-party app ran under this same measurement protocol

These are local checks dated 2026-10-09. The media demonstration is a recorded on-screen demo on generated content, not footage of the physical lid. Its output frame rate is not a performance measurement

## Recorded demo limitation

The 0.4.3 recordings include brief brightening and ghosting as the held picture returns to the current desktop. One visible case is Frozen at 12.4 seconds in the comparison video, corresponding to 6.6 seconds in the untouched source clip. This is not an edit between modes. Version 0.4.5 removes partial-alpha desktop blending and aligns the held picture before replacing it. The existing media remains a record of 0.4.3; physical lid behavior has not been rechecked

## Follow-up validation of the 0.4.5 changes

A separate check dated 2026-10-11 used the real controller and Metal renderer with synthetic 2560x1664 frames instead of ScreenCaptureKit. It ran 30 complete five-second demos, ten per mode, followed by one minute idle. Every stop released the overlay surface, and the next demo rendered again

| Measurement | Physical footprint |
|---|---:|
| Baseline before the demos | 35.6 MiB |
| Largest observed sample | 423.4 MiB |
| Median of the final 30 idle seconds | 43.2 MiB |

The final footprint was 7.6 MiB above baseline; those remaining allocations were not classified. Metal allocations returned to 7.4 MiB by the fifth idle second. This validates overlay cleanup, not a percentage improvement against the earlier 90-demo run: the process, capture source, repetition count and recovery duration differ. It does not establish ScreenCaptureKit memory use, battery savings or a comparison with another app

All 77 project tests passed, including GPU return brightness, opaque-or-clear presentation, alignment at three pace settings, and overlay cleanup followed by another demo in each mode. These checks do not replace physical lid tests
