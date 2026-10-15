import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

/// Where photos are kept.
///
/// On Android: the shared Pictures/Glaz, not the app's own storage. Android
/// deletes an app's own folders when it is uninstalled; shared media stays,
/// and shows in the phone's gallery too. Since Android 11 an app may write
/// there with no permission, and reads back what it wrote. Photos left by an
/// earlier install belong to that install, though: reading them takes the
/// photos permission ([photoAccess]).
///
/// Elsewhere: the app's documents folder.
Future<Directory> photoRoot() async {
  if (!kIsWeb && Platform.isAndroid) {
    final own = await getExternalStorageDirectory();
    final shared = own == null ? null : sharedPictures(own.path);
    if (shared != null && await _writable(Directory(shared))) {
      return Directory(shared);
    }
  }
  return Directory('${(await getApplicationDocumentsDirectory()).path}/photos');
}

/// Android 10 and older want a storage permission to write there, which
/// this app does not ask for; on those the photos stay in the app's own
/// folder instead.
Future<bool> _writable(Directory dir) async {
  try {
    await dir.create(recursive: true);
    final probe = File('${dir.path}/.glaz-probe');
    await probe.writeAsString('');
    await probe.delete();
    return true;
  } catch (_) {
    return false;
  }
}

/// The shared Pictures/Glaz of the storage volume holding [appExternal],
/// the app's own external folder:
/// `/storage/emulated/0/Android/data/<id>/files` becomes
/// `/storage/emulated/0/Pictures/Glaz`. Null for any other shape.
@visibleForTesting
String? sharedPictures(String appExternal) {
  final i = appExternal.indexOf('/Android/data/');
  if (i <= 0) return null;
  return '${appExternal.substring(0, i)}/Pictures/Glaz';
}

/// Whether the app may read photos it did not write itself -- those of an
/// earlier install. [request] asks the user.
Future<bool> photoAccess({bool request = false}) async {
  if (kIsWeb || !Platform.isAndroid) return true;
  final status = request
      ? await Permission.photos.request()
      : await Permission.photos.status;
  // Android 14+ "selected photos only" still shows what was picked
  return status.isGranted || status.isLimited;
}
