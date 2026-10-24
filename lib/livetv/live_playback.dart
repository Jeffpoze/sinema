import 'dart:async';
import 'dart:io' show Platform;

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

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
  // In memory only; iOS apps can't create mpv's on-disk cache.
  await set('cache-on-disk', 'no');
  if (softwareDecode) await set('hwdec', 'no');
}

// How Live TV draws video. On iPhone, media_kit's hardware renderer is built
// on OpenGL ES, which recent iOS versions no longer provide — mpv then has no
// render context and never shows a picture. Its software renderer works
// everywhere; decoding still uses the hardware decoder, copying frames back.
VideoController liveVideoController(Player player) => VideoController(
      player,
      configuration: Platform.isIOS
          ? const VideoControllerConfiguration(enableHardwareAcceleration: false, hwdec: 'auto-copy')
          : const VideoControllerConfiguration(),
    );

// The video surface must exist before a stream is opened, or mpv starts
// with no video output ("No render context set") and never shows a picture.
Future<void> videoReady(VideoController controller) async {
  try {
    await controller.platform.future.timeout(const Duration(seconds: 5));
  } catch (_) {}
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
