import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../widgets/sinema_image.dart';
import 'iptv_models.dart';
import 'iptv_player_screen.dart';
import 'iptv_repository.dart';
import 'live_playback.dart';
import 'live_tv_screen.dart' show ensureUnlocked;

// TiviMate's multi-view: up to four channels at once in a 2×2 grid. Only the
// focused tile plays sound; tap a tile to move the sound to it, double-tap to
// go full screen on it, long-press to change or remove it.
class MultiViewScreen extends StatefulWidget {
  const MultiViewScreen({super.key, required this.channels, this.initial = const []});
  final List<IptvItem> channels;
  final List<IptvItem> initial;

  @override
  State<MultiViewScreen> createState() => _MultiViewScreenState();
}

class _Tile {
  _Tile(this.channel) : player = Player(configuration: const PlayerConfiguration(bufferSize: 8 * 1024 * 1024)) {
    video = VideoController(player);
  }

  IptvItem channel;
  final Player player;
  late final VideoController video;
  bool failed = false;
}

class _MultiViewScreenState extends State<MultiViewScreen> {
  static const _maxTiles = 4;
  final _repo = IptvRepository.instance;
  final List<_Tile> _tiles = [];
  int _focus = 0;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    for (final channel in widget.initial.take(_maxTiles)) {
      _addTile(channel);
    }
  }

  Future<void> _start(_Tile tile) async {
    try {
      await videoReady(tile.video);
      await tuneForLive(tile.player);
      await _applyVolumes();
      await tile.player.open(_media(tile.channel));
    } catch (_) {
      if (mounted) setState(() => tile.failed = true);
    }
  }

  void _addTile(IptvItem channel) {
    final tile = _Tile(channel);
    setState(() {
      _tiles.add(tile);
      _focus = _tiles.length - 1;
    });
    _start(tile);
  }

  Future<void> _replaceTile(int index, IptvItem channel) async {
    final tile = _tiles[index];
    setState(() {
      tile.channel = channel;
      tile.failed = false;
      _focus = index;
    });
    try {
      await tile.player.open(_media(channel));
    } catch (_) {
      if (mounted) setState(() => tile.failed = true);
    }
  }

  Media _media(IptvItem channel) {
    final headers = _repo.sourceFor(channel.sourceId)?.headers ?? const <String, String>{};
    return Media(_repo.playbackUrl(channel), httpHeaders: headers.isEmpty ? null : headers);
  }

  void _removeTile(int index) {
    final tile = _tiles.removeAt(index);
    tile.player.dispose();
    setState(() => _focus = _tiles.isEmpty ? 0 : _focus.clamp(0, _tiles.length - 1));
    _applyVolumes();
  }

  Future<void> _applyVolumes() async {
    for (var i = 0; i < _tiles.length; i++) {
      try {
        // media_kit volume is 0–100.
        await _tiles[i].player.setVolume(i == _focus ? 100 : 0);
      } catch (_) {}
    }
  }

  void _setFocus(int index) {
    setState(() => _focus = index);
    _applyVolumes();
  }

  Future<IptvItem?> _pickChannel() async {
    final channels = widget.channels.isNotEmpty ? widget.channels : _repo.liveChannels;
    final picked = await showModalBottomSheet<IptvItem>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => _ChannelPicker(channels: channels),
    );
    if (picked == null || !mounted) return null;
    if (!await ensureUnlocked(context, picked)) return null;
    return picked;
  }

  Future<void> _addFromPicker() async {
    final channel = await _pickChannel();
    if (channel != null) _addTile(channel);
  }

  Future<void> _tileMenu(int index) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: Text(_tiles[index].channel.name, style: const TextStyle(fontWeight: FontWeight.w700))),
            ListTile(leading: const Icon(Icons.fullscreen), title: const Text('Watch Full Screen'), onTap: () => Navigator.of(sheetContext).pop('full')),
            ListTile(leading: const Icon(Icons.swap_horiz), title: const Text('Change Channel'), onTap: () => Navigator.of(sheetContext).pop('change')),
            ListTile(leading: const Icon(Icons.close), title: const Text('Remove'), onTap: () => Navigator.of(sheetContext).pop('remove')),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'full':
        _goFullScreen(index);
      case 'change':
        final channel = await _pickChannel();
        if (channel != null) await _replaceTile(index, channel);
      case 'remove':
        _removeTile(index);
    }
  }

  void _goFullScreen(int index) {
    final channel = _tiles[index].channel;
    final list = widget.channels.contains(channel) ? widget.channels : [channel];
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => IptvPlayerScreen(items: list, initialIndex: list.indexOf(channel)),
    ));
  }

  @override
  void dispose() {
    for (final tile in _tiles) {
      tile.player.dispose();
    }
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final cells = [
      for (var i = 0; i < _tiles.length; i++) _buildTile(i, accent),
      if (_tiles.length < _maxTiles) _buildAddCell(),
    ];
    // 1 tile: full; 2: side by side; 3–4: 2×2.
    final rows = cells.length <= 2 ? [cells] : [cells.sublist(0, 2), cells.sublist(2)];
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Column(
            children: [
              for (final row in rows)
                Expanded(
                  child: Row(
                    children: [
                      for (final cell in row) Expanded(child: Padding(padding: const EdgeInsets.all(1.5), child: cell)),
                      if (row.length == 1 && rows.length > 1) const Expanded(child: SizedBox.shrink()),
                    ],
                  ),
                ),
            ],
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                  style: IconButton.styleFrom(backgroundColor: Colors.black54),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTile(int index, Color accent) {
    final tile = _tiles[index];
    final focused = index == _focus;
    final now = _repo.nowPlaying(tile.channel);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _setFocus(index),
      onDoubleTap: () => _goFullScreen(index),
      onLongPress: () => _tileMenu(index),
      child: Stack(
        fit: StackFit.expand,
        children: [
          IgnorePointer(child: Video(controller: tile.video, controls: NoVideoControls, fill: Colors.black)),
          if (tile.failed)
            const ColoredBox(color: Colors.black87, child: Center(child: Text('Couldn\'t play this channel', style: TextStyle(color: Colors.white70)))),
          // Focus ring + label.
          IgnorePointer(
            child: Container(
              decoration: BoxDecoration(border: Border.all(color: focused ? accent : Colors.transparent, width: 3)),
              alignment: Alignment.bottomLeft,
              padding: const EdgeInsets.all(8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(focused ? Icons.volume_up : Icons.volume_off, size: 14, color: focused ? accent : Colors.white54),
                    const SizedBox(width: 6),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 220),
                      child: Text(
                        now == null ? tile.channel.name : '${tile.channel.name} · ${now.title}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAddCell() => InkWell(
        onTap: _addFromPicker,
        child: Container(
          color: const Color(0xFF0E0F12),
          alignment: Alignment.center,
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.add_circle_outline, size: 40, color: Colors.white54),
              SizedBox(height: 8),
              Text('Add Channel', style: TextStyle(color: Colors.white54)),
            ],
          ),
        ),
      );
}

class _ChannelPicker extends StatefulWidget {
  const _ChannelPicker({required this.channels});
  final List<IptvItem> channels;

  @override
  State<_ChannelPicker> createState() => _ChannelPickerState();
}

class _ChannelPickerState extends State<_ChannelPicker> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final list = q.isEmpty ? widget.channels : widget.channels.where((c) => c.name.toLowerCase().contains(q)).toList();
    return SizedBox(
      height: MediaQuery.of(context).size.height * .85,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: TextField(
              autofocus: false,
              onChanged: (v) => setState(() => _query = v),
              decoration: const InputDecoration(hintText: 'Search channels', prefixIcon: Icon(Icons.search), isDense: true),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemExtent: 56,
              itemCount: list.length,
              itemBuilder: (context, index) {
                final channel = list[index];
                return ListTile(
                  leading: SizedBox(
                    width: 44,
                    height: 30,
                    child: channel.logo == null
                        ? const Icon(Icons.live_tv, color: Colors.white38)
                        : SinemaImage(imageUrl: channel.logo!, fit: BoxFit.contain, memCacheWidth: 132, errorWidget: (_, _, _) => const Icon(Icons.live_tv, color: Colors.white38)),
                  ),
                  title: Text(channel.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () => Navigator.of(context).pop(channel),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
