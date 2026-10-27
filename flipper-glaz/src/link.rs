//! The glaz service: the Flipper's one way to the phone and back.
//!
//! The Flipper is no keyboard: Android sees no keys from it, and no app
//! but glaz hears them. Two characteristics:
//!
//! - status, phone to Flipper, written: what the Flipper shows of the
//!   glasses. Written whole each time, at most `STATUS_MAX_LEN` bytes and
//!   in one write (glaz asks for a large enough MTU): a version byte, 1,
//!   then fields as tag, length, value -- see `Status::parse` in main.rs.
//! - keys, Flipper to phone, notified: one press, `KEYS_LEN` bytes -- a
//!   version byte, 1, the key and the press; see `Key` and `Press` in
//!   main.rs.

use core::ffi::c_void;
use core::mem::zeroed;
use core::ptr;

use flipperzero::{info, warn};
use flipperzero_sys as sys;

/// a96fe95e-083f-402e-8be1-a9d5235813ca, little-endian as the stack has it.
pub const SERVICE_UUID: [u8; 16] = [
    0xca, 0x13, 0x58, 0x23, 0xd5, 0xa9, 0xe1, 0x8b, 0x2e, 0x40, 0x3f, 0x08, 0x5e, 0xe9, 0x6f, 0xa9,
];
/// 99a2eadd-2f24-4073-b412-56fc14ba5ecb: the glasses' status, written by
/// the phone.
const STATUS_UUID: [u8; 16] = [
    0xcb, 0x5e, 0xba, 0x14, 0xfc, 0x56, 0x12, 0xb4, 0x73, 0x40, 0x24, 0x2f, 0xdd, 0xea, 0xa2, 0x99,
];
/// fdf4c755-bc63-4750-9c39-e6ee8b8f55e9: the presses, notified to the
/// phone.
const KEYS_UUID: [u8; 16] = [
    0xe9, 0x55, 0x8f, 0x8b, 0xee, 0xe6, 0x39, 0x9c, 0x50, 0x47, 0x63, 0xbc, 0x55, 0xc7, 0xf4, 0xfd,
];
/// Version, key, press.
pub const KEYS_LEN: u16 = 3;
/// The longest status, two names of 23 bytes, both numbers and the
/// battery, is 66.
pub const STATUS_MAX_LEN: u16 = 72;

// From the ST BLE stack headers (lib/stm32wb_copro).
const UUID_TYPE_128: u8 = 0x02;
const PRIMARY_SERVICE: u8 = 0x01;
const CHAR_PROP_WRITE_WITHOUT_RESP: u8 = 0x04;
const CHAR_PROP_WRITE: u8 = 0x08;
const CHAR_PROP_NOTIFY: u8 = 0x10;
const ATTR_PERMISSION_NONE: u8 = 0x00;
const ATTR_PERMISSION_AUTHEN_WRITE: u8 = 0x08;
const GATT_NOTIFY_ATTRIBUTE_WRITE: u8 = 0x01;
const CHAR_VALUE_LEN_CONSTANT: u8 = 0x00;
const CHAR_VALUE_LEN_VARIABLE: u8 = 0x01;
const HCI_VENDOR_SPECIFIC_DEBUG_EVT_CODE: u8 = 0xFF;
const ACI_GATT_ATTRIBUTE_MODIFIED_VSEVT_CODE: u16 = 0x0C01;

/// Hears what the phone wrote, on the BLE thread: it must not block.
pub type Receiver = unsafe fn(data: &[u8], context: *mut c_void);

struct Link {
    svc_handle: u16,
    status: sys::BleGattCharacteristicInstance,
    keys: sys::BleGattCharacteristicInstance,
    event_handler: *mut sys::GapSvcEventHandler,
    receiver: Option<Receiver>,
    context: *mut c_void,
}

static mut LINK: Link = unsafe { zeroed() };
static mut STATUS_PARAMS: sys::BleGattCharacteristicParams = unsafe { zeroed() };
static mut KEYS_PARAMS: sys::BleGattCharacteristicParams = unsafe { zeroed() };

/// Who hears the writes; set before the profile starts.
pub fn set_receiver(receiver: Option<Receiver>, context: *mut c_void) {
    unsafe {
        let link = &mut *(&raw mut LINK);
        link.receiver = receiver;
        link.context = context;
    }
}

/// A write to the status: aci_gatt_attribute_modified_event_rp0, after
/// hci_uart_pckt's type, hci_event_pckt's evt and plen, and
/// evt_blecore_aci's ecode -- all little-endian.
unsafe extern "C" fn service_event(
    event: *mut c_void,
    context: *mut c_void,
) -> sys::BleEventAckStatus {
    let p = event as *const u8;
    let link = unsafe { &*(context as *const Link) };
    unsafe {
        let u16_at = |i: usize| u16::from_le_bytes([*p.add(i), *p.add(i + 1)]);
        if *p.add(1) != HCI_VENDOR_SPECIFIC_DEBUG_EVT_CODE
            || u16_at(3) != ACI_GATT_ATTRIBUTE_MODIFIED_VSEVT_CODE
        {
            return sys::BleEventNotAck;
        }
        // The phone turning the keys' notifications on or off: the stack
        // keeps that itself.
        if link.keys.handle != 0 && u16_at(7) == link.keys.handle + 2 {
            return sys::BleEventAckFlowEnable;
        }
        if u16_at(7) != link.status.handle + 1 {
            return sys::BleEventNotAck;
        }
        let offset = u16_at(9);
        let len = u16_at(11) as usize;
        if offset != 0 {
            // A long write, in pieces: the phone was to ask for a large
            // enough MTU.
            warn!("status written in pieces, at {}: dropped", offset);
        } else if let Some(receiver) = link.receiver {
            receiver(core::slice::from_raw_parts(p.add(13), len), link.context);
        }
    }
    sys::BleEventAckFlowEnable
}

/// Adds the service; the profile calls it when it starts.
pub unsafe fn start() -> bool {
    unsafe {
        let link = &mut *(&raw mut LINK);
        let params = &mut *(&raw mut STATUS_PARAMS);
        let keys = &mut *(&raw mut KEYS_PARAMS);

        *params = zeroed();
        params.name = c"Glaz Status".as_ptr();
        params.uuid.Char_UUID_128 = STATUS_UUID;
        params._bitfield_1 = sys::BleGattCharacteristicParams::new_bitfield_1(
            sys::FlipperGattCharacteristicDataFixed,
            CHAR_VALUE_LEN_VARIABLE,
            UUID_TYPE_128,
        );
        params.data.fixed = sys::BleGattCharacteristicParams__bindgen_ty_1__bindgen_ty_1 {
            ptr: ptr::null(),
            length: STATUS_MAX_LEN,
        };
        params.char_properties = CHAR_PROP_WRITE | CHAR_PROP_WRITE_WITHOUT_RESP;
        // Only the phone the Flipper is paired with.
        params.security_permissions = ATTR_PERMISSION_AUTHEN_WRITE;
        params.gatt_evt_mask = GATT_NOTIFY_ATTRIBUTE_WRITE;

        *keys = zeroed();
        keys.name = c"Glaz Keys".as_ptr();
        keys.uuid.Char_UUID_128 = KEYS_UUID;
        keys._bitfield_1 = sys::BleGattCharacteristicParams::new_bitfield_1(
            sys::FlipperGattCharacteristicDataFixed,
            CHAR_VALUE_LEN_CONSTANT,
            UUID_TYPE_128,
        );
        keys.data.fixed = sys::BleGattCharacteristicParams__bindgen_ty_1__bindgen_ty_1 {
            ptr: ptr::null(),
            length: KEYS_LEN,
        };
        keys.char_properties = CHAR_PROP_NOTIFY;
        keys.security_permissions = ATTR_PERMISSION_NONE;
        keys.gatt_evt_mask = GATT_NOTIFY_ATTRIBUTE_WRITE;

        let uuid = sys::Service_UUID_t {
            Service_UUID_128: SERVICE_UUID,
        };
        // The service; the status' declaration and value; the keys'
        // declaration, value and notification switch.
        if !sys::ble_gatt_service_add(
            UUID_TYPE_128,
            &uuid,
            PRIMARY_SERVICE,
            6,
            &mut link.svc_handle,
        ) {
            warn!("glaz service not added");
            return false;
        }
        sys::ble_gatt_characteristic_init(link.svc_handle, params, &mut link.status);
        if link.status.handle == 0 {
            // The firmware has logged why; the keys work without.
            warn!("glaz status not added");
        }
        sys::ble_gatt_characteristic_init(link.svc_handle, keys, &mut link.keys);
        if link.keys.handle == 0 {
            warn!("glaz keys not added");
        }
        link.event_handler = sys::ble_event_dispatcher_register_svc_handler(
            Some(service_event),
            (link as *mut Link).cast(),
        );
        info!("glaz service at {}", link.svc_handle);
    }
    true
}

/// Takes the service away; the profile calls it when it stops.
pub unsafe fn stop() {
    unsafe {
        let link = &mut *(&raw mut LINK);
        if link.event_handler.is_null() {
            return;
        }
        sys::ble_event_dispatcher_unregister_svc_handler(link.event_handler);
        link.event_handler = ptr::null_mut();
        sys::ble_gatt_characteristic_delete(link.svc_handle, &mut link.status);
        sys::ble_gatt_characteristic_delete(link.svc_handle, &mut link.keys);
        sys::ble_gatt_service_delete(link.svc_handle);
    }
}

/// Tells the phone of a press: notified if it listens, else only kept.
pub fn send_keys(value: &[u8; KEYS_LEN as usize]) -> bool {
    unsafe {
        let link = &mut *(&raw mut LINK);
        if link.event_handler.is_null() || link.keys.handle == 0 {
            return false;
        }
        sys::ble_gatt_characteristic_update(link.svc_handle, &mut link.keys, value.as_ptr().cast())
    }
}
