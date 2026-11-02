# APF RAM for Mac

A native Apple Silicon utility for exchanging files with Atari Portfolio APF-01 USB memory cards. It uses macOS IOKit HID directly and runs without Windows, Wine, Homebrew or additional USB drivers.

This is an independent implementation of the Windows utility's USB protocol. It is not affiliated with the APF-01 manufacturer.

## Download

Get the **Apple Silicon Mac app** from the [latest release](https://github.com/pgeo101/apf-ram-mac/releases/latest), unzip it and open **APF RAM.app**. Requires macOS 12 or later, including M1 Macs.

The app is ad-hoc signed, not Apple notarized. macOS may require **Open Anyway** in **System Settings → Privacy & Security** for a downloaded copy.

## Use

1. Connect the APF-01 to the Mac with a USB data cable. Keep it disconnected from the Portfolio during transfers. Turn the Portfolio off before inserting or removing its card.
2. Click **Connect / Refresh**. This reads the complete card once before displaying its files.
3. Double-click folders to browse. Use **Upload**, **Download**, **New Folder** or **Back Up Card**.

The card must already be formatted by the Portfolio. Use DOS 8.3 names such as `GAME.COM`, `README.TXT` and `TOOLS`. Upload accepts multiple files and folders recursively; hidden Mac files are skipped inside uploaded folders. Existing names are refused. There are no overwrite, delete or format commands.

Before each change, the app saves a disk-image backup in `~/Library/Application Support/APF RAM/Backups/`. Choose **Show Automatic Backups** in the app menu to find them. Keep USB connected until the operation finishes.

### Faster uploads in v0.2

Uploads reuse the loaded card image. Each change checks the boot/reserved area, all allocation tables and directories, and every sector that will be written. It then writes only changed sectors and reads each one back to verify it.

For a tiny file on the tested 512 KB card layout, regression tests require **37 checking reads instead of 1,021**—about 96% fewer checking reads. Larger files and additional subdirectories require more checks. This is a reduction in USB reads, not a measured transfer-speed multiplier.

Use **Connect / Refresh** after using the card in the Portfolio or changing it outside this app. Backups contain the loaded snapshot plus earlier verified uploads in that session.

### Card images

**Open Image** opens unpartitioned FAT12 `.img` files up to 2 MB. Upload and New Folder then modify that image on the Mac, with an automatic backup. This version does not restore an image to a physical card.

## Compatibility and validation

- Native `arm64`, built for macOS 12 or later.
- Recognizes APF-01 capacity codes for 512 KB, 1 MB, 1.5 MB, 1.9 MB and 2 MB, with 128-, 256- or 512-byte physical sectors.
- APF-02 readers are not supported by this build.
- Physical USB reading, backup, upload and file read-back were verified with v0.1 on a **512 KB APF-01, hardware v1.2**. Other capacities have not been physically tested.
- The v0.2 checking path passes **154 mock-hardware regression checks**. The suite also includes FAT12, offline-session and HID protocol tests.

See [VALIDATION.md](VALIDATION.md) for test details and [PROTOCOL.md](PROTOCOL.md) for the recovered HID commands.

## Build and test

Install Apple's Xcode Command Line Tools, then run from the repository root:

```sh
sh build.sh
sh test.sh
```

The build produces `APF RAM.app`. Automated tests use disposable images and mock USB calls; they do not write to a connected card.

The app also provides read-only command-line operations:

```sh
"./APF RAM.app/Contents/MacOS/APFRAM" --probe
"./APF RAM.app/Contents/MacOS/APFRAM" --list
"./APF RAM.app/Contents/MacOS/APFRAM" --backup /path/to/new-card-backup.img
"./APF RAM.app/Contents/MacOS/APFRAM" --inspect /path/to/card.img
```

No CLI command writes to a physical card. USB access requires running outside a restrictive automation sandbox.

## License and acknowledgements

The app's source code, tools and documentation are available under the [MIT License](LICENSE), copyright © 2026 pgeo101.

The original Windows executable, third-party Atari software and card backups are not distributed by this project and are not covered by its license.

The [manufacturer's site](https://apfram.com/#downloads) provides the original Windows utility. macOS feature-report handling was cross-checked against the [HIDAPI macOS implementation](https://github.com/libusb/hidapi/blob/master/mac/hid.c); this app uses Apple's APIs directly and does not bundle HIDAPI.
