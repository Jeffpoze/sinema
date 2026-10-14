import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:just_audio/just_audio.dart';

import 'services/jellyfin_api_service.dart';

// Plays an item's theme song quietly behind its detail page, the way Plex
// does. One shared player for the whole app: opening a new detail page
// hands the music over to that item, and only the page that started a song
// can stop it, so pushing a related title and popping back doesn't leave
// two themes fighting or cut off the wrong one.
class ThemeMusicPlayer {
  ThemeMusicPlayer._() {
    _lifecycle = AppLifecycleListener(
      onHide: () => _player?.pause(),
      onShow: () {
        if (_ownerItemId != null && _player != null) _player!.play();
      },
    );
  }

  static final instance = ThemeMusicPlayer._();

  // Background level: present but well under dialogue/UI sounds.
  static const _targetVolume = 0.35;

  // Held so the listener stays registered for the app's lifetime.
  // ignore: unused_field
  late final AppLifecycleListener _lifecycle;
  final _api = JellyfinApiService();
  AudioPlayer? _player;
  String? _ownerItemId;
  Timer? _fadeTimer;
  int _generation = 0;

  bool isPlayingFor(String itemId) => _ownerItemId == itemId && _player != null;

  Future<void> playFor({
    required String serverUrl,
    required String userId,
    required String token,
    required String itemId,
  }) async {
    if (isPlayingFor(itemId)) return;
    final generation = ++_generation;
    _ownerItemId = itemId;
    final songs = await _api.getThemeSongs(serverUrl, userId, token, itemId);
    // Another page claimed the music (or it was stopped) while we waited.
    if (generation != _generation) return;
    final songId = songs.whereType<Map<String, dynamic>>().firstOrNull?['Id'];
    if (songId is! String) {
      await _release();
      _ownerItemId = itemId;
      return;
    }
    await _release();
    if (generation != _generation) return;
    _ownerItemId = itemId;
    final player = AudioPlayer();
    _player = player;
    try {
      await player.setUrl(
        JellyfinApiService.getAudioStreamUrl(serverUrl, songId, userId, token),
        headers: JellyfinApiService.authHeaders(token),
      );
      if (generation != _generation) return;
      await player.setVolume(0);
      unawaited(player.play());
      _fadeTo(player, _targetVolume, const Duration(milliseconds: 1600));
    } catch (_) {
      // A theme song is decoration — a failed load just means silence.
      if (_player == player) await _release();
    }
  }

  // Stops the music only if [itemId]'s page is the one that owns it.
  Future<void> stopFor(String itemId) async {
    if (_ownerItemId != itemId) return;
    await stop();
  }

  Future<void> stop() async {
    _generation++;
    _ownerItemId = null;
    final player = _player;
    if (player == null) return;
    _fadeTo(player, 0, const Duration(milliseconds: 500));
    await Future<void>.delayed(const Duration(milliseconds: 520));
    if (_player == player) await _release();
  }

  void _fadeTo(AudioPlayer player, double target, Duration duration) {
    _fadeTimer?.cancel();
    const step = Duration(milliseconds: 50);
    final steps = (duration.inMilliseconds / step.inMilliseconds).ceil().clamp(1, 1000);
    final start = player.volume;
    var tick = 0;
    _fadeTimer = Timer.periodic(step, (timer) {
      tick++;
      final t = (tick / steps).clamp(0.0, 1.0);
      player.setVolume(start + (target - start) * Curves.easeInOut.transform(t));
      if (tick >= steps) timer.cancel();
    });
  }

  Future<void> _release() async {
    _fadeTimer?.cancel();
    final player = _player;
    _player = null;
    if (player == null) return;
    try {
      await player.stop();
    } catch (_) {}
    await player.dispose();
  }
}
