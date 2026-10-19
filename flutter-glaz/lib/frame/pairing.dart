/// When the pairing between the phone and the glasses no longer holds, and
/// whose side has to forget it.
///
/// Frame keeps one pairing (bluetooth.c in the firmware). It refuses to
/// pair again while it has one -- it answers with a disconnect, HCI 0x13 --
/// and when its pairing is reset (the button on the charger, a factory
/// reset, a firmware update) it no longer knows the keys the phone still
/// offers, so encrypting the link fails and it drops. Either way the
/// glasses are found and the link comes up, then goes down within seconds,
/// again and again.
enum PairingTrouble {
  none,

  /// The glasses forgot this phone; the phone still holds the old pairing.
  /// The phone can forget it itself (Android: removeBond) and pair again.
  phoneStale,

  /// The glasses are paired, but not with this phone as it is now: another
  /// phone, or this one after it forgot them. Only the glasses can forget
  /// that -- the button on the charger.
  pairedElsewhere,
}

/// Disconnect reasons that say the keys did not match. Android passes on
/// the HCI reason, or a GATT status for a failed read or write:
/// 5 authentication failure / insufficient authentication, 6 key missing,
/// 61 (0x3D) MIC failure: encrypted with a key the other side does not
/// have, 137 (0x89) GATT_AUTH_FAIL.
const authFailures = {5, 6, 61, 137};

/// HCI 0x13, remote user terminated: what Frame answers a pairing request
/// with while it is paired already.
const remoteTerminated = 19;

/// Disconnect reasons that say the glasses went quiet, not that they
/// refused: HCI 0x08 supervision timeout, 147 (0x93)
/// GATT_CONNECTION_TIMEOUT. Out of range, or busy or rebooting -- seen
/// right after a module starts or stops. Never pairing trouble, however
/// many in a row.
const timeouts = {8, 147};

/// A link that goes down sooner than this after it came up counts as a
/// quick drop: the glasses turned it down rather than went away.
const quickDrop = Duration(seconds: 5);

/// What a disconnect says about the pairing. [bonded]: the phone holds a
/// pairing with the glasses; [code]: the disconnect reason, if any;
/// [quickDrops]: links in a row, this one included, that went down within
/// [quickDrop] of coming up.
PairingTrouble pairingTrouble({
  required bool bonded,
  required int? code,
  required int quickDrops,
}) {
  if (timeouts.contains(code)) return PairingTrouble.none;
  if (bonded) {
    if (authFailures.contains(code) || quickDrops >= 2) {
      return PairingTrouble.phoneStale;
    }
  } else if (code == remoteTerminated && quickDrops >= 1) {
    return PairingTrouble.pairedElsewhere;
  }
  return PairingTrouble.none;
}
