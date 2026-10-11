# Similar projects

Checked on 2026-10-09. This is a feature comparison of the linked documentation and inspected source versions. Third-party applications were not run in our performance tests. Their macOS requirements are declared by their maintainers; hardware support needs a separate check

| App | Desktop image during the fold | Controls and scope | Declared macOS |
|---|---|---|---|
| Kampsis 0.4.3 | Choose Live, Frozen or Snapshot | Soft/Deep/Matte; bend, blur, dimming, timing; English/Russian; DMG or Homebrew | 26+ |
| [Lid Plane](https://github.com/jh3y/lid-plane/blob/ba290ffc1ade87325b93133374c0d12197bac6c2/README.md) | Live desktop | Perspective and progressive blur; angle or movement controls | 13+ |
| [Mac Duo](https://github.com/Toketec/mac-duo/blob/b29c9ccbc7291a8a53ede162e65cb4cbf50527b9/README.md) | Live desktop | Perspective/blur; animation range and one-click preview | 14+ |
| [Foldbook](https://github.com/shivamchopra7/Macbook-Duo-App/blob/5488d821e05c6cd3148cab0157e725cff6894a63/README.md) | Live desktop | 12 effects, motion/look controls and preview | 13+ |
| [macTilt](https://github.com/lqSky7/iphone-duo-macos-animation/blob/a1745b9159d64fae38038b24d5d0e5fcb09f2ce3/README.md) | Picture held during fold | Tilt thresholds, preview; timed opening without an angle sensor | 14+ |
| [Bendable](https://github.com/opensourcevillain/Bendable/blob/13848be18f16ce9239f1e719e4e1f62b18dd6787/README.md) | Single still for desktop styles | 9 styles; some work without screen access; hinge settings | 14+ |
| [Shut](https://github.com/notthamer/shut/blob/667e3e5582affa035e5d46cfa915c0210d6544f2/README.md) | Single still for desktop styles | 8 styles; adjustable dials and import/export of presets | 14+ |

Kampsis lets you choose whether the image keeps updating or holds still, independently of the bend, blur and dimming look. Some alternatives offer a larger selection of effects or work with older macOS versions. Shared mechanisms such as Metal rendering, blur caching and prewarming are not unique advantages

## Source versions and capture paths

The image behavior below is an inference from the inspected capture implementation. It describes desktop-redrawing styles, not every preset or behavior on unsupported hardware

- Lid Plane: [ba290ff](https://github.com/jh3y/lid-plane/blob/ba290ffc1ade87325b93133374c0d12197bac6c2/Sources/LidPlane/DesktopCapture.swift). Live desktop.
- Mac Duo: [b29c9cc](https://github.com/Toketec/mac-duo/blob/b29c9ccbc7291a8a53ede162e65cb4cbf50527b9/Sources/MacDuo/DesktopCapture.swift). Live desktop.
- Foldbook: [5488d82](https://github.com/shivamchopra7/Macbook-Duo-App/blob/5488d821e05c6cd3148cab0157e725cff6894a63/Sources/MacbookDuo/Capture/DesktopCapture.swift). Live desktop.
- macTilt: [a1745b9](https://github.com/lqSky7/iphone-duo-macos-animation/blob/a1745b9159d64fae38038b24d5d0e5fcb09f2ce3/Sources/OverlayWindowController.swift). Picture held during fold.
- Bendable: [13848be](https://github.com/opensourcevillain/Bendable/blob/13848be18f16ce9239f1e719e4e1f62b18dd6787/Bendable/Overlay/ScreenCapture.swift). Single still for desktop styles.
- Shut: [667e3e5](https://github.com/notthamer/shut/blob/667e3e5582affa035e5d46cfa915c0210d6544f2/Sources/TransitionKit/ScreenCapturer.swift). Single still for desktop styles.

## Limits of the comparison

We have not measured these projects on the same Mac under the same workload, so there is no speed, memory or battery ranking. Kampsis measurements describe Kampsis modes only. Screen-capture indicators are controlled by macOS; absence of a custom indicator workaround in inspected source does not prove its runtime behavior

Kampsis currently requires a readable lid angle sensor. Bendable, macTilt and Shut document timed behavior when only lid-open/lid-closed events are available. That is a useful alternative for some machines, rather than continuous angle tracking
