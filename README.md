# SandGuide Camera

An iOS app that streams synchronized color images, metric depth, and camera
intrinsics from the front TrueDepth camera to a desktop computer over Wi-Fi or
USB. It supplies the camera data for SandGuide's material excavation and molding
guidance, including surface calibration, material zeroing, and STL comparison.

This repository contains the iPhone sender. A compatible SandGuide desktop
receiver is required to display the cut/fill overlay and load STL models.

## Features

- Front TrueDepth capture through AVFoundation; compatible hardware includes
  the iPhone 11. Rear LiDAR is not required.
- Synchronized RGB and depth frames, with camera intrinsics scaled to the RGB
  image dimensions.
- JPEG color images and little-endian Float32 depth maps in meters.
- Wi-Fi streaming to a desktop TCP receiver, or USB streaming through a local
  TCP forwarder.
- Capture targeting approximately 15 frames per second, with frame dropping
  when the network cannot keep up.

## Requirements

- A TrueDepth-equipped iPhone running iOS 15 or later.
- Camera permission and local network permission.
- A compatible desktop receiver on Windows or Linux.
- For USB: a data cable, Apple's device-support components on Windows or
  `usbmuxd` on Linux, and [pymobiledevice3](https://github.com/doronz88/pymobiledevice3).
- For a local iOS build: macOS, Xcode 16 or later, and
  [XcodeGen](https://github.com/yonaskolb/XcodeGen).

## Build and install

### GitHub Actions

Run **Actions → Build free iPhone camera app → Run workflow**. The
[build workflow](.github/workflows/build-iphone.yml) compiles the app for a
physical iPhone and produces the **SandGuideCamera-unsigned** artifact.
Extract the artifact to obtain `SandGuideCamera-unsigned.ipa`.

The IPA requires signing before installation. On Windows,
[Sideloadly](https://sideloadly.io/) can sign and install it using an Apple ID.
Free Apple ID signing normally requires refreshing every seven days. On iOS 16
or later, enable Developer Mode when prompted and approve the developer profile
on the phone if required.

### Local Xcode build

From the repository root:

```bash
brew install xcodegen
cd ios
xcodegen generate --spec project.yml
open SandGuideCamera.xcodeproj
```

In Xcode, select the **SandGuideCamera** target, configure your development team
and automatic signing, select the connected iPhone, and run the app.

## Wi-Fi streaming

1. Connect the phone and computer to the same local network.
2. Start the compatible desktop receiver in Wi-Fi/server mode, listening on TCP
   port `8765`.
3. Open **SandGuide Camera**, enter the computer's local IPv4 address and port,
   and tap **Wi-Fi connect**.

Keep the app open while capturing. Permit the receiver through the computer's
firewall on the local network if required. Use a trusted local network; the TCP
stream does not provide authentication or encryption.

## USB streaming

1. Connect and unlock the phone, then accept **Trust This Computer** if prompted.
2. In the app, keep port `8765` and tap **USB: listen**. The PC address field is
   not used in this mode.
3. On the computer, install the USB forwarder and run it in a terminal:

```bash
python -m pip install pymobiledevice3
python -m pymobiledevice3 usbmux forward 8765 8765
```

4. Start the compatible desktop receiver in USB/client mode, connecting to
   `127.0.0.1:8765`. Leave the forwarder running during capture.

On Linux, use `python3` if required and ensure `usbmuxd` is running. USB mode
does not require Wi-Fi or a personal hotspot. For a different PC-side port,
forward, for example, `8766 8765` and connect the desktop receiver to port `8766`.
The phone continues listening on `8765`.

## Stream format

Each TCP packet contains a 16-byte header followed by JSON metadata, a JPEG
image, and a depth buffer. Receivers must handle fragmented TCP reads.

| Header field | Encoding |
| --- | --- |
| Magic | Four ASCII bytes: `SGD1` |
| JSON byte count | Unsigned 32-bit integer, big-endian |
| JPEG byte count | Unsigned 32-bit integer, big-endian |
| Depth byte count | Unsigned 32-bit integer, big-endian |

Metadata supplies `rgb_width`, `rgb_height`, `depth_width`, `depth_height`,
`intrinsics` as `[fx, fy, cx, cy]`, and a capture timestamp. Intrinsics refer to
the RGB dimensions. Depth is a row-major Float32 little-endian array in meters,
with pixel-buffer row padding removed. Both transmitted images use unmirrored
landscape orientation. A receiver that mirrors an image must apply the same
pixel transform to its intrinsic matrix.

## Source layout

| Path | Purpose |
| --- | --- |
| [ios/Sources/SandGuideCameraApp.swift](ios/Sources/SandGuideCameraApp.swift) | Capture, transport, and phone interface |
| [ios/project.yml](ios/project.yml) | XcodeGen project configuration |
| [.github/workflows/build-iphone.yml](.github/workflows/build-iphone.yml) | Unsigned physical-device build |

## Limitations

The app is experimental. Physical iPhone 11 capture, USB/Wi-Fi performance,
and measurement accuracy require hardware validation. Keep the phone fixed
after calibrating the desktop guidance system. Depth resolution and sensor
noise limit the size of features that can be measured reliably.
