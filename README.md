<p align="center">
  <img src="assets/icon-master.png" width="160" height="160" alt="Kampsis icon">
</p>

# Kampsis

[Русский](README.ru.md) · English

Your desktop folds, blurs and dims as you close your MacBook lid. Open it again and the screen returns to normal.

## Install

Requires macOS 26 or later and a MacBook with Apple silicon and a lid angle sensor. This version is verified on Mac17,3; other models are experimental. The effect appears only on the built-in display.

1. Download **Kampsis-v0.4.3-macos-arm64.dmg** from [Releases](https://github.com/boundlessend/kampsis/releases/latest).
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
- Choose **Show Demo** to see a five-second demonstration on your desktop.
- In **General Settings**, choose launch at login, an opening sound, and whether to show the Dock and menu bar icons. Launch at login runs in the background without opening a window. **Customize Effect…** returns to the effect window.
- English is the default language. To switch to Russian, choose **Language → Русский** in **General Settings**, then reopen Kampsis.

The Dock icon is hidden by default; the menu bar icon is visible. If you hide both, open Kampsis from **Applications** to bring back General Settings.

## Desktop image modes

Kampsis 0.4.3 offers three ways to obtain the desktop image:

- **Single Snapshot** takes one picture at the start of the fold without a continuous stream. It is the default for new settings. On the verified Mac17,3/macOS 27.0.1, it worked without the persistent purple capture indicator or Terminal in the Dock. macOS controls the indicator; other systems are unverified.
- **Live Desktop** prepares capture during lid movement and updates the picture throughout the fold.
- **Freeze at Fold Start** prepares a stream, holds the picture at the start of the fold, and stops the stream. A new fold obtains a new picture.

Choose the mode in **General Settings → Screen Access → Desktop Image**. An existing saved choice is preserved. Slider preview uses a sample desktop; **Show on Screen** uses the selected capture mode.

The system pointer stays visible in Live Desktop. Freeze and Single Snapshot hide it while the held picture is shown, then restore it when the effect ends.

**Use experimental Terminal launch** is optional for Live and Freeze and is unavailable for Single Snapshot. It may hide the stream indicator on some macOS versions. It needs permission for Kampsis to control Apple Terminal and for Terminal to record the screen; that screen access also applies to other commands run in Terminal. Kampsis closes its launch window and preserves existing Terminal windows. Terminal may remain in the Dock while Kampsis runs. Selecting Single Snapshot returns to the normal app launch. A macOS update may stop the workaround from hiding the indicator.

Unreadable effect settings leave the effect off and show a recovery message. **Reset Effect Settings…** replaces that record only after confirmation; the effect remains off until you enable it.

Build instructions and verification commands are in [Development](docs/DEVELOPMENT.md).

## Updates

Choose **Check for Updates…** from the menu, or enable daily checks in General Settings. Daily checks show available versions in the menu and General Settings without opening a dialog. Download the new version and replace Kampsis in Applications. Your settings stay in place.

## Privacy

No account, analytics or screenshot storage. Screen images stay in your Mac's memory and are never uploaded. Audio is not captured. Capture stops when the effect is off or your Mac sleeps or locks.

Update checks contact GitHub to read release information. You can turn automatic checks off.

## Good to know

Kampsis changes how the desktop looks; apps and their click targets stay in place. External displays are unaffected. Protected video may not appear in the effect. Your MacBook still sleeps normally when the lid closes.

If the effect does not work, open **General Settings**, check **Screen Recording** and the sensor status, then click **Check Again**. **Copy Diagnostics** copies a technical report without screenshots for a problem report.

[Report a problem](https://github.com/boundlessend/kampsis/issues) · [License](LICENSE)
