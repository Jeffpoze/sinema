import 'dart:async';

import 'package:media_kit/media_kit.dart';

// Shared setup for the Live TV players (full screen, guide preview,
// multi-view), all running on media_kit / libmpv.

const liveLogLevel = MPVLogLevel.warn;

// Live-friendly mpv options: give up on a dead stream instead of hanging, and
// optionally decode in software (some broadcast streams — interlaced SD
// H.264 in particular — won't decode in the iPhone's hardware decoder).
Future<void> tuneForLive(Player player, {bool softwareDecode = false}) async {
  final native = player.platform;
  if (native is! NativePlayer) return;
  Future<void> set(String key, String value) async {
    try {
      await native.setProperty(key, value);
    } catch (_) {}
  }

  await set('network-timeout', '20');
  await set('cache', 'yes');
  if (softwareDecode) await set('hwdec', 'no');
}

// Keeps the last few warnings/errors mpv printed, to show when a stream
// won't play (the real reason, not just "couldn't play").
class MpvLogTail {
  MpvLogTail(Player player) {
    _sub = player.stream.log.listen((log) {
      final text = log.text.trim();
      if (text.isEmpty) return;
      _lines.add('${log.prefix}: $text');
      if (_lines.length > 4) _lines.removeAt(0);
    });
  }

  final List<String> _lines = [];
  StreamSubscription<PlayerLog>? _sub;

  String get summary => _lines.join('\n');
  void clear() => _lines.clear();
  void dispose() => _sub?.cancel();
}
