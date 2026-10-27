# Glasses and their parts

How glaz runs on more than one kind of glasses: Brilliant Labs Frame and
Halo (docs/HALO.md). This covers the code on the glasses and what the
phone does with it.

## Plain-language summary

Every app on the glasses is written once and adapted for each pair of
glasses. Its main file holds what it does: its state, its answers to taps
and to the phone, its pictures and texts. Next to it, a small file for each
kind of glasses holds what is done differently there: where things go on the
screen, how it is drawn, and so on. The phone knows which glasses it is
connected to, so it sends the main file and that one small file, nothing
else. The glasses never have to work out what they are, because they only
carry their own code. An app without a file for some glasses is not sent to
them, and the phone does not list it in their menu.

## Parts

| File | What it is | Goes to |
| --- | --- | --- |
| `name.lua` | the same on every pair of glasses: logic, state, assets | every pair the name is on |
| `name.frame.lua` | its part for Frame | Frame only |
| `name.halo.lua` | its part for Halo | Halo only |

Every part has the same name as its file plus the glasses' name: `reader.lua`,
`reader.frame.lua`. A part with no `name.lua` is a file only those glasses
have: `app/glaz_blink.frame.lua`, the eye closing before sleep, is Frame's
alone.

The glasses' names are those of `GlassesModel` on the phone
(`flutter-glaz/lib/frame/model.dart`): `frame`, `halo`. `check.sh` refuses a
part named for any other.

## On the glasses: require() hands a file its part

`require(name)` is glaz's own (`app/glaz_boot.lua`). It loads
`name.<glasses>.lua` first, if it is there, then `name.lua`, and runs that
with the part as its second argument. For example (Brightness does not do
this yet: it is Frame's only):

```lua
-- modules/brightness.lua
local D = select(2, ...)     -- brightness.frame.lua or brightness.halo.lua
local _M = {}
local function apply(level) D.set_brightness(level) end
...
return _M

-- modules/brightness.frame.lua
local D = {}
function D.set_brightness(level) frame.display.set_brightness(level) end
return D
```

So `name.lua` decides what the part must provide, its contract, and calls it.
The part sees nothing of `name.lua` but what it is handed. What it needs, it
gets as arguments: `D.top_bar(bar)` gets the bar's contents.

Nothing on the glasses asks which glasses they are. The phone uploads only
their parts, and `require` loads whatever part is there. `check.sh` refuses
`frame.display.width()` and `HARDWARE_VERSION`, the ways a script could
ask.

### main.lua: the one part that comes first

Something has to know the glasses before anything can be loaded, so the
boot is the other way round. `main.lua` is glaz_boot's part for the glasses
at hand: `app/glaz_boot.frame.lua` or `app/glaz_boot.halo.lua`. It says
which glasses these are (`D.device`), loads a file the way those glasses
must (`D.load`: Frame's firmware require() cannot be trusted with large
files, docs/FRAME.md), and says "restarted" on their screen
(`D.restarted`). Then it runs `glaz_boot.lua` with itself as D.
`glaz_boot.lua` defines `require`, starts the app (`glaz_app.lua`, which is
`glaz.lua`) and restarts it after an error.

### The app: glaz.lua and its parts

`glaz.lua` is the app on every pair of glasses: the menu, taps, the phone's
messages, notifications, sleep. What it shows is decided there. Where
and how it is drawn is its parts', `glaz.frame.lua` and `glaz.halo.lua`
(`glaz_app.frame.lua` on the glasses):

| D. | What |
| --- | --- |
| `layout` | the list's rows: `row_h`, `top_y`, `left_x`, `visible_rows`, `text_rows`, `notice_chars` |
| `text(s, x, y, color, size)` | text in a palette colour (a name); Halo ignores x and centres |
| `show()` | puts what was drawn on the screen (Frame flips its back buffer; Halo has drawn already) |
| `begin()` | a screen starts (Halo clears the panel) |
| `blank()` | an empty screen |
| `power(on)` | the panel on or off |
| `top_bar(bar)` | the breadcrumb, icons, clock and battery: `bar.path(n)` gives the path cut to n characters; `bar.icon`, `bar.link` are `{ palette offset, bits }`; `bar.clock`, `bar.level`, `bar.low` |
| `splash(word, color, brackets)` | `<glaz>` on start |

The icons themselves are assets, so they are in `glaz.lua`; both parts draw
them with `bitmap()`.

### Modules

A module is on the glasses it has a part for. All of them have a Frame part;
those with nothing of Frame's own have one that is empty (`return {}`):
having it is what puts the module on Frame. Most modules are Frame's only
for now: they draw for Frame's screen themselves. A module is ported to
Halo by moving what differs into its parts and adding `name.halo.lua`.
Modules that only use what both pairs of glasses have (the clock, the
battery, Bluetooth, text through the app) have an empty Halo part already:
About, Battery, Bluetooth, Firmware, Uptime, Stopwatch, Weather,
Notifications (Settings).

### What check.sh holds to

- A part's suffix names glasses there are.
- Every module in `modules/` has a part, or it is on no glasses.
- A file that reaches more than one pair of glasses does not draw: it calls
  no `frame.display.*`, its parts do. This covers `glaz.lua`, the common
  files in `app/`, and a module with more than one part.
- Nothing asks which glasses these are.

## On the phone

- **Which glasses.** `FrameLink.model`, from the name they advertise
  (`model.dart`, docs/HALO.md).
- **Which apps they have.** `GlassesParts` (`lib/frame/parts.dart`) reads
  the parts from the app's assets once, at start: a module is on a pair of
  glasses when it has a part for them.
- **Menu tab.** It lists only the apps the glasses at hand have, those
  connected or those of last time. An app without a part for them is not
  shown.
- **Upload.** `luaFiles(..., model:)` (`lib/frame/upload.dart`) sends:
  - the libraries, the common files and that model's parts;
  - the modules switched on that have a part for the model;
  - `glaz.lua` and its part;
  - glaz_boot's part last, as `main.lua`.

  Another model's parts never go up, and the old files a past upload left
  are cleared as before. Bytecode goes to Frame only: Halo's require() loads
  text. The glasses compile nothing; a file without bytecode goes up as
  text, but Frame needs the app itself as bytecode (`needBytecode`).
- **Firmware.** The Firmware screen offers only the firmware for the
  glasses at hand: `frame-firmware-*` to Frame, `halo-firmware-*` to Halo
  (`firmwareFor` in `lib/frame/firmware.dart`), and installs nothing onto
  other glasses than its own.
- **`host_test.py`** uploads the same way, Frame's parts only.

## Adding glasses

1. Add the model to `GlassesModel` (`model.dart`), told by its advertised
   name.
2. Add the parts:
   - `app/glaz_boot.<model>.lua`;
   - `glaz.<model>.lua`, with every name in the table above;
   - a part for each module that runs there.
3. Add the name to `devices` in `check.sh`, to `device_of` in
   `host_test.py` if it uploads there, and to the file list in `flake.nix`.
4. Turn on `supported` for the model in `model.dart` once Upload works
   there.
