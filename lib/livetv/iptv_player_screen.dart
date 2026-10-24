import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../widgets/sinema_image.dart';
import 'iptv_models.dart';
import 'iptv_repository.dart';
import 'live_playback.dart';
import 'live_tv_screen.dart' show ensureUnlocked, playCatchup;
import 'multiview_screen.dart';

// Player for Live TV channels and IPTV movies/episodes. Deliberately lean:
// no server negotiation, just the stream URL, with TiviMate-style channel
// zapping (up/down, a channel list, now/next info) when playing live.
//
// Runs on media_kit (libmpv/ffmpeg) rather than the system player: IPTV is
// mostly raw MPEG-TS (Dispatcharr, Xtream ".ts", HDHomeRun), which iOS's
// AVPlayer refuses outright. mpv plays TS, HLS and everything else.
class IptvPlayerScreen extends StatefulWidget {
  const IptvPlayerScreen({super.key, required this.items, required this.initialIndex, this.subtitle});

  // For live TV, the channels you can zap through (usually the current group).
  // For movies/episodes, a single entry.
  final List<IptvItem> items;
  final int initialIndex;
  final String? subtitle;

  // How many full-screen players are open. The guide's preview stops while
  // one is, so a single-stream IPTV plan isn't asked for two streams.
  static final ValueNotifier<int> openCount = ValueNotifier(0);

  @override
  State<IptvPlayerScreen> createState() => _IptvPlayerScreenState();
}

class _IptvPlayerScreenState extends State<IptvPlayerScreen> {
  final _repo = IptvRepository.instance;
  late final Player _player;
  late final VideoController _video;
  final List<StreamSubscription<dynamic>> _subs = [];
  late final MpvLogTail _log;
  bool _softwareDecode = false;
  Timer? _startWatchdog;
  late int _index = widget.initialIndex;
  String? _error;
  bool _triedHlsFallback = false;
  bool _isPlaying = false;
  bool _isBuffering = true;
  bool _showChannelList = false;
  bool _userPaused = false;
  bool _showControls = true;
  bool _hasPlayed = false;
  int _reconnects = 0;
  Duration _lastPosition = Duration.zero;
  Timer? _pollTimer;
  Timer? _clockTimer;
  Timer? _hideTimer;
  int _zapToken = 0;

  IptvItem get _item => widget.items[_index];
  bool get _isLive => _item.kind == IptvKind.live;

  @override
  void initState() {
    super.initState();
    IptvPlayerScreen.openCount.value++;
    SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _player = Player(configuration: PlayerConfiguration(title: _item.name, bufferSize: 16 * 1024 * 1024, logLevel: liveLogLevel));
    _log = MpvLogTail(_player);
    _video = liveVideoController(_player);
    _subs
      ..add(_player.stream.error.listen(_onError))
      ..add(_player.stream.completed.listen((done) {
        if (done) _onCompleted();
      }));
    _pollTimer = Timer.periodic(const Duration(milliseconds: 500), (_) => _poll());
    // Keeps the now/next progress bars moving.
    _clockTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
    _start();
  }

  Future<void> _start() async {
    // Let initState finish before _open's first setState.
    await Future<void>.value();
    await videoReady(_video);
    await tuneForLive(_player);
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
      _hasPlayed = false;
      _lastPosition = Duration.zero;
    });
    _bumpControls();
    try {
      final headers = source?.headers ?? const <String, String>{};
      _log.clear();
      await _player.open(Media(overrideUrl ?? _repo.playbackUrl(item), httpHeaders: headers.isEmpty ? null : headers));
      if (token != _zapToken) return;
      _repo.markWatched(item);
      // Still nothing after 10 s: some channels won't hardware-decode on the
      // iPhone, so switch to software decoding once and reopen; after that,
      // show what mpv reported.
      _startWatchdog?.cancel();
      _startWatchdog = Timer(Duration(seconds: _softwareDecode ? 15 : 10), () async {
        if (!mounted || token != _zapToken || _hasPlayed || _error != null || _userPaused) return;
        if (!_softwareDecode) {
          _softwareDecode = true;
          await tuneForLive(_player, softwareDecode: true);
          if (mounted && token == _zapToken) _open(overrideUrl: overrideUrl);
        } else {
          _handleError('No picture from this channel.');
        }
      });
    } catch (e) {
      if (token == _zapToken && mounted) _handleError(e.toString());
    }
  }

  // mpv reports plenty of harmless hiccups as errors (a dropped packet, a
  // missing subtitle). Only treat it as fatal before anything has played.
  void _onError(String message) {
    if (_hasPlayed || !mounted) return;
    _handleError(message.isEmpty ? 'This stream couldn\'t be played.' : message);
  }

  void _onCompleted() {
    if (!mounted) return;
    if (_isLive) {
      // A live stream "ending" means the connection dropped: reconnect a few
      // times before giving up, as TiviMate does.
      if (_reconnects < 3) {
        _reconnects++;
        _open();
      } else {
        _handleError('The channel stopped sending video.');
      }
      return;
    }
    // Series: roll straight into the next episode of the season.
    if (_index < widget.items.length - 1) {
      _zap(1);
    } else {
      Navigator.of(context).maybePop();
    }
  }

  void _handleError(String message) {
    if (!mounted) return;
    // Many panels serve the same channel as HLS when ".ts" is swapped for
    // ".m3u8" — and iOS can't play raw MPEG-TS at all. Try that once.
    final url = _repo.playbackUrl(_item);
    if (!_triedHlsFallback && RegExp(r'\.ts(\?|$)').hasMatch(url)) {
      _triedHlsFallback = true;
      _open(overrideUrl: url.replaceFirst(RegExp(r'\.ts(?=\?|$)'), '.m3u8'));
      return;
    }
    final details = _log.summary;
    setState(() {
      _error = details.isEmpty ? message : '$message\n\n$details';
      _isBuffering = false;
    });
    // Release the provider connection while the error is showing.
    _player.stop();
  }

  // The clock moving is the reliable signal: it drives both the play/pause
  // icon and the loading spinner (shown while we expect playback but the
  // stream hasn't produced a frame yet).
  void _poll() {
    if (!mounted || _error != null) return;
    final state = _player.state;
    final position = state.position;
    final advancing = position > _lastPosition;
    _lastPosition = position;
    if (advancing && !_hasPlayed) {
      _hasPlayed = true;
      _reconnects = 0;
    }
    final playing = !_userPaused && (advancing || state.playing);
    final buffering = !_userPaused && (!_hasPlayed || state.buffering);
    if (playing != _isPlaying || buffering != _isBuffering) {
      setState(() {
        _isPlaying = playing;
        _isBuffering = buffering;
      });
    }
  }

  // Channel the viewer was on before the current one (TiviMate's "last
  // channel" / recall button).
  int? _previousIndex;
  Timer? _sleepTimer;
  DateTime? _sleepAt;

  void _switchTo(int index) {
    if (index == _index) return;
    setState(() {
      _previousIndex = _index;
      _index = index;
      _showChannelList = false;
    });
    _triedHlsFallback = false;
    _reconnects = 0;
    _open();
  }

  void _zap(int delta) {
    final n = widget.items.length;
    if (n < 2) return;
    var next = _index;
    // Step past channels behind the parental lock.
    for (var i = 0; i < n; i++) {
      next = (next + delta) % n;
      if (next < 0) next += n;
      if (!_repo.isLocked(widget.items[next])) break;
    }
    _switchTo(next);
  }

  Future<void> _playAt(int index) async {
    setState(() => _showChannelList = false);
    if (!await ensureUnlocked(context, widget.items[index])) return;
    _switchTo(index);
  }

  void _recall() {
    final previous = _previousIndex;
    if (previous != null && previous < widget.items.length) _switchTo(previous);
  }

  // Type a channel number, like a remote's number keys.
  Future<void> _enterNumber() async {
    final controller = TextEditingController();
    final number = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Go to Channel'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(hintText: 'Channel number'),
          onSubmitted: (v) => Navigator.of(dialogContext).pop(int.tryParse(v.trim())),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(int.tryParse(controller.text.trim())), child: const Text('Go')),
        ],
      ),
    );
    if (number == null) return;
    var index = widget.items.indexWhere((c) => c.number == number);
    // Playlists without channel numbers: use the position in the list.
    if (index < 0 && number >= 1 && number <= widget.items.length && widget.items.every((c) => c.number == null)) index = number - 1;
    if (index < 0) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('No channel $number in this list.')));
      return;
    }
    _playAt(index);
  }

  Future<void> _chooseSleepTimer() async {
    final now = _repo.nowPlaying(_item);
    final choice = await showModalBottomSheet<Duration?>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(title: Text('Sleep Timer', style: TextStyle(fontWeight: FontWeight.w700))),
            for (final minutes in [15, 30, 45, 60, 90, 120])
              ListTile(title: Text('$minutes minutes'), onTap: () => Navigator.of(sheetContext).pop(Duration(minutes: minutes))),
            if (_isLive && now != null)
              ListTile(title: Text('End of ${now.title}'), onTap: () => Navigator.of(sheetContext).pop(now.end.difference(DateTime.now()))),
            if (_sleepAt != null) ListTile(title: const Text('Turn Off'), onTap: () => Navigator.of(sheetContext).pop(Duration.zero)),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    _sleepTimer?.cancel();
    if (choice == Duration.zero) {
      setState(() => _sleepAt = null);
      return;
    }
    setState(() => _sleepAt = DateTime.now().add(choice));
    _sleepTimer = Timer(choice, () {
      if (mounted) Navigator.of(context).maybePop();
    });
  }

  String? get _sleepLabel {
    final at = _sleepAt;
    if (at == null) return null;
    final left = at.difference(DateTime.now());
    return left.inMinutes >= 1 ? '${left.inMinutes}m' : '<1m';
  }

  void _restartProgram() {
    final now = _repo.nowPlaying(_item);
    if (now == null) return;
    playCatchup(context, _item, now);
  }

  void _openMultiView() {
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => MultiViewScreen(channels: widget.items, initial: [_item]),
    ));
  }

  Future<void> _togglePlay() async {
    if (_isPlaying) {
      setState(() {
        _isPlaying = false;
        _userPaused = true;
        _isBuffering = false;
      });
      await _player.pause();
    } else {
      setState(() {
        _isPlaying = true;
        _userPaused = false;
      });
      await _player.play();
    }
  }

  void _seekBy(Duration offset) {
    final target = _player.state.position + offset;
    final duration = _player.state.duration;
    _player.seek(target < Duration.zero ? Duration.zero : (duration > Duration.zero && target > duration ? duration : target));
  }

  // Controls fade out a few seconds after the last tap while playing.
  void _bumpControls() {
    _hideTimer?.cancel();
    if (!_showControls) setState(() => _showControls = true);
    _hideTimer = Timer(const Duration(seconds: 5), () {
      if (mounted && _isPlaying && !_showChannelList) setState(() => _showControls = false);
    });
  }

  void _toggleControls() {
    if (_showControls) {
      _hideTimer?.cancel();
      setState(() => _showControls = false);
    } else {
      _bumpControls();
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _clockTimer?.cancel();
    _sleepTimer?.cancel();
    _hideTimer?.cancel();
    _startWatchdog?.cancel();
    _log.dispose();
    for (final sub in _subs) {
      sub.cancel();
    }
    _player.dispose();
    IptvPlayerScreen.openCount.value--;
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
            Video(controller: _video, controls: NoVideoControls, fill: Colors.black),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _toggleControls,
              child: AnimatedOpacity(
                opacity: _showControls ? 1 : 0,
                duration: const Duration(milliseconds: 200),
                child: IgnorePointer(
                  ignoring: !_showControls,
                  child: Listener(
                    onPointerDown: (_) => _bumpControls(),
                    child: _Controls(
                item: _item,
                subtitle: widget.subtitle,
                isLive: _isLive,
                isPlaying: _isPlaying,
                canZap: widget.items.length > 1,
                player: _player,
                onClose: () => Navigator.of(context).pop(),
                onTogglePlay: _togglePlay,
                onZapUp: () => _zap(-1),
                onZapDown: () => _zap(1),
                onSeekBy: _seekBy,
                onOpenChannelList: () => setState(() => _showChannelList = true),
                onRecall: _isLive && _previousIndex != null ? _recall : null,
                onEnterNumber: _isLive && widget.items.length > 1 ? _enterNumber : null,
                onSleepTimer: _chooseSleepTimer,
                sleepLabel: _sleepLabel,
                onRestart: _isLive && _repo.nowPlaying(_item) != null && _repo.canCatchup(_item, _repo.nowPlaying(_item)!) ? _restartProgram : null,
                onMultiView: _isLive && widget.items.length > 1 ? _openMultiView : null,
                    ),
                  ),
                ),
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
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 160, maxWidth: 560),
                      child: SingleChildScrollView(child: SelectableText(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFFA5A7AC)))),
                    ),
                    const SizedBox(height: 20),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        OutlinedButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
                        const SizedBox(width: 12),
                        FilledButton(
                          onPressed: () {
                            _triedHlsFallback = false;
                            _reconnects = 0;
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
    required this.player,
    required this.onClose,
    required this.onTogglePlay,
    required this.onZapUp,
    required this.onZapDown,
    required this.onSeekBy,
    required this.onOpenChannelList,
    required this.onRecall,
    required this.onEnterNumber,
    required this.onSleepTimer,
    required this.sleepLabel,
    required this.onRestart,
    required this.onMultiView,
  });

  final IptvItem item;
  final String? subtitle;
  final bool isLive;
  final bool isPlaying;
  final bool canZap;
  final Player player;
  final VoidCallback onClose;
  final VoidCallback onTogglePlay;
  final VoidCallback onZapUp;
  final VoidCallback onZapDown;
  final ValueChanged<Duration> onSeekBy;
  final VoidCallback onOpenChannelList;
  final VoidCallback? onRecall;
  final VoidCallback? onEnterNumber;
  final VoidCallback onSleepTimer;
  final String? sleepLabel;
  final VoidCallback? onRestart;
  final VoidCallback? onMultiView;

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
                  if (onEnterNumber != null)
                    IconButton(onPressed: onEnterNumber, icon: const Icon(Icons.dialpad, size: 26), tooltip: 'Channel number'),
                  if (onMultiView != null)
                    IconButton(onPressed: onMultiView, icon: const Icon(Icons.grid_view_rounded, size: 26), tooltip: 'Multi-view'),
                  sleepLabel == null
                      ? IconButton(onPressed: onSleepTimer, icon: const Icon(Icons.bedtime_outlined, size: 26), tooltip: 'Sleep timer')
                      : TextButton.icon(
                          onPressed: onSleepTimer,
                          icon: Icon(Icons.bedtime, size: 20, color: accent),
                          label: Text(sleepLabel!, style: TextStyle(color: accent)),
                        ),
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
                if (isLive && onRestart != null)
                  IconButton(iconSize: 40, onPressed: onRestart, icon: const Icon(Icons.restart_alt), tooltip: 'Watch from start'),
                const SizedBox(width: 48),
                IconButton(iconSize: 64, onPressed: onTogglePlay, icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow)),
                const SizedBox(width: 48),
                if (!isLive)
                  IconButton(iconSize: 44, onPressed: () => onSeekBy(const Duration(seconds: 10)), icon: const Icon(Icons.forward_10)),
                if (isLive && onRecall != null)
                  IconButton(iconSize: 40, onPressed: onRecall, icon: const Icon(Icons.history_toggle_off), tooltip: 'Last channel'),
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
                        stream: player.stream.position,
                        initialData: player.state.position,
                        builder: (context, positionSnapshot) => StreamBuilder<Duration>(
                          stream: player.stream.duration,
                          initialData: player.state.duration,
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
                                    onChanged: maxMs <= 0 ? null : (v) => player.seek(Duration(milliseconds: v.round())),
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
