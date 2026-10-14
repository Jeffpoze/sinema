import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:typed_data';

import 'iptv_models.dart';

// Everything in this file is pure and top-level so it can run inside
// `compute()` — playlists with tens of thousands of entries and XMLTV guides
// of 100MB+ are parsed off the UI thread.

// Stable across app launches (unlike String.hashCode), so favorites keyed by
// these ids survive a playlist refresh.
String stableId(String sourceId, String key) {
  var hash = 0x811c9dc5;
  for (final unit in key.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return '$sourceId|${hash.toRadixString(36)}|${key.length}';
}

final _attrPattern = RegExp(r'([a-zA-Z0-9_-]+)="([^"]*)"');
final _episodePattern = RegExp(r'\bS(\d{1,2})\s*[._ -]?\s*E(\d{1,3})\b', caseSensitive: false);
final _videoExtension = RegExp(r'\.(mp4|mkv|avi|mov|m4v|wmv|flv)(\?|$)', caseSensitive: false);

class M3uParseResult {
  const M3uParseResult(this.items, this.epgUrl);
  final List<IptvItem> items;
  final String? epgUrl;
}

M3uParseResult parseM3u(({String text, String sourceId}) input) {
  final items = <IptvItem>[];
  String? epgUrl;
  // Playlist-wide catch-up defaults from the #EXTM3U header.
  Map<String, String> header = const {};
  Map<String, String> attrs = const {};
  String? title;
  String? extGroup;
  final seen = <String>{};

  for (final rawLine in const LineSplitter().convert(input.text)) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#EXTM3U')) {
      header = {for (final m in _attrPattern.allMatches(line)) m.group(1)!.toLowerCase(): m.group(2)!};
      epgUrl = header['url-tvg'] ?? header['x-tvg-url'];
      // Some playlists list several guides separated by commas; take the first.
      if (epgUrl != null && epgUrl.contains(',')) epgUrl = epgUrl.split(',').first.trim();
      continue;
    }
    if (line.startsWith('#EXTINF')) {
      // Attributes live between "#EXTINF:-1" and the last comma before the
      // display name; titles can themselves contain commas, so split on the
      // first comma that follows the final closing quote.
      final lastQuote = line.lastIndexOf('"');
      final comma = line.indexOf(',', lastQuote < 0 ? 0 : lastQuote);
      final attrPart = comma < 0 ? line : line.substring(0, comma);
      attrs = {for (final m in _attrPattern.allMatches(attrPart)) m.group(1)!.toLowerCase(): m.group(2)!};
      title = comma < 0 ? null : line.substring(comma + 1).trim();
      continue;
    }
    if (line.startsWith('#EXTGRP:')) {
      extGroup = line.substring(8).trim();
      continue;
    }
    if (line.startsWith('#')) continue;

    // A URL line closes the current entry.
    final url = line;
    final name = (title != null && title.isNotEmpty) ? title : (attrs['tvg-name'] ?? 'Channel');
    final group = attrs['group-title']?.trim().isNotEmpty == true ? attrs['group-title']!.trim() : (extGroup ?? 'Uncategorized');
    final lowerUrl = url.toLowerCase();
    final episode = _episodePattern.firstMatch(name);
    final IptvKind kind;
    if (lowerUrl.contains('/series/') || (episode != null && _videoExtension.hasMatch(lowerUrl))) {
      kind = IptvKind.series;
    } else if (lowerUrl.contains('/movie/') || _videoExtension.hasMatch(lowerUrl)) {
      kind = IptvKind.movie;
    } else {
      kind = IptvKind.live;
    }
    final id = stableId(input.sourceId, url);
    final catchupType = attrs['catchup'] ?? attrs['catchup-type'] ?? header['catchup'] ?? header['catchup-type'] ?? (attrs['timeshift'] != null ? 'default' : null);
    final catchupDays = int.tryParse(attrs['catchup-days'] ?? attrs['timeshift'] ?? header['catchup-days'] ?? '') ?? (catchupType != null ? 7 : null);
    if (seen.add(id)) {
      items.add(IptvItem(
        id: id,
        sourceId: input.sourceId,
        kind: kind,
        name: name,
        group: group,
        url: url,
        logo: (attrs['tvg-logo']?.isNotEmpty ?? false) ? attrs['tvg-logo'] : null,
        epgId: (attrs['tvg-id']?.isNotEmpty ?? false) ? attrs['tvg-id'] : null,
        number: int.tryParse(attrs['tvg-chno'] ?? ''),
        seriesName: kind == IptvKind.series ? _seriesNameFrom(name, episode) : null,
        catchupType: kind == IptvKind.live ? catchupType : null,
        catchupDays: kind == IptvKind.live ? catchupDays : null,
        catchupSource: kind == IptvKind.live ? (attrs['catchup-source'] ?? header['catchup-source']) : null,
      ));
    }
    attrs = const {};
    title = null;
    extGroup = null;
  }
  return M3uParseResult(items, epgUrl);
}

String _seriesNameFrom(String name, RegExpMatch? episode) {
  if (episode == null) return name;
  final cleaned = name.substring(0, episode.start).replaceAll(RegExp(r'[\s\-–|:._]+$'), '').trim();
  return cleaned.isEmpty ? name : cleaned;
}

// ---------------------------------------------------------------------------
// Xtream Codes

String _str(dynamic v) => v == null ? '' : v.toString();
String? _optStr(dynamic v) {
  final s = _str(v).trim();
  return s.isEmpty || s == 'null' ? null : s;
}

Map<String, String> xtreamCategoryNames(List<dynamic> categories) => {
      for (final c in categories.whereType<Map<String, dynamic>>()) _str(c['category_id']): _str(c['category_name']),
    };

List<IptvItem> parseXtreamLive(({String sourceId, String base, String user, String pass, List<dynamic> streams, Map<String, String> categories}) input) {
  final out = <IptvItem>[];
  for (final s in input.streams.whereType<Map<String, dynamic>>()) {
    final streamId = _str(s['stream_id']);
    if (streamId.isEmpty) continue;
    out.add(IptvItem(
      id: stableId(input.sourceId, 'live/$streamId'),
      sourceId: input.sourceId,
      kind: IptvKind.live,
      name: _str(s['name']).trim(),
      group: input.categories[_str(s['category_id'])] ?? 'Uncategorized',
      // HLS rather than the default MPEG-TS: AVPlayer on iOS can't play a
      // raw .ts stream, and every Xtream panel can serve both.
      url: '${input.base}/live/${input.user}/${input.pass}/$streamId.m3u8',
      logo: _optStr(s['stream_icon']),
      epgId: _optStr(s['epg_channel_id']),
      number: int.tryParse(_str(s['num'])),
      streamId: streamId,
      catchupType: _str(s['tv_archive']) == '1' ? 'xtream' : null,
      catchupDays: _str(s['tv_archive']) == '1' ? (int.tryParse(_str(s['tv_archive_duration'])) ?? 3) : null,
    ));
  }
  return out;
}

List<IptvItem> parseXtreamVod(({String sourceId, String base, String user, String pass, List<dynamic> streams, Map<String, String> categories}) input) {
  final out = <IptvItem>[];
  for (final s in input.streams.whereType<Map<String, dynamic>>()) {
    final streamId = _str(s['stream_id']);
    if (streamId.isEmpty) continue;
    final ext = _optStr(s['container_extension']) ?? 'mp4';
    out.add(IptvItem(
      id: stableId(input.sourceId, 'movie/$streamId'),
      sourceId: input.sourceId,
      kind: IptvKind.movie,
      name: _str(s['name']).trim(),
      group: input.categories[_str(s['category_id'])] ?? 'Uncategorized',
      url: '${input.base}/movie/${input.user}/${input.pass}/$streamId.$ext',
      logo: _optStr(s['stream_icon']),
      rating: _optStr(s['rating']),
      year: _optStr(s['year']),
    ));
  }
  return out;
}

List<IptvItem> parseXtreamSeries(({String sourceId, List<dynamic> series, Map<String, String> categories}) input) {
  final out = <IptvItem>[];
  for (final s in input.series.whereType<Map<String, dynamic>>()) {
    final seriesId = _str(s['series_id']);
    if (seriesId.isEmpty) continue;
    out.add(IptvItem(
      id: stableId(input.sourceId, 'series/$seriesId'),
      sourceId: input.sourceId,
      kind: IptvKind.series,
      name: _str(s['name']).trim(),
      group: input.categories[_str(s['category_id'])] ?? 'Uncategorized',
      logo: _optStr(s['cover']),
      seriesId: seriesId,
      seriesName: _str(s['name']).trim(),
      plot: _optStr(s['plot']),
      rating: _optStr(s['rating']),
      year: _optStr(s['releaseDate'])?.split('-').first,
    ));
  }
  return out;
}

List<IptvEpisode> parseXtreamEpisodes(Map<String, dynamic> info, String base, String user, String pass) {
  final episodes = <IptvEpisode>[];
  final bySeason = info['episodes'];
  final Iterable<dynamic> lists = bySeason is Map<String, dynamic>
      ? bySeason.values
      : (bySeason is List<dynamic> ? bySeason : const []);
  for (final list in lists) {
    if (list is! List<dynamic>) continue;
    for (final e in list.whereType<Map<String, dynamic>>()) {
      final id = _str(e['id']);
      if (id.isEmpty) continue;
      final ext = _optStr(e['container_extension']) ?? 'mp4';
      final epInfo = e['info'] is Map<String, dynamic> ? e['info'] as Map<String, dynamic> : const <String, dynamic>{};
      episodes.add(IptvEpisode(
        title: _str(e['title']).trim(),
        season: int.tryParse(_str(e['season'])) ?? 1,
        episode: int.tryParse(_str(e['episode_num'])) ?? 0,
        url: '$base/series/$user/$pass/$id.$ext',
        image: _optStr(epInfo['movie_image']),
        plot: _optStr(epInfo['plot']),
        duration: _optStr(epInfo['duration']),
      ));
    }
  }
  episodes.sort((a, b) => a.season != b.season ? a.season.compareTo(b.season) : a.episode.compareTo(b.episode));
  return episodes;
}

// ---------------------------------------------------------------------------
// XMLTV

class EpgParseResult {
  const EpgParseResult(this.programs, this.nameToId);
  // Keyed by the XMLTV channel id.
  final Map<String, List<EpgProgram>> programs;
  // Lower-cased display name -> channel id, for playlists without tvg-id.
  final Map<String, String> nameToId;
}

final _channelPattern = RegExp(r'<channel\b[^>]*\bid="([^"]*)"[^>]*>(.*?)</channel>', dotAll: true);
final _displayNamePattern = RegExp(r'<display-name[^>]*>(.*?)</display-name>', dotAll: true);
final _programmePattern = RegExp(r'<programme\b([^>]*)>(.*?)</programme>', dotAll: true);
final _titlePattern = RegExp(r'<title[^>]*>(.*?)</title>', dotAll: true);
final _descPattern = RegExp(r'<desc[^>]*>(.*?)</desc>', dotAll: true);

EpgParseResult parseXmltv(({Uint8List bytes, int nowMs, int offsetMinutes}) input) {
  var bytes = input.bytes;
  if (bytes.length > 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
    bytes = Uint8List.fromList(gzip.decode(bytes));
  }
  final text = utf8.decode(bytes, allowMalformed: true);
  final now = DateTime.fromMillisecondsSinceEpoch(input.nowMs);
  // Keep a practical window: a little history for "what was just on" and
  // two days ahead for the guide. Older/newer entries are dropped to keep
  // the cache small.
  // Long enough back to cover a week of catch-up.
  final windowStart = now.subtract(const Duration(days: 7));
  final offset = Duration(minutes: input.offsetMinutes);
  final windowEnd = now.add(const Duration(hours: 48));

  final nameToId = <String, String>{};
  for (final m in _channelPattern.allMatches(text)) {
    final id = _unescape(m.group(1)!);
    for (final d in _displayNamePattern.allMatches(m.group(2)!)) {
      nameToId.putIfAbsent(_unescape(d.group(1)!).trim().toLowerCase(), () => id);
    }
  }

  final programs = <String, List<EpgProgram>>{};
  for (final m in _programmePattern.allMatches(text)) {
    final attrs = {for (final a in _attrPattern.allMatches(m.group(1)!)) a.group(1)!: a.group(2)!};
    final start = _parseXmltvTime(attrs['start'])?.add(offset);
    final end = _parseXmltvTime(attrs['stop'])?.add(offset);
    final channel = attrs['channel'];
    if (start == null || end == null || channel == null) continue;
    if (end.isBefore(windowStart) || start.isAfter(windowEnd)) continue;
    final body = m.group(2)!;
    final title = _titlePattern.firstMatch(body)?.group(1);
    final desc = _descPattern.firstMatch(body)?.group(1);
    (programs[_unescape(channel)] ??= []).add(EpgProgram(
      start: start,
      end: end,
      title: title == null ? 'No information' : _unescape(title).trim(),
      description: desc == null ? null : _unescape(desc).trim(),
    ));
  }
  for (final list in programs.values) {
    list.sort((a, b) => a.start.compareTo(b.start));
  }
  return EpgParseResult(programs, nameToId);
}

// "20261014193000 +0200" (offset optional).
DateTime? _parseXmltvTime(String? value) {
  if (value == null || value.length < 12) return null;
  final digits = value.trim();
  final y = int.tryParse(digits.substring(0, 4));
  final mo = int.tryParse(digits.substring(4, 6));
  final d = int.tryParse(digits.substring(6, 8));
  final h = int.tryParse(digits.substring(8, 10));
  final mi = int.tryParse(digits.substring(10, 12));
  final s = digits.length >= 14 ? int.tryParse(digits.substring(12, 14)) ?? 0 : 0;
  if (y == null || mo == null || d == null || h == null || mi == null) return null;
  var utc = DateTime.utc(y, mo, d, h, mi, s);
  final offsetMatch = RegExp(r'([+-])(\d{2})(\d{2})$').firstMatch(digits);
  if (offsetMatch != null) {
    final sign = offsetMatch.group(1) == '-' ? -1 : 1;
    final offset = Duration(hours: int.parse(offsetMatch.group(2)!), minutes: int.parse(offsetMatch.group(3)!));
    utc = utc.subtract(offset * sign);
  }
  return utc.toLocal();
}

final _entityPattern = RegExp(r'&(#x?[0-9a-fA-F]+|amp|lt|gt|quot|apos);');

String _unescape(String value) {
  var v = value;
  if (v.startsWith('<![CDATA[') && v.endsWith(']]>')) v = v.substring(9, v.length - 3);
  if (!v.contains('&')) return v;
  return v.replaceAllMapped(_entityPattern, (m) {
    final e = m.group(1)!;
    switch (e) {
      case 'amp':
        return '&';
      case 'lt':
        return '<';
      case 'gt':
        return '>';
      case 'quot':
        return '"';
      case 'apos':
        return "'";
    }
    final code = e.startsWith('#x') ? int.tryParse(e.substring(2), radix: 16) : int.tryParse(e.substring(1));
    return code == null ? m.group(0)! : String.fromCharCode(code);
  });
}

// ---------------------------------------------------------------------------
// Cache encoding (also run in isolates).

String encodeItems(List<IptvItem> items) => jsonEncode([for (final i in items) i.toJson()]);

List<IptvItem> decodeItems(String json) => [
      for (final j in (jsonDecode(json) as List<dynamic>)) IptvItem.fromJson(j as Map<String, dynamic>),
    ];

String encodeEpg(EpgParseResult epg) => jsonEncode({
      'p': {for (final e in epg.programs.entries) e.key: [for (final p in e.value) p.toJson()]},
      'n': epg.nameToId,
    });

EpgParseResult decodeEpg(String json) {
  final data = jsonDecode(json) as Map<String, dynamic>;
  final programs = <String, List<EpgProgram>>{};
  (data['p'] as Map<String, dynamic>).forEach((key, value) {
    programs[key] = [for (final p in value as List<dynamic>) EpgProgram.fromJson(p as List<dynamic>)];
  });
  return EpgParseResult(programs, (data['n'] as Map<String, dynamic>).cast<String, String>());
}
