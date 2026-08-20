# Dawn Recorder for iPhone

Native iPhone companion app for the BK7258 wearable recorder. This repository
contains the hardware and local-storage workflow only. It contains no cloud
backend, transcription provider, LLM integration, API key, or deployment secret.

## What Works

- Discover nearby Bluetooth Low Energy peripherals and identify compatible
  `NSRecorder-...` devices.
- Connect to the recorder and display battery, storage, and recording status.
- Start and stop recording through the recorder command channel.
- Receive live Opus frames through BLE characteristic `A103` when supported by
  the firmware, and save the completed stream on the iPhone.
- Request the recorder's temporary Wi-Fi transfer network over BLE.
- Join that network, list and download completed recordings over FTP, validate
  or recover the raw Opus frame stream, and save each file locally.
- Remove the temporary recorder Wi-Fi configuration after transfer.
- Rename, share, and delete local recordings with immediate list updates.
- Produce a shareable transfer report with stable stage-specific support codes.

## Hardware Flow

1. Open **Dawn Recorder** and allow Bluetooth and local-network access.
2. Tap **Find Recorder** and connect to the compatible wearable.
3. Record on the wearable or control recording from the app.
4. Tap **Download Recordings**.
5. The app switches from BLE to the recorder's temporary Wi-Fi, downloads the
   completed files, saves them on the iPhone, and removes that Wi-Fi configuration.
6. Open **Recordings** to rename, share, or delete a file.

The firmware currently switches between BLE and Wi-Fi for file transfer. BLE
status is unavailable while the recorder access point is active.

## Build

Requirements:

- macOS with full Xcode installed.
- XcodeGen (`brew install xcodegen`).
- iOS 17 or later.
- BK7258 firmware implementing service `A001`, command characteristic `A102`,
  response characteristic `A101`, optional live-audio characteristic `A103`,
  transfer command `0x0B`, and the recorder FTP service.

Run:

```bash
./verify.command
./open_in_xcode.command
```

In Xcode, select your own development team and unique bundle identifier before
installing on an iPhone. No Apple signing credential is included in this repository.

## Privacy Boundary

Audio stays on the recorder and iPhone in this build. The app does not upload
recordings and does not contact an application backend. Private provider and
server modules are intentionally excluded by `.gitignore`.

