# APF-01 protocol recovered from the supplied executable

Static inspection of `apfRAM.exe` (PE32 x86; built May 27, 2026):

- HID VID `16c0`, PID `1771`.
- Full Windows `HIDP_CAPS.FeatureReportByteLength` used for feature requests. The native implementation derives this length from the device's HID report descriptor.
- Identity: `GetFeature(0x16)`. Raw byte 0 is hardware major, byte 1 minor, byte 2 capacity. Real hardware returns exactly three bytes for identity; trailing buffer bytes are zeroed locally.
- Capacity byte: `10` = 512 KB, `20` = 1 MB, `30` = 1.5 MB, `40` = 1.9 MB, `50` = 2 MB. Hardware major 7 identifies APF-02.

Logical sectors map to firmware sector numbers:

```c
wire = logical < 256 ? logical : logical + 1 + (logical - 256) / 255;
```

Examples: 255→255; 256→257; 510→511; 511→513. Physical numbers 256, 512, 768, etc. are skipped.

Read: `SetFeature` with `[14, 01, wire_hi, wire_lo, 00, zero padding...]`; then `GetFeature(14)` repeatedly. Each response provides 64 raw card bytes starting at buffer offset 0. Do not strip or insert a report ID in returned data. Sector 0 BPB bytes 11–12 specify 128/256/512 bytes per sector. The first response establishes bootstrap geometry.

Write: `SetFeature` with `[14, command, wire_hi, wire_lo, payload...]`. Command 2 starts a sector; command 3 continues it. Each payload is 60 bytes at offsets 4–63; the final payload is zero-padded. `GetFeature(15)` follows every chunk. The Windows app ignores its result; this native build requires the USB request to succeed and verifies every written sector by reading it back. No status-byte meaning has been established.

Disassembly locations (image base `0x400000`): discovery `0x40CFA0`, initialization/identity `0x40C674`, reads `0x40D200`, writes `0x40D3F0`. These are addresses in this exact binary, not public API entry points.

The card image starts with the FAT12 BPB, without an MBR. The legacy Portfolio filesystem does not require a 55AA signature at byte 510. Transport commands were inferred from the original program; real-card compatibility requires explicit validation.
