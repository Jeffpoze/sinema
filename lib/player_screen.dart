import 'dart:async';

import 'package:better_native_video_player/better_native_video_player.dart';
import 'package:better_native_video_player/cast.dart' as nvp_cast;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'services/jellyfin_api_service.dart';
import 'settings_controller.dart';
import 'widgets/sinema_image.dart';

enum StreamQuality { original, high, medium, low }

extension on StreamQuality {
  int? get maxBitrateBps => switch (this) {
    StreamQuality.original => null,
    StreamQuality.high => 8000000,
    StreamQuality.medium => 4000000,
    StreamQuality.low => 1500000,
  };

  String get label => switch (this) {
    StreamQuality.original => 'Original',
    StreamQuality.high => 'High (8 Mbps)',
    StreamQuality.medium => 'Medium (4 Mbps)',
    StreamQuality.low => 'Low (1.5 Mbps)',
  };
}

// Platform view ids must be unique per screen instance; a plain incrementing
// counter is simpler than deriving one from the item id (which can repeat
// across a list -> detail -> player navigation stack).
int _nextControllerId = 1;

// Moving to the next episode replaces one PlayerScreen with another, and the
// outgoing player is disposed only after the new one is already up. Count
// live players so only the last one out restores portrait orientation.
int _livePlayers = 0;

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    required this.title,
    required this.serverUrl,
    required this.userId,
    required this.token,
    required this.itemId,
    this.startPosition = Duration.zero,
    this.subtitle,
    this.onNext,
    this.nextTitle,
    this.nextSubtitle,
    this.nextImageUrl,
    this.isAudioOnly = false,
    required this.settings,
    this.localFilePath,
  });
  final String title;
  final String? subtitle;
  final String serverUrl;
  final String userId;
  final String token;
  final String itemId;
  final Duration startPosition;
  final VoidCallback? onNext;
  // What the Up Next card shows for the episode [onNext] will start.
  final String? nextTitle;
  final String? nextSubtitle;
  final String? nextImageUrl;
  final bool isAudioOnly;
  final SettingsController settings;
  // When set, plays this local file directly instead of streaming — no
  // Jellyfin session negotiation, progress reporting, or network URL at all.
  final String? localFilePath;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  final _api = JellyfinApiService();
  late final NativeVideoPlayerController _controller;
  String? _error;
  List<dynamic> _jellyfinStreams = const [];
  late StreamQuality _quality = switch (widget.settings.defaultQuality) {
    'high' => StreamQuality.high,
    'medium' => StreamQuality.medium,
    'low' => StreamQuality.low,
    _ => StreamQuality.original,
  };
  int? _subtitleStreamIndex;
  final double _speed = 1.0;
  bool _locked = false;
  Duration _lastKnownPosition = Duration.zero;
  String _playSessionId = '${DateTime.now().microsecondsSinceEpoch}';
  Timer? _progressTimer;
  bool _hasOpenedStreamBefore = false;
  String? _currentStreamUrl;

  bool _isAirplayAvailable = false;
  bool _isAirplayConnected = false;

  nvp_cast.CastSession? _castSession;
  nvp_cast.CastDevice? _castDevice;
  StreamSubscription<nvp_cast.CastSessionStatus>? _castStatusSub;

  bool _isPlaying = true;
  StreamSubscription<PlayerActivityState>? _playerStateSub;
  // After a tap, trust the optimistic icon briefly while the native player
  // catches up, then go back to mirroring what it's actually doing.
  DateTime _lastManualToggle = DateTime.fromMillisecondsSinceEpoch(0);
  Duration _lastPolledPosition = Duration.zero;

  // Intro / recap / credits markers from the server, and where we are in them.
  List<MediaSegment> _segments = const [];
  MediaSegment? _activeSegment;
  final Set<MediaSegment> _autoSkipped = {};
  Timer? _positionTimer;

  // Up Next: a cancellable countdown during the credits before moving on.
  static const _upNextCountdown = 10;
  static const _creditsFallback = Duration(seconds: 30);
  bool _upNextVisible = false;
  bool _upNextCancelled = false;
  bool _advanced = false;
  int _upNextRemaining = _upNextCountdown;
  Timer? _upNextTimer;

  @override
  void initState() {
    super.initState();
    _livePlayers++;
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _controller = NativeVideoPlayerController(
      id: _nextControllerId++,
      autoPlay: true,
      showNativeControls: false,
      allowsPictureInPicture: true,
      canStartPictureInPictureAutomatically: true,
      mediaInfo: NativeVideoPlayerMediaInfo(
        title: widget.title,
        subtitle: widget.subtitle,
      ),
    );
    _controller.addActivityListener(_handleActivityEvent);
    _controller.addAirPlayAvailabilityListener(_handleAirPlayAvailability);
    _controller.addAirPlayConnectionListener(_handleAirPlayConnection);
    // The play/pause icon used to read straight off controller.playerStateStream,
    // but that stream doesn't reliably fire right after a manual play()/pause()
    // call — the icon would stay stuck on the pre-tap state. Track it locally
    // instead: flip it optimistically on tap, and let this subscription correct
    // it for changes we didn't initiate (buffering, completion, etc).
    _playerStateSub = _controller.playerStateStream.listen((state) {
      if (mounted) setState(() => _isPlaying = state.isPlaying);
    });
    // Polled rather than subscribing to positionStream, which the progress
    // bar already listens to. Also keeps the play/pause icon honest: the
    // state stream doesn't reliably report autoplay starting, which left a
    // Play icon showing over a video that was already playing.
    _positionTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      _syncPlayingState();
      if (!widget.isAudioOnly) _handlePosition(_controller.currentPosition);
    });
    if (!widget.isAudioOnly && widget.localFilePath == null) {
      // Jellyfin's transcode has its own idle "kill timer" that tears down
      // the ffmpeg process if it stops hearing from the client — server logs
      // showed exactly this happening mid-playback, since we never sent any
      // keep-alive. Ping roughly every 10s while a stream is open.
      _progressTimer = Timer.periodic(const Duration(seconds: 10), (_) {
        if (_error == null) {
          final position =
              _castSession?.status.position ?? _controller.currentPosition;
          final paused = _castSession != null
              ? !_castSession!.status.isPlaying
              : !_controller.activityState.isPlaying;
          _api.reportPlaybackProgress(
            widget.serverUrl,
            widget.token,
            widget.itemId,
            _playSessionId,
            position,
            isPaused: paused,
          );
        }
      });
    }
    _initializeAndPlay();
  }

  Future<void> _initializeAndPlay() async {
    try {
      await _controller.initialize();
    } catch (e) {
      if (mounted) setState(() => _error = 'Failed to start the player.\n$e');
      return;
    }
    if (!widget.isAudioOnly && widget.localFilePath == null) {
      try {
        final streams = await _api.getMediaStreams(
          widget.serverUrl,
          widget.userId,
          widget.token,
          widget.itemId,
        );
        if (mounted) setState(() => _jellyfinStreams = streams);
      } catch (_) {}
    }
    if (!widget.isAudioOnly) {
      // Fire-and-forget: markers arriving a moment after playback starts is
      // fine, and a server without them just never shows a Skip button.
      _api.getSkipSegments(widget.serverUrl, widget.token, widget.itemId, userId: widget.userId).then((segments) {
        if (mounted) setState(() => _segments = segments);
      });
    }
    _openStream(position: widget.startPosition);
  }

  Future<void> _openStream({required Duration position}) async {
    final localPath = widget.localFilePath;
    if (localPath != null) {
      // Fully offline: no Jellyfin session to negotiate or report progress
      // to. Watch state for this playback syncs next time the item is
      // streamed normally, same as any offline-capable client.
      _hasOpenedStreamBefore = true;
      await _controller.load(url: 'file://$localPath', startAt: position, force: true);
      if (_speed != 1.0) await _controller.setSpeed(_speed);
      return;
    }
    // Reopening (quality/subtitle change, or Retry) without telling Jellyfin
    // the previous session ended can leave its transcode job running
    // alongside the new one — two ffmpeg jobs competing for the same CPU is
    // exactly the kind of contention that starves both and shows up as a
    // fatal read timeout on either.
    if (_hasOpenedStreamBefore && !widget.isAudioOnly) {
      _api.reportPlaybackStopped(
        widget.serverUrl,
        widget.token,
        widget.itemId,
        _playSessionId,
        _controller.currentPosition,
      );
    }
    _hasOpenedStreamBefore = true;
    if (widget.isAudioOnly) {
      final url = JellyfinApiService.getAudioStreamUrl(
        widget.serverUrl,
        widget.itemId,
        widget.userId,
        widget.token,
        maxBitrateBps: _quality.maxBitrateBps,
      );
      _currentStreamUrl = url;
      await _controller.load(
        url: url,
        headers: JellyfinApiService.authHeaders(widget.token),
        startAt: position,
        force: true,
      );
      if (_speed != 1.0) await _controller.setSpeed(_speed);
      return;
    }

    // Only the plain "Original, no forced subtitle" case is eligible for
    // direct-play negotiation. Quality caps and burned-in subtitles keep
    // using the known-working forced-transcode request.
    if (_quality == StreamQuality.original && _subtitleStreamIndex == null) {
      try {
        final playbackInfo = await _api.getPlaybackInfo(
          widget.serverUrl,
          widget.userId,
          widget.token,
          widget.itemId,
        );
        final result = JellyfinApiService.buildUrlFromPlaybackInfo(
          widget.serverUrl,
          widget.itemId,
          widget.token,
          playbackInfo,
        );
        if (result != null) {
          final (url, playSessionId) = result;
          _playSessionId = playSessionId;
          _currentStreamUrl = url;
          await _controller.load(
            url: url,
            headers: JellyfinApiService.authHeaders(widget.token),
            startAt: position,
            force: true,
          );
          if (_speed != 1.0) await _controller.setSpeed(_speed);
          _api.reportPlaybackStart(
            widget.serverUrl,
            widget.token,
            widget.itemId,
            _playSessionId,
          );
          return;
        }
      } catch (e) {
        print(
          'getPlaybackInfo negotiation failed for ${widget.itemId}, falling back to forced transcode: $e',
        );
      }
    }

    final url = JellyfinApiService.getStreamUrl(
      widget.serverUrl,
      widget.itemId,
      widget.token,
      maxBitrateBps: _quality.maxBitrateBps,
      subtitleStreamIndex: _subtitleStreamIndex,
      subtitleMethod: _subtitleStreamIndex == null
          ? null
          : JellyfinApiService.subtitleMethodFor(
              _subtitleCodec(_subtitleStreamIndex!),
            ),
      playSessionId: _playSessionId,
    );
    _currentStreamUrl = url;
    await _controller.load(
      url: url,
      headers: JellyfinApiService.authHeaders(widget.token),
      startAt: position,
      force: true,
    );
    if (_speed != 1.0) await _controller.setSpeed(_speed);
    if (_subtitleStreamIndex != null) {
      // The plugin deliberately starts every new item with subtitles off,
      // regardless of what the HLS manifest itself flags as DEFAULT — its
      // own docs say the app owns subtitle selection. Jellyfin embeds only
      // the one subtitle stream we asked for via SubtitleStreamIndex, so
      // there should be exactly one (non-off) track to select here.
      final tracks = await _controller.getAvailableSubtitleTracks();
      if (tracks.isNotEmpty) await _controller.setSubtitleTrack(tracks.first);
    }
    _api.reportPlaybackStart(
      widget.serverUrl,
      widget.token,
      widget.itemId,
      _playSessionId,
    );
  }

  void _handleActivityEvent(PlayerActivityEvent event) {
    switch (event.state) {
      case PlayerActivityState.error:
        _lastKnownPosition = _controller.currentPosition;
        final nativeMessage =
            (event.data?['message'] as String?) ?? 'Unable to play this video.';
        if (mounted) setState(() => _error = nativeMessage);
        break;
      case PlayerActivityState.completed:
        if (widget.settings.autoPlayNext && !_upNextCancelled) _playNext();
        break;
      default:
        break;
    }
  }

  void _handleAirPlayAvailability(bool available) {
    if (mounted) setState(() => _isAirplayAvailable = available);
  }

  void _handleAirPlayConnection(bool connected) {
    if (mounted) setState(() => _isAirplayConnected = connected);
  }

  String? _subtitleCodec(int index) {
    final match = _jellyfinStreams.whereType<Map<String, dynamic>>().where(
      (s) => s['Index'] == index,
    );
    return match.isEmpty ? null : match.first['Codec'] as String?;
  }

  List<Map<String, dynamic>> get _subtitleTracks => _jellyfinStreams
      .whereType<Map<String, dynamic>>()
      .where((s) => s['Type'] == 'Subtitle')
      .toList();

  List<Map<String, dynamic>> get _audioStreamsJellyfin => _jellyfinStreams
      .whereType<Map<String, dynamic>>()
      .where((s) => s['Type'] == 'Audio')
      .toList();

  static const _languageNames = {
    'eng': 'English',
    'en': 'English',
    'fre': 'French',
    'fra': 'French',
    'fr': 'French',
    'ger': 'German',
    'deu': 'German',
    'de': 'German',
    'spa': 'Spanish',
    'es': 'Spanish',
    'ita': 'Italian',
    'it': 'Italian',
    'jpn': 'Japanese',
    'ja': 'Japanese',
    'kor': 'Korean',
    'ko': 'Korean',
    'chi': 'Chinese',
    'zho': 'Chinese',
    'zh': 'Chinese',
    'por': 'Portuguese',
    'pt': 'Portuguese',
    'rus': 'Russian',
    'ru': 'Russian',
    'ara': 'Arabic',
    'ar': 'Arabic',
    'hin': 'Hindi',
    'hi': 'Hindi',
    'dut': 'Dutch',
    'nld': 'Dutch',
    'nl': 'Dutch',
    'swe': 'Swedish',
    'sv': 'Swedish',
    'pol': 'Polish',
    'pl': 'Polish',
    'tur': 'Turkish',
    'tr': 'Turkish',
  };

  String? _languageName(String? code) {
    if (code == null || code.isEmpty) return null;
    return _languageNames[code.toLowerCase()] ?? code.toUpperCase();
  }

  // AVFoundation/ExoPlayer's own introspected audio-track metadata is often
  // missing or generic (e.g. "Unknown") for tracks remuxed without proper
  // language tags — Jellyfin's own MediaStreams data (ffprobe-derived) is
  // reliable, so prefer it, matched to the native track list by ordinal
  // position (both reflect the same file's audio tracks in the same order).
  String _audioTrackLabel(NativeVideoPlayerAudioTrack track, int ordinalIndex) {
    final jellyfinStreams = _audioStreamsJellyfin;
    if (ordinalIndex >= 0 && ordinalIndex < jellyfinStreams.length) {
      final stream = jellyfinStreams[ordinalIndex];
      final language = _languageName(stream['Language'] as String?);
      final codec = (stream['Codec'] as String?)?.toUpperCase();
      final channelLayout = stream['ChannelLayout'] as String?;
      if (language != null) {
        final details = [
          if (codec != null && codec.isNotEmpty) codec,
          if (channelLayout != null && channelLayout.isNotEmpty) channelLayout,
        ].join(' ');
        return details.isEmpty ? language : '$language ($details)';
      }
    }
    final languageName = _languageName(track.language);
    if (languageName != null) return languageName;
    return track.displayName.isNotEmpty ? track.displayName : 'Audio';
  }

  Future<void> _toggleSubtitles() async {
    final tracks = _subtitleTracks;
    if (tracks.isEmpty) return;
    final position = _controller.currentPosition;
    setState(
      () => _subtitleStreamIndex = _subtitleStreamIndex == null
          ? tracks.first['Index'] as int?
          : null,
    );
    await _openStream(position: position);
  }

  void _syncPlayingState() {
    if (!mounted || _castSession != null) return;
    if (DateTime.now().difference(_lastManualToggle) < const Duration(milliseconds: 1500)) return;
    // The clock moving is the ground truth for "playing"; only when it's
    // standing still do we fall back to the plugin's own state flag.
    final position = _controller.currentPosition;
    final advanced = position > _lastPolledPosition;
    _lastPolledPosition = position;
    final playing = advanced || _controller.activityState.isPlaying;
    if (playing != _isPlaying) setState(() => _isPlaying = playing);
  }

  Future<void> _togglePlayPause() async {
    _lastManualToggle = DateTime.now();
    final wasPlaying = _isPlaying;
    setState(() => _isPlaying = !wasPlaying);
    if (wasPlaying) {
      await _controller.pause();
    } else {
      await _controller.play();
    }
  }

  void _toggleLock() {
    setState(() => _locked = !_locked);
  }

  void _seekBy(Duration offset) {
    final position = _controller.currentPosition + offset;
    final duration = _controller.duration;
    final clamped = position < Duration.zero
        ? Duration.zero
        : (duration > Duration.zero && position > duration
              ? duration
              : position);
    _controller.seekTo(clamped);
  }

  Future<void> _retry() async {
    setState(() => _error = null);
    await _openStream(position: _lastKnownPosition);
  }

  Future<void> _openSettings() async {
    final position = _controller.currentPosition;
    final audioTracks = await _controller.getAvailableAudioTracks();
    final subtitleStreams = _subtitleTracks;
    if (!mounted) return;

    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetContext) => _PlayerSettingsSheet(
        quality: _quality,
        subtitleLabel: _subtitleLabel(),
        audioLabel: audioTracks.isEmpty ? 'Default' : _audioTrackLabel(audioTracks[_selectedAudioIndex(audioTracks)], _selectedAudioIndex(audioTracks)),
        hasSubtitles: subtitleStreams.isNotEmpty,
        hasAudioChoices: audioTracks.length > 1,
        onQuality: () => _chooseQuality(sheetContext, position),
        onSubtitles: () =>
            _chooseSubtitles(sheetContext, position, subtitleStreams),
        onAudio: () => _chooseAudio(sheetContext, audioTracks),
      ),
    );
  }

  int _selectedAudioIndex(List<NativeVideoPlayerAudioTrack> tracks) {
    final index = tracks.indexWhere((t) => t.isSelected);
    return index >= 0 ? index : 0;
  }

  String _subtitleLabel() {
    if (_subtitleStreamIndex == null) return 'Off';
    final stream = _subtitleTracks
        .cast<Map<String, dynamic>>()
        .where((s) => s['Index'] == _subtitleStreamIndex)
        .firstOrNull;
    if (stream == null) return 'On';
    final language = _languageName(stream['Language'] as String?) ?? 'Unknown';
    final codec = (stream['Codec'] as String?)?.toUpperCase();
    return codec == null || codec.isEmpty ? language : '$language ($codec)';
  }

  Future<void> _chooseQuality(
    BuildContext sheetContext,
    Duration position,
  ) async {
    final selected = await _showChoiceSheet<StreamQuality>(
      sheetContext,
      title: 'Quality',
      value: _quality,
      options: StreamQuality.values
          .map((quality) => _ChoiceOption(quality, quality.label))
          .toList(),
    );
    if (selected == null || !mounted) return;
    setState(() => _quality = selected);
    await _openStream(position: position);
  }

  Future<void> _chooseSubtitles(
    BuildContext sheetContext,
    Duration position,
    List<Map<String, dynamic>> streams,
  ) async {
    final options = <_ChoiceOption<int?>>[_ChoiceOption(null, 'Off')];
    for (final stream in streams) {
      final language =
          _languageName(stream['Language'] as String?) ?? 'Unknown';
      final codec = (stream['Codec'] as String?)?.toUpperCase();
      options.add(
        _ChoiceOption(
          stream['Index'] as int?,
          codec == null ? language : '$language ($codec)',
        ),
      );
    }
    final selected = await _showChoiceSheet<int?>(
      sheetContext,
      title: 'Subtitles',
      value: _subtitleStreamIndex,
      options: options,
    );
    if (!mounted) return;
    setState(() => _subtitleStreamIndex = selected);
    await _openStream(position: position);
  }

  Future<void> _chooseAudio(
    BuildContext sheetContext,
    List<NativeVideoPlayerAudioTrack> tracks,
  ) async {
    final selectedIndex = await _showChoiceSheet<int>(
      sheetContext,
      title: 'Audio',
      value: tracks.indexWhere((t) => t.isSelected),
      options: [
        for (var i = 0; i < tracks.length; i++)
          _ChoiceOption(i, _audioTrackLabel(tracks[i], i)),
      ],
    );
    if (selectedIndex == null || selectedIndex < 0 || !mounted) return;
    await _controller.setAudioTrack(tracks[selectedIndex]);
  }

  Future<T?> _showChoiceSheet<T>(
    BuildContext context, {
    required String title,
    required T value,
    required List<_ChoiceOption<T>> options,
  }) => showModalBottomSheet<T>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (context) =>
        _ChoiceSheet<T>(title: title, value: value, options: options),
  );

  Future<void> _showCastPicker() async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF101114),
      isScrollControlled: true,
      builder: (sheetContext) => _CastPickerSheet(
        onSelected: (device) {
          Navigator.of(sheetContext).pop();
          _connectCast(device);
        },
      ),
    );
  }

  Future<void> _connectCast(nvp_cast.CastDevice device) async {
    final url = _currentStreamUrl;
    if (url == null) return;
    try {
      final session = await nvp_cast.CastSession.connect(device);
      await session.loadMedia(
        contentUrl: url,
        contentType: 'application/x-mpegURL',
        title: widget.title,
        subtitle: widget.subtitle,
        startAt: _controller.currentPosition,
      );
      await _controller.pause();
      if (!mounted) {
        await session.close();
        return;
      }
      setState(() {
        _castSession = session;
        _castDevice = device;
      });
      _castStatusSub = session.statusStream.listen((_) {
        if (mounted) setState(() {});
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not cast to ${device.displayName}: $e'),
          ),
        );
      }
    }
  }

  Future<void> _disconnectCast() async {
    final session = _castSession;
    _castStatusSub?.cancel();
    _castStatusSub = null;
    setState(() {
      _castSession = null;
      _castDevice = null;
    });
    await session?.close();
    await _controller.play();
  }

  MediaSegment? get _outro {
    for (final segment in _segments) {
      if (segment.kind == MediaSegmentKind.outro) return segment;
    }
    return null;
  }

  // With no credits marker, treat the last 30s of anything over 5 minutes
  // as the credits so Up Next still appears.
  bool _isInCredits(Duration position) {
    final outro = _outro;
    if (outro != null) return position >= outro.start;
    final duration = _controller.duration;
    if (duration < const Duration(minutes: 5)) return false;
    return duration - position <= _creditsFallback;
  }

  void _handlePosition(Duration position) {
    if (!mounted || _castSession != null) return;
    MediaSegment? active;
    for (final segment in _segments) {
      if (segment.contains(position)) {
        active = segment;
        break;
      }
    }
    if (active != _activeSegment) setState(() => _activeSegment = active);

    if (active != null &&
        active.kind != MediaSegmentKind.outro &&
        widget.settings.autoSkipIntro &&
        _autoSkipped.add(active)) {
      _controller.seekTo(active.end);
      return;
    }

    final canAutoAdvance = widget.onNext != null && widget.settings.autoPlayNext && !_upNextCancelled && !_advanced;
    if (!canAutoAdvance) return;
    final inCredits = _isInCredits(position);
    if (inCredits && !_upNextVisible) {
      _showUpNext();
    } else if (!inCredits && _upNextVisible) {
      // Scrubbed back out of the credits: put the card away, but let it come
      // back with a fresh countdown next time.
      _upNextTimer?.cancel();
      setState(() => _upNextVisible = false);
    }
  }

  void _showUpNext() {
    _upNextTimer?.cancel();
    setState(() {
      _upNextVisible = true;
      _upNextRemaining = _upNextCountdown;
    });
    _upNextTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      // Hold the countdown while the viewer has paused.
      if (!_isPlaying) return;
      if (_upNextRemaining <= 1) {
        timer.cancel();
        _playNext();
        return;
      }
      setState(() => _upNextRemaining--);
    });
  }

  void _cancelUpNext() {
    _upNextTimer?.cancel();
    setState(() {
      _upNextVisible = false;
      _upNextCancelled = true;
    });
  }

  void _playNext() {
    final onNext = widget.onNext;
    if (onNext == null || _advanced) return;
    _advanced = true;
    _upNextTimer?.cancel();
    onNext();
  }

  void _skipActiveSegment() {
    final segment = _activeSegment;
    if (segment == null) return;
    if (segment.kind == MediaSegmentKind.outro && widget.onNext != null) {
      _playNext();
      return;
    }
    _controller.seekTo(segment.end);
  }

  String? get _skipLabel {
    final segment = _activeSegment;
    if (segment == null) return null;
    return switch (segment.kind) {
      MediaSegmentKind.intro => 'Skip Intro',
      MediaSegmentKind.recap => 'Skip Recap',
      MediaSegmentKind.preview => 'Skip Preview',
      MediaSegmentKind.commercial => 'Skip Ad',
      // The Up Next card already covers this when it's showing.
      MediaSegmentKind.outro => _upNextVisible ? null : (widget.onNext != null ? 'Next Episode' : 'Skip Credits'),
    };
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    _upNextTimer?.cancel();
    _positionTimer?.cancel();
    _playerStateSub?.cancel();
    _controller.removeActivityListener(_handleActivityEvent);
    _controller.removeAirPlayAvailabilityListener(_handleAirPlayAvailability);
    _controller.removeAirPlayConnectionListener(_handleAirPlayConnection);
    _castStatusSub?.cancel();
    _castSession?.close();
    if (!widget.isAudioOnly && widget.localFilePath == null) {
      final position =
          _castSession?.status.position ?? _controller.currentPosition;
      _api.reportPlaybackStopped(
        widget.serverUrl,
        widget.token,
        widget.itemId,
        _playSessionId,
        position,
      );
    }
    _controller.dispose();
    _livePlayers--;
    if (_livePlayers == 0) {
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    body: _error != null
        ? Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Unable to play this video.\n$_error',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Color(0xFFA5A7AC)),
                  ),
                  const SizedBox(height: 20),
                  FilledButton(onPressed: _retry, child: const Text('Retry')),
                ],
              ),
            ),
          )
        : _castSession != null
        ? _CastingView(
            device: _castDevice!,
            session: _castSession!,
            title: widget.title,
            subtitle: widget.subtitle,
            onStop: _disconnectCast,
          )
        : Stack(
            fit: StackFit.expand,
            children: [
              NativeVideoPlayer(
            controller: _controller,
            overlayBuilder: (overlayContext, controller) => _locked
                ? Positioned(
                    left: 16,
                    bottom: 16,
                    child: SafeArea(
                      child: IconButton(
                        onPressed: _toggleLock,
                        icon: const Icon(
                          Icons.lock_outline,
                          color: Colors.white70,
                        ),
                        style: IconButton.styleFrom(
                          backgroundColor: Colors.black45,
                        ),
                      ),
                    ),
                  )
                : Stack(
                    fit: StackFit.expand,
                    children: [
                      DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.black.withValues(alpha: .6),
                              Colors.transparent,
                              Colors.transparent,
                              Colors.black.withValues(alpha: .75),
                            ],
                          ),
                        ),
                      ),
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: _TopBar(
                          title: widget.title,
                          subtitle: widget.subtitle,
                          onBack: () => Navigator.of(context).pop(),
                          onLock: _toggleLock,
                          isAirplayAvailable: _isAirplayAvailable,
                          isAirplayConnected: _isAirplayConnected,
                          onAirPlay: () => _controller.showAirPlayPicker(),
                          onCast: _showCastPicker,
                        ),
                      ),
                      _CenterControls(
                        isPlaying: _isPlaying,
                        skipSeconds: widget.settings.skipSeconds,
                        onSeekBack: () => _seekBy(
                          Duration(seconds: -widget.settings.skipSeconds),
                        ),
                        onSeekForward: () => _seekBy(
                          Duration(seconds: widget.settings.skipSeconds),
                        ),
                        onPlayPause: _togglePlayPause,
                      ),
                      _BottomBar(
                        controller: _controller,
                        onSettings: _openSettings,
                        onToggleSubtitles: _subtitleTracks.isEmpty
                            ? null
                            : _toggleSubtitles,
                        subtitlesOn: _subtitleStreamIndex != null,
                        onNext: widget.onNext,
                      ),
                    ],
                  ),
              ),
              // Kept outside the player's own overlay so they stay up while
              // the regular controls auto-hide, like every streaming app.
              if (!_locked && _skipLabel != null)
                Positioned(
                  right: 28,
                  bottom: 120,
                  child: SafeArea(
                    child: _SkipButton(label: _skipLabel!, onPressed: _skipActiveSegment),
                  ),
                ),
              if (!_locked && _upNextVisible)
                Positioned(
                  right: 28,
                  bottom: 110,
                  child: SafeArea(
                    child: _UpNextCard(
                      title: widget.nextTitle ?? 'Next Episode',
                      subtitle: widget.nextSubtitle,
                      imageUrl: widget.nextImageUrl,
                      token: widget.token,
                      secondsRemaining: _upNextRemaining,
                      totalSeconds: _upNextCountdown,
                      onPlayNow: _playNext,
                      onCancel: _cancelUpNext,
                    ),
                  ),
                ),
            ],
          ),
  );
}

class _SkipButton extends StatelessWidget {
  const _SkipButton({required this.label, required this.onPressed});
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    onPressed: onPressed,
    icon: const Icon(Icons.skip_next_rounded, size: 22),
    label: Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
    style: OutlinedButton.styleFrom(
      foregroundColor: Colors.white,
      backgroundColor: Colors.black.withValues(alpha: .55),
      side: const BorderSide(color: Colors.white70, width: 1.2),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
  );
}

class _UpNextCard extends StatelessWidget {
  const _UpNextCard({
    required this.title,
    required this.subtitle,
    required this.imageUrl,
    required this.token,
    required this.secondsRemaining,
    required this.totalSeconds,
    required this.onPlayNow,
    required this.onCancel,
  });
  final String title;
  final String? subtitle;
  final String? imageUrl;
  final String token;
  final int secondsRemaining;
  final int totalSeconds;
  final VoidCallback onPlayNow;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Container(
      width: 340,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xE6101114),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              width: 120,
              height: 68,
              child: imageUrl == null
                  ? const ColoredBox(color: Color(0xFF1B1D22), child: Icon(Icons.movie_outlined, color: Colors.white38))
                  : SinemaImage(
                      imageUrl: imageUrl!,
                      httpHeaders: JellyfinApiService.authHeaders(token),
                      fit: BoxFit.cover,
                      memCacheWidth: 360,
                      errorWidget: (_, _, _) => const ColoredBox(color: Color(0xFF1B1D22)),
                    ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('UP NEXT IN $secondsRemaining', style: TextStyle(color: accent, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.4)),
                const SizedBox(height: 4),
                Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                if (subtitle != null)
                  Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: Color(0xFFA5A7AC))),
                const SizedBox(height: 10),
                Row(
                  children: [
                    FilledButton.icon(
                      onPressed: onPlayNow,
                      icon: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          value: 1 - (secondsRemaining - 1) / totalSeconds,
                          strokeWidth: 2.2,
                          color: Colors.black,
                          backgroundColor: Colors.black26,
                        ),
                      ),
                      label: const Text('Play Now'),
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: Colors.black,
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: onCancel,
                      style: TextButton.styleFrom(foregroundColor: Colors.white70, visualDensity: VisualDensity.compact),
                      child: const Text('Cancel'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PlayerSettingsSheet extends StatelessWidget {
  const _PlayerSettingsSheet({
    required this.quality,
    required this.subtitleLabel,
    required this.audioLabel,
    required this.hasSubtitles,
    required this.hasAudioChoices,
    required this.onQuality,
    required this.onSubtitles,
    required this.onAudio,
  });
  final StreamQuality quality;
  final String subtitleLabel;
  final String audioLabel;
  final bool hasSubtitles;
  final bool hasAudioChoices;
  final VoidCallback onQuality;
  final VoidCallback onSubtitles;
  final VoidCallback onAudio;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Container(
      margin: const EdgeInsets.symmetric(horizontal: 66),
      padding: const EdgeInsets.fromLTRB(34, 12, 34, 34),
      decoration: const BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 42,
            height: 5,
            decoration: BoxDecoration(
              color: const Color(0xFF29292C),
              borderRadius: BorderRadius.circular(99),
            ),
          ),
          const SizedBox(height: 28),
          const Text(
            'Settings',
            style: TextStyle(
              color: Colors.white,
              fontSize: 25,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 26),
          const Divider(color: Color(0xFF252529), height: 1),
          _SettingsRow(
            label: 'Quality',
            value: quality == StreamQuality.original
                ? 'Original'
                : quality.label,
            onTap: onQuality,
          ),
          _SettingsRow(
            label: 'Subtitles',
            value: subtitleLabel,
            onTap: hasSubtitles ? onSubtitles : null,
          ),
          _SettingsRow(
            label: 'Audio',
            value: audioLabel,
            onTap: hasAudioChoices ? onAudio : null,
          ),
          const _SettingsRow(label: 'Playback Options', value: '', onTap: null),
        ],
      ),
    ),
  );
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.label,
    required this.value,
    required this.onTap,
  });
  final String label;
  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(8),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 25),
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(
              color: onTap == null ? const Color(0xFF808084) : Colors.white,
              fontSize: 20,
            ),
          ),
          const Spacer(),
          if (value.isNotEmpty)
            Text(
              value,
              style: const TextStyle(color: Color(0xFFA9A8AD), fontSize: 20),
            ),
          if (onTap != null)
            const Padding(
              padding: EdgeInsets.only(left: 8),
              child: Icon(Icons.chevron_right, color: Color(0xFFA9A8AD)),
            ),
        ],
      ),
    ),
  );
}

class _ChoiceOption<T> {
  const _ChoiceOption(this.value, this.label);
  final T value;
  final String label;
}

class _ChoiceSheet<T> extends StatelessWidget {
  const _ChoiceSheet({
    required this.title,
    required this.value,
    required this.options,
  });
  final String title;
  final T value;
  final List<_ChoiceOption<T>> options;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.8),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 66),
        padding: const EdgeInsets.fromLTRB(34, 12, 34, 0),
        decoration: const BoxDecoration(
          color: Color(0xFF101114),
          borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 42,
              height: 5,
              decoration: BoxDecoration(
                color: const Color(0xFF29292C),
                borderRadius: BorderRadius.circular(99),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 25,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: 28),
                children: [
                  for (final option in options)
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                      title: Text(
                        option.label,
                        style: const TextStyle(color: Colors.white, fontSize: 18),
                      ),
                      trailing: option.value == value
                          ? const Icon(Icons.check, color: Color(0xFFFFB800))
                          : null,
                      onTap: () => Navigator.of(context).pop(option.value),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _CastPickerSheet extends StatefulWidget {
  const _CastPickerSheet({required this.onSelected});
  final void Function(nvp_cast.CastDevice device) onSelected;

  @override
  State<_CastPickerSheet> createState() => _CastPickerSheetState();
}

class _CastPickerSheetState extends State<_CastPickerSheet> {
  List<nvp_cast.CastDevice>? _devices;
  String? _error;

  @override
  void initState() {
    super.initState();
    _discover();
  }

  Future<void> _discover() async {
    try {
      final devices = await nvp_cast.CastDeviceDiscovery.discover();
      if (mounted) setState(() => _devices = devices);
    } on nvp_cast.CastDiscoveryException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted)
        setState(() => _error = 'Could not search for Cast devices: $e');
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Container(
      margin: const EdgeInsets.symmetric(horizontal: 40),
      padding: const EdgeInsets.fromLTRB(28, 12, 28, 28),
      decoration: const BoxDecoration(
        color: Color(0xFF101114),
        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 42,
            height: 5,
            decoration: BoxDecoration(
              color: const Color(0xFF29292C),
              borderRadius: BorderRadius.circular(99),
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'Cast to Device',
            style: TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 16),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(
                _error!,
                style: const TextStyle(color: Color(0xFFA5A7AC)),
                textAlign: TextAlign.center,
              ),
            )
          else if (_devices == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: CircularProgressIndicator(),
            )
          else if (_devices!.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Text(
                'No Cast devices found on your network.',
                style: TextStyle(color: Color(0xFFA5A7AC)),
              ),
            )
          else
            for (final device in _devices!)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.cast, color: Colors.white),
                title: Text(
                  device.displayName,
                  style: const TextStyle(color: Colors.white, fontSize: 17),
                ),
                subtitle: device.model != null
                    ? Text(
                        device.model!,
                        style: const TextStyle(color: Color(0xFFA9A8AD)),
                      )
                    : null,
                onTap: () => widget.onSelected(device),
              ),
        ],
      ),
    ),
  );
}

class _CastingView extends StatelessWidget {
  const _CastingView({
    required this.device,
    required this.session,
    required this.title,
    required this.subtitle,
    required this.onStop,
  });
  final nvp_cast.CastDevice device;
  final nvp_cast.CastSession session;
  final String title;
  final String? subtitle;
  final VoidCallback onStop;

  String _format(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.cast_connected, color: Color(0xFFFFB800), size: 64),
          const SizedBox(height: 20),
          Text(
            'Casting to ${device.displayName}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w800,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          Text(
            title,
            style: const TextStyle(color: Color(0xFFAAA9AE), fontSize: 16),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 32),
          StreamBuilder<nvp_cast.CastSessionStatus>(
            stream: session.statusStream,
            initialData: session.status,
            builder: (context, snapshot) {
              final status = snapshot.data ?? session.status;
              final duration = status.duration ?? Duration.zero;
              final maxMs = duration.inMilliseconds.toDouble();
              final valueMs = status.position.inMilliseconds.toDouble().clamp(
                0.0,
                maxMs <= 0 ? 1.0 : maxMs,
              );
              return Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        iconSize: 56,
                        onPressed: status.isPlaying
                            ? session.pause
                            : session.play,
                        icon: Icon(
                          status.isPlaying
                              ? Icons.pause_circle_filled
                              : Icons.play_circle_filled,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                  Slider(
                    value: valueMs,
                    max: maxMs <= 0 ? 1 : maxMs,
                    onChanged: maxMs <= 0
                        ? null
                        : (value) => session.seek(
                            Duration(milliseconds: value.round()),
                          ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        _format(status.position),
                        style: const TextStyle(color: Colors.white70),
                      ),
                      Text(
                        _format(duration),
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 24),
          OutlinedButton(onPressed: onStop, child: const Text('Stop Casting')),
        ],
      ),
    ),
  );
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.title,
    required this.subtitle,
    required this.onBack,
    required this.onLock,
    required this.isAirplayAvailable,
    required this.isAirplayConnected,
    required this.onAirPlay,
    required this.onCast,
  });
  final String title;
  final String? subtitle;
  final VoidCallback onBack;
  final VoidCallback onLock;
  final bool isAirplayAvailable;
  final bool isAirplayConnected;
  final VoidCallback onAirPlay;
  final VoidCallback onCast;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(54, 26, 42, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFFAAA9AE),
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            onPressed: onLock,
            icon: const Icon(
              Icons.lock_open,
              color: Color(0xFFD3D2D6),
              size: 26,
            ),
          ),
          IconButton(
            onPressed: isAirplayAvailable ? onAirPlay : null,
            icon: Icon(
              Icons.airplay,
              color: isAirplayConnected
                  ? const Color(0xFFFFB800)
                  : (isAirplayAvailable
                        ? const Color(0xFFD3D2D6)
                        : const Color(0xFF5A5A5E)),
              size: 31,
            ),
          ),
          IconButton(
            onPressed: onCast,
            icon: const Icon(
              Icons.cast_outlined,
              color: Color(0xFFD3D2D6),
              size: 31,
            ),
          ),
          IconButton(
            onPressed: onBack,
            icon: const Icon(Icons.close, color: Color(0xFFD3D2D6), size: 36),
          ),
        ],
      ),
    ),
  );
}

class _CenterControls extends StatelessWidget {
  const _CenterControls({
    required this.isPlaying,
    required this.skipSeconds,
    required this.onSeekBack,
    required this.onSeekForward,
    required this.onPlayPause,
  });
  final bool isPlaying;
  final int skipSeconds;
  final VoidCallback onSeekBack;
  final VoidCallback onSeekForward;
  final VoidCallback onPlayPause;

  @override
  Widget build(BuildContext context) => Center(
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          iconSize: 46,
          onPressed: onSeekBack,
          icon: _SeekIcon(forward: false, seconds: skipSeconds),
        ),
        const SizedBox(width: 66),
        IconButton(
          iconSize: 68,
          onPressed: onPlayPause,
          icon: Icon(
            isPlaying ? Icons.pause : Icons.play_arrow,
            color: Colors.white,
          ),
        ),
        const SizedBox(width: 66),
        IconButton(
          iconSize: 46,
          onPressed: onSeekForward,
          icon: _SeekIcon(forward: true, seconds: skipSeconds),
        ),
      ],
    ),
  );
}

// Mirrors Material's built-in replay_10/forward_10 glyphs, but with the
// actual configured skip interval overlaid instead of a hardcoded "10" —
// the app lets the skip interval be changed in Settings (5/10/15/30/60s).
class _SeekIcon extends StatelessWidget {
  const _SeekIcon({required this.forward, required this.seconds});
  final bool forward;
  final int seconds;

  @override
  Widget build(BuildContext context) => Stack(
    alignment: Alignment.center,
    children: [
      // Material has no matching "forward" circle glyph (Icons.forward is a
      // mail-style arrow), so mirror the replay circle instead.
      Transform.flip(
        flipX: forward,
        child: const Icon(Icons.replay, color: Colors.white, size: 46),
      ),
      Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Text(
          '$seconds',
          style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w800),
        ),
      ),
    ],
  );
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.controller,
    required this.onSettings,
    required this.onToggleSubtitles,
    required this.subtitlesOn,
    this.onNext,
  });
  final NativeVideoPlayerController controller;
  final VoidCallback onSettings;
  final VoidCallback? onToggleSubtitles;
  final bool subtitlesOn;
  final VoidCallback? onNext;

  String _format(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) => Positioned(
    left: 0,
    right: 0,
    bottom: 0,
    child: SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(54, 8, 54, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (onNext != null) ...[
                  IconButton(
                    onPressed: onNext,
                    icon: const Icon(
                      Icons.skip_next,
                      color: Color(0xFFD3D2D6),
                      size: 31,
                    ),
                  ),
                  const SizedBox(width: 18),
                ],
                if (onToggleSubtitles != null)
                  IconButton(
                    onPressed: onToggleSubtitles,
                    icon: Icon(
                      subtitlesOn
                          ? Icons.closed_caption
                          : Icons.closed_caption_outlined,
                      color: const Color(0xFFD3D2D6),
                      size: 31,
                    ),
                  ),
                const SizedBox(width: 18),
                IconButton(
                  onPressed: onSettings,
                  icon: const Icon(
                    Icons.settings,
                    color: Color(0xFFD3D2D6),
                    size: 34,
                  ),
                ),
              ],
            ),
            StreamBuilder<Duration>(
              stream: controller.positionStream,
              initialData: controller.currentPosition,
              builder: (context, positionSnapshot) {
                final position = positionSnapshot.data ?? Duration.zero;
                return StreamBuilder<Duration>(
                  stream: controller.durationStream,
                  initialData: controller.duration,
                  builder: (context, durationSnapshot) {
                    final duration = durationSnapshot.data ?? Duration.zero;
                    final maxMs = duration.inMilliseconds.toDouble();
                    final valueMs = position.inMilliseconds.toDouble().clamp(
                      0.0,
                      maxMs <= 0 ? 1.0 : maxMs,
                    );
                    final remaining = duration > position
                        ? duration - position
                        : Duration.zero;
                    return Row(
                      children: [
                        SizedBox(
                          width: 76,
                          child: Text(
                            _format(position),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                            ),
                            textAlign: TextAlign.left,
                          ),
                        ),
                        Expanded(
                          child: SliderTheme(
                            data: SliderThemeData(
                              activeTrackColor: const Color(0xFFFFB800),
                              inactiveTrackColor: const Color(0xFF5D5D60),
                              trackHeight: 8,
                              thumbColor: Colors.white,
                              thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 16,
                              ),
                              overlayShape: SliderComponentShape.noOverlay,
                            ),
                            child: Slider(
                              value: valueMs,
                              max: maxMs <= 0 ? 1 : maxMs,
                              onChanged: maxMs <= 0
                                  ? null
                                  : (value) => controller.seekTo(
                                      Duration(milliseconds: value.round()),
                                    ),
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 86,
                          child: Text(
                            '-${_format(remaining)}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                            ),
                            textAlign: TextAlign.right,
                          ),
                        ),
                      ],
                    );
                  },
                );
              },
            ),
            const Icon(
              Icons.keyboard_arrow_down,
              color: Color(0xFFD3D2D6),
              size: 28,
            ),
          ],
        ),
      ),
    ),
  );
}
