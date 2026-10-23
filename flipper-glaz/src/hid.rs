//! The Flipper's Bluetooth keyboard, as its own Remote app has it.
//!
//! The Remote app (`applications/system/hid_app` in the Flipper firmware)
//! links `ble_profile_hid` from the SDK's `ble_profile` library, which
//! flipperzero-rs does not bind: what is here is that profile and its GATT
//! service, `lib/ble_profile/extra_profiles/hid_profile.c` and
//! `extra_services/hid_service.c`, moved to Rust over the firmware's own
//! API. The same report map, the same address and name ("Control" and the
//! Flipper's name), and the Remote's own pairing file: a phone paired
//! with the Flipper's Remote takes this app for it, with no new pairing.
//!
//! Only the keyboard and consumer keys are used; the mouse report stays
//! in the report map so the device is the Remote's to the byte.

use core::ffi::{CStr, c_void};
use core::mem::zeroed;
use core::ptr;

use flipperzero_sys as sys;
use flipperzero_sys::furi::UnsafeRecord;

/// Keyboard usages (USB HID usage tables, page 7).
pub const KEY_UP: u16 = 0x52;
pub const KEY_DOWN: u16 = 0x51;
pub const KEY_LEFT: u16 = 0x50;
pub const KEY_RIGHT: u16 = 0x4F;
pub const KEY_SPACE: u16 = 0x2C;
/// Backspace; the firmware calls it HID_KEYBOARD_DELETE.
pub const KEY_BACKSPACE: u16 = 0x2A;
/// Consumer page: AC Back, Android's Back.
pub const CONSUMER_AC_BACK: u16 = 0x224;

/// The Remote app's pairing: `APP_DATA_PATH(".bt_hid.keys")` of appid
/// `hid_ble`.
const KEYS_PATH: &CStr = c"/ext/apps_data/hid_ble/.bt_hid.keys";

// From the ST BLE stack headers (lib/stm32wb_copro) and the HID spec.
const UUID_TYPE_16: u8 = 0x01;
const PRIMARY_SERVICE: u8 = 0x01;
const CHAR_PROP_READ: u8 = 0x02;
const CHAR_PROP_WRITE_WITHOUT_RESP: u8 = 0x04;
const CHAR_PROP_NOTIFY: u8 = 0x10;
const ATTR_PERMISSION_NONE: u8 = 0x00;
const ATTR_ACCESS_READ_WRITE: u8 = 0x03;
const GATT_DONT_NOTIFY_EVENTS: u8 = 0x00;
const GATT_NOTIFY_ATTRIBUTE_WRITE: u8 = 0x01;
const CHAR_VALUE_LEN_CONSTANT: u8 = 0x00;
const CHAR_VALUE_LEN_VARIABLE: u8 = 0x01;
const HCI_VENDOR_SPECIFIC_DEBUG_EVT_CODE: u8 = 0xFF;
const ACI_GATT_ATTRIBUTE_MODIFIED_VSEVT_CODE: u16 = 0x0C01;
const ACI_GATT_SERVER_CONFIRMATION_VSEVT_CODE: u16 = 0x0C17;
const GAP_APPEARANCE_KEYBOARD: u16 = 0x03C1;

const HUMAN_INTERFACE_DEVICE_SERVICE_UUID: u16 = 0x1812;
const PROTOCOL_MODE_CHAR_UUID: u16 = 0x2A4E;
const REPORT_MAP_CHAR_UUID: u16 = 0x2A4B;
const HID_INFORMATION_CHAR_UUID: u16 = 0x2A4A;
const HID_CONTROL_POINT_CHAR_UUID: u16 = 0x2A4C;
const REPORT_CHAR_UUID: u16 = 0x2A4D;
const REPORT_REFERENCE_DESCRIPTOR_UUID: u16 = 0x2908;

const INPUT_REPORT_COUNT: usize = 3;
/// Input report numbers: the report id less one.
const REPORT_KEYBOARD: usize = 0;
const REPORT_CONSUMER: usize = 2;
const KB_MAX_KEYS: usize = 6;

/// Keyboard, mouse and consumer, report ids 1, 2 and 3: the bytes of
/// `ble_profile_hid_report_map_data`, compiled from its HID_* macros.
#[rustfmt::skip]
static REPORT_MAP: [u8; 140] = [
    0x05, 0x01, 0x09, 0x06, 0xA1, 0x01, 0x85, 0x01, 0x05, 0x07, 0x19, 0xE0,
    0x29, 0xE7, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x08, 0x81, 0x02,
    0x95, 0x01, 0x75, 0x08, 0x81, 0x03, 0x05, 0x08, 0x95, 0x08, 0x75, 0x01,
    0x19, 0x01, 0x29, 0x08, 0x91, 0x02, 0x95, 0x06, 0x75, 0x08, 0x15, 0x00,
    0x26, 0xFF, 0x00, 0x05, 0x07, 0x19, 0x00, 0x2A, 0xFF, 0x00, 0x81, 0x00,
    0xC0, 0x05, 0x01, 0x09, 0x02, 0xA1, 0x01, 0x09, 0x01, 0xA1, 0x00, 0x85,
    0x02, 0x05, 0x09, 0x19, 0x01, 0x29, 0x03, 0x15, 0x00, 0x25, 0x01, 0x95,
    0x03, 0x75, 0x01, 0x81, 0x02, 0x75, 0x01, 0x95, 0x05, 0x81, 0x03, 0x05,
    0x01, 0x09, 0x30, 0x09, 0x31, 0x09, 0x38, 0x15, 0x81, 0x25, 0x7F, 0x75,
    0x08, 0x95, 0x03, 0x81, 0x06, 0xC0, 0xC0, 0x05, 0x0C, 0x09, 0x01, 0xA1,
    0x01, 0x85, 0x03, 0x15, 0x00, 0x26, 0xFF, 0x03, 0x19, 0x00, 0x2A, 0xFF,
    0x03, 0x95, 0x01, 0x75, 0x10, 0x81, 0x00, 0xC0,
];

/// HID 1.01, no country, remote wake and normally connectable.
static HID_INFO: [u8; 4] = [0x01, 0x01, 0x00, 0x03];

/// The value a data callback reads: `HidSvcDataWrapper`.
#[repr(C)]
struct Data {
    ptr: *const u8,
    len: u16,
}

/// Protocol mode, report map, HID information, control point.
const CHAR_COUNT: usize = 4;

/// The profile, as the firmware keeps it: `base` first, as it takes a
/// pointer to it for the whole.
#[repr(C)]
struct Profile {
    base: sys::FuriHalBleProfileBase,
    kb_report: [u8; 2 + KB_MAX_KEYS],
    consumer_report: u16,
    battery_svc: *mut sys::BleServiceBattery,
    dev_info_svc: *mut sys::BleServiceDevInfo,
    svc_handle: u16,
    chars: [sys::BleGattCharacteristicInstance; CHAR_COUNT],
    input_reports: [sys::BleGattCharacteristicInstance; INPUT_REPORT_COUNT],
    event_handler: *mut sys::GapSvcEventHandler,
}

// One profile at a time, as the radio has one. The characteristics keep
// pointers to their parameters, so these live as long as the app.
static mut PROFILE: Profile = unsafe { zeroed() };
static mut CHAR_PARAMS: [sys::BleGattCharacteristicParams; CHAR_COUNT] = unsafe { zeroed() };
static mut REPORT_PARAMS: [sys::BleGattCharacteristicParams; INPUT_REPORT_COUNT] =
    unsafe { zeroed() };
static mut REPORT_DESCRIPTORS: [sys::BleGattCharacteristicDescriptorParams; INPUT_REPORT_COUNT] =
    unsafe { zeroed() };
/// Report reference: report id, then type (1, input).
static mut REPORT_REFS: [[u8; 2]; INPUT_REPORT_COUNT] = [[1, 1], [2, 1], [3, 1]];

static TEMPLATE: sys::FuriHalBleProfileTemplate = sys::FuriHalBleProfileTemplate {
    start: Some(profile_start),
    stop: Some(profile_stop),
    get_gap_config: Some(profile_get_gap_config),
};

/// A report reference descriptor: two bytes at its context.
unsafe extern "C" fn descriptor_data(
    context: *const c_void,
    data: *mut *const u8,
    data_len: *mut u16,
) -> bool {
    unsafe {
        *data_len = 2;
        if !data.is_null() {
            *data = context.cast();
        }
    }
    false
}

/// The report map and the reports: the `Data` given to the update.
unsafe extern "C" fn report_data(
    context: *const c_void,
    data: *mut *const u8,
    data_len: *mut u16,
) -> bool {
    unsafe {
        if !data.is_null() {
            let source = &*(context as *const Data);
            *data = source.ptr;
            *data_len = source.len;
        } else {
            // At init, the room to keep: the u16 `callback` was given.
            *data_len = *(context as *const u16);
        }
    }
    false
}

/// Acknowledges writes to the protocol mode and the control point, and
/// confirmations of notifications; the rest is for other services.
unsafe extern "C" fn service_event(
    event: *mut c_void,
    _context: *mut c_void,
) -> sys::BleEventAckStatus {
    // hci_uart_pckt: type; hci_event_pckt: evt, plen; evt_blecore_aci:
    // ecode, little-endian.
    let p = event as *const u8;
    unsafe {
        if *p.add(1) == HCI_VENDOR_SPECIFIC_DEBUG_EVT_CODE {
            let ecode = u16::from_le_bytes([*p.add(3), *p.add(4)]);
            if ecode == ACI_GATT_ATTRIBUTE_MODIFIED_VSEVT_CODE
                || ecode == ACI_GATT_SERVER_CONFIRMATION_VSEVT_CODE
            {
                return sys::BleEventAckFlowEnable;
            }
        }
    }
    sys::BleEventNotAck
}

fn char_params(
    name: &'static CStr,
    uuid: u16,
    data_type: sys::BleGattCharacteristicDataType,
    is_variable: u8,
    properties: u8,
    events: u8,
) -> sys::BleGattCharacteristicParams {
    let mut params: sys::BleGattCharacteristicParams = unsafe { zeroed() };
    params.name = name.as_ptr();
    params.uuid.Char_UUID_16 = uuid;
    params._bitfield_1 =
        sys::BleGattCharacteristicParams::new_bitfield_1(data_type, is_variable, UUID_TYPE_16);
    params.char_properties = properties;
    params.security_permissions = ATTR_PERMISSION_NONE;
    params.gatt_evt_mask = events;
    params
}

fn fixed(length: u16) -> sys::BleGattCharacteristicParams__bindgen_ty_1 {
    sys::BleGattCharacteristicParams__bindgen_ty_1 {
        fixed: sys::BleGattCharacteristicParams__bindgen_ty_1__bindgen_ty_1 {
            ptr: ptr::null(),
            length,
        },
    }
}

/// A value given by `report_data`, `max_len` bytes at most. The
/// firmware keeps 255 for the report map and every report; that leaves
/// the Bluetooth's 1344 bytes of values (`CFG_BLE_ATT_VALUE_ARRAY_SIZE`)
/// no room for the glaz service, so these keep what they need.
fn callback(max_len: &'static u16) -> sys::BleGattCharacteristicParams__bindgen_ty_1 {
    sys::BleGattCharacteristicParams__bindgen_ty_1 {
        callback: sys::BleGattCharacteristicParams__bindgen_ty_1__bindgen_ty_2 {
            fn_: Some(report_data),
            context: (max_len as *const u16).cast(),
        },
    }
}

static REPORT_MAP_LEN: u16 = REPORT_MAP.len() as u16;
/// Keyboard, mouse, consumer: modifiers, reserved and 6 keys; buttons,
/// x, y and wheel; one 16-bit key.
static REPORT_LENS: [u16; INPUT_REPORT_COUNT] = [2 + KB_MAX_KEYS as u16, 4, 2];

/// `ble_svc_hid_start`: the service, then its characteristics in the
/// firmware's order -- protocol mode, the input reports, the rest.
unsafe fn service_start(profile: &mut Profile) -> bool {
    unsafe {
        let chars = &mut *(&raw mut CHAR_PARAMS);
        let reports = &mut *(&raw mut REPORT_PARAMS);
        let descriptors = &mut *(&raw mut REPORT_DESCRIPTORS);
        let refs = &*(&raw const REPORT_REFS);

        chars[0] = char_params(
            c"Protocol Mode",
            PROTOCOL_MODE_CHAR_UUID,
            sys::FlipperGattCharacteristicDataFixed,
            CHAR_VALUE_LEN_CONSTANT,
            CHAR_PROP_READ | CHAR_PROP_WRITE_WITHOUT_RESP,
            GATT_NOTIFY_ATTRIBUTE_WRITE,
        );
        chars[0].data = fixed(1);
        chars[1] = char_params(
            c"Report Map",
            REPORT_MAP_CHAR_UUID,
            sys::FlipperGattCharacteristicDataCallback,
            CHAR_VALUE_LEN_VARIABLE,
            CHAR_PROP_READ,
            GATT_DONT_NOTIFY_EVENTS,
        );
        chars[1].data = callback(&REPORT_MAP_LEN);
        chars[2] = char_params(
            c"HID Information",
            HID_INFORMATION_CHAR_UUID,
            sys::FlipperGattCharacteristicDataFixed,
            CHAR_VALUE_LEN_CONSTANT,
            CHAR_PROP_READ,
            GATT_DONT_NOTIFY_EVENTS,
        );
        chars[2].data = fixed(HID_INFO.len() as u16);
        chars[3] = char_params(
            c"HID Control Point",
            HID_CONTROL_POINT_CHAR_UUID,
            sys::FlipperGattCharacteristicDataFixed,
            CHAR_VALUE_LEN_CONSTANT,
            CHAR_PROP_WRITE_WITHOUT_RESP,
            GATT_NOTIFY_ATTRIBUTE_WRITE,
        );
        chars[3].data = fixed(1);

        profile.event_handler =
            // The firmware checks the context is not NULL; the handler does
            // not use it.
            sys::ble_event_dispatcher_register_svc_handler(
                Some(service_event),
                (profile as *mut Profile).cast(),
            );

        let uuid = sys::Service_UUID_t {
            Service_UUID_16: HUMAN_INTERFACE_DEVICE_SERVICE_UUID,
        };
        // Service, protocol mode, 4 for each input report, report map,
        // HID information, control point.
        let records = 1 + 2 + 4 * INPUT_REPORT_COUNT as u8 + 2 + 2 + 2;
        if !sys::ble_gatt_service_add(
            UUID_TYPE_16,
            &uuid,
            PRIMARY_SERVICE,
            records,
            &mut profile.svc_handle,
        ) {
            sys::ble_event_dispatcher_unregister_svc_handler(profile.event_handler);
            return false;
        }

        sys::ble_gatt_characteristic_init(profile.svc_handle, &chars[0], &mut profile.chars[0]);
        let protocol_mode: u8 = 1;
        sys::ble_gatt_characteristic_update(
            profile.svc_handle,
            &mut profile.chars[0],
            (&raw const protocol_mode).cast(),
        );

        for i in 0..INPUT_REPORT_COUNT {
            let descriptor = &mut descriptors[i];
            descriptor.uuid_type = UUID_TYPE_16;
            descriptor.uuid.Char_UUID_16 = REPORT_REFERENCE_DESCRIPTOR_UUID;
            descriptor.max_length = 2;
            descriptor.data_callback.fn_ = Some(descriptor_data);
            descriptor.data_callback.context = refs[i].as_ptr().cast();
            descriptor.security_permissions = ATTR_PERMISSION_NONE;
            descriptor.access_permissions = ATTR_ACCESS_READ_WRITE;
            descriptor.gatt_evt_mask = GATT_DONT_NOTIFY_EVENTS;
            descriptor.is_variable = CHAR_VALUE_LEN_CONSTANT;

            reports[i] = char_params(
                c"Report",
                REPORT_CHAR_UUID,
                sys::FlipperGattCharacteristicDataCallback,
                CHAR_VALUE_LEN_VARIABLE,
                CHAR_PROP_READ | CHAR_PROP_NOTIFY,
                GATT_DONT_NOTIFY_EVENTS,
            );
            reports[i].data = callback(&REPORT_LENS[i]);
            reports[i].descriptor_params = descriptor;
            sys::ble_gatt_characteristic_init(
                profile.svc_handle,
                &reports[i],
                &mut profile.input_reports[i],
            );
        }

        for i in 1..CHAR_COUNT {
            sys::ble_gatt_characteristic_init(profile.svc_handle, &chars[i], &mut profile.chars[i]);
        }
    }
    true
}

unsafe fn service_stop(profile: &mut Profile) {
    unsafe {
        sys::ble_event_dispatcher_unregister_svc_handler(profile.event_handler);
        for c in profile
            .chars
            .iter_mut()
            .chain(profile.input_reports.iter_mut())
        {
            sys::ble_gatt_characteristic_delete(profile.svc_handle, c);
        }
        sys::ble_gatt_service_delete(profile.svc_handle);
    }
}

/// `ble_profile_hid_start`, called by the Bt service from `bt_profile_start`.
unsafe extern "C" fn profile_start(
    _params: sys::FuriHalBleProfileParams,
) -> *mut sys::FuriHalBleProfileBase {
    unsafe {
        let profile = &mut *(&raw mut PROFILE);
        *profile = zeroed();
        profile.base.config = &TEMPLATE;
        profile.battery_svc = sys::ble_svc_battery_start(true);
        profile.dev_info_svc = sys::ble_svc_dev_info_start();
        if !service_start(profile) {
            return ptr::null_mut();
        }
        let map = Data {
            ptr: REPORT_MAP.as_ptr(),
            len: REPORT_MAP.len() as u16,
        };
        sys::ble_gatt_characteristic_update(
            profile.svc_handle,
            &mut profile.chars[1],
            (&raw const map).cast(),
        );
        sys::ble_gatt_characteristic_update(
            profile.svc_handle,
            &mut profile.chars[2],
            HID_INFO.as_ptr().cast(),
        );
        // The glasses' status, beside the keyboard; the keys work without.
        crate::link::start();
        &mut profile.base
    }
}

unsafe extern "C" fn profile_stop(_profile: *mut sys::FuriHalBleProfileBase) {
    unsafe {
        let profile = &mut *(&raw mut PROFILE);
        sys::ble_svc_battery_stop(profile.battery_svc);
        sys::ble_svc_dev_info_stop(profile.dev_info_svc);
        service_stop(profile);
        crate::link::stop();
    }
}

/// `ble_profile_hid_get_config`: a keyboard, paired with a PIN shown on
/// both sides, at the Flipper's address with its third byte one up, as
/// "Control" and the Flipper's name.
unsafe extern "C" fn profile_get_gap_config(
    config: *mut sys::GapConfig,
    _params: sys::FuriHalBleProfileParams,
) {
    unsafe {
        let config = &mut *config;
        *config = zeroed();
        config.adv_service.UUID_Type = UUID_TYPE_16;
        config.adv_service.Service_UUID_16 = HUMAN_INTERFACE_DEVICE_SERVICE_UUID;
        config.appearance_char = GAP_APPEARANCE_KEYBOARD;
        config.bonding_mode = true;
        config.pairing_method = sys::GapPairingPinCodeVerifyYesNo;
        // 7.5 to 45 ms.
        config.conn_param.conn_int_min = 0x06;
        config.conn_param.conn_int_max = 0x24;

        ptr::copy_nonoverlapping(
            sys::furi_hal_version_get_ble_mac(),
            config.mac_address.as_mut_ptr(),
            6,
        );
        config.mac_address[2] = config.mac_address[2].wrapping_add(1);

        // "%c%s %s": the first byte of the Flipper's own advertised name
        // (its AD type), "Control", a space, the Flipper's name.
        let mut name = Name {
            buf: &mut config.adv_name,
            len: 0,
        };
        name.push(*sys::furi_hal_version_get_ble_local_device_name_ptr() as u8);
        name.extend(b"Control ");
        let flipper = sys::furi_hal_version_get_name_ptr();
        if !flipper.is_null() {
            name.extend(CStr::from_ptr(flipper).to_bytes());
        }
    }
}

/// A NUL-terminated name cut to its buffer, as snprintf does.
struct Name<'a> {
    buf: &'a mut [core::ffi::c_char],
    len: usize,
}

impl Name<'_> {
    fn push(&mut self, b: u8) {
        if self.len + 1 < self.buf.len() {
            self.buf[self.len] = b as core::ffi::c_char;
            self.len += 1;
            self.buf[self.len] = 0;
        }
    }

    fn extend(&mut self, bytes: &[u8]) {
        for &b in bytes {
            self.push(b);
        }
    }
}

/// The Flipper as a Bluetooth keyboard while this lives; the Flipper's
/// own Bluetooth (the phone app's RPC) comes back when it is dropped.
pub struct Hid {
    bt: UnsafeRecord<sys::Bt>,
}

impl Hid {
    /// Takes over the Bluetooth as `hid_ble_app` does. `on_status` hears
    /// of the phone connecting and going, from the Bt service's thread;
    /// `on_data`, of what it writes to the glaz service (`link`).
    pub fn start(
        on_status: sys::BtStatusChangedCallback,
        on_data: crate::link::Receiver,
        context: *mut c_void,
    ) -> Option<Self> {
        crate::link::set_receiver(Some(on_data), context);
        unsafe {
            let bt = UnsafeRecord::<sys::Bt>::open(c"bt");
            sys::bt_disconnect(bt.as_ptr());
            // The second core writes its keys to flash meanwhile.
            sys::furi_delay_ms(200);
            sys::bt_keys_storage_set_storage_path(bt.as_ptr(), KEYS_PATH.as_ptr());
            if sys::bt_profile_start(bt.as_ptr(), &TEMPLATE, ptr::null_mut()).is_null() {
                sys::bt_keys_storage_set_default_path(bt.as_ptr());
                sys::bt_profile_restore_default(bt.as_ptr());
                return None;
            }
            sys::furi_hal_bt_start_advertising();
            sys::bt_set_status_changed_callback(bt.as_ptr(), on_status, context);
            Some(Self { bt })
        }
    }

    fn profile(&self) -> &mut Profile {
        unsafe { &mut *(&raw mut PROFILE) }
    }

    fn send(&self, number: usize, data: *const u8, len: usize) -> bool {
        let profile = self.profile();
        let data = Data {
            ptr: data,
            len: len as u16,
        };
        unsafe {
            sys::ble_gatt_characteristic_update(
                profile.svc_handle,
                &mut profile.input_reports[number],
                (&raw const data).cast(),
            )
        }
    }

    fn send_kb(&self) -> bool {
        let report = &self.profile().kb_report;
        self.send(REPORT_KEYBOARD, report.as_ptr(), report.len())
    }

    /// Holds a key down; a modifier in the high byte, as the firmware has.
    pub fn kb_press(&self, key: u16) -> bool {
        let report = &mut self.profile().kb_report;
        if let Some(slot) = report[2..].iter_mut().find(|k| **k == 0) {
            *slot = key as u8;
        }
        report[0] |= (key >> 8) as u8;
        self.send_kb()
    }

    pub fn kb_release(&self, key: u16) -> bool {
        let report = &mut self.profile().kb_report;
        if let Some(slot) = report[2..].iter_mut().find(|k| **k == key as u8) {
            *slot = 0;
        }
        report[0] &= !((key >> 8) as u8);
        self.send_kb()
    }

    pub fn kb_release_all(&self) -> bool {
        self.profile().kb_report = [0; 2 + KB_MAX_KEYS];
        self.send_kb()
    }

    pub fn consumer_press(&self, key: u16) -> bool {
        let profile = self.profile();
        if profile.consumer_report == 0 {
            profile.consumer_report = key;
        }
        self.send(
            REPORT_CONSUMER,
            (&raw const profile.consumer_report).cast(),
            2,
        )
    }

    pub fn consumer_release(&self, key: u16) -> bool {
        let profile = self.profile();
        if profile.consumer_report == key {
            profile.consumer_report = 0;
        }
        self.send(
            REPORT_CONSUMER,
            (&raw const profile.consumer_report).cast(),
            2,
        )
    }
}

impl Drop for Hid {
    fn drop(&mut self) {
        unsafe {
            let bt = self.bt.as_ptr();
            sys::bt_set_status_changed_callback(bt, None, ptr::null_mut());
            crate::link::set_receiver(None, ptr::null_mut());
            sys::bt_disconnect(bt);
            sys::furi_delay_ms(200);
            sys::bt_keys_storage_set_default_path(bt);
            sys::bt_profile_restore_default(bt);
        }
    }
}
