# Brilliant Labs Halo

## Plain-language summary

Halo is Brilliant Labs' newer pair of glasses. Like Frame, it runs Lua and
talks over the same Bluetooth service, so the phone app already finds it.
It has a round display, a speaker and a button, and it differs from Frame
in its screen, camera, sleep and firmware updates. glaz does not run on it
yet: the phone app finds Halo, names it, and keeps Upload, Restart, Files
and Firmware off for it, so the Frame app never goes onto a Halo by
mistake.

## Telling Halo from Frame

Both advertise the Lua service `7a230001-5475-a6a4-654c-8431f6ad49c4`
(TX `...0002`, RX `...0003`), so the scan in `flutter-glaz/lib/frame/link.dart`
finds both. The advertised name tells them apart:

| Advertised name | Model |
| --- | --- |
| `Frame 4F` | Frame |
| `Frame Update` | Frame's bootloader (no Lua service, never found by the scan) |
| `Halo 1A2B` | Halo |

`GlassesModel.fromName` (`flutter-glaz/lib/frame/model.dart`) reads it; a
name that says neither (none yet, or one given in the phone's Bluetooth
settings) is taken for Frame, as every pair was before. The Log's `up:`
line says which model came up.

With Halo connected the app does not look for the glaz app (`AppCheck`),
so it never offers to upload Frame's bytecode, and the Glasses tab says
Halo is not supported yet.

## What differs from Frame

Collected from a working Halo client (Valogen's Santos, iOS) and the
[halo-firmware](https://github.com/brilliantlabsAR/halo-firmware) source.
Not yet measured from glaz, nor on Android.

| | Frame | Halo |
| --- | --- | --- |
| Display | 640x400, back buffer and `show()`, palette colours | 256x256 round, drawn at once, `0xRRGGBB` colours, `clear()` |
| Font | proportional; ours adds Cyrillic and emoji | Dogica, multiples of 8 px, printable ASCII only |
| REPL input | one line held at a time | 1 KB ring; a full one refuses the write with ATT error 0x11 |
| File modes | `'read'`, `'write'`, `'append'` | `'r'`, `'w'`, `'a'` |
| Taps | one event per tap, counted by the app | the callback gets `'single'`, `'double'` or `'triple'` |
| Button | none | `frame.button.single/double/long` |
| Sleep | `frame.sleep()`, a tap wakes | `frame.sleep()` drops Bluetooth and wakes on the button only; `frame.standby()` wakes on a tap |
| Microphone | 8 kHz | 8 or 16 kHz |
| Speaker | none | PCM stream on `7a230005-...` |
| Camera | `camera.min`, auto exposure | `frame.camera.capture{resolution=640, quality=...}`, `image_ready()`, `read()` |
| Firmware update | Nordic DFU | MCUmgr (SMP), service `8d53dc1d-1db7-4cd3-868b-8a527460aa84` |

## Next steps

1. Measure on a Halo: MTU, `frame.bluetooth.max_length()`, `_VERSION`,
   whether Frame bytecode loads (expect not: upload source), the sign of
   `frame.imu.direction().roll`, and how Android reports a full REPL ring.
2. Upload for Halo: source instead of bytecode, file modes through one
   helper.
3. The glasses app on Halo: a round layout, taps from the callback's kind,
   the button, standby instead of deep sleep.
4. The modules, the camera first; then Halo's own: firmware updates over
   SMP, answers spoken on its speaker.
