import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'glaz_log.dart';
import 'recordings.dart';

/// Where photos are kept.
///
/// On Android: the shared Pictures/Glaz, not the app's own storage. Android
/// deletes an app's own folders when it is uninstalled; shared media stays,
/// and shows in the phone's gallery too. Since Android 11 an app may write
/// there with no permission, and reads back what it wrote. Photos left by an
/// earlier install belong to that install, though: reading them takes the
/// photos permission ([photoAccess]).
///
/// Elsewhere: the app's documents folder. So it is on Android too where
/// the shared folder cannot be written, and what lands there moves to the
/// shared one as soon as it can ([adoptInto]).
Future<Directory> photoRoot() => _mediaRoot('Pictures/Glaz', 'photos', 'jpg');

/// Where Recorder's recordings are kept: the shared Recordings/Glaz, the
/// same way as [photoRoot]. Shown in the phone's own recorder and music
/// apps too. Their transcripts are inside them (recordings.dart,
/// wavComment): Recordings/ takes no text files.
Future<Directory> recordingRoot() =>
    _mediaRoot('Recordings/Glaz', 'recordings', 'wav', before: foldTranscripts);

/// The app's own folder for transcripts a recording cannot hold
/// (RecordingStore.notes).
Future<Directory> recordingNotes() async =>
    Directory('${(await getApplicationDocumentsDirectory()).path}/notes');

/// [ext]: the kind of file kept there. Android 11 and on let an app write
/// in Pictures/ images only, in Recordings/ sound only: anything else is
/// refused, a probe with no extension too -- which once kept every photo in
/// the app's own folder, gone with the app.
Future<Directory> _mediaRoot(
  String shared,
  String own,
  String ext, {
  Future<void> Function(Directory)? before,
}) async {
  final mine = Directory(
    '${(await getApplicationDocumentsDirectory()).path}/$own',
  );
  if (!kIsWeb && Platform.isAndroid) {
    final external = await getExternalStorageDirectory();
    final path = external == null ? null : sharedDir(external.path, shared);
    if (path != null && await _writable(Directory(path), ext)) {
      final dir = Directory(path);
      try {
        await before?.call(mine);
        final moved = await adoptInto(mine, dir, ext);
        if (moved > 0) glazLog(LogKind.task, 'Moved $moved files to $shared');
      } catch (e) {
        glazLog(LogKind.task, 'Moving to $shared: $e', problem: true);
      }
      return dir;
    }
  }
  return mine;
}

/// Moves the [ext] files under [from] to the same places under [to],
/// leaving any already there; the folders left empty go. How many moved.
@visibleForTesting
Future<int> adoptInto(Directory from, Directory to, String ext) async {
  if (!await from.exists()) return 0;
  var moved = 0;
  final files = await from
      .list(recursive: true)
      .where((e) => e is File && e.path.endsWith('.$ext'))
      .cast<File>()
      .toList();
  for (final f in files) {
    final target = File('${to.path}${f.path.substring(from.path.length)}');
    if (await target.exists()) continue;
    await target.parent.create(recursive: true);
    // not rename: the two are on different file systems
    await f.copy(target.path);
    await f.delete();
    moved++;
  }
  final dirs =
      (await from.list(recursive: true).toList())
          .whereType<Directory>()
          .toList()
        ..sort((a, b) => b.path.length.compareTo(a.path.length));
  for (final d in [...dirs, from]) {
    if (await d.list().isEmpty) await d.delete();
  }
  return moved;
}

/// Android 10 and older want a storage permission to write there, which
/// this app does not ask for; on those the photos stay in the app's own
/// folder instead.
Future<bool> _writable(Directory dir, String ext) async {
  try {
    await dir.create(recursive: true);
    final probe = File('${dir.path}/.glaz-probe.$ext');
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
String? sharedPictures(String appExternal) =>
    sharedDir(appExternal, 'Pictures/Glaz');

/// [sub] of the storage volume holding [appExternal]; null for any other
/// shape.
@visibleForTesting
String? sharedDir(String appExternal, String sub) {
  final i = appExternal.indexOf('/Android/data/');
  if (i <= 0) return null;
  return '${appExternal.substring(0, i)}/$sub';
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

/// Whether the app may read recordings it did not write itself, as
/// [photoAccess].
Future<bool> recordingAccess({bool request = false}) async {
  if (kIsWeb || !Platform.isAndroid) return true;
  final status = request
      ? await Permission.audio.request()
      : await Permission.audio.status;
  return status.isGranted;
}
