import 'package:flutter_test/flutter_test.dart';

import 'package:glaz/frame/pairing.dart';

void main() {
  PairingTrouble t(bool bonded, int? code, int drops) =>
      pairingTrouble(bonded: bonded, code: code, quickDrops: drops);

  test('the glasses forgot the phone: keys refused, or quick drops', () {
    expect(t(true, 61, 1), PairingTrouble.phoneStale); // MIC failure
    expect(t(true, 5, 1), PairingTrouble.phoneStale);
    expect(t(true, 137, 0), PairingTrouble.phoneStale);
    expect(t(true, 19, 2), PairingTrouble.phoneStale);
  });

  test('the glasses keep a pairing the phone does not have', () {
    expect(t(false, 19, 1), PairingTrouble.pairedElsewhere);
  });

  test('ordinary drops are not pairing trouble', () {
    expect(t(true, 8, 1), PairingTrouble.none); // out of range, once
    expect(t(true, 19, 0), PairingTrouble.none); // a long link, ended
    expect(t(false, 19, 0), PairingTrouble.none);
    expect(t(false, 61, 3), PairingTrouble.none); // nothing to forget here
  });

  test('the glasses went quiet: timeouts, however many', () {
    expect(t(true, 147, 3), PairingTrouble.none); // GATT_CONNECTION_TIMEOUT
    expect(t(true, 8, 2), PairingTrouble.none); // supervision timeout
    expect(t(false, 147, 3), PairingTrouble.none);
  });

  test('a connect looks for the glasses first when not paired with them', () {
    expect(scanFirst(hasId: false, bonded: null), isTrue); // first time
    expect(scanFirst(hasId: true, bonded: false), isTrue); // pairing forgotten
    expect(scanFirst(hasId: true, bonded: true), isFalse); // straight there
    expect(scanFirst(hasId: true, bonded: null), isFalse); // not Android
  });
}
