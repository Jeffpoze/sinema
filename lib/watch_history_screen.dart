import 'package:flutter/material.dart';

import 'detail_screen.dart';
import 'services/jellyfin_api_service.dart';
import 'settings_controller.dart';
import 'widgets/sinema_image.dart';

// Movies and episodes the signed-in user has finished, newest first.
class WatchHistoryScreen extends StatefulWidget {
  const WatchHistoryScreen({super.key, required this.session, required this.settings});
  final JellyfinSession session;
  final SettingsController settings;

  @override
  State<WatchHistoryScreen> createState() => _WatchHistoryScreenState();
}

class _WatchHistoryScreenState extends State<WatchHistoryScreen> {
  final _api = JellyfinApiService();
  List<Map<String, dynamic>> _items = const [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final items = await _api.getWatchHistory(widget.session.serverUrl, widget.session.userId, widget.session.token);
      if (!mounted) return;
      setState(() {
        _items = items.whereType<Map<String, dynamic>>().toList();
        _isLoading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _error = 'Couldn\'t load your watch history.';
        });
      }
    }
  }

  String _playedLabel(Map<String, dynamic> item) {
    final iso = (item['UserData'] as Map<String, dynamic>?)?['LastPlayedDate'];
    final played = iso is String ? DateTime.tryParse(iso)?.toLocal() : null;
    if (played == null) return 'Watched';
    final today = DateUtils.dateOnly(DateTime.now());
    final day = DateUtils.dateOnly(played);
    final diff = today.difference(day).inDays;
    if (diff == 0) return 'Watched today';
    if (diff == 1) return 'Watched yesterday';
    if (diff < 7) return 'Watched $diff days ago';
    return 'Watched ${played.year}-${played.month.toString().padLeft(2, '0')}-${played.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('WATCH HISTORY', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: 1.8))),
        body: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? _ZeroState(
                    icon: Icons.cloud_off_outlined,
                    title: _error!,
                    message: 'Check your connection to the server and try again.',
                    action: FilledButton(onPressed: _load, child: const Text('Retry')),
                  )
                : _items.isEmpty
                    ? const _ZeroState(
                        icon: Icons.history,
                        title: 'Nothing watched yet',
                        message: 'Movies and episodes you finish will show up here, newest first.',
                      )
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: ListView.separated(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          itemCount: _items.length,
                          separatorBuilder: (_, _) => const Divider(height: 1, color: Color(0xFF1B1D22), indent: 108),
                          itemBuilder: (context, index) => _HistoryTile(
                            item: _items[index],
                            session: widget.session,
                            playedLabel: _playedLabel(_items[index]),
                            onTap: () {
                              final id = _items[index]['Id'] as String?;
                              if (id == null) return;
                              Navigator.of(context).push(MaterialPageRoute(
                                builder: (_) => DetailScreen(serverUrl: widget.session.serverUrl, userId: widget.session.userId, token: widget.session.token, itemId: id, settings: widget.settings),
                              ));
                            },
                          ),
                        ),
                      ),
      );
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({required this.item, required this.session, required this.playedLabel, required this.onTap});
  final Map<String, dynamic> item;
  final JellyfinSession session;
  final String playedLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isEpisode = item['Type'] == 'Episode';
    final id = item['Id'] as String?;
    final tags = item['ImageTags'] is Map ? item['ImageTags'] as Map : const {};
    final ownTag = tags['Primary'] as String?;
    // Episode stills are landscape already; fall back to the show's poster.
    final imageId = ownTag != null ? id : (isEpisode ? item['SeriesId'] as String? : id);
    final imageTag = ownTag ?? (isEpisode ? item['SeriesPrimaryImageTag'] as String? : null);
    final imageUrl = imageId != null && imageTag != null
        ? JellyfinApiService.getImageUrl(session.serverUrl, imageId, imageTag: imageTag, maxWidth: 320)
        : null;
    final title = isEpisode ? (item['SeriesName'] as String? ?? item['Name'] as String? ?? '') : (item['Name'] as String? ?? '');
    final season = item['ParentIndexNumber'];
    final episode = item['IndexNumber'];
    final detail = isEpisode
        ? [if (season != null && episode != null) 'S$season:E$episode', if (item['Name'] is String) item['Name'] as String].join(' · ')
        : (item['ProductionYear']?.toString() ?? 'Movie');

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 80,
                height: 45,
                child: imageUrl == null
                    ? const ColoredBox(color: Color(0xFF17191D), child: Icon(Icons.movie_outlined, color: Colors.white24, size: 20))
                    : SinemaImage(
                        imageUrl: imageUrl,
                        httpHeaders: JellyfinApiService.authHeaders(session.token),
                        fit: BoxFit.cover,
                        memCacheWidth: 240,
                        errorWidget: (_, _, _) => const ColoredBox(color: Color(0xFF17191D)),
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  if (detail.isNotEmpty)
                    Text(detail, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: Color(0xFFD3D2D6))),
                  Text(playedLabel, style: const TextStyle(fontSize: 12, color: Color(0xFFA5A7AC))),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ZeroState extends StatelessWidget {
  const _ZeroState({required this.icon, required this.title, required this.message, this.action});
  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFF1B1D22)),
                child: Icon(icon, size: 34, color: Colors.white54),
              ),
              const SizedBox(height: 20),
              Text(title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(message, textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFFA5A7AC), height: 1.4)),
              if (action != null) ...[const SizedBox(height: 20), action!],
            ],
          ),
        ),
      );
}
