//! flipper-glaz: a Flipper Zero remote for the Frame glasses.
//!
//! Held upright like the Flipper's own Keynote Vertical remote, but where
//! Keynote draws its keys this draws the glasses, then what the phone
//! tells about them: their name, battery, free disk, free memory and the
//! app on their screen. Keys are told apart by a short and a long press: a long
//! one is a command of its own, not the short one repeated.
//!
//! A draft. The Flipper is no keyboard: each press goes to glaz on the
//! phone, and to no other app, over a Bluetooth service of the app's own
//! (`ble`, `link`); the phone writes what it knows of the glasses back
//! over the same service, and until it does, the glasses show as
//! disconnected. What a press does is glaz's to say.

#![no_main]
#![no_std]

// Required for panic handler
extern crate flipperzero_rt;

mod ble;
mod link;

use core::ffi::{CStr, c_void};
use core::fmt::Write;

use flipperzero::furi::message_queue::MessageQueue;
use flipperzero::furi::sync::Mutex;
use flipperzero::furi::time::FuriDuration;
use flipperzero::info;
use flipperzero_rt::entry;
use flipperzero_rt::manifest::{_padded, ApplicationManifestV1, ManifestBase};
use flipperzero_sys as sys;
use flipperzero_sys::furi::UnsafeRecord;

/// The Flipper API this app is for: 88.0, firmware 1.5. flipperzero-rs
/// 0.16 is bound to 87.1, and a Flipper refuses an app of another major
/// version ("outdated app"). 88 only took away the USB smart card (CCID)
/// and added to the GUI: every function and value this app takes from the
/// firmware is the same in both (README.md, "Flipper API").
const API_VERSION: u32 = 88 << 16;

// manifest!(), but with API_VERSION, which the macro does not take.
#[unsafe(no_mangle)]
#[unsafe(link_section = ".fapmeta")]
static FAP_MANIFEST: ApplicationManifestV1 = ApplicationManifestV1 {
    base: ManifestBase {
        api_version: API_VERSION,
        ..ApplicationManifestV1::default().base
    },
    app_version: 4,
    name: _padded(b"Glaz"),
    has_icon: 1,
    icon: _padded(include_bytes!("glaz-10x10.icon")),
    ..ApplicationManifestV1::default()
};

entry!(main);

/// Screen width, held upright; it is 128 high.
const W: i32 = 64;

/// A short line of text, kept without an allocator. Longer text is cut.
#[derive(Clone, Copy)]
struct Text {
    buf: [u8; 24],
    len: usize,
}

impl Text {
    const fn new() -> Self {
        Self {
            buf: [0; 24],
            len: 0,
        }
    }

    fn from(s: &str) -> Self {
        let mut t = Self::new();
        let _ = t.write_str(s);
        t
    }

    /// The text with its terminating NUL, for the canvas.
    fn as_ptr(&self) -> *const core::ffi::c_char {
        self.buf.as_ptr().cast()
    }
}

impl Write for Text {
    fn write_str(&mut self, s: &str) -> core::fmt::Result {
        // One byte stays for the NUL.
        for &b in s.as_bytes() {
            if self.len + 1 >= self.buf.len() {
                break;
            }
            self.buf[self.len] = b;
            self.len += 1;
        }
        self.buf[self.len] = 0;
        Ok(())
    }
}

/// What the phone tells about the glasses. `None`: not known yet.
#[derive(Clone, Copy)]
struct Status {
    /// The glasses' Bluetooth name; `None` while no glasses are connected.
    name: Option<Text>,
    /// Charge, in percent.
    battery: Option<u8>,
    disk_free: Option<u32>,
    mem_free: Option<u32>,
    /// The app on the glasses' screen, or the menu.
    app: Option<Text>,
}

impl Status {
    /// Nothing known: no glasses, as the phone has told of none.
    const fn unknown() -> Self {
        Self {
            name: None,
            battery: None,
            disk_free: None,
            mem_free: None,
            app: None,
        }
    }

    /// What the phone writes to the glaz service (`link`): a version byte,
    /// 1, then fields as tag, length, value. A field left out is not
    /// known; no name, no glasses connected to the phone. Tags not known
    /// here are skipped, so the phone can send more than this reads.
    ///
    /// | Tag | Value |
    /// | --- | --- |
    /// | 1 | the glasses' name, text |
    /// | 2 | free disk, bytes, u32 little-endian |
    /// | 3 | free memory, bytes, u32 little-endian |
    /// | 4 | the app on the glasses, text |
    /// | 5 | the glasses' battery, percent, u8 |
    fn parse(data: &[u8]) -> Option<Self> {
        let (&version, mut rest) = data.split_first()?;
        if version != 1 {
            return None;
        }
        let mut status = Self::unknown();
        while let [tag, len, tail @ ..] = rest {
            let value = tail.get(..*len as usize)?;
            rest = &tail[*len as usize..];
            let text = || Text::from(core::str::from_utf8(value).unwrap_or("?"));
            let number = || value.try_into().ok().map(u32::from_le_bytes);
            match tag {
                1 => status.name = Some(text()),
                2 => status.disk_free = number(),
                3 => status.mem_free = number(),
                4 => status.app = Some(text()),
                5 => status.battery = value.first().map(|&b| b.min(100)),
                _ => {}
            }
        }
        Some(status)
    }
}

#[derive(Clone, Copy, PartialEq)]
enum Key {
    Up,
    Down,
    Left,
    Right,
    Ok,
    Back,
}

impl Key {
    fn from_sys(key: sys::InputKey) -> Option<Self> {
        Some(match key {
            sys::InputKeyUp => Self::Up,
            sys::InputKeyDown => Self::Down,
            sys::InputKeyLeft => Self::Left,
            sys::InputKeyRight => Self::Right,
            sys::InputKeyOk => Self::Ok,
            sys::InputKeyBack => Self::Back,
            _ => return None,
        })
    }

    /// The key as the phone hears it (`link`).
    fn code(self) -> u8 {
        match self {
            Self::Up => 1,
            Self::Down => 2,
            Self::Left => 3,
            Self::Right => 4,
            Self::Ok => 5,
            Self::Back => 6,
        }
    }

    fn name(self) -> &'static str {
        match self {
            Self::Up => "Up",
            Self::Down => "Down",
            Self::Left => "Left",
            Self::Right => "Right",
            Self::Ok => "OK",
            Self::Back => "Back",
        }
    }
}

/// A press as the Flipper tells them apart: a short one comes on release
/// (`InputTypeShort`), a long one while the key is still held, after
/// about 0.5 s (`InputTypeLong`), and then no short one; held on, it
/// repeats (`InputTypeRepeat`) until let go.
#[derive(Clone, Copy, PartialEq)]
enum Press {
    Short,
    Long,
    Repeat,
}

impl Press {
    /// The press as the phone hears it (`link`).
    fn code(self) -> u8 {
        match self {
            Self::Short => 1,
            Self::Long => 2,
            Self::Repeat => 3,
        }
    }

    fn name(self) -> &'static str {
        match self {
            Self::Short => "short",
            Self::Long => "long",
            Self::Repeat => "repeat",
        }
    }
}

/// What the main loop waits for.
#[derive(Clone, Copy)]
enum Event {
    Input(sys::InputEvent),
    /// The phone connected (true) or went.
    Phone(bool),
    /// The phone told about the glasses.
    Glasses(Status),
}

/// What the draw callback shows; the main loop changes it.
struct State {
    /// A phone is connected to the Flipper.
    phone: bool,
    status: Status,
}

/// Draws the screen, upright: 64 wide, 128 high. Called from the GUI
/// thread.
unsafe extern "C" fn draw_callback(canvas: *mut sys::Canvas, context: *mut c_void) {
    let state = unsafe { &*(context as *const Mutex<State>) }.lock();
    let status = state.status;
    unsafe {
        sys::canvas_clear(canvas);

        draw_dolphin(canvas, status.name.is_some());
        // The phone: a dot while connected, a ring while not.
        if state.phone {
            sys::canvas_draw_disc(canvas, W - 4, 5, 2);
        } else {
            sys::canvas_draw_circle(canvas, W - 4, 5, 2);
        }

        sys::canvas_set_font(canvas, sys::FontSecondary);
        if let Some(battery) = status.battery {
            draw_battery(canvas, battery);
        }
        // "(disconnected)" while the phone tells of no glasses; without the
        // brackets if the font makes it wider than the screen.
        let mut name = status.name.unwrap_or(Text::from("(disconnected)"));
        if status.name.is_none() && sys::canvas_string_width(canvas, name.as_ptr()) as i32 > W {
            name = Text::from("disconnected");
        }
        sys::canvas_draw_str_aligned(
            canvas,
            W / 2,
            ART_BOTTOM + 2,
            sys::AlignCenter,
            sys::AlignTop,
            name.as_ptr(),
        );
        sys::canvas_draw_line(canvas, 0, ART_BOTTOM + 12, W - 1, ART_BOTTOM + 12);

        draw_row(canvas, ART_BOTTOM + 16, c"Storage", size(status.disk_free));
        draw_row(canvas, ART_BOTTOM + 28, c"Mem", size(status.mem_free));

        // The app on the glasses' screen, on the last line.
        let app = status.app.unwrap_or(Text::from("-"));
        sys::canvas_draw_str_aligned(
            canvas,
            W / 2,
            127,
            sys::AlignCenter,
            sys::AlignBottom,
            app.as_ptr(),
        );
    }
}

/// The text starts this far down; the dolphin sits above it, centred.
const ART_BOTTOM: i32 = 78;

/// The Flipper's dolphin in Frame glasses: '#' always drawn, '+' only
/// while glasses are connected -- the display lit in the lens it sits
/// behind.
const DOLPHIN: &[&str] = &[
    "................................###########.....................",
    ".............................####.........####..................",
    "..........................####...............###................",
    "........................###....................###..............",
    ".......................##........................##.............",
    "......................##..........................##............",
    ".....................##............................##...........",
    ".....................#..............................#...........",
    "....................##..............................##..........",
    "....................#................................#..........",
    "....................#................................##.........",
    "...................##.................................#.........",
    "...................#..................................##........",
    "...................#...................................#........",
    "...................#........###........................#........",
    "................#.##......#######......................#........",
    "...............####......####.####....................#.........",
    "...............###......###.....###...................#.........",
    "..............##.##.....####.....##.##########.......#..........",
    "..............#...#.#######.#....#############......#...........",
    "..............#...#.######..#.....##..........#.....#...........",
    "..............#...##...######....###..........#....#............",
    "..............##.###....####.....##...............#.............",
    "...............###.########+++++###...............#.............",
    "..........########.#.....####+####..............................",
    ".........#......#.........#######............#..................",
    "........#.....#.............###..............#..................",
    "........#.####...............................#..................",
    "........#...................................#...................",
    ".........#.................................#....................",
    "..........##########.....................##.....................",
    "..............#.....####............#####.......................",
    ".............#..........############............................",
    ".............#..................................................",
    "..............#.................................................",
    "...............##...............................................",
    "...............#####............................................",
    "...............##..#######......................................",
    "................#......#############............................",
    "................#......############.............................",
    "................#......###########..............................",
    "................##....###########...............................",
    ".................#...##.#.#####.................................",
    ".................#..##..#.......................................",
    ".................####...#.......................................",
    "..................#......#......................................",
    "..................#......#......................................",
    ".........................#......................................",
];

unsafe fn draw_dolphin(canvas: *mut sys::Canvas, connected: bool) {
    let top = (ART_BOTTOM - DOLPHIN.len() as i32) / 2;
    for (y, row) in DOLPHIN.iter().enumerate() {
        let left = (W - row.len() as i32) / 2;
        for (x, c) in row.bytes().enumerate() {
            if c == b'#' || (c == b'+' && connected) {
                unsafe { sys::canvas_draw_dot(canvas, left + x as i32, top + y as i32) };
            }
        }
    }
}

/// The glasses' battery, top left, across from the phone's dot: a
/// battery filled as far as it is charged, the percent beside it.
unsafe fn draw_battery(canvas: *mut sys::Canvas, percent: u8) {
    unsafe {
        sys::canvas_draw_frame(canvas, 0, 2, 12, 7);
        sys::canvas_draw_box(canvas, 12, 4, 2, 3);
        sys::canvas_draw_box(canvas, 2, 4, 8 * percent as usize / 100, 3);
        let mut t = Text::new();
        let _ = write!(t, "{}%", percent);
        sys::canvas_draw_str_aligned(canvas, 16, 1, sys::AlignLeft, sys::AlignTop, t.as_ptr());
    }
}

/// A label on the left, its value on the right.
unsafe fn draw_row(canvas: *mut sys::Canvas, y: i32, label: &CStr, value: Text) {
    unsafe {
        sys::canvas_draw_str_aligned(canvas, 0, y, sys::AlignLeft, sys::AlignTop, label.as_ptr());
        sys::canvas_draw_str_aligned(
            canvas,
            W - 1,
            y,
            sys::AlignRight,
            sys::AlignTop,
            value.as_ptr(),
        );
    }
}

/// Bytes as "137 KB" or "1.3 MB"; "-" when not known.
fn size(bytes: Option<u32>) -> Text {
    let mut t = Text::new();
    let _ = match bytes {
        None => write!(t, "-"),
        Some(b) if b < 1024 => write!(t, "{} B", b),
        Some(b) if b < 1024 * 1024 => write!(t, "{} KB", b / 1024),
        Some(b) => write!(
            t,
            "{}.{} MB",
            b / (1024 * 1024),
            b % (1024 * 1024) * 10 / (1024 * 1024)
        ),
    };
    t
}

/// Hands the key to the main loop. Called from the GUI thread.
unsafe extern "C" fn input_callback(event: *mut sys::InputEvent, context: *mut c_void) {
    let queue = unsafe { &*(context as *const MessageQueue<Event>) };
    let _ = queue.put(Event::Input(unsafe { *event }), FuriDuration::WAIT_FOREVER);
}

/// Hands the phone's coming and going to the main loop. Called from the
/// Bt service's thread.
unsafe extern "C" fn bt_status_callback(status: sys::BtStatus, context: *mut c_void) {
    let queue = unsafe { &*(context as *const MessageQueue<Event>) };
    let _ = queue.put(
        Event::Phone(status == sys::BtStatusConnected),
        FuriDuration::WAIT_FOREVER,
    );
}

/// Hands what the phone wrote to the main loop. Called from the BLE
/// thread, so it does not wait: a status the queue has no room for is
/// dropped, and the next one replaces it anyway.
unsafe fn link_data(data: &[u8], context: *mut c_void) {
    let queue = unsafe { &*(context as *const MessageQueue<Event>) };
    match Status::parse(data) {
        Some(status) => {
            let _ = queue.put(Event::Glasses(status), FuriDuration::from_millis(0));
        }
        None => flipperzero::warn!("status not understood, {} bytes", data.len()),
    }
}

fn main(_args: Option<&CStr>) -> i32 {
    let state = Mutex::new(State {
        phone: false,
        status: Status::unknown(),
    });
    let queue: MessageQueue<Event> = MessageQueue::new(8);

    let Some(ble) = ble::Ble::start(
        Some(bt_status_callback),
        link_data,
        &queue as *const _ as *mut c_void,
    ) else {
        flipperzero::error!("no Bluetooth");
        return 1;
    };

    unsafe {
        let notifications = UnsafeRecord::<sys::NotificationApp>::open(c"notification");
        let view_port = sys::view_port_alloc();
        // As Keynote Vertical: the D-pad below the screen.
        sys::view_port_set_orientation(view_port, sys::ViewPortOrientationVerticalFlip);
        sys::view_port_draw_callback_set(
            view_port,
            Some(draw_callback),
            &state as *const _ as *mut c_void,
        );
        sys::view_port_input_callback_set(
            view_port,
            Some(input_callback),
            &queue as *const _ as *mut c_void,
        );

        let gui = UnsafeRecord::<sys::Gui>::open(c"gui");
        sys::gui_add_view_port(gui.as_ptr(), view_port, sys::GuiLayerFullscreen);

        loop {
            let event = match queue.get(FuriDuration::WAIT_FOREVER) {
                Ok(Event::Input(event)) => event,
                Ok(Event::Phone(connected)) => {
                    // The LED blue while connected, as the Remote app has it.
                    let sequence = if connected {
                        &raw const sys::sequence_set_blue_255
                    } else {
                        &raw const sys::sequence_reset_blue
                    };
                    sys::notification_message(notifications.as_ptr(), sequence);
                    let mut state = state.lock();
                    state.phone = connected;
                    // Without the phone nothing is known of the glasses.
                    if !connected {
                        state.status = Status::unknown();
                    }
                    drop(state);
                    sys::view_port_update(view_port);
                    continue;
                }
                Ok(Event::Glasses(status)) => {
                    state.lock().status = status;
                    sys::view_port_update(view_port);
                    continue;
                }
                Err(_) => continue,
            };
            let Some(key) = Key::from_sys(event.key) else {
                continue;
            };

            // Every short, long and repeated press goes to the phone, but
            // a long Back: it leaves, as in the Flipper's own remotes.
            let press = match event.type_ {
                sys::InputTypeShort => Press::Short,
                sys::InputTypeLong => Press::Long,
                sys::InputTypeRepeat => Press::Repeat,
                _ => continue,
            };
            if key == Key::Back && press == Press::Long {
                break;
            }
            ble.send_key(key.code(), press.code());
            info!("press {} {}", key.name(), press.name());
        }

        sys::notification_message(notifications.as_ptr(), &raw const sys::sequence_reset_blue);
        sys::view_port_enabled_set(view_port, false);
        sys::gui_remove_view_port(gui.as_ptr(), view_port);
        sys::view_port_free(view_port);
    }
    drop(ble);

    0
}
