import 'package:flutter/material.dart';

import 'arr_service.dart';
import 'services/jellyfin_api_service.dart';
import 'settings_controller.dart';
import 'widgets/sinema_image.dart';

class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key, required this.serverUrl, required this.userId, required this.token, required this.settings});
  final String serverUrl;
  final String userId;
  final String token;
  final SettingsController settings;

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  final _api = JellyfinApiService();
  List<_CalendarEntry> _entries = const [];
  bool _isLoading = true;
  String? _error;

  bool get _sonarrConfigured => widget.settings.sonarrUrl.isNotEmpty && widget.settings.sonarrApiKey.isNotEmpty;
  bool get _radarrConfigured => widget.settings.radarrUrl.isNotEmpty && widget.settings.radarrApiKey.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final cutoff = today.add(const Duration(days: 7));

    try {
      final entries = <_CalendarEntry>[];

      if (_sonarrConfigured) {
        final sonarrItems = await ArrService.getSonarrCalendar(
          widget.settings.sonarrUrl,
          widget.settings.sonarrApiKey,
          today.toUtc().subtract(const Duration(days: 1)),
          cutoff.toUtc().add(const Duration(days: 1)),
        );
        entries.addAll(sonarrItems.whereType<Map<String, dynamic>>().map(_CalendarEntry.fromSonarr).whereType<_CalendarEntry>());
      }
      if (_radarrConfigured) {
        final radarrItems = await ArrService.getRadarrCalendar(
          widget.settings.radarrUrl,
          widget.settings.radarrApiKey,
          today.toUtc().subtract(const Duration(days: 1)),
          cutoff.toUtc().add(const Duration(days: 1)),
        );
        entries.addAll(radarrItems.whereType<Map<String, dynamic>>().map(_CalendarEntry.fromRadarr).whereType<_CalendarEntry>());
      }
      // Only fall back to Jellyfin's own (file-scan-based) schedule for
      // whichever media type isn't covered by a configured *arr instance —
      // Sonarr/Radarr know about items before they're even downloaded, so
      // they're the better source whenever available.
      if (!_sonarrConfigured || !_radarrConfigured) {
        final jellyfinItems = await _api.getUpcomingItems(widget.serverUrl, widget.userId, widget.token);
        entries.addAll(
          jellyfinItems.whereType<Map<String, dynamic>>().where((item) {
            if (_sonarrConfigured && item['Type'] == 'Episode') return false;
            if (_radarrConfigured && item['Type'] == 'Movie') return false;
            return true;
          }).map((item) => _CalendarEntry.fromJellyfin(item, widget.serverUrl)).whereType<_CalendarEntry>(),
        );
      }

      if (!mounted) return;
      setState(() {
        _entries = entries;
        _isLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() { _isLoading = false; _error = 'Unable to load upcoming releases.'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groupByDate(_entries);
    return Scaffold(
      appBar: AppBar(title: const Text('CALENDAR', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: 1.8))),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!, style: const TextStyle(color: Color(0xFFA5A7AC))))
              : groups.isEmpty
                  ? const Center(child: Text('No upcoming releases found.', style: TextStyle(color: Color(0xFFA5A7AC))))
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      itemCount: groups.length,
                      itemBuilder: (context, index) {
                        final group = groups[index];
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                              child: Text(group.label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFFA5A7AC))),
                            ),
                            for (final entry in group.entries) _UpcomingRow(entry: entry, token: widget.token),
                          ],
                        );
                      },
                    ),
    );
  }

  List<_DateGroup> _groupByDate(List<_CalendarEntry> entries) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final cutoff = today.add(const Duration(days: 7));
    final byDate = <String, List<_CalendarEntry>>{};
    for (final entry in entries) {
      final localDate = entry.airDateUtc.toLocal();
      final localDay = DateTime(localDate.year, localDate.month, localDate.day);
      if (localDay.isBefore(today) || !localDay.isBefore(cutoff)) continue;
      final key = '${localDay.year}-${localDay.month.toString().padLeft(2, '0')}-${localDay.day.toString().padLeft(2, '0')}';
      byDate.putIfAbsent(key, () => []).add(entry);
    }
    final keys = byDate.keys.toList()..sort();
    return [
      for (final key in keys)
        _DateGroup(
          label: _formatGroupLabel(key),
          entries: byDate[key]!..sort((a, b) => a.airDateUtc.compareTo(b.airDateUtc)),
        ),
    ];
  }

  String _formatGroupLabel(String key) {
    final date = DateTime.tryParse(key);
    if (date == null) return 'Date unknown';
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final target = DateTime(date.year, date.month, date.day);
    final diff = target.difference(today).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Tomorrow';
    return '${months[date.month - 1]} ${date.day}, ${date.year}';
  }
}

class _DateGroup {
  const _DateGroup({required this.label, required this.entries});
  final String label;
  final List<_CalendarEntry> entries;
}

// A single source-agnostic row: built from a Jellyfin item, a Sonarr
// calendar entry, or a Radarr calendar entry.
class _CalendarEntry {
  const _CalendarEntry({
    required this.title,
    required this.subtitle,
    required this.airDateUtc,
    this.posterUrl,
    this.posterNeedsAuth = false,
    this.statusLabel,
    this.statusColor,
  });

  final String title;
  final String subtitle;
  final DateTime airDateUtc;
  final String? posterUrl;
  final bool posterNeedsAuth;
  final String? statusLabel;
  final Color? statusColor;

  static _CalendarEntry? fromJellyfin(Map<String, dynamic> item, String serverUrl) {
    final airDateUtc = DateTime.tryParse(item['PremiereDate'] as String? ?? '');
    if (airDateUtc == null) return null;
    final isEpisode = item['Type'] == 'Episode';
    final title = isEpisode ? (item['SeriesName'] as String? ?? 'Unknown Show') : (item['Name'] as String? ?? 'Untitled');
    final subtitle = isEpisode ? 'S${item['ParentIndexNumber'] ?? '?'}E${item['IndexNumber'] ?? '?'} • ${item['Name'] ?? ''}' : 'Movie';
    final (posterId, tag) = _jellyfinPosterImage(item);
    final posterUrl = posterId != null && tag != null ? JellyfinApiService.getImageUrl(serverUrl, posterId, imageTag: tag, maxWidth: 170) : null;
    return _CalendarEntry(title: title, subtitle: subtitle, airDateUtc: airDateUtc, posterUrl: posterUrl, posterNeedsAuth: true);
  }

  static (String?, String?) _jellyfinPosterImage(Map<String, dynamic> item) {
    final itemId = item['Id'] as String?;
    final primaryTag = item['PrimaryImageTag'];
    if (primaryTag is String && primaryTag.isNotEmpty) return (itemId, primaryTag);
    final imageTags = item['ImageTags'];
    if (imageTags is Map && imageTags['Primary'] is String) return (itemId, imageTags['Primary'] as String);
    final seriesTag = item['SeriesPrimaryImageTag'];
    final seriesId = item['SeriesId'];
    if (seriesTag is String && seriesTag.isNotEmpty && seriesId is String) return (seriesId, seriesTag);
    return (null, null);
  }

  static _CalendarEntry? fromSonarr(Map<String, dynamic> item) {
    final airDateUtc = DateTime.tryParse(item['airDateUtc'] as String? ?? '');
    if (airDateUtc == null) return null;
    final series = item['series'] is Map<String, dynamic> ? item['series'] as Map<String, dynamic> : const <String, dynamic>{};
    final title = series['title'] as String? ?? 'Unknown Show';
    final subtitle = 'S${item['seasonNumber'] ?? '?'}E${item['episodeNumber'] ?? '?'} • ${item['title'] ?? ''}';
    final images = (series['images'] as List<dynamic>? ?? const []).whereType<Map<String, dynamic>>();
    final poster = images.where((i) => i['coverType'] == 'poster').firstOrNull;
    final posterUrl = poster?['remoteUrl'] as String?;
    final hasFile = item['hasFile'] == true;
    final episodeFile = item['episodeFile'] as Map<String, dynamic>?;
    final fileQuality = episodeFile?['quality'] as Map<String, dynamic>?;
    final qualityInfo = fileQuality?['quality'] as Map<String, dynamic>?;
    final qualityName = hasFile ? (qualityInfo?['name'] as String?) : null;
    return _CalendarEntry(
      title: title,
      subtitle: subtitle,
      airDateUtc: airDateUtc,
      posterUrl: posterUrl,
      statusLabel: hasFile ? 'Downloaded${qualityName != null ? ' ($qualityName)' : ''}' : 'Unaired',
      statusColor: hasFile ? const Color(0xFF3DB86B) : const Color(0xFF4AA8E0),
    );
  }

  static _CalendarEntry? fromRadarr(Map<String, dynamic> item) {
    final dateString = (item['digitalRelease'] ?? item['physicalRelease'] ?? item['inCinemas']) as String?;
    final airDateUtc = DateTime.tryParse(dateString ?? '');
    if (airDateUtc == null) return null;
    final title = item['title'] as String? ?? 'Untitled';
    final images = (item['images'] as List<dynamic>? ?? const []).whereType<Map<String, dynamic>>();
    final poster = images.where((i) => i['coverType'] == 'poster').firstOrNull;
    final posterUrl = poster?['remoteUrl'] as String?;
    final hasFile = item['hasFile'] == true;
    final movieFile = item['movieFile'] as Map<String, dynamic>?;
    final fileQuality = movieFile?['quality'] as Map<String, dynamic>?;
    final qualityInfo = fileQuality?['quality'] as Map<String, dynamic>?;
    final qualityName = hasFile ? (qualityInfo?['name'] as String?) : null;
    return _CalendarEntry(
      title: title,
      subtitle: 'Movie',
      airDateUtc: airDateUtc,
      posterUrl: posterUrl,
      statusLabel: hasFile ? 'Downloaded${qualityName != null ? ' ($qualityName)' : ''}' : 'Missing',
      statusColor: hasFile ? const Color(0xFF3DB86B) : const Color(0xFF4AA8E0),
    );
  }
}

class _UpcomingRow extends StatelessWidget {
  const _UpcomingRow({required this.entry, required this.token});
  final _CalendarEntry entry;
  final String token;

  @override
  Widget build(BuildContext context) {
    final time = _releaseTime(entry.airDateUtc);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              width: 56,
              height: 80,
              child: entry.posterUrl == null
                  ? const ColoredBox(color: Color(0xFF17191D), child: Icon(Icons.movie_outlined, color: Colors.white24))
                  : SinemaImage(
                      imageUrl: entry.posterUrl!,
                      httpHeaders: entry.posterNeedsAuth ? JellyfinApiService.authHeaders(token) : null,
                      fit: BoxFit.cover,
                      memCacheWidth: 170,
                      placeholder: (_, _) => const ColoredBox(color: Color(0xFF17191D)),
                      errorWidget: (_, _, _) => const ColoredBox(color: Color(0xFF17191D), child: Icon(Icons.movie_outlined, color: Colors.white24)),
                    ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(entry.title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text(entry.subtitle, style: const TextStyle(fontSize: 13, color: Color(0xFFA5A7AC)), maxLines: 1, overflow: TextOverflow.ellipsis),
                if (entry.statusLabel != null) ...[
                  const SizedBox(height: 4),
                  Text(entry.statusLabel!, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: entry.statusColor)),
                ],
              ],
            ),
          ),
          if (time != null) ...[
            const SizedBox(width: 10),
            Text(time, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFFA5A7AC))),
          ],
        ],
      ),
    );
  }

  // Plenty of metadata providers only ever populate a bare date (which
  // arrives as UTC midnight) with no real air time — showing a "time" for
  // those would just be showing an artifact of the UTC conversion, so this
  // only surfaces a time when the source timestamp actually carries one.
  String? _releaseTime(DateTime utcDate) {
    if (utcDate.hour == 0 && utcDate.minute == 0 && utcDate.second == 0) return null;
    final local = utcDate.toLocal();
    final hour24 = local.hour;
    final hour = hour24 % 12 == 0 ? 12 : hour24 % 12;
    final minute = local.minute.toString().padLeft(2, '0');
    final period = hour24 < 12 ? 'AM' : 'PM';
    return '$hour:$minute $period';
  }
}
