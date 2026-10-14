import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'iptv_models.dart';
import 'iptv_parsers.dart';

// Owns every Live TV source, its cached playlist and guide, and the user's
// favorites / recently watched channels. One shared instance for the app.
//
// Lightweight by design: playlists and guides are downloaded once, parsed in
// a background isolate, and cached as compact JSON on disk. Opening Live TV
// afterwards reads the cache instead of hitting the provider, and refreshes
// quietly in the background once the cache is stale.
class IptvRepository extends ChangeNotifier {
  IptvRepository._();
  static final instance = IptvRepository._();

  static const _sourcesKey = 'iptv.sources';
  static const _favoritesKey = 'iptv.favorites';
  static const _recentsKey = 'iptv.recents';
  static const _playlistMaxAge = Duration(hours: 24);
  static const _epgMaxAge = Duration(hours: 12);

  final _client = http.Client();
  bool _loaded = false;

  List<IptvSource> _sources = [];
  List<IptvSource> get sources => List.unmodifiable(_sources);

  final Map<String, List<IptvItem>> _itemsBySource = {};
  final Map<String, EpgParseResult> _epgBySource = {};
  final Set<String> _refreshing = {};
  final Map<String, String> _errors = {};

  Set<String> _favorites = {};
  List<String> _recents = [];

  bool get hasSources => _sources.isNotEmpty;
  bool isRefreshing(String sourceId) => _refreshing.contains(sourceId);
  bool get isAnyRefreshing => _refreshing.isNotEmpty;
  String? errorFor(String sourceId) => _errors[sourceId];

  // Filtered lists are memoized until the underlying playlists change, so
  // the UI can ask for them on every rebuild even with huge playlists.
  final Map<IptvKind, List<IptvItem>> _kindCache = {};
  List<IptvItem>? _seriesCache;

  void _invalidate() {
    _kindCache.clear();
    _seriesCache = null;
  }

  List<IptvItem> _all(IptvKind kind) => _kindCache[kind] ??= List.unmodifiable([
        for (final source in _sources)
          ...?_itemsBySource[source.id]?.where((i) => i.kind == kind),
      ]);

  List<IptvItem> get liveChannels => _all(IptvKind.live);
  List<IptvItem> get movies => _all(IptvKind.movie);

  // Xtream series come in as one entry per show; M3U series arrive one entry
  // per episode, so collapse those into one card per show here.
  List<IptvItem> get series {
    final cached = _seriesCache;
    if (cached != null) return cached;
    final shows = <String, IptvItem>{};
    for (final item in _all(IptvKind.series)) {
      final key = item.seriesId != null ? item.id : '${item.sourceId}|${item.seriesName ?? item.name}';
      shows.putIfAbsent(key, () => item);
    }
    return _seriesCache = List.unmodifiable(shows.values);
  }

  List<IptvItem> m3uEpisodesFor(IptvItem show) => _all(IptvKind.series)
      .where((i) => i.sourceId == show.sourceId && i.seriesId == null && (i.seriesName ?? i.name) == (show.seriesName ?? show.name))
      .toList();

  IptvSource? sourceFor(String id) {
    for (final s in _sources) {
      if (s.id == id) return s;
    }
    return null;
  }

  // ---------------------------------------------------------------- loading

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_sourcesKey);
    if (raw != null) {
      try {
        _sources = [for (final j in jsonDecode(raw) as List<dynamic>) IptvSource.fromJson(j as Map<String, dynamic>)];
      } catch (_) {
        _sources = [];
      }
    }
    _favorites = (prefs.getStringList(_favoritesKey) ?? const []).toSet();
    _recents = prefs.getStringList(_recentsKey) ?? [];
    notifyListeners();
    for (final source in _sources) {
      await _loadFromCache(source);
    }
    _invalidate();
    notifyListeners();
    for (final source in _sources) {
      _refreshIfStale(source);
    }
  }

  Future<Directory> _cacheDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/iptv');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  Future<File> _playlistFile(String id) async => File('${(await _cacheDir()).path}/$id.items.json');
  Future<File> _epgFile(String id) async => File('${(await _cacheDir()).path}/$id.epg.json');

  Future<void> _loadFromCache(IptvSource source) async {
    try {
      final file = await _playlistFile(source.id);
      if (file.existsSync()) {
        _itemsBySource[source.id] = await compute(decodeItems, await file.readAsString());
      }
    } catch (_) {}
    try {
      final file = await _epgFile(source.id);
      if (file.existsSync()) {
        _epgBySource[source.id] = await compute(decodeEpg, await file.readAsString());
      }
    } catch (_) {}
  }

  Future<void> _refreshIfStale(IptvSource source) async {
    final playlist = await _playlistFile(source.id);
    final epg = await _epgFile(source.id);
    final now = DateTime.now();
    final playlistStale = !playlist.existsSync() || now.difference(playlist.lastModifiedSync()) > _playlistMaxAge;
    final epgStale = source.effectiveEpgUrl.isNotEmpty &&
        (!epg.existsSync() || now.difference(epg.lastModifiedSync()) > _epgMaxAge);
    if (playlistStale) {
      await refresh(source.id);
    } else if (epgStale) {
      await refreshEpg(source.id);
    }
  }

  // --------------------------------------------------------------- sources

  Future<void> _saveSources() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_sourcesKey, jsonEncode([for (final s in _sources) s.toJson()]));
  }

  Future<void> addSource(IptvSource source) async {
    _sources = [..._sources, source];
    _invalidate();
    await _saveSources();
    notifyListeners();
    await refresh(source.id);
  }

  Future<void> updateSource(IptvSource source) async {
    _sources = [for (final s in _sources) s.id == source.id ? source : s];
    _invalidate();
    await _saveSources();
    notifyListeners();
    await refresh(source.id);
  }

  Future<void> removeSource(String id) async {
    _sources = _sources.where((s) => s.id != id).toList();
    _itemsBySource.remove(id);
    _epgBySource.remove(id);
    _errors.remove(id);
    _invalidate();
    await _saveSources();
    try {
      final playlist = await _playlistFile(id);
      if (playlist.existsSync()) playlist.deleteSync();
      final epg = await _epgFile(id);
      if (epg.existsSync()) epg.deleteSync();
    } catch (_) {}
    notifyListeners();
  }

  // -------------------------------------------------------------- fetching

  Future<void> refresh(String sourceId) async {
    final source = sourceFor(sourceId);
    if (source == null || _refreshing.contains(sourceId)) return;
    _refreshing.add(sourceId);
    _errors.remove(sourceId);
    notifyListeners();
    try {
      final items = source.type == IptvSourceType.xtream ? await _fetchXtream(source) : await _fetchM3u(source);
      _itemsBySource[sourceId] = items;
      _invalidate();
      final file = await _playlistFile(sourceId);
      await file.writeAsString(await compute(encodeItems, items));
    } catch (e) {
      _errors[sourceId] = _friendlyError(e);
    } finally {
      _refreshing.remove(sourceId);
      notifyListeners();
    }
    await refreshEpg(sourceId);
  }

  // The M3U header may name its own guide; remembered per refresh so a
  // playlist that ships "url-tvg" gets a guide without extra setup.
  final Map<String, String> _m3uHeaderEpg = {};

  Future<List<IptvItem>> _fetchM3u(IptvSource source) async {
    final response = await _client.get(Uri.parse(source.url.trim()), headers: source.headers).timeout(const Duration(seconds: 60));
    if (response.statusCode != 200) throw HttpException('The playlist returned HTTP ${response.statusCode}.');
    final text = utf8.decode(response.bodyBytes, allowMalformed: true);
    if (!text.trimLeft().startsWith('#EXTM3U') && !text.contains('#EXTINF')) {
      throw const FormatException('That URL didn\'t return an M3U playlist.');
    }
    final result = await compute(parseM3u, (text: text, sourceId: source.id));
    final headerEpg = result.epgUrl;
    if (headerEpg != null && headerEpg.isNotEmpty) _m3uHeaderEpg[source.id] = headerEpg;
    return result.items;
  }

  Uri _xtreamUri(IptvSource source, String action, [Map<String, String> extra = const {}]) =>
      Uri.parse('${source.serverBase}/player_api.php').replace(queryParameters: {
        'username': source.username,
        'password': source.password,
        'action': action,
        ...extra,
      });

  Future<dynamic> _xtreamGet(IptvSource source, String action, [Map<String, String> extra = const {}]) async {
    final response = await _client.get(_xtreamUri(source, action, extra), headers: source.headers).timeout(const Duration(seconds: 60));
    if (response.statusCode != 200) throw HttpException('The server returned HTTP ${response.statusCode}.');
    return jsonDecode(utf8.decode(response.bodyBytes, allowMalformed: true));
  }

  Future<List<IptvItem>> _fetchXtream(IptvSource source) async {
    // Validate the login first so a typo gives a clear message.
    final account = await _client
        .get(Uri.parse('${source.serverBase}/player_api.php').replace(queryParameters: {'username': source.username, 'password': source.password}), headers: source.headers)
        .timeout(const Duration(seconds: 30));
    if (account.statusCode != 200) throw HttpException('The server returned HTTP ${account.statusCode}.');
    final info = jsonDecode(account.body);
    final userInfo = info is Map<String, dynamic> ? info['user_info'] : null;
    if (userInfo is! Map<String, dynamic> || userInfo['auth'].toString() != '1') {
      throw const FormatException('The username or password was rejected.');
    }

    final base = source.serverBase;
    final user = Uri.encodeComponent(source.username);
    final pass = Uri.encodeComponent(source.password);
    final results = await Future.wait([
      _xtreamGet(source, 'get_live_categories'),
      _xtreamGet(source, 'get_live_streams'),
      _xtreamGet(source, 'get_vod_categories').catchError((_) => <dynamic>[]),
      _xtreamGet(source, 'get_vod_streams').catchError((_) => <dynamic>[]),
      _xtreamGet(source, 'get_series_categories').catchError((_) => <dynamic>[]),
      _xtreamGet(source, 'get_series').catchError((_) => <dynamic>[]),
    ]);
    List<dynamic> list(dynamic v) => v is List<dynamic> ? v : const [];
    final live = await compute(parseXtreamLive, (
      sourceId: source.id,
      base: base,
      user: user,
      pass: pass,
      streams: list(results[1]),
      categories: xtreamCategoryNames(list(results[0])),
    ));
    final vod = await compute(parseXtreamVod, (
      sourceId: source.id,
      base: base,
      user: user,
      pass: pass,
      streams: list(results[3]),
      categories: xtreamCategoryNames(list(results[2])),
    ));
    final shows = await compute(parseXtreamSeries, (
      sourceId: source.id,
      series: list(results[5]),
      categories: xtreamCategoryNames(list(results[4])),
    ));
    return [...live, ...vod, ...shows];
  }

  Future<List<IptvEpisode>> xtreamEpisodes(IptvItem show) async {
    final source = sourceFor(show.sourceId);
    final seriesId = show.seriesId;
    if (source == null || seriesId == null) return const [];
    final info = await _xtreamGet(source, 'get_series_info', {'series_id': seriesId});
    if (info is! Map<String, dynamic>) return const [];
    return parseXtreamEpisodes(info, source.serverBase, Uri.encodeComponent(source.username), Uri.encodeComponent(source.password));
  }

  Future<void> refreshEpg(String sourceId) async {
    final source = sourceFor(sourceId);
    if (source == null) return;
    final url = source.effectiveEpgUrl.isNotEmpty ? source.effectiveEpgUrl : (_m3uHeaderEpg[sourceId] ?? '');
    if (url.isEmpty) return;
    _refreshing.add(sourceId);
    notifyListeners();
    try {
      final response = await _client.get(Uri.parse(url), headers: source.headers).timeout(const Duration(minutes: 3));
      if (response.statusCode != 200) throw HttpException('The guide returned HTTP ${response.statusCode}.');
      final epg = await compute(parseXmltv, (bytes: response.bodyBytes, nowMs: DateTime.now().millisecondsSinceEpoch));
      _epgBySource[sourceId] = epg;
      final file = await _epgFile(sourceId);
      await file.writeAsString(await compute(encodeEpg, epg));
    } catch (e) {
      // A missing guide shouldn't hide the channels; surface it softly.
      _errors.putIfAbsent(sourceId, () => 'Guide: ${_friendlyError(e)}');
    } finally {
      _refreshing.remove(sourceId);
      notifyListeners();
    }
  }

  Future<void> refreshAll() async {
    await Future.wait([for (final s in _sources) refresh(s.id)]);
  }

  String _friendlyError(Object e) {
    if (e is SocketException) return 'Couldn\'t reach the server. Check the address and your connection.';
    if (e is HttpException) return e.message;
    if (e is FormatException) return e.message;
    return e.toString();
  }

  // ------------------------------------------------------------------- EPG

  List<EpgProgram> programsFor(IptvItem channel) {
    final epg = _epgBySource[channel.sourceId];
    if (epg == null) return const [];
    final byId = channel.epgId == null ? null : epg.programs[channel.epgId];
    if (byId != null) return byId;
    final mapped = epg.nameToId[channel.name.trim().toLowerCase()];
    return mapped == null ? const [] : (epg.programs[mapped] ?? const []);
  }

  bool get hasGuide => _epgBySource.values.any((e) => e.programs.isNotEmpty);

  EpgProgram? nowPlaying(IptvItem channel, [DateTime? at]) {
    final time = at ?? DateTime.now();
    for (final p in programsFor(channel)) {
      if (p.isAiringAt(time)) return p;
      if (p.start.isAfter(time)) break;
    }
    return null;
  }

  EpgProgram? upNext(IptvItem channel, [DateTime? at]) {
    final time = at ?? DateTime.now();
    for (final p in programsFor(channel)) {
      if (p.start.isAfter(time)) return p;
    }
    return null;
  }

  // ------------------------------------------------------- favorites/recent

  bool isFavorite(IptvItem item) => _favorites.contains(item.id);

  Future<void> toggleFavorite(IptvItem item) async {
    if (!_favorites.remove(item.id)) _favorites.add(item.id);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_favoritesKey, _favorites.toList());
  }

  List<IptvItem> favoritesOf(IptvKind kind) {
    final pool = kind == IptvKind.series ? series : _all(kind);
    return pool.where((i) => _favorites.contains(i.id)).toList();
  }

  List<IptvItem> get recentChannels {
    final byId = {for (final c in liveChannels) c.id: c};
    return [for (final id in _recents) ?byId[id]];
  }

  Future<void> markWatched(IptvItem item) async {
    if (item.kind != IptvKind.live) return;
    _recents = [item.id, ..._recents.where((id) => id != item.id)].take(20).toList();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_recentsKey, _recents);
  }
}
