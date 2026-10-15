#!/usr/bin/env python3
"""Pixel-art logo for glaz: a wide-open, bloodshot eye. Three variants.

Plain Python, no Pillow: the art is computed on a small grid, then written
as PNG with zlib, scaled up by whole pixels so the edges stay sharp.

    python tool/logo.py preview          # writes assets/logo/preview.png
    python tool/logo.py icons [variant]  # all platform icons from one variant
    python tool/logo.py glasses [variant]  # ../sprites/logo.lua, the splash
    python tool/logo.py update [variant]   # lib/frame/update_art.dart, the
                                         # eye wired up for a firmware update
    python tool/logo.py adaptive-preview [variant] [out.png]
                                         # the Android icon under Pixel's mask

Variants: bloodshot (default), oled, flipper.
"""
import math
import struct
import sys
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Frame's display palette, so the logo matches what the glasses draw.
FRAME = {
    'void': (0, 0, 0), 'white': (255, 255, 255), 'grey': (157, 157, 157),
    'red': (190, 38, 51), 'pink': (224, 111, 139), 'orange': (235, 137, 49),
    'yellow': (247, 226, 107), 'green': (68, 137, 26), 'lightgreen': (163, 206, 39),
    'nightblue': (0, 87, 132), 'seablue': (49, 162, 242), 'skyblue': (178, 220, 239),
}


def rgba(c, a=255):
    return (*c, a)


CLEAR = (0, 0, 0, 0)


class Grid:
    def __init__(self, n, fill=CLEAR):
        self.n = n
        self.px = [[fill] * n for _ in range(n)]

    def set(self, x, y, c):
        if 0 <= x < self.n and 0 <= y < self.n:
            self.px[y][x] = c

    def get(self, x, y):
        return self.px[y][x]


def line(x0, y0, x1, y1):
    """Bresenham: the integer points from (x0, y0) to (x1, y1)."""
    pts = []
    dx, dy = abs(x1 - x0), -abs(y1 - y0)
    sx, sy = (1 if x0 < x1 else -1), (1 if y0 < y1 else -1)
    err = dx + dy
    while True:
        pts.append((x0, y0))
        if x0 == x1 and y0 == y1:
            return pts
        e2 = 2 * err
        if e2 >= dy:
            err += dy
            x0 += sx
        if e2 <= dx:
            err += dx
            y0 += sy


def eye(n, *, half_w, half_h, iris_r, pupil_r, colors, veins, bg=None,
        bg_radius=0, look=(0, 0)):
    """Draw one eye on an n x n grid.

    The eye is a lens (two circular lids meeting at pointed corners); a tall
    lens reads as a wide-open, staring eye with white all round the iris.
    veins: polylines in grid coordinates, the first segment drawn darker.
    """
    g = Grid(n)
    c = (n - 1) / 2
    # rounded-square background
    if bg:
        for y in range(n):
            for x in range(n):
                dx = max(0, abs(x - c) - (c - bg_radius))
                dy = max(0, abs(y - c) - (c - bg_radius))
                if dx * dx + dy * dy <= bg_radius * bg_radius + 0.5:
                    g.set(x, y, bg)

    R = (half_w ** 2 + half_h ** 2) / (2 * half_h)

    def inside(x, y):
        up = math.hypot(x - c, y - (c + (R - half_h)))
        down = math.hypot(x - c, y - (c - (R - half_h)))
        return up <= R and down <= R

    sclera = {(x, y) for y in range(n) for x in range(n) if inside(x, y)}
    # outline: pixels next to the sclera (8-neighbourhood) but outside it
    outline = set()
    for (x, y) in sclera:
        for ddx in (-1, 0, 1):
            for ddy in (-1, 0, 1):
                p = (x + ddx, y + ddy)
                if p not in sclera:
                    outline.add(p)
    for p in outline:
        g.set(*p, colors['outline'])
    ix, iy = c + look[0], c + look[1]
    for (x, y) in sclera:
        # shadow under the upper lid
        top = min(yy for (xx, yy) in sclera if xx == x)
        g.set(x, y, colors['shade'] if y - top < 1 else colors['sclera'])

    # veins, clipped to the sclera
    for path in veins:
        for i in range(len(path) - 1):
            col = colors['vein_dark'] if i == 0 else colors['vein']
            for p in line(*path[i], *path[i + 1]):
                if p in sclera:
                    g.set(*p, col)

    # iris, pupil, highlight
    for (x, y) in sclera:
        d = math.hypot(x - ix, y - iy)
        if d <= iris_r:
            if d > iris_r - 1.2:
                col = colors['iris_edge']
            elif d <= pupil_r + 0.4:
                col = colors['pupil']
            elif d <= pupil_r + 1.6:
                col = colors['iris_in']
            else:
                # spokes: alternate two tones by angle
                a = math.atan2(y - iy, x - ix)
                col = colors['iris'] if int((a + math.pi) / (math.pi / 6)) % 2 \
                    else colors['iris_alt']
            g.set(x, y, col)
    hx, hy = round(ix - pupil_r * 0.9), round(iy - pupil_r * 0.9)
    for p in ((hx, hy), (hx - 1, hy), (hx, hy - 1), (hx - 1, hy - 1)):
        if p in sclera:
            g.set(*p, colors['glint'])
    g.set(round(ix + pupil_r), round(iy + pupil_r - 1), colors['glint'])
    return g


def veins_for(n):
    """Hand-placed vein paths, scaled from a 32-pixel layout."""
    s = n / 32
    base = [
        # from the left corner
        [(3, 16), (7, 15), (10, 13), (11, 10)],
        [(7, 15), (9, 18), (8, 21)],
        [(4, 17), (8, 19), (10, 22)],
        [(5, 14), (7, 11), (9, 9)],
        # from the right corner
        [(28, 16), (24, 17), (22, 20), (22, 23)],
        [(24, 17), (23, 13), (24, 10)],
        [(27, 15), (24, 13), (21, 9)],
        [(27, 17), (25, 20), (26, 21)],
        # from the lids
        [(15, 6), (14, 8), (12, 8)],
        [(18, 26), (19, 24), (21, 24)],
        [(12, 25), (11, 23)],
    ]
    return [[(round(x * s), round(y * s)) for (x, y) in path] for path in base]


def variant(name):
    F = FRAME
    if name == 'bloodshot':
        # classic: white of the eye, green iris, transparent background
        return eye(32, half_w=14.5, half_h=10.5, iris_r=7.2, pupil_r=2.6,
                   veins=veins_for(32), colors={
                       'outline': rgba((24, 8, 12)), 'sclera': rgba((250, 244, 236)),
                       'shade': rgba((214, 196, 192)),
                       'vein_dark': rgba((140, 18, 30)), 'vein': rgba(F['red']),
                       'iris_edge': rgba((24, 60, 10)), 'iris': rgba(F['green']),
                       'iris_alt': rgba(F['lightgreen']), 'iris_in': rgba((120, 170, 30)),
                       'pupil': rgba((8, 8, 8)), 'glint': rgba(F['white']),
                   })
    if name == 'oled':
        # Frame's OLED look: black tile, sky-blue rim, blue iris, pink-red veins
        return eye(32, half_w=13.5, half_h=10, iris_r=6.6, pupil_r=2.4,
                   veins=veins_for(32), bg=rgba((6, 6, 10)), bg_radius=7,
                   colors={
                       'outline': rgba(F['skyblue']), 'sclera': rgba((236, 238, 244)),
                       'shade': rgba((150, 170, 190)),
                       'vein_dark': rgba(F['red']), 'vein': rgba(F['pink']),
                       'iris_edge': rgba(F['nightblue']), 'iris': rgba(F['seablue']),
                       'iris_alt': rgba(F['skyblue']), 'iris_in': rgba(F['nightblue']),
                       'pupil': rgba((0, 0, 0)), 'glint': rgba(F['white']),
                   })
    if name == 'flipper':
        # chunky 24-pixel eye on Flipper orange, pin-prick pupil: staring
        return eye(24, half_w=10.5, half_h=8.5, iris_r=5.6, pupil_r=1.0,
                   veins=veins_for(24), bg=rgba(F['orange']), bg_radius=5,
                   colors={
                       'outline': rgba((0, 0, 0)), 'sclera': rgba((255, 246, 214)),
                       'shade': rgba((224, 190, 150)),
                       'vein_dark': rgba((150, 14, 24)), 'vein': rgba(F['red']),
                       'iris_edge': rgba((0, 0, 0)), 'iris': rgba(F['yellow']),
                       'iris_alt': rgba(F['orange']), 'iris_in': rgba(F['orange']),
                       'pupil': rgba((0, 0, 0)), 'glint': rgba(F['white']),
                   })
    raise SystemExit(f'unknown variant {name!r}')


VARIANTS = ('bloodshot', 'oled', 'flipper')


def render(g, size, *, pad=0, bg=CLEAR):
    """Scale a grid to size x size: nearest neighbour, optional padding."""
    inner = size - 2 * pad
    out = [[bg] * size for _ in range(size)]
    for y in range(inner):
        for x in range(inner):
            p = g.get(x * g.n // inner, y * g.n // inner)
            if p[3]:
                out[y + pad][x + pad] = p
    return out


def write_png(path, rows, alpha=True):
    """RGBA, or RGB when alpha=False: the App Store refuses icons that have
    an alpha channel at all, even a fully opaque one."""
    h, w = len(rows), len(rows[0])
    n = 4 if alpha else 3
    raw = b''.join(b'\0' + bytes(v for px in r for v in px[:n]) for r in rows)

    def chunk(tag, data):
        body = tag + data
        return struct.pack('>I', len(data)) + body + \
            struct.pack('>I', zlib.crc32(body) & 0xffffffff)
    png = b'\x89PNG\r\n\x1a\n' + \
        chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6 if alpha else 2, 0, 0, 0)) + \
        chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b'')
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(png)


def preview():
    cell, gap = 384, 32
    bg = (32, 32, 36, 255)
    w = 3 * cell + 4 * gap
    rows = [[bg] * w for _ in range(cell + 2 * gap)]
    for i, name in enumerate(VARIANTS):
        tile = render(variant(name), cell)
        ox = gap + i * (cell + gap)
        for y in range(cell):
            for x in range(cell):
                if tile[y][x][3]:
                    rows[gap + y][ox + x] = tile[y][x]
    write_png(ROOT / 'assets/logo/preview.png', rows)
    for name in VARIANTS:
        write_png(ROOT / f'assets/logo/{name}.png', render(variant(name), 512))


# Android 8+ adaptive icon. The launcher masks a 108 dp layer to its own
# shape -- a circle on Pixel, 72 dp across -- so the art goes on its own
# layer, sized to that circle, over a black one. Before this the square icon
# was shrunk to fit inside the circle and the eye came out small.
#
# The eye is EYE_DP wide: inside the 72 dp circle, with its corners just
# clear of the edge. At every density that is a whole multiple of the 32
# pixel art, so the pixels stay square: 2x at mdpi, 8x at xxxhdpi.
ADAPTIVE_DP = 108
EYE_DP = 64
DENSITIES = (('mdpi', 1), ('hdpi', 1.5), ('xhdpi', 2), ('xxhdpi', 3),
             ('xxxhdpi', 4))


def adaptive_layer(g, scale):
    size = round(ADAPTIVE_DP * scale)
    eye_px = round(EYE_DP * scale)
    pad = (size - eye_px) // 2
    rows = [[CLEAR] * size for _ in range(size)]
    art = render(g, eye_px)
    for y in range(eye_px):
        rows[pad + y][pad:pad + eye_px] = art[y]
    return rows


def adaptive(g, res):
    for d, scale in DENSITIES:
        write_png(res / f'mipmap-{d}/ic_launcher_foreground.png',
                  adaptive_layer(g, scale))
    (res / 'values/ic_launcher_background.xml').write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<!-- Generated by tool/logo.py: the OLED\'s "off". -->\n'
        '<resources>\n'
        '    <color name="ic_launcher_background">#000000</color>\n'
        '</resources>\n')
    anydpi = res / 'mipmap-anydpi-v26'
    anydpi.mkdir(parents=True, exist_ok=True)
    (anydpi / 'ic_launcher.xml').write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<!-- Generated by tool/logo.py: the eye on its own layer, so the\n'
        '     launcher\'s mask (a circle on Pixel) frames it. -->\n'
        '<adaptive-icon '
        'xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@color/ic_launcher_background" />\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground" />\n'
        '</adaptive-icon>\n')


def adaptive_preview(name, path):
    """How Pixel shows it: the 108 dp layers under a 72 dp circle mask."""
    layer = adaptive_layer(variant(name), 4)
    size = len(layer)
    c, r = (size - 1) / 2, 36 * 4
    page = (48, 48, 52, 255)
    rows = [[page] * size for _ in range(size)]
    for y in range(size):
        for x in range(size):
            if (x - c) ** 2 + (y - c) ** 2 <= r * r:
                rows[y][x] = layer[y][x] if layer[y][x][3] else (0, 0, 0, 255)
    write_png(path, rows)


def icons(name):
    g = variant(name)
    black = (0, 0, 0, 255)
    # In the app: the art at 512 px, transparent where the art is.
    write_png(ROOT / 'assets/logo/logo.png', render(g, 512))
    # Launcher icons have no transparency on iOS; fill with black, the OLED's
    # "off", and leave a margin so the eye is not cropped by the mask.
    def solid(size):
        pad = size // 10
        return render(g, size, pad=pad, bg=black)
    res = ROOT / 'android/app/src/main/res'
    # Before Android 8: a plain square, shown as it is.
    for d, s in (('mdpi', 48), ('hdpi', 72), ('xhdpi', 96), ('xxhdpi', 144),
                 ('xxxhdpi', 192)):
        write_png(res / f'mipmap-{d}/ic_launcher.png', solid(s))
    adaptive(g, res)
    ios = ROOT / 'ios/Runner/Assets.xcassets/AppIcon.appiconset'
    for f in ios.glob('Icon-App-*.png'):
        pts, scale = f.stem.removeprefix('Icon-App-').split('@')
        size = round(float(pts.split('x')[0]) * int(scale.rstrip('x')))
        write_png(f, solid(size), alpha=False)
    # iOS launch screen: the eye alone, on the storyboard's black background
    launch = ROOT / 'ios/Runner/Assets.xcassets/LaunchImage.imageset'
    for suffix, size in (('', 128), ('@2x', 256), ('@3x', 384)):
        write_png(launch / f'LaunchImage{suffix}.png', render(g, size))
    # Android launch screen: drawn by launch_background.xml
    write_png(res / 'drawable-nodpi/launch_eye.png', render(g, 384))
    mac = ROOT / 'macos/Runner/Assets.xcassets/AppIcon.appiconset'
    for f in mac.glob('app_icon_*.png'):
        size = int(f.stem.removeprefix('app_icon_'))
        write_png(f, render(g, size, pad=size // 10))


# The same eye for the glasses' splash screen: ../sprites/logo.lua, in the
# format frame_app.lua scans (one character per pixel, characters mapped to
# Frame's palette), with the word "glaz" in Russian under it. Frame's font
# has no Cyrillic, so the word is drawn here as pixels too.
SPRITE_CHARS = {      # variant colour -> (sprite character, palette index)
    'outline': '.', 'pupil': '.',      # black: the OLED is black anyway
    'sclera': 'w', 'glint': 'w', 'shade': 'k',
    'vein_dark': 'r', 'vein': 'r',
    'iris_edge': 'd', 'iris': 'g', 'iris_in': 'g', 'iris_alt': 'G',
}
PALETTE = {'.': (0, 'VOID, transparent'), 'w': (1, 'WHITE'), 'k': (2, 'GREY'),
           'r': (3, 'RED'), 'd': (9, 'DARKGREEN'), 'g': (10, 'GREEN'),
           'G': (11, 'LIGHTGREEN')}
CAPTION_CHAR = 'G'

# 5x7 capitals, '#' = lit. "ГЛАЗ" -- glaz, Russian for "eye".
CYRILLIC = {
    'Г': ['#####', '#....', '#....', '#....', '#....', '#....', '#....'],
    'Л': ['..###', '.#..#', '.#..#', '.#..#', '.#..#', '.#..#', '#...#'],
    'А': ['.###.', '#...#', '#...#', '#####', '#...#', '#...#', '#...#'],
    'З': ['.###.', '#...#', '....#', '..##.', '....#', '#...#', '.###.'],
}
CAPTION = 'ГЛАЗ'


def glasses_sprite(name='bloodshot'):
    colors = _variant_colors(name)
    g = variant(name)
    lookup = {c: SPRITE_CHARS[k] for k, c in colors.items()}
    rows = [''.join('.' if not g.get(x, y)[3] else lookup[g.get(x, y)]
                    for x in range(g.n)) for y in range(g.n)]
    while rows and set(rows[0]) == {'.'}:      # trim the empty margin
        rows.pop(0)
    while rows and set(rows[-1]) == {'.'}:
        rows.pop()
    width = g.n
    text = ['.'.join(CYRILLIC[ch][r] for ch in CAPTION) for r in range(7)]
    left = (width - len(text[0])) // 2
    rows += ['.' * width] * 3
    rows += [('.' * left + t.replace('#', CAPTION_CHAR)).ljust(width, '.')
             for t in text]
    used = sorted({c for r in rows for c in r}, key=lambda c: PALETTE[c][0])
    out = [
        "-- Splash sprite: the glaz eye, as in the phone app's logo, with",
        "-- 'GLAZ' in Cyrillic under it. ASCII only. Generated by",
        "-- flutter-glaz/tool/logo.py glasses -- edit the art there, not here.",
        "--",
        "-- One character per pixel, one string per row; frame_app.lua draws it",
        "-- scaled up (SPLASH_SCALE) and centred. '.' is transparent, which on",
        "-- the OLED is simply black.",
        "local _M = {}",
        "",
        "-- character -> palette index (the order of frame.display's colour table)",
        "_M.colors = {",
    ]
    for c in used:
        idx, label = PALETTE[c]
        key = "['.']" if c == '.' else c
        out.append(f"  {key} = {idx},".ljust(16) + f"-- {label}")
    out += ["}", "", "_M.art = {"]
    out += [f"  '{r}'," for r in rows]
    out += ["}", "", "return _M", ""]
    path = ROOT.parent / 'sprites/logo.lua'
    path.write_text('\n'.join(out), encoding='ascii')
    return path


# The eye wired up, shown on the glasses while their firmware is replaced
# (lib/frame/update_screen.dart): a plug in each corner of the eye, cables
# running out and down, and one more from below into a connector.
WIRE = {'cable': 'k', 'plug': 'y', 'pin': 'o'}
UPDATE_PALETTE = {**PALETTE, 'y': (8, 'YELLOW'), 'o': (7, 'ORANGE')}


def _eye_rows(name):
    colors = _variant_colors(name)
    g = variant(name)
    lookup = {c: SPRITE_CHARS[k] for k, c in colors.items()}
    rows = [''.join('.' if not g.get(x, y)[3] else lookup[g.get(x, y)]
                    for x in range(g.n)) for y in range(g.n)]
    while rows and set(rows[0]) == {'.'}:
        rows.pop(0)
    while rows and set(rows[-1]) == {'.'}:
        rows.pop()
    return rows


def update_art(name='bloodshot'):
    eye = _eye_rows(name)
    side = 8                                    # room for the cables
    width = len(eye[0]) + 2 * side
    below = 7
    grid = [list('.' * width) for _ in range(len(eye) + below)]
    for y, row in enumerate(eye):
        for x, c in enumerate(row):
            grid[y][x + side] = c

    def put(x, y, c):
        if 0 <= y < len(grid) and 0 <= x < width:
            grid[y][x] = c

    mid = len(eye) // 2
    bottom = len(grid) - 1
    for sign in (-1, 1):                        # left, then mirrored right
        edge = (min if sign < 0 else max)(
            x for x, c in enumerate(''.join(grid[mid])) if c != '.')
        plug = edge + sign * 1
        for dy in (-1, 0):                       # a plug 2x2 on the eye
            put(plug, mid + dy, WIRE['plug'])
            put(plug + sign, mid + dy, WIRE['plug'])
        run = plug + sign * 2
        far = run + sign * 3
        for x in range(min(run, far), max(run, far) + 1):
            put(x, mid, WIRE['cable'])
        for y in range(mid, bottom - 1):
            put(far, y, WIRE['cable'])
        for x in (far - 1, far, far + 1):        # its connector
            put(x, bottom - 1, WIRE['pin'])
            put(x, bottom, WIRE['pin'])
    centre = width // 2
    last = max(y for y in range(len(eye)) if grid[y][centre] != '.')
    for y in range(last + 1, bottom - 2):
        put(centre, y, WIRE['cable'])
        put(centre - 1, y, WIRE['cable'])
    for x in range(centre - 3, centre + 3):      # a plug from below
        put(x, bottom - 2, WIRE['plug'])
        put(x, bottom - 1, WIRE['plug'])
    for x in (centre - 2, centre + 1):
        put(x, bottom, WIRE['pin'])

    rows = [''.join(r) for r in grid]
    used = sorted({c for r in rows for c in r}, key=lambda c: UPDATE_PALETTE[c][0])
    out = [
        '// The glaz eye wired up, drawn on the glasses while their firmware',
        '// is replaced (update_screen.dart). Generated by tool/logo.py',
        '// update -- edit the art there, not here.',
        '//',
        "// One character per pixel; the characters map to Frame's palette.",
        "// '.' is transparent, which on the OLED is simply black.",
        '',
        "/// Character -> palette index (frame.display's colour table).",
        'const updateArtColors = {',
    ]
    for c in used:
        idx, label = UPDATE_PALETTE[c]
        out.append(f"  '{c}': {idx}, // {label}")
    out += ['};', '', '/// The rows, top to bottom.', 'const updateArt = [']
    out += [f"  '{r}'," for r in rows]
    out += ['];', '']
    path = ROOT / 'lib/frame/update_art.dart'
    path.write_text('\n'.join(out), encoding='ascii')
    return path


def _variant_colors(name):
    """The colours a variant was drawn with, by role, read back from eye()."""
    captured = {}
    real = globals()['eye']

    def spy(*args, **kw):
        captured.update(kw['colors'])
        return real(*args, **kw)
    globals()['eye'] = spy
    try:
        variant(name)
    finally:
        globals()['eye'] = real
    return captured


if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'preview'
    if cmd == 'preview':
        preview()
    elif cmd == 'icons':
        icons(sys.argv[2] if len(sys.argv) > 2 else 'bloodshot')
    elif cmd == 'glasses':
        print(glasses_sprite(sys.argv[2] if len(sys.argv) > 2 else 'bloodshot'))
    elif cmd == 'update':
        print(update_art(sys.argv[2] if len(sys.argv) > 2 else 'bloodshot'))
    elif cmd == 'adaptive-preview':
        adaptive_preview(sys.argv[2] if len(sys.argv) > 2 else 'bloodshot',
                         Path(sys.argv[3] if len(sys.argv) > 3
                              else 'adaptive-preview.png'))
    else:
        raise SystemExit(__doc__)
