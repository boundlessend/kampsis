# Kampsis

A macOS menu bar app. When you lower your MacBook lid, the desktop on the built-in display folds away in perspective, frosts over and dims. Open the lid and the screen is back to normal.

## Features

- Three styles: soft, deep and matte. Bend, blur, dimming and the angle where the effect fades out are adjustable on their own.
- A preview on a sample desktop: the angle comes from a slider or from the lid itself.
- A five second demo on the real screen.
- A keyboard shortcut, <kbd>⌘</kbd><kbd>⌥</kbd><kbd>B</kbd> by default, turns the effect on and off and stops the demo. You can change it in General Settings.
- Optional: a click when the lid opens, and launch at login.
- New releases are checked on GitHub, manually or once a day.
- Screen capture and rendering only run while the effect may be needed.

## Requirements

- macOS 26 or newer, a Mac with Apple silicon.
- A MacBook with a lid angle sensor, see the table below.
- Screen recording permission. Without it only the preview works.
- The effect appears on the built-in display only, external monitors are left alone.

### Which MacBooks work

An M-series chip alone does not guarantee the sensor. The list is based on data from the [LidAngleSensor](https://github.com/samhenrigold/LidAngleSensor) project.

| Models | Lid angle sensor | With Kampsis |
| --- | --- | --- |
| 14″ and 16″ MacBook Pro with Apple silicon, 2021 and later | yes | sensor reading verified on a Mac17,3 |
| MacBook Air with M2, M3, M4 | yes | untested; on some models the angle is not exposed over standard HID |
| MacBook Air with M1 | no, open or closed only | preview and demo work |
| 13″ MacBook Pro with M1 and M2 | no | preview and demo work |
| Intel MacBook | some models have it | builds are Apple silicon only |

New models are not blocked by that list: the sensor is detected at launch. `scripts/diagnose-lid.sh` prints a compatibility report. The script only reads the model, the macOS version and the list of Apple HID devices.

## Installing

### DMG image

1. Download `Kampsis-vVERSION-macos-arm64.dmg` from [releases](https://github.com/boundlessend/kampsis/releases) and drag the app into Applications.
2. On first launch macOS says it cannot verify the app. Open System Settings → Privacy & Security and click Open Anyway. This happens because the build is signed with the project's own certificate rather than an Apple Developer ID.
3. In the Kampsis window click Allow Screen Access… and turn Kampsis on under Screen Recording. Restart the app if macOS asks you to.

The image carries the same instructions, and they open without an internet connection.

## Updates

Check for Updates… in the menu compares the installed version with the latest GitHub release and opens the release page when a newer one exists. On first launch Kampsis asks whether to check once a day; you can change the answer in General Settings. A new version is installed the same way as the first one, by replacing the app. Every release is signed with the same certificate, so screen recording permission survives an update.

## Privacy

- No accounts, no analytics, no crash reporting.
- Frames of the built-in display are processed in memory through ScreenCaptureKit and Metal and never written to files. Audio, the microphone and the cursor are not captured. The effect window is excluded from capture; open settings windows stay in the picture.
- Capture stops when the effect is off, when the Mac sleeps or is locked, and shortly after the lid opens past the fade-out angle.
- Settings live in UserDefaults, the lid angle is read locally over HID.
- Checking for updates makes a request to `api.github.com`. GitHub sees the usual connection details, such as an IP address. Neither the image nor the settings are part of that request.

## Limitations

- The effect is drawn on top of the screen: windows and click targets underneath do not move.
- The frost is drawn by the app's own shader, it is not the system Liquid Glass material.
- The sensor report format is not documented by Apple as a public contract and may change.
- Hiding the cursor above other apps' windows relies on an undocumented WindowServer connection property. Without it the cursor stays visible over foreign windows.
- Capture runs in SDR, up to 2560 points wide and 60 frames per second. Rendering goes up to 120 frames on ProMotion displays, but that is not guaranteed on every Mac.
- Protected content may be missing from the capture. Sleep and screen behaviour with a closed lid stay with macOS.

## Development

You need a Mac with Apple silicon on macOS 26, Xcode 26 and XcodeGen (`brew install xcodegen`). The Xcode project is generated from `project.yml` and is not part of the repository.

```sh
xcodegen generate
open Kampsis.xcodeproj
```

Where things live:

- `Kampsis/Core`: pure logic without system calls (settings, lid angle estimation, capture decisions, sensor parsing, versions).
- `Kampsis/System`: connectors to IOKit, ScreenCaptureKit, Carbon, WindowServer and GitHub.
- `Kampsis/Render`: the shader, the blur, the Metal surface and the sample desktop.
- `Kampsis/App` and `Kampsis/UI`: state, orchestration and the SwiftUI interface.

### Tests

```sh
scripts/test.sh unit   # logic; no GPU and no screen, this is what CI runs
scripts/test.sh all    # plus GPU rendering and smoothness on the built-in display
```

The full run needs a MacBook with an unlocked screen. Test windows and a full-screen animation cover the desktop for a while.

### Building

```sh
scripts/build.sh check          # unsigned, just check that it builds
scripts/build.sh adhoc          # a local copy without a certificate
scripts/build.sh selfsigned     # a release signed with the project certificate
scripts/build.sh development    # an Apple Development certificate
scripts/build.sh developer-id   # Developer ID; then scripts/notarize.sh
```

The `development` and `developer-id` modes take the certificate from `KAMPSIS_SIGN_IDENTITY` and the team from `KAMPSIS_TEAM_ID`. Archives and checksums appear in `dist/`, existing files are never overwritten. An ad-hoc signature changes its hash on every build, so macOS asks for screen recording permission again after each update.

To investigate hardware problems the app can be launched with `--diagnostics /path/to/status.json`: once a second it writes the sensor state, the capture state and frame counters there, but never the image.

`--capture-check` replaces the app with a one-off capture test: with no windows open it starts the stream, then prints how long the stream took to start, the size and pixel format of the first frame, and how far frames lag behind their own timestamps. Run it from the installed copy so that screen recording permission applies:

```sh
/Applications/Kampsis.app/Contents/MacOS/Kampsis --capture-check
```

ScreenCaptureKit only sends a frame when the picture changes, so `frames: none` on a still desktop is normal, not a failure.

Screen recording permission belongs to the app responsible for the process, and for a command started in a terminal that is the terminal itself. So `granted` in the check can mean the terminal's permission rather than the app's. To see what the app itself is allowed, launch Kampsis normally and read the status line, or `--diagnostics`.

### Release certificate

macOS ties screen recording permission to the app signature. So that updates do not reset that permission, every release is signed with one self-signed certificate, without changing system trust.

- `scripts/create-signing-identity.sh` runs once in the lifetime of the project. It puts the public certificate into `signing/kampsis-release.crt` for the repository, the private part into `~/Library/Application Support/Kampsis/Signing/identity.p12`, and the password into the keychain.
- Keep a backup copy of `identity.p12` and the password outside the repository. Creating a new certificate resets screen recording permission for every existing installation.
- `scripts/sign-selfsigned.sh` signs through a pinned version of rcodesign, and `scripts/verify-release-signature.sh` checks that the signature really comes from that certificate.

### Release

1. Raise `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`.
2. `scripts/build.sh selfsigned`
3. `scripts/build-dmg.sh dist/Kampsis-vVERSION-macos-arm64.zip` (needs `uv`)
4. Create a `vVERSION` release on GitHub with the DMG and its `.sha256`.

## Vulnerabilities

Report through a private security advisory on GitHub. If that is unavailable, open an issue asking for a private contact, without details. Fixes ship for the latest version only.
