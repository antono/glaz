import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:frame_ble/brilliant_dfu_device.dart';
import 'package:frame_ble/frame_ble.dart';

import '../services/notifications.dart';
import 'firmware.dart';
import 'link.dart';
import 'protocol.dart';
import 'update_screen.dart';
import 'upload.dart';

/// Installing a firmware package over Bluetooth (Nordic Secure DFU), the
/// way the Noa app does it (lib/models/app_logic_model.dart there):
///
/// 1. break the running app, put the eye wired up and the version being
///    installed on the glasses (GlassesPicture, kept there through the reboot) and ask
///    the REPL for frame.update(): the
///    glasses reboot into the bootloader, which advertises service fe59 as
///    "Frame Update" and gives up after 3 minutes of nothing
///    (NRF_BL_DFU_INACTIVITY_TIMEOUT_MS in the bootloader's sdk_config.h);
/// 2. find it, connect, and hand the zip to frame_ble's BrilliantDfuDevice,
///    which sends application.dat then application.bin;
/// 3. the glasses reboot into the new firmware, with their files gone --
///    the update wipes the file system (seen on the device) -- so the app
///    is uploaded again, as Upload does it.
///
/// Only the application is replaced (it carries the FPGA image too); the
/// bootloader never is, so a bad build is undone by installing an official
/// one the same way (docs/FIRMWARE.md, docs/RECOVERY.md).
Future<void> installFirmware(
  FrameLink link,
  BrilliantDevice device,
  FirmwarePackage package,
  List<LuaFile> app,
  void Function(String step, [double? progress]) report,
) async {
  report('Stopping the app');
  await device.sendBreakSignal();
  final repl = Repl(device);
  await repl.ready();

  // the eye wired up and the version going on, kept on screen through the
  // update; only a picture, so the update goes on without it. It cannot
  // move: during DFU only the bootloader runs, and it never draws. The bar
  // comes back with the upload after, and a notice says when it is done.
  report('Showing the update on the glasses');
  try {
    final picture = GlassesPicture(repl.run);
    await picture.load();
    await picture.draw('FW ${package.version}');
    await picture.freeze();
  } catch (_) {}

  report('Rebooting into the bootloader');
  try {
    // no answer: the glasses reset before sending one
    await device.sendString('frame.update()', awaitResponse: false);
  } catch (_) {}

  // Let go of the glasses as they were, auto-reconnect and all: it would
  // hold the radio with 30 s connect attempts while the bootloader waits.
  await link.release();

  report('Looking for Frame Update');
  final bootloader = await _findBootloader(const Duration(seconds: 60));

  report('Connecting to the bootloader');
  final connected = await BrilliantBluetooth.connect(bootloader);
  if (connected.state != BrilliantConnectionState.dfuConnected) {
    throw Exception('found the glasses, but not in update mode');
  }
  final dfu = BrilliantDfuDevice(
    device: connected.device,
    state: BrilliantConnectionState.dfuConnected,
  );
  await dfu.connect();

  report('Installing ${package.version}', 0);
  await for (final percent in dfu.updateFirmware(package.asset)) {
    report('Installing ${package.version}', percent / 100);
  }

  // the final EXECUTE reboots the glasses and drops this link
  report('Rebooting into ${package.version}', 1);
  try {
    await dfu.disconnect();
  } catch (_) {}

  report('Connecting to the glasses again');
  await link.reconnect(const Duration(seconds: 60));

  // The update wipes the files on the glasses -- seen: the next Upload
  // found no .lua left to clear -- so the app goes back on at once, and
  // compiled by the new firmware's Lua at that.
  final glasses = link.device;
  if (glasses == null) throw Exception('the glasses dropped the link');
  await uploadApp(glasses, app, report);

  // Their app answers STATUS with the firmware version.
  report('Checking the version');
  link.firmware = null;
  await link.requestStatus(duringTask: true);
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (link.firmware == null && DateTime.now().isBefore(deadline)) {
    await Future.delayed(const Duration(milliseconds: 250));
  }
  final now = link.firmware;
  if (now == null) {
    throw Exception(
      'installed, but the app on the glasses does not answer; '
      'try Upload',
    );
  }
  if (now != package.version) {
    throw Exception('the glasses still report $now');
  }
  report('Installed ${package.version}', 1);
  try {
    await link.send(
      notify,
      NotificationService.encode('Firmware', 'Installed', package.version),
      duringTask: true,
    );
  } catch (_) {}
}

/// The first device advertising the DFU service. Not BrilliantBluetooth.scan:
/// that also matches the glasses in normal mode and takes the strongest
/// signal, which may be another Frame nearby.
Future<BrilliantScannedDevice> _findBootloader(Duration timeout) async {
  final found = Completer<BrilliantScannedDevice>();
  final sub = FlutterBluePlus.onScanResults.listen((results) {
    for (final r in results) {
      if (!found.isCompleted) {
        found.complete(BrilliantScannedDevice(device: r.device, rssi: r.rssi));
      }
    }
  });
  try {
    await FlutterBluePlus.startScan(
      withServices: [Guid('fe59')],
      timeout: timeout,
    );
    return await found.future.timeout(
      timeout,
      onTimeout: () => throw TimeoutException(
        'the glasses did not come up in update mode; they leave it by '
        'themselves within 3 minutes',
      ),
    );
  } finally {
    await sub.cancel();
    await FlutterBluePlus.stopScan();
  }
}
