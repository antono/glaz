//! The Flipper's Bluetooth while the app is open: a profile of its own
//! with only the glaz service (`link`) on it.
//!
//! No keyboard: Android sees a plain Bluetooth device, so its on-screen
//! keyboard stays and no app but glaz hears the keys. The Flipper's own
//! Bluetooth (the phone app's RPC) is off meanwhile, and comes back when
//! this is dropped, as after the Flipper's Remote.
//!
//! Its own address, name and pairing, apart from the Flipper's and its
//! Remote's: a phone pairs with "Glaz" once, and the Remote's pairing
//! is left as it was.

use core::ffi::{CStr, c_void};
use core::mem::zeroed;
use core::ptr;

use flipperzero_sys as sys;
use flipperzero_sys::furi::UnsafeRecord;

/// Where the pairing is kept, in a folder of the app's own.
const KEYS_DIR: &CStr = c"/ext/apps_data/glaz";
const KEYS_PATH: &CStr = c"/ext/apps_data/glaz/.bt.keys";

// From the ST BLE stack headers (lib/stm32wb_copro).
const UUID_TYPE_128: u8 = 0x02;
/// Generic Remote Control.
const GAP_APPEARANCE_REMOTE: u16 = 0x0180;

/// The name. With the glaz service's 128-bit UUID it has to fit the 31
/// bytes of an advertisement: "Glaz" and the Flipper's name, cut to 8,
/// did not -- nothing was advertised -- and "Glaz" alone does.
const NAME: &[u8] = b"Glaz";

/// The profile, as the firmware keeps it: `base` first, as it takes a
/// pointer to it for the whole.
#[repr(C)]
struct Profile {
    base: sys::FuriHalBleProfileBase,
}

// One profile at a time, as the radio has one.
static mut PROFILE: Profile = unsafe { zeroed() };

static TEMPLATE: sys::FuriHalBleProfileTemplate = sys::FuriHalBleProfileTemplate {
    start: Some(profile_start),
    stop: Some(profile_stop),
    get_gap_config: Some(profile_get_gap_config),
};

/// Called by the Bt service from `bt_profile_start`.
unsafe extern "C" fn profile_start(
    _params: sys::FuriHalBleProfileParams,
) -> *mut sys::FuriHalBleProfileBase {
    unsafe {
        let profile = &mut *(&raw mut PROFILE);
        *profile = zeroed();
        profile.base.config = &TEMPLATE;
        if !crate::link::start() {
            return ptr::null_mut();
        }
        &mut profile.base
    }
}

unsafe extern "C" fn profile_stop(_profile: *mut sys::FuriHalBleProfileBase) {
    unsafe { crate::link::stop() }
}

/// A remote, paired with a PIN shown on both sides, at the Flipper's
/// address with its third byte two up (the Remote's is one up), as
/// "Glaz".
unsafe extern "C" fn profile_get_gap_config(
    config: *mut sys::GapConfig,
    _params: sys::FuriHalBleProfileParams,
) {
    unsafe {
        let config = &mut *config;
        *config = zeroed();
        config.adv_service.UUID_Type = UUID_TYPE_128;
        config.adv_service.Service_UUID_128 = crate::link::SERVICE_UUID;
        config.appearance_char = GAP_APPEARANCE_REMOTE;
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
        config.mac_address[2] = config.mac_address[2].wrapping_add(2);

        // The first byte of the Flipper's own advertised name (its AD
        // type), then the name; the rest stays NUL.
        config.adv_name[0] = *sys::furi_hal_version_get_ble_local_device_name_ptr();
        for (i, &b) in NAME.iter().enumerate() {
            config.adv_name[1 + i] = b as core::ffi::c_char;
        }
    }
}

/// The Flipper's Bluetooth as the glaz remote while this lives; its own
/// comes back when it is dropped.
pub struct Ble {
    bt: UnsafeRecord<sys::Bt>,
}

impl Ble {
    /// Takes over the Bluetooth as the Remote app does. `on_status` hears
    /// of the phone connecting and going, from the Bt service's thread;
    /// `on_data`, of what it writes to the glaz service (`link`).
    pub fn start(
        on_status: sys::BtStatusChangedCallback,
        on_data: crate::link::Receiver,
        context: *mut c_void,
    ) -> Option<Self> {
        crate::link::set_receiver(Some(on_data), context);
        unsafe {
            let storage = UnsafeRecord::<sys::Storage>::open(c"storage");
            sys::storage_simply_mkdir(storage.as_ptr(), KEYS_DIR.as_ptr());
            drop(storage);

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

    /// Tells the phone of a press (`link::send_keys`).
    pub fn send_key(&self, key: u8, press: u8) -> bool {
        crate::link::send_keys(&[1, key, press])
    }
}

impl Drop for Ble {
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
