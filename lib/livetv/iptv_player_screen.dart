import 'dart:async';

import 'package:better_native_video_player/better_native_video_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../widgets/sinema_image.dart';
import 'iptv_models.dart';
import 'iptv_repository.dart';

int _nextIptvControllerId = 50000;

// Player for Live TV channels and IPTV movies/episodes. Deliberately lean:
// no server negotiation, just the stream URL, with TiviMate-style channel
// zapping (up/down, a channel list, now/next info) when playing live.
class IptvPlayerScreen extends StatefulWidget {
  const IptvPlayerScreen({super.key, required this.items, required this.initialIndex, this.subtitle});

  // For live TV, the channels you can zap through (usually the current group).
  // For movies/episodes, a single entry.
  final List<IptvItem> items;
  final int initialIndex;
  final String? subtitle;

  @override
  State<IptvPlayerScreen> createState() => _IptvPlayerScreenState();
}

class _IptvPlayerScreenState extends State<IptvPlayerScreen> {
  final _repo = IptvRepository.instance;
  late final NativeVideoPlayerController _controller;
  late int _index = widget.initialIndex;
  String? _error;
  bool _triedHlsFallback = false;
  bool _isPlaying = false;
  bool _isBuffering = true;
  bool _showChannelList = false;
  bool _userPaused = false;
  Duration _lastPosition = Duration.zero;
  Timer? _pollTimer;
  Timer? _clockTimer;
  int _zapToken = 0;

  IptvItem get _item => widget.items[_index];
  bool get _isLive => _item.kind == IptvKind.live;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _controller = NativeVideoPlayerController(
      id: _nextIptvControllerId++,
      autoPlay: true,
      showNativeControls: false,
      allowsPictureInPicture: true,
      canStartPictureInPictureAutomatically: true,
      mediaInfo: NativeVideoPlayerMediaInfo(title: _item.name, subtitle: widget.subtitle),
    );
    _controller.addActivityListener(_onActivity);
    _pollTimer = Timer.periodic(const Duration(milliseconds: 500), (_) => _poll());
    // Keeps the now/next progress bars moving.
    _clockTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
    _start();
  }

  Future<void> _start() async {
    try {
      await _controller.initialize();
    } catch (e) {
      if (mounted) setState(() => _error = 'Failed to start the player.\n$e');
      return;
    }
    await _open();
  }

  Future<void> _open({String? overrideUrl}) async {
    final token = ++_zapToken;
    final item = _item;
    final source = _repo.sourceFor(item.sourceId);
    setState(() {
      _error = null;
      _isBuffering = true;
      _userPaused = false;
      _lastPosition = Duration.zero;
    });
    try {
      await _controller.load(url: overrideUrl ?? item.url, headers: source?.headers ?? const {}, force: true);
      if (token != _zapToken) return;
      _repo.markWatched(item);
    } catch (e) {
      if (token == _zapToken && mounted) _handleError(e.toString());
    }
  }

  void _onActivity(PlayerActivityEvent event) {
    if (event.state == PlayerActivityState.error) {
      _handleError((event.data?['message'] as String?) ?? 'This stream couldn\'t be played.');
    } else if (event.state == PlayerActivityState.completed && !_isLive) {
      if (!mounted) return;
      // Series: roll straight into the next episode of the season.
      if (_index < widget.items.length - 1) {
        _zap(1);
      } else {
        Navigator.of(context).maybePop();
      }
    }
  }

  void _handleError(String message) {
    if (!mounted) return;
    // Many panels serve the same channel as HLS when ".ts" is swapped for
    // ".m3u8" — and iOS can't play raw MPEG-TS at all. Try that once.
    final url = _item.url;
    if (!_triedHlsFallback && RegExp(r'\.ts(\?|$)').hasMatch(url)) {
      _triedHlsFallback = true;
      _open(overrideUrl: url.replaceFirst(RegExp(r'\.ts(?=\?|$)'), '.m3u8'));
      return;
    }
    setState(() {
      _error = message;
      _isBuffering = false;
    });
  }

  // The clock moving is the reliable signal: it drives both the play/pause
  // icon and the loading spinner (shown while we expect playback but the
  // stream hasn't produced a frame yet).
  void _poll() {
    if (!mounted || _error != null) return;
    final position = _controller.currentPosition;
    final advancing = position > _lastPosition;
    _lastPosition = position;
    final playing = !_userPaused && (advancing || _controller.activityState.isPlaying);
    final buffering = !_userPaused && !advancing;
    if (playing != _isPlaying || buffering != _isBuffering) {
      setState(() {
        _isPlaying = playing;
        _isBuffering = buffering;
      });
    }
  }

  void _zap(int delta) {
    if (widget.items.length < 2) return;
    _index = (_index + delta) % widget.items.length;
    if (_index < 0) _index += widget.items.length;
    _triedHlsFallback = false;
    _open();
  }

  void _playAt(int index) {
    setState(() {
      _index = index;
      _showChannelList = false;
    });
    _triedHlsFallback = false;
    _open();
  }

  Future<void> _togglePlay() async {
    if (_isPlaying) {
      setState(() {
        _isPlaying = false;
        _userPaused = true;
        _isBuffering = false;
      });
      await _controller.pause();
    } else {
      setState(() {
        _isPlaying = true;
        _userPaused = false;
      });
      await _controller.play();
    }
  }

  void _seekBy(Duration offset) {
    final target = _controller.currentPosition + offset;
    final duration = _controller.duration;
    _controller.seekTo(target < Duration.zero ? Duration.zero : (duration > Duration.zero && target > duration ? duration : target));
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _clockTimer?.cancel();
    _controller.removeActivityListener(_onActivity);
    _controller.dispose();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            NativeVideoPlayer(
              controller: _controller,
              overlayBuilder: (overlayContext, controller) => _Controls(
                item: _item,
                subtitle: widget.subtitle,
                isLive: _isLive,
                isPlaying: _isPlaying,
                canZap: widget.items.length > 1,
                controller: controller,
                onClose: () => Navigator.of(context).pop(),
                onTogglePlay: _togglePlay,
                onZapUp: () => _zap(-1),
                onZapDown: () => _zap(1),
                onSeekBy: _seekBy,
                onOpenChannelList: () => setState(() => _showChannelList = true),
              ),
            ),
            if (_isBuffering && _error == null)
              const IgnorePointer(child: Center(child: CircularProgressIndicator(color: Colors.white70))),
            if (_error != null)
              Container(
                color: Colors.black87,
                alignment: Alignment.center,
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_item.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFFA5A7AC))),
                    const SizedBox(height: 20),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        OutlinedButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
                        const SizedBox(width: 12),
                        FilledButton(
                          onPressed: () {
                            _triedHlsFallback = false;
                            _open();
                          },
                          child: const Text('Retry'),
                        ),
                        if (_isLive && widget.items.length > 1) ...[
                          const SizedBox(width: 12),
                          OutlinedButton(onPressed: () => _zap(1), child: const Text('Next Channel')),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            if (_showChannelList)
              _ChannelListPanel(
                channels: widget.items,
                currentIndex: _index,
                onSelect: _playAt,
                onClose: () => setState(() => _showChannelList = false),
              ),
          ],
        ),
      );
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.item,
    required this.subtitle,
    required this.isLive,
    required this.isPlaying,
    required this.canZap,
    required this.controller,
    required this.onClose,
    required this.onTogglePlay,
    required this.onZapUp,
    required this.onZapDown,
    required this.onSeekBy,
    required this.onOpenChannelList,
  });

  final IptvItem item;
  final String? subtitle;
  final bool isLive;
  final bool isPlaying;
  final bool canZap;
  final NativeVideoPlayerController controller;
  final VoidCallback onClose;
  final VoidCallback onTogglePlay;
  final VoidCallback onZapUp;
  final VoidCallback onZapDown;
  final ValueChanged<Duration> onSeekBy;
  final VoidCallback onOpenChannelList;

  String _time(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  String _format(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final repo = IptvRepository.instance;
    final now = isLive ? repo.nowPlaying(item) : null;
    final next = isLive ? repo.upNext(item) : null;
    final accent = Theme.of(context).colorScheme.primary;
    return AnimatedBuilder(
      animation: repo,
      builder: (context, _) => Stack(
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.black.withValues(alpha: .7), Colors.transparent, Colors.transparent, Colors.black.withValues(alpha: .8)],
              ),
            ),
          ),
          // Top: channel identity + actions.
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(32, 16, 24, 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (item.logo != null)
                    Padding(
                      padding: const EdgeInsets.only(right: 14),
                      child: SizedBox(
                        width: 56,
                        height: 40,
                        child: SinemaImage(imageUrl: item.logo!, fit: BoxFit.contain, errorWidget: (_, _, _) => const SizedBox.shrink()),
                      ),
                    ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          [if (isLive && item.number != null) '${item.number}', item.name].join('  '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                        ),
                        if (subtitle != null)
                          Text(subtitle!, style: const TextStyle(color: Color(0xFFAAA9AE), fontSize: 15, fontWeight: FontWeight.w600)),
                        if (isLive && now == null)
                          Text(item.group, style: const TextStyle(color: Color(0xFFAAA9AE), fontSize: 15)),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => repo.toggleFavorite(item),
                    icon: Icon(repo.isFavorite(item) ? Icons.star_rounded : Icons.star_outline_rounded, color: repo.isFavorite(item) ? accent : Colors.white, size: 30),
                    tooltip: 'Favorite',
                  ),
                  if (isLive && canZap)
                    IconButton(onPressed: onOpenChannelList, icon: const Icon(Icons.format_list_bulleted, size: 28), tooltip: 'Channels'),
                  if (Theme.of(context).platform == TargetPlatform.iOS)
                    IconButton(onPressed: () => controller.showAirPlayPicker(), icon: const Icon(Icons.airplay, size: 28), tooltip: 'AirPlay'),
                  IconButton(onPressed: onClose, icon: const Icon(Icons.close, size: 30)),
                ],
              ),
            ),
          ),
          // Center: play/pause (+ seek for VOD), channel up/down for live.
          Center(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (!isLive)
                  IconButton(iconSize: 44, onPressed: () => onSeekBy(const Duration(seconds: -10)), icon: const Icon(Icons.replay_10)),
                const SizedBox(width: 48),
                IconButton(iconSize: 64, onPressed: onTogglePlay, icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow)),
                const SizedBox(width: 48),
                if (!isLive)
                  IconButton(iconSize: 44, onPressed: () => onSeekBy(const Duration(seconds: 10)), icon: const Icon(Icons.forward_10)),
              ],
            ),
          ),
          if (isLive && canZap)
            Positioned(
              right: 28,
              top: 0,
              bottom: 0,
              child: SafeArea(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton.filledTonal(onPressed: onZapUp, icon: const Icon(Icons.keyboard_arrow_up, size: 30), tooltip: 'Previous channel'),
                    const SizedBox(height: 4),
                    const Text('CH', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.white70)),
                    const SizedBox(height: 4),
                    IconButton.filledTonal(onPressed: onZapDown, icon: const Icon(Icons.keyboard_arrow_down, size: 30), tooltip: 'Next channel'),
                  ],
                ),
              ),
            ),
          // Bottom: now/next for live, scrubber for VOD.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(40, 0, 40, 18),
                child: isLive
                    ? (now == null
                        ? const SizedBox.shrink()
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(4)),
                                    child: const Text('LIVE', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800)),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(child: Text(now.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700))),
                                  Text('${_time(now.start)} – ${_time(now.end)}', style: const TextStyle(color: Color(0xFFAAA9AE))),
                                ],
                              ),
                              const SizedBox(height: 8),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(2),
                                child: LinearProgressIndicator(value: now.progressAt(DateTime.now()), minHeight: 4, color: accent, backgroundColor: Colors.white24),
                              ),
                              if (next != null) ...[
                                const SizedBox(height: 8),
                                Text('Next  ${_time(next.start)}  ${next.title}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Color(0xFFAAA9AE))),
                              ],
                            ],
                          ))
                    : StreamBuilder<Duration>(
                        stream: controller.positionStream,
                        initialData: controller.currentPosition,
                        builder: (context, positionSnapshot) => StreamBuilder<Duration>(
                          stream: controller.durationStream,
                          initialData: controller.duration,
                          builder: (context, durationSnapshot) {
                            final position = positionSnapshot.data ?? Duration.zero;
                            final duration = durationSnapshot.data ?? Duration.zero;
                            final maxMs = duration.inMilliseconds.toDouble();
                            return Row(
                              children: [
                                Text(_format(position)),
                                Expanded(
                                  child: Slider(
                                    value: maxMs <= 0 ? 0 : position.inMilliseconds.clamp(0, maxMs.toInt()).toDouble(),
                                    max: maxMs <= 0 ? 1 : maxMs,
                                    activeColor: accent,
                                    inactiveColor: Colors.white24,
                                    onChanged: maxMs <= 0 ? null : (v) => controller.seekTo(Duration(milliseconds: v.round())),
                                  ),
                                ),
                                Text('-${_format(duration > position ? duration - position : Duration.zero)}'),
                              ],
                            );
                          },
                        ),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChannelListPanel extends StatelessWidget {
  const _ChannelListPanel({required this.channels, required this.currentIndex, required this.onSelect, required this.onClose});
  final List<IptvItem> channels;
  final int currentIndex;
  final ValueChanged<int> onSelect;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final repo = IptvRepository.instance;
    final accent = Theme.of(context).colorScheme.primary;
    return Stack(
      children: [
        Positioned.fill(child: GestureDetector(onTap: onClose, child: const ColoredBox(color: Colors.black38))),
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: 380,
          child: Material(
            color: const Color(0xEE0C0D10),
            child: SafeArea(
              right: false,
              child: ListView.builder(
                controller: ScrollController(initialScrollOffset: (currentIndex * 64.0 - 120).clamp(0, double.infinity)),
                itemExtent: 64,
                itemCount: channels.length,
                itemBuilder: (context, index) {
                  final channel = channels[index];
                  final now = repo.nowPlaying(channel);
                  final selected = index == currentIndex;
                  return InkWell(
                    onTap: () => onSelect(index),
                    child: Container(
                      color: selected ? accent.withValues(alpha: .18) : null,
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 34,
                            child: Text(channel.number?.toString() ?? '${index + 1}', style: const TextStyle(color: Color(0xFFA5A7AC), fontSize: 13)),
                          ),
                          SizedBox(
                            width: 44,
                            height: 30,
                            child: channel.logo == null
                                ? const Icon(Icons.live_tv, size: 18, color: Colors.white38)
                                : SinemaImage(imageUrl: channel.logo!, fit: BoxFit.contain, memCacheWidth: 132, errorWidget: (_, _, _) => const Icon(Icons.live_tv, size: 18, color: Colors.white38)),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(channel.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w600, color: selected ? accent : Colors.white)),
                                if (now != null)
                                  Text(now.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Color(0xFFA5A7AC))),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}
