import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Where the assistant's speech would go now.
class Headphones {
  const Headphones(this.ok, {this.name, this.why});

  /// Into headphones: it may be said.
  final bool ok;

  /// The output, as Android names it.
  final String? name;

  /// Why not, when not: 'the phone's loudspeaker', 'a Bluetooth speaker'.
  final String? why;
}

/// The assistant's answers read aloud -- in headphones only, never where
/// everyone around hears them (android/.../Voice.kt).
abstract class Voice {
  /// The one this platform has; null where there is none.
  static Voice? get platform =>
      !kIsWeb && Platform.isAndroid ? AndroidVoice() : null;

  Future<Headphones> headphones();

  /// Says [text] in [language] (a BCP 47 tag, or 'auto') if it would go to
  /// headphones; false, and nothing said, otherwise.
  Future<bool> speak(String text, String language);

  Future<void> stop();
}

class AndroidVoice implements Voice {
  static const _calls = MethodChannel('glaz/voice');

  @override
  Future<Headphones> headphones() async {
    try {
      final m = await _calls.invokeMapMethod<String, Object?>('headphones');
      return Headphones(
        m?['ok'] == true,
        name: m?['name'] as String?,
        why: m?['why'] as String?,
      );
    } catch (e) {
      return Headphones(false, why: '$e');
    }
  }

  @override
  Future<bool> speak(String text, String language) async {
    try {
      return await _calls.invokeMethod<bool>('speak', {
            'text': text,
            'language': language,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _calls.invokeMethod('stop');
    } catch (_) {}
  }
}
