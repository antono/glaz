//! The glaz service: how the phone tells the Flipper about the glasses.
//!
//! A GATT service of its own beside the keyboard's (`hid`), on the same
//! connection: the phone is connected to the Flipper as to a keyboard
//! anyway, and glaz writes the glasses' status to the one characteristic
//! here. Nothing to pair or switch, and the keys go on as they are.
//!
//! The value, written whole each time, at most `STATUS_MAX_LEN` bytes and
//! in one write (glaz asks for a large enough MTU): a version byte, 1,
//! then fields as tag, length, value -- see `Status::parse` in main.rs.

use core::ffi::c_void;
use core::mem::zeroed;
use core::ptr;

use flipperzero::{info, warn};
use flipperzero_sys as sys;

/// a96fe95e-083f-402e-8be1-a9d5235813ca, little-endian as the stack has it.
const SERVICE_UUID: [u8; 16] = [
    0xca, 0x13, 0x58, 0x23, 0xd5, 0xa9, 0xe1, 0x8b, 0x2e, 0x40, 0x3f, 0x08, 0x5e, 0xe9, 0x6f, 0xa9,
];
/// 99a2eadd-2f24-4073-b412-56fc14ba5ecb: the glasses' status, written by
/// the phone.
const STATUS_UUID: [u8; 16] = [
    0xcb, 0x5e, 0xba, 0x14, 0xfc, 0x56, 0x12, 0xb4, 0x73, 0x40, 0x24, 0x2f, 0xdd, 0xea, 0xa2, 0x99,
];
/// The longest status, two names of 23 bytes and both numbers, is 63.
/// The Bluetooth has little room for values (see `hid::callback`).
pub const STATUS_MAX_LEN: u16 = 64;

// From the ST BLE stack headers (lib/stm32wb_copro).
const UUID_TYPE_128: u8 = 0x02;
const PRIMARY_SERVICE: u8 = 0x01;
const CHAR_PROP_WRITE_WITHOUT_RESP: u8 = 0x04;
const CHAR_PROP_WRITE: u8 = 0x08;
const ATTR_PERMISSION_AUTHEN_WRITE: u8 = 0x08;
const GATT_NOTIFY_ATTRIBUTE_WRITE: u8 = 0x01;
const CHAR_VALUE_LEN_VARIABLE: u8 = 0x01;
const HCI_VENDOR_SPECIFIC_DEBUG_EVT_CODE: u8 = 0xFF;
const ACI_GATT_ATTRIBUTE_MODIFIED_VSEVT_CODE: u16 = 0x0C01;

/// Hears what the phone wrote, on the BLE thread: it must not block.
pub type Receiver = unsafe fn(data: &[u8], context: *mut c_void);

struct Link {
    svc_handle: u16,
    status: sys::BleGattCharacteristicInstance,
    event_handler: *mut sys::GapSvcEventHandler,
    receiver: Option<Receiver>,
    context: *mut c_void,
}

static mut LINK: Link = unsafe { zeroed() };
static mut STATUS_PARAMS: sys::BleGattCharacteristicParams = unsafe { zeroed() };

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
            || u16_at(7) != link.status.handle + 1
        {
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

        let uuid = sys::Service_UUID_t {
            Service_UUID_128: SERVICE_UUID,
        };
        // The service, and the status' declaration and value.
        if !sys::ble_gatt_service_add(
            UUID_TYPE_128,
            &uuid,
            PRIMARY_SERVICE,
            3,
            &mut link.svc_handle,
        ) {
            warn!("glaz service not added");
            return false;
        }
        sys::ble_gatt_characteristic_init(link.svc_handle, params, &mut link.status);
        if link.status.handle == 0 {
            // The firmware has logged why; the keyboard works without.
            warn!("glaz status not added");
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
        sys::ble_gatt_service_delete(link.svc_handle);
    }
}
