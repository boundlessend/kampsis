# Development

The local project builds Kampsis 0.4.3 (7). The published Homebrew cask remains on 0.2.0 until a separately approved release. Do not update its version, URL, or checksum to an unpublished package.

## Tools

Use an Apple silicon Mac and Xcode with the macOS 26 SDK or newer. Verified development environment: Xcode 27 / Apple Swift 6.4 on macOS 27.0.1. Other toolchains need their own verification. XcodeGen generates the ignored Xcode project from `project.yml`. Install it in your development environment before building. The app has no third-party runtime dependencies.

## Build

```sh
scripts/build.sh check
```

This builds Release without signing. The command prints its DerivedData location. Set `KAMPSIS_DERIVED_DATA` to reuse a task-specific directory; preserve needed test results before removing it.

For a distributable package, use the existing signing setup:

```sh
scripts/build.sh selfsigned
scripts/build-dmg.sh dist/Kampsis-v0.4.3-macos-arm64.zip
```

`selfsigned` needs the project's existing release identity and Keychain entry. Do not regenerate an existing identity. Passwords are injected through protected files and Security APIs; never put them in shell arguments or logs. Package scripts refuse to overwrite an existing output. Both ZIP and DMG contain the signed app and its bundled LICENSE.

Developer ID signing and notarization are separate release workflows in `build.sh` and `notarize.sh`.

## Tests

```sh
scripts/test.sh unit
scripts/test.sh all
```

`unit` runs pure decisions, motion, hardware parsing, settings persistence, and release checks without a GPU requirement. `all` includes controller integration, real Metal rendering, and cadence. It needs an active built-in MacBook display; test windows and overlays appear on the desktop. Avoid moving the lid during an automated cadence run. CI runs `unit` on macOS 26.

Choose unique result paths for each run:

```sh
KAMPSIS_DERIVED_DATA=/private/tmp/KampsisChecks \
KAMPSIS_TEST_RESULTS=/private/tmp/KampsisChecks/Tests.xcresult \
scripts/test.sh all
```

## Real capture

Quit any running copy before a command-line check. For each mode:

```sh
/Applications/Kampsis.app/Contents/MacOS/Kampsis --capture-check --capture-mode live
/Applications/Kampsis.app/Contents/MacOS/Kampsis --capture-check --capture-mode frozen
/Applications/Kampsis.app/Contents/MacOS/Kampsis --capture-check --capture-mode snapshot
```

These checks read the built-in display without saving its pixels. Running a binary from Terminal can attribute Screen Recording permission and the indicator to Terminal. For normal app-launch verification, use Finder or `open /Applications/Kampsis.app` and the app's real demo controls. Test the indicator and Dock through the actual UI, not process absence alone.

A diagnostic run uses `--diagnostics <local-json-path>`. It reports launch route, Terminal preference, capture mode/phase, source readiness, displayed frame number, GPU durations, and presentation intervals. The bounded presentation ring retains at most 1024 timestamps and GPU samples; it stores no screen pixels.

`firstFrameMilliseconds` measures source preparation including overlay setup. `presentation.firstVisibleMilliseconds` measures from the capture request to the first presented frame above the visibility threshold, including overlay/Metal preparation. In Live/Freeze it can include deliberate prewarming before the fold; it is not a physical sensor-to-photon latency measurement. GPU timestamps describe Kampsis command buffers, not total WindowServer work or battery drain.

## Compatibility checks

Record the Mac model, macOS build, app version/build, mode, launch route, permissions, and exact result for every check. Use the local task's verification log for measured results rather than treating a planned check as passed.

On each available machine, test all three modes with normal app launch: demo, cancellation during preparation, switching modes during the effect, effect off/on, full-screen synthetic content, sleep/wake, lock/unlock, and external display changes. Where hardware or system access is unavailable, record **not tested**. Controller event-injection tests exercise the same sleep handlers without posting fake system-wide lock notifications.

Manual lid check: with the effect enabled, slowly cross the fade-out angle, pause below it, open fully, then close and reopen more quickly. Verify that each new Snapshot/Freeze fold obtains a fresh picture, the effect follows the lid, and the pointer stays visible in Live and returns after the effect in Freeze/Snapshot. Repeat with Reduce Motion enabled. The demo does not replace this mechanical check.

For a sustained comparison use changing synthetic content, alternate mode order, record per-process CPU/footprint and GPU timing, and inspect idle recovery after repeated cycles. Estimated SoC power needs the system `powermetrics` tool and a user-run privileged measurement. Never replace a rejected privileged command with another tool or infer energy use from CPU percentages.
