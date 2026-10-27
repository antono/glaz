# Scales

A glasses app that shows scales on the fretboard, two related
scales at once, so the guitarist sees both and picks the colour to
improvise with.

`modules/scales.lua`, Apps > Scales. Frame only; Halo gets a stub (below).

## Example: "Oye Como Va" (Santana), A Dorian

Am pentatonic (A C D E G) is the safe framework; A Dorian
(A B C D E F# G) adds B and F#. The F# -- the raised 6th -- is what
separates Dorian from natural minor, so it is the note to highlight.

Box at frets 5-10, high e on top:

```
Am pentatonic          5   6   7   8   9   10
                e   |--R--|---|---|--o--|---|--o--|
                B   |--o--|---|---|--o--|---|--R--|
                G   |--o--|---|--o--|---|--o--|---|
                D   |--o--|---|--R--|---|---|--o--|
                A   |--o--|---|--o--|---|---|--o--|
                E   |--R--|---|---|--o--|---|--o--|

A Dorian               5   6   7   8   9   10
                e   |--R--|---|--o--|--o--|---|--o--|
                B   |--o--|---|--*--|--o--|---|--R--|
                G   |--o--|---|--o--|---|--o--|---|
                D   |--o--|---|--R--|---|--o--|--o--|
                A   |--o--|---|--o--|---|--*--|--o--|
                E   |--R--|---|--o--|--o--|---|--o--|

R = root A (red)   o = scale note   * = F#, the Dorian note (green)
```

## Instruments

Scales opens on a list: tilt to one, tap to take it; a double tap on the
fretboard comes back to the list, and on the list leaves for the menu.
The first string, the highest, is drawn on top.

| Instrument | Strings, 1st to last | Boxes start on | Up to fret |
| --- | --- | --- | --- |
| Guitar | E B G D A E | 6th, low E | 22 |
| Bass | G D A E | 4th, E | 20 |
| Banjo, 5-string, open G | D B G D g | 4th, D | 22 |
| Ukulele, re-entrant | A E C G | 4th, G | 15 |
| Balalaika, prima | A E E | 3rd, E | 16 |

The banjo's 5th string is short and starts at fret 5: nothing is drawn
on it below that but the open string.

## Display

- Two scales (the default): the minor pentatonic on top, the mode under
  it, the same box of the neck. With the pentatonic itself chosen, one
  board.
- One scale: the mode alone, bigger.
- Colours: the root red, the mode's own note green -- Dorian's raised
  6th, the blues' flat 5th, Phrygian's flat 2nd -- the rest white.
- The top row: key and mode, and `fr N`, the box's lowest fret.

A box is six frets wide. There are five, one starting on each note of
the pentatonic on the string the boxes start on, from the root up
(guitar in A: frets 5, 8, 10, 12, 15); one that would run past the
instrument's last fret moves an octave down, if there is an octave below
it. A box at
fret 0 has a nut after its first column.

## Input

| Glasses | Flipper / keyboard (docs/REMOTE.md) | Does |
| --- | --- | --- |
| tilt right / left | Down, Right / Up, Left | next box up / down the neck; on the list, the next instrument |
| single tap | OK | next mode: pentatonic, Dorian, blues, Phrygian; on the list, take the instrument |
| double tap | Back | back to the list; on the list, to the menu |

On the phone, Glaz > Menu > Scales: **Key** (C to B, A by default) and
**View** (two scales or one); the glasses read them when Scales starts.

Playing, the hands are on the guitar, so a tilt keeps the module open as
a tap does: it closes after 10 minutes with no input, not the usual
minute.

## Halo

Not drawn there yet. Halo support (a part per device, docs/DEVICES.md)
lives on branch `halo-display`; when it reaches `main`, Scales gets a
Frame part only, and a Halo stub saying "Frame only" until its screen
(256x256, round) has a layout of its own.
