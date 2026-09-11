# ADBDAV

Mount your Android phone in macOS Finder at USB speed. No kernel extensions, no file copying. Powered by adb + WebDAV.

## Why

macOS does not speak MTP. Windows Explorer does, which is why plugging an Android phone into a Windows PC just works and plugging it into a Mac shows nothing.

The usual workarounds each cost something:

| Approach | Cost |
|---|---|
| macFUSE-based tools | Kernel extension. Apple Silicon needs Reduced Security. |
| File Provider apps | Materializes files locally. Slow, eats disk. |
| Image Capture (PTP) | Photos only. No folders, no organizing. |
| Wi-Fi file server apps | Wi-Fi speed, killed by Android when the screen sleeps. |

ADBDAV takes a different route: **don't teach macOS to speak MTP — make the phone speak something macOS already knows.**

## How it works

```
/sdcard on your phone
  → rclone serves it over WebDAV, bound to the phone's own loopback
  → adb forward tunnels that port over the USB cable
  → macOS mounts it with its built-in WebDAV client
```

Nothing is installed on the Mac beyond this app. Nothing is installed on the phone — a single static binary is copied to a temp directory and can be deleted with one command.

The rclone build is pinned to a specific version and verified against its published SHA-256 before it is used. A pinned version keeps working even if this project stops being maintained, which chasing the latest release would not. It is downloaded once on first connect and cached under `~/Library/Application Support/ADBDAV`.

The server listens only on the phone's loopback interface, so it is never exposed to your network.

## Performance

Measured on a Galaxy S25 Ultra and an M5 MacBook Pro.

| Operation | USB | Wi-Fi |
|---|---|---|
| Open a folder of 170 photos | 0.03 s | 0.11 s |
| Open one 4 MB photo | 0.04 s | 0.55 s |
| Write throughput | 232 MB/s | 6.4 MB/s |
| 40 small files (93 MB) | 107 MB/s | — |

For reference, raw `adb push` over the same cable reaches 273 MB/s, so the WebDAV layer costs about 15%. Wi-Fi is slow because adb itself is slow over the network, not because of this tool.

## Requirements

- macOS 13 or later
- `adb` — `brew install android-platform-tools`
- USB debugging enabled on the phone

## Build

Xcode is not required. The Swift compiler from Command Line Tools is enough.

```bash
./build.sh
```

Produces `ADBDAV.app`, about 200 KB. The phone-side binary is fetched at first connect, not bundled.

## Usage

1. Launch `ADBDAV.app`. A phone icon appears in the menu bar.
2. Plug in the phone. It mounts automatically at `~/ADBDAV`.
3. Browse and organize in Finder. Read and write both work.

The menu bar icon lets you switch between USB and Wi-Fi, connect and disconnect manually, open the folder in Finder, and change the interface language.

The interface follows your macOS language and falls back to English. Korean is also available, and you can pin either one from the Language menu.

The phone does **not** need to be unlocked. adb reads the filesystem directly, unlike MTP and PTP.

## Notes and limitations

- **USB debugging is required.** This is a developer-oriented tool. If you are not willing to enable it, use [OpenMTP](https://github.com/ganeshrvel/openmtp) instead.
- **Wi-Fi mode works but is roughly 35x slower.** Convenient for grabbing a few files, painful for bulk work.
- **Samsung phones cannot run USB debugging and wireless debugging at the same time.** Turning one on turns the other off.
- **Finder shows the mount in the sidebar under its host name**, grouped as a server. Drag `~/ADBDAV` into the Favorites section for a one-click entry named ADBDAV.
- **The app is ad-hoc signed**, so macOS asks for network volume permission once per build.
- Only `/sdcard` is exposed. App-private storage is not accessible.

## Removing it from the phone

```bash
adb shell rm -f /data/local/tmp/rclone /data/local/tmp/rclone.log
```

## Credits

Built on [rclone](https://github.com/rclone/rclone), whose WebDAV server does the heavy lifting.

## License

MIT
