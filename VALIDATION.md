# Validation — November 2, 2026

## Version 0.2 upload performance

- Removed the full-card preflight scan before every upload. It now checks the union of all boot/reserved sectors, all FAT copies, all root/subdirectory-chain sectors, and all sectors that will change.
- Added 154 mock-hardware regression checks. A 512 KB fixture matching the connected card's geometry requires 37 preflight reads and 3 write-verification reads for a tiny file, versus the previous 1,021 preflight reads. A second upload uses the updated snapshot and keeps the same read budget.
- Tests cover all supported physical sector sizes, multiple FAT copies, multiple sectors per cluster, extra reserved sectors, complete directory chains, external metadata/data conflicts, read errors and read-back verification failures. Detected conflicts and I/O failures block further writes until refresh.
- Initial Connect / Refresh still reads a full snapshot. Backups remain local writes of the session snapshot. USB writes and their read-back verification are unchanged.
- Version 0.2's check selection is tested with mock hardware. Physical USB transport and writes were verified on the card in the original validation below.

## Build

- Native arm64 Mach-O executable, deployment target macOS 12.0.
- Built and tested on this Apple Silicon Mac running macOS 27.0.1.
- Local app code signature verified with `codesign --verify --strict`.

## Automated tests

- HID protocol tests: passed. Mock USB calls cover descriptors, report lengths, identity padding, all supported sector sizes, address mapping, write payload padding, per-chunk acknowledgement requests and error handling. These tests never access hardware.
- FAT12 tests: 146 checks passed for 128-, 256- and 512-byte sectors, root and nested directories, directory growth, upload/extraction, allocation, corruption detection and failed-mutation rollback.
- Offline CardSession integration: 40 checks passed, including prechange backups, stale image edits, trailing bytes, geometry changes, backup failure and reconnect requirements.

## Interface

Tested through the actual AppKit interface with a disposable FAT12 image:

- Open Image and root listing.
- Download; downloaded bytes compared independently with known content.
- Upload; stored directory entry and file bytes checked independently.
- New Folder; directory entry checked independently.
- Double-click directory navigation.

## Connected APF-01

- Detected VID/PID `16c0:1771`.
- Hardware identity `01 02 10`: 512 KB APF-01, v1.2.
- HID feature buffer: 64 bytes. Identity response: 3 bytes.
- BPB sector size: 512 bytes. Logical sectors: 1,021 (522,752 logical image bytes, with the firmware's bank sectors omitted).
- Repeated boot-sector reads match.
- Full-card read completed and FAT12 header parsed successfully.
- A full-card backup was saved locally before the hardware test.
- Real upload through the production CardSession/IOKit path: passed. Created `APFTEST.TXT` containing 39 bytes, after comparing every card sector against the saved backup.
- Changed logical sectors were 1 (FAT), 4 (root directory) and 38 (new file data). All written sectors were read back and verified. An independent reread reconstructed the file and matched its exact contents.
- The test then restored all three changed sectors from the backup, read each back and verified a byte-for-byte match. The temporary test file was removed.
- Write acknowledgements succeed on this hardware; no compatibility relaxation from the strict native implementation was required.

Only this connected hardware version can be verified directly. Other APF-01 capacities use the recovered protocol and simulated tests; they have not been tested on physical cards.
