<p align="center">
  <img src="assets/icon-master.png" width="160" height="160" alt="Kampsis icon">
</p>

# Kampsis

[Русский](README.ru.md) · English

Your desktop folds, blurs and dims as you close your MacBook lid. Open it again and the screen returns to normal.

![Live, Frozen and Snapshot on the same generated desktop](assets/readme/desktop-modes.gif)

[Watch the MP4](assets/readme/desktop-modes.mp4) for the recorded motion, or open the [static preview](assets/readme/desktop-modes-poster.png). The GIF is a reduced preview. This is an on-screen demo using generated content, not footage of physical lid movement. Frozen and Snapshot intentionally look similar; their capture paths differ, as explained below. These demos were recorded with 0.4.3 and show its earlier brightening and ghosting during return. Version 0.4.5 aligns the picture before replacing it without a crossfade.

## Install

Requires macOS 26 or later and a MacBook with Apple silicon and a lid angle sensor. This version is verified on Mac17,3; other models are experimental. The effect appears only on the built-in display.

1. Download **Kampsis-v0.4.5-macos-arm64.dmg** from [Releases](https://github.com/boundlessend/kampsis/releases/latest).
2. Open the image and drag **Kampsis** into **Applications**.
3. Launch Kampsis. If macOS blocks it, go to **System Settings → Privacy & Security → Open Anyway**. The app uses the project's own signing certificate and is not notarized by Apple.
4. Click **Allow Screen Access…** and enable Kampsis in **Screen Recording**. Restart the app if macOS asks.

To install the published version with Homebrew:

```sh
brew tap boundlessend/kampsis https://github.com/boundlessend/kampsis
brew install --cask boundlessend/kampsis/kampsis
```

To update it later, quit Kampsis, then run `brew update` and `brew upgrade --cask boundlessend/kampsis/kampsis`. Homebrew may ask you to trust this third-party tap; inspect the cask before accepting.

## Use

- **Left-click the menu bar icon** to turn the effect on or off. **Right-click** to open the menu. The icon dims when the effect is off.
- Press **⌘⌥B** to toggle the effect. Change the shortcut in **General Settings**.
- Open **Customize Effect…** to choose **Soft**, **Deep** or **Matte**, adjust the bend, blur and dimming, and try the preview.
- **Effect timing** controls how early the effect develops as the lid closes. **Lid anticipation** responds ahead of the measured angle during movement; select **Lid** in the preview or click **Try with Lid** to test it. Anticipation does not affect the slider preview or demo.
- Choose **Show on Screen** to see a five-second demonstration on your desktop.
- In **General Settings**, choose launch at login, an opening sound, and whether to show the Dock and menu bar icons. Launch at login runs in the background without opening a window. **Customize Effect…** returns to the effect window.
- English is the default language. To switch to Russian, choose **Language → Русский** in **General Settings**, then reopen Kampsis.

The Dock icon is hidden by default; the menu bar icon is visible. If you hide both, open Kampsis from **Applications** to bring back General Settings.

## Desktop image modes

Choose a mode in **General Settings → Screen Access → Desktop Image**. New settings use Single Snapshot; an existing choice is preserved.

| Mode | What you see during the fold | Pointer | Choose it when |
|---|---|---|---|
| **Single Snapshot** | One picture from the start of each fold; no continuous stream | Hidden until the effect ends | You want a still-image effect with the normal app launch |
| **Live Desktop** | The desktop keeps updating | Visible | You want to see video, window movement or other changes during the effect |
| **Freeze at Fold Start** | A prepared frame is held; its stream stops | Hidden until the effect ends | You prefer a prepared image that stays still during the fold |

In Frozen and Snapshot, apps still receive input, but changes underneath become visible only after the effect ends. Let the image return before precise clicking. Live keeps updating, but click targets remain in their original positions while the image bends.

Slider preview uses a sample desktop; **Show on Screen** uses the selected mode. On Mac17,3/macOS 27.0.1, Snapshot worked without a persistent purple capture indicator or Terminal in the Dock. macOS controls the indicator; other systems are unverified.

**Use experimental Terminal launch** is optional for Live and Freeze and is unavailable for Single Snapshot. It may hide the stream indicator on some macOS versions. It needs permission for Kampsis to control Apple Terminal and for Terminal to record the screen; that screen access also applies to other commands run in Terminal. Kampsis closes its launch window and preserves existing Terminal windows. Terminal may remain in the Dock while Kampsis runs. Selecting Single Snapshot returns to the normal app launch. A macOS update may stop the workaround from hiding the indicator.

Unreadable effect settings leave the effect off and show a recovery message. **Reset Effect Settings…** replaces that record only after confirmation; the effect remains off until you enable it.

Build instructions and verification commands are in [Development](docs/DEVELOPMENT.md).

## Compatibility

| Mac / macOS | What has been checked |
|---|---|
| Mac17,3 / macOS 27.0.1 | Lid sensor readings, desktop demos in all three modes, capture and pointer behavior |
| macOS 26 | CI build and tests without hardware; desktop effects on a physical Mac have not been checked |
| Other Apple silicon MacBooks with a lid angle sensor | Experimental; no broad hardware verification |
| Intel Macs or Windows | Not supported by this release |
| External display | The effect targets the built-in screen; external-display transitions have not been checked on hardware |

New slow/fast physical lid checks, real sleep/lock transitions and Reduce Motion checks are still pending. Automated controller-event tests do not replace those checks. Find your model identifier in **General Settings → Status** or **Copy Diagnostics**.

## Resource use

On the checked Mac, 90 repeated demos used about 86 MiB before the run, peaked at 507 MiB and settled at 184 MiB after ten minutes idle. Memory was stable during that idle window but did not return to the initial level; caches and leaks are not separated.

![Memory before, during and after repeated demos](assets/readme/memory.png)

This is one local run with a heavy Matte look. Short demos averaged about 59-60 FPS with occasional longer frame gaps; the power readings describe the whole Mac, not battery savings. [Method, numeric data and limitations](docs/PERFORMANCE.md).

## Similar projects

A feature comparison, checked on 2026-10-09. macOS requirements below are declared by each project; the other apps were not run in our benchmarks

| App | What it offers | Declared macOS |
|---|---|---|
| Kampsis 0.4.3 | Live/Frozen/Snapshot choice; Soft/Deep/Matte; English/Russian; DMG or Homebrew | 26+ |
| [Lid Plane](https://github.com/jh3y/lid-plane/blob/ba290ffc1ade87325b93133374c0d12197bac6c2/README.md) | Live picture; perspective and blur | 13+ |
| [Mac Duo](https://github.com/Toketec/mac-duo/blob/b29c9ccbc7291a8a53ede162e65cb4cbf50527b9/README.md) | Live picture; fold range and preview | 14+ |
| [Foldbook](https://github.com/shivamchopra7/Macbook-Duo-App/blob/5488d821e05c6cd3148cab0157e725cff6894a63/README.md) | Live picture; 12 effects | 13+ |
| [macTilt](https://github.com/lqSky7/iphone-duo-macos-animation/blob/a1745b9159d64fae38038b24d5d0e5fcb09f2ce3/README.md) | Held picture; tilt settings | 14+ |
| [Bendable](https://github.com/opensourcevillain/Bendable/blob/13848be18f16ce9239f1e719e4e1f62b18dd6787/README.md) | Single still for desktop styles; 9 styles | 14+ |
| [Shut](https://github.com/notthamer/shut/blob/667e3e5582affa035e5d46cfa915c0210d6544f2/README.md) | Single still for desktop styles; 8 styles and presets | 14+ |

Kampsis offers a choice of image behavior. Some alternatives offer more effects or support older macOS versions. There is no measured performance or battery ranking. [Source versions and details](docs/COMPARISON.md).

## Updates

Choose **Check for Updates…** from the menu, or enable daily checks in General Settings. Daily checks show available versions in the menu and General Settings without opening a dialog. Download the new version and replace Kampsis in Applications. Your settings stay in place.

## Permissions and privacy

| Access | Why it is needed |
|---|---|
| Screen Recording for Kampsis | Read the built-in display to draw the effect, including Single Snapshot |
| Automation of Terminal and Screen Recording for Terminal | Only for the optional experimental Terminal launch; Terminal screen access also covers other commands run there |
| GitHub connection | Read release information when checking for updates; automatic checks can be disabled |

The normal effect does not need a camera, microphone, Accessibility or Input Monitoring permission. No account, analytics or screenshot storage. Screen images stay in your Mac's memory and are never uploaded; audio is not captured. Capture stops when the effect is off or your Mac sleeps or locks. The optional Terminal launch does not grant Kampsis an official way to control macOS privacy indicators.

## Good to know

Protected video may not appear in the effect. Your MacBook still sleeps normally when the lid closes.

If the effect does not work, open **General Settings**, check **Screen Recording** and the sensor status, then click **Check Again**. **Copy Diagnostics** copies a technical report without screenshots for a problem report.

[Report a problem](https://github.com/boundlessend/kampsis/issues) · [License](LICENSE)
