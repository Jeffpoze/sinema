import 'dart:convert';
import 'dart:ui';

import 'package:better_native_video_player/better_native_video_player.dart' show VideoDownloadStatus;
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'download_manager.dart';
import 'manage_screen.dart';
import 'player_screen.dart';
import 'services/jellyfin_api_service.dart';
import 'settings_controller.dart';
import 'theme_music_player.dart';
import 'trailer_screen.dart';
import 'widgets/sinema_image.dart';

// `dynamic as Type?` throws if the value is non-null but the wrong type —
// it does not return null. These treat an unexpected type as absent instead
// of crashing the whole page over a single malformed/unusual field.
String? _asString(dynamic value) => value is String ? value : null;
int? _asInt(dynamic value) => value is num ? value.toInt() : null;
num? _asNum(dynamic value) => value is num ? value : null;

class DetailScreen extends StatefulWidget {
  const DetailScreen({super.key, required this.serverUrl, required this.userId, required this.token, required this.itemId, required this.settings});
  final String serverUrl;
  final String userId;
  final String token;
  final String itemId;
  final SettingsController settings;

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  final _api = JellyfinApiService();
  Map<String, dynamic>? _item;
  List<dynamic> _seasons = const [];
  Map<String, dynamic>? _nextUp;
  String? _selectedSeasonId;
  List<dynamic> _seasonEpisodes = const [];
  bool _isLoadingEpisodes = false;
  List<dynamic> _tracks = const [];
  List<dynamic> _techStreams = const [];
  bool _isLoading = true;
  String? _error;
  bool _favoriteBusy = false;
  bool _watchedBusy = false;
  bool _isAdmin = false;
  String? _imdbRating;
  String? _rottenTomatoesRating;
  bool _isDownloaded = false;
  // null = not downloading, -1 = downloading with unknown size, 0..1 = progress
  double? _downloadProgress;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    ThemeMusicPlayer.instance.stopFor(widget.itemId);
    super.dispose();
  }

  // Movies, shows and collections get their theme song on the detail page,
  // like Plex. Episodes and music are left alone: an episode page would
  // replay the show's theme every time, and an album already is music.
  void _startThemeMusic() {
    final type = _item?['Type'];
    if (!widget.settings.themeMusic) return;
    if (type != 'Movie' && type != 'Series' && type != 'BoxSet') return;
    ThemeMusicPlayer.instance.playFor(serverUrl: widget.serverUrl, userId: widget.userId, token: widget.token, itemId: widget.itemId);
  }

  Future<void> _load() async {
    try {
      final item = await _api.getItemDetail(widget.serverUrl, widget.userId, widget.token, widget.itemId);
      if (!mounted) return;
      setState(() {
        _item = item;
        _isLoading = false;
      });
      _startThemeMusic();
      if (item['Type'] == 'Series') {
        _loadSeriesExtras();
      } else if (item['IsFolder'] == true) {
        _loadTracks();
      } else {
        _loadTechStreams(widget.itemId);
      }
      _loadExternalRatings(item);
      DownloadManager.instance.isDownloaded(widget.itemId).then((downloaded) {
        if (mounted) setState(() => _isDownloaded = downloaded);
      });
    } catch (error) {
      if (mounted) setState(() { _isLoading = false; _error = 'Unable to load details.\n$error'; });
    }
    try {
      final isAdmin = await _api.checkIsAdministrator(widget.serverUrl, widget.userId, widget.token);
      if (mounted) setState(() => _isAdmin = isAdmin);
    } catch (_) {
      // Admin-only actions just stay hidden if this check fails.
    }
  }

  // Jellyfin's own CommunityRating is just whatever its configured metadata
  // provider set (often TheTVDB for TV libraries, TMDB for movie libraries)
  // — it doesn't expose a separate, named-source rating. A real IMDb rating
  // needs an external lookup: OMDB (omdbapi.com), keyed off the IMDb id
  // Jellyfin already stores, gives back both an IMDb rating and (where OMDB
  // has one) a Rotten Tomatoes critic score in the same call. No-ops if the
  // user hasn't set an OMDB key in Settings.
  Future<void> _loadExternalRatings(Map<String, dynamic> item) async {
    final apiKey = widget.settings.omdbApiKey;
    if (apiKey.isEmpty) return;
    final providerIds = item['ProviderIds'] as Map<String, dynamic>?;
    final imdbId = _asString(providerIds?['Imdb']);
    if (imdbId == null || imdbId.isEmpty) return;
    try {
      final response = await http.get(Uri.parse('https://www.omdbapi.com/?i=$imdbId&apikey=$apiKey'));
      if (response.statusCode != 200) return;
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (data['Response'] == 'False') return;
      final imdbRating = _asString(data['imdbRating']);
      final ratings = (data['Ratings'] as List<dynamic>?)?.whereType<Map<String, dynamic>>();
      final rt = ratings?.firstWhereOrNull((r) => r['Source'] == 'Rotten Tomatoes');
      if (!mounted) return;
      setState(() {
        if (imdbRating != null && imdbRating != 'N/A') _imdbRating = imdbRating;
        final rtValue = _asString(rt?['Value']);
        if (rtValue != null) _rottenTomatoesRating = rtValue;
      });
    } catch (_) {
      // Ratings are a nice-to-have; a network hiccup shouldn't show an error.
    }
  }

  Future<void> _loadSeriesExtras() async {
    try {
      final results = await Future.wait([
        _api.getSeasons(widget.serverUrl, widget.userId, widget.token, widget.itemId),
        _api.getNextUp(widget.serverUrl, widget.userId, widget.token, widget.itemId),
      ]);
      if (!mounted) return;
      final seasons = results[0] as List<dynamic>;
      final nextUp = results[1] as Map<String, dynamic>?;
      setState(() {
        _seasons = seasons;
        _nextUp = nextUp;
      });
      final defaultSeasonId = (nextUp?['SeasonId'] as String?) ?? seasons.whereType<Map<String, dynamic>>().firstOrNull?['Id'] as String?;
      if (defaultSeasonId != null) _selectSeason(defaultSeasonId);
      final techItemId = nextUp?['Id'] as String?;
      if (techItemId != null) _loadTechStreams(techItemId);
    } catch (_) {
      // The item detail remains usable if a series-only endpoint is slow or
      // temporarily unavailable.
    }
  }

  Future<void> _loadTracks() async {
    try {
      final tracks = await _api.getChildItems(widget.serverUrl, widget.userId, widget.token, widget.itemId);
      if (mounted) setState(() => _tracks = tracks);
    } catch (_) {}
  }

  Future<void> _loadTechStreams(String itemId) async {
    try {
      final streams = await _api.getMediaStreams(widget.serverUrl, widget.userId, widget.token, itemId);
      if (mounted) setState(() => _techStreams = streams);
    } catch (_) {}
  }

  Future<void> _selectSeason(String seasonId) async {
    setState(() { _selectedSeasonId = seasonId; _isLoadingEpisodes = true; });
    try {
      final episodes = await _api.getEpisodes(widget.serverUrl, widget.userId, widget.token, widget.itemId, seasonId: seasonId);
      if (!mounted || _selectedSeasonId != seasonId) return;
      setState(() { _seasonEpisodes = episodes; _isLoadingEpisodes = false; });
    } catch (_) {
      if (mounted) setState(() => _isLoadingEpisodes = false);
    }
  }

  bool get _isFavorite => (_item?['UserData'] as Map<String, dynamic>?)?['IsFavorite'] == true;
  bool get _isWatched => (_item?['UserData'] as Map<String, dynamic>?)?['Played'] == true;

  Future<void> _toggleFavorite() async {
    final item = _item;
    if (item == null || _favoriteBusy) return;
    final next = !_isFavorite;
    setState(() => _favoriteBusy = true);
    try {
      await _api.setFavorite(widget.serverUrl, widget.userId, widget.token, widget.itemId, next);
      if (!mounted) return;
      setState(() => (item['UserData'] as Map<String, dynamic>)['IsFavorite'] = next);
    } catch (_) {
    } finally {
      if (mounted) setState(() => _favoriteBusy = false);
    }
  }

  Future<void> _setWatched(bool watched) async {
    final item = _item;
    if (item == null || _watchedBusy) return;
    setState(() => _watchedBusy = true);
    try {
      await _api.setWatched(widget.serverUrl, widget.userId, widget.token, widget.itemId, watched);
      if (!mounted) return;
      setState(() => (item['UserData'] as Map<String, dynamic>)['Played'] = watched);
    } catch (_) {
    } finally {
      if (mounted) setState(() => _watchedBusy = false);
    }
  }

  Future<void> _toggleWatched() => _setWatched(!_isWatched);

  Future<void> _openRateDialog() async {
    if (!_isAdmin) {
      _showUnavailable('Rating');
      return;
    }
    final item = _item;
    if (item == null) return;
    final current = _asNum(item['CommunityRating'])?.toDouble() ?? 5.0;
    final result = await showDialog<double>(
      context: context,
      builder: (context) => _RatingDialog(initialValue: current),
    );
    if (result == null) return;
    try {
      final fullItem = await _api.getItemForEdit(widget.serverUrl, widget.userId, widget.token, widget.itemId);
      fullItem['CommunityRating'] = result;
      await _api.updateItemMetadata(widget.serverUrl, widget.token, widget.itemId, fullItem);
      if (mounted) await _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save rating: $e')));
    }
  }

  Future<void> _toggleDownload() async {
    final item = _item;
    if (item == null) return;
    final isSeries = item['Type'] == 'Series';
    final isContainer = !isSeries && item['IsFolder'] == true;
    if (isSeries || isContainer) {
      _showUnavailable('Downloading from this page');
      return;
    }
    if (_isDownloaded) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Remove Download?'),
          content: const Text('This deletes the downloaded file from your device.'),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Remove')),
          ],
        ),
      );
      if (confirmed == true) {
        await DownloadManager.instance.remove(widget.itemId);
        if (mounted) setState(() => _isDownloaded = false);
      }
      return;
    }
    if (_downloadProgress != null) {
      await DownloadManager.instance.cancel(widget.itemId);
      if (mounted) setState(() => _downloadProgress = null);
      return;
    }
    setState(() => _downloadProgress = -1);
    try {
      Map<String, dynamic>? source;
      try {
        source = await _api.getFileInfo(widget.serverUrl, widget.userId, widget.token, widget.itemId);
      } catch (_) {}
      final container = (_asString(source?['Container']) ?? '').toLowerCase();
      final needsTranscode = !['mp4', 'm4v', 'mov'].contains(container);
      final url = JellyfinApiService.getDownloadUrl(widget.serverUrl, widget.itemId, widget.token, needsTranscode: needsTranscode);
      final stream = await DownloadManager.instance.download(widget.itemId, url, JellyfinApiService.authHeaders(widget.token));
      await for (final progress in stream) {
        if (!mounted) return;
        switch (progress.status) {
          case VideoDownloadStatus.downloading:
            setState(() => _downloadProgress = progress.fraction ?? -1);
          case VideoDownloadStatus.completed:
            setState(() {
              _isDownloaded = true;
              _downloadProgress = null;
            });
          case VideoDownloadStatus.failed:
            setState(() => _downloadProgress = null);
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Download failed: ${progress.error}')));
          case VideoDownloadStatus.canceled:
            setState(() => _downloadProgress = null);
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _downloadProgress = null);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Download failed: $e')));
      }
    }
  }

  // Server logs showed two independent transcode jobs spun up ~15s apart
  // for the same file, each competing for CPU with the other and likely
  // starving both. That's consistent with a double-tap on Watch/an episode
  // firing two overlapping PlayerScreen pushes (Flutter's route-transition
  // animation leaves the old screen hit-testable for a frame or two), each
  // independently negotiating its own Jellyfin session. Guard against it.
  bool _isOpeningPlayer = false;

  Future<void> _play(String itemId, String title, {String? subtitle, Duration startPosition = Duration.zero, VoidCallback? onNext, String? nextTitle, String? nextSubtitle, String? nextImageUrl, bool replace = false, bool isAudioOnly = false}) async {
    // A replace comes from the player itself (Up Next / Next Episode) while
    // the current player is still open, so the double-tap guard must not
    // block it — that guard only protects against opening two players.
    if (_isOpeningPlayer && !replace) return;
    _isOpeningPlayer = true;
    // Fade the theme out before the video's own audio starts.
    await ThemeMusicPlayer.instance.stopFor(widget.itemId);
    String? localFilePath;
    if (itemId == widget.itemId && _isDownloaded) {
      localFilePath = await DownloadManager.instance.localPathFor(itemId);
    }
    if (!mounted) return;
    final route = MaterialPageRoute<void>(
      builder: (_) => PlayerScreen(title: title, subtitle: subtitle, serverUrl: widget.serverUrl, userId: widget.userId, token: widget.token, itemId: itemId, startPosition: startPosition, onNext: onNext, nextTitle: nextTitle, nextSubtitle: nextSubtitle, nextImageUrl: nextImageUrl, isAudioOnly: isAudioOnly, settings: widget.settings, localFilePath: localFilePath),
    );
    final future = replace ? Navigator.of(context).pushReplacement(route) : Navigator.of(context).push(route);
    future.then((_) {
      if (!mounted) return;
      _isOpeningPlayer = false;
      // A replaced player (auto-advancing to the next episode) completes
      // this future too, while the next episode is still on screen — only
      // bring the theme back once this page is actually visible again.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && (ModalRoute.of(context)?.isCurrent ?? false)) _startThemeMusic();
      });
    });
  }

  void _playEpisode(Map<String, dynamic> episode, {bool replace = false, bool fromBeginning = false}) {
    final itemId = episode['Id'] as String?;
    if (itemId == null) return;
    final seriesName = _item?['Name'] as String? ?? '';
    final season = episode['ParentIndexNumber'];
    final epNum = episode['IndexNumber'];
    final epName = (episode['Name'] as String?) ?? 'Episode';
    final subtitle = season != null && epNum != null ? 'S$season:E$epNum - $epName' : epName;
    final ticks = (episode['UserData'] as Map<String, dynamic>?)?['PlaybackPositionTicks'];
    final episodes = _seasonEpisodes.whereType<Map<String, dynamic>>().toList();
    final index = episodes.indexWhere((e) => e['Id'] == itemId);
    final next = index >= 0 && index + 1 < episodes.length ? episodes[index + 1] : null;
    final nextId = _asString(next?['Id']);
    final nextTag = _asString((next?['ImageTags'] as Map<String, dynamic>?)?['Primary']);
    final nextSeason = next?['ParentIndexNumber'];
    final nextNumber = next?['IndexNumber'];
    _play(
      itemId,
      seriesName,
      subtitle: subtitle,
      startPosition: fromBeginning ? Duration.zero : ticksToDuration(ticks),
      replace: replace,
      onNext: next == null ? null : () => _playEpisode(next, replace: true),
      nextTitle: _asString(next?['Name']),
      nextSubtitle: nextSeason != null && nextNumber != null ? 'Season $nextSeason, Episode $nextNumber' : null,
      // Episodes without their own still (common for anime) fall back to the
      // show's backdrop rather than an empty box.
      nextImageUrl: nextId == null
          ? null
          : (nextTag != null
              ? JellyfinApiService.getImageUrl(widget.serverUrl, nextId, imageTag: nextTag, maxWidth: 480)
              : JellyfinApiService.getBackdropUrl(widget.serverUrl, widget.itemId, maxWidth: 480)),
    );
  }

  void _playTrack(Map<String, dynamic> track, {bool fromBeginning = false}) {
    final itemId = track['Id'] as String?;
    if (itemId == null) return;
    final title = (track['Name'] as String?) ?? 'Track';
    final ticks = (track['UserData'] as Map<String, dynamic>?)?['PlaybackPositionTicks'];
    final isAudioOnly = track['Type'] == 'Audio' || track['Type'] == 'AudioBook';
    _play(itemId, title, startPosition: fromBeginning ? Duration.zero : ticksToDuration(ticks), isAudioOnly: isAudioOnly);
  }

  Map<String, dynamic>? get _firstPlayableTrack {
    final tracks = _tracks.whereType<Map<String, dynamic>>().toList();
    return tracks.firstWhereOrNull((t) => (t['UserData'] as Map<String, dynamic>?)?['Played'] != true) ?? tracks.firstOrNull;
  }

  void _playMain({bool fromBeginning = false}) {
    final item = _item;
    if (item == null) return;
    final name = item['Name'] as String? ?? 'Untitled';
    if (item['Type'] == 'Series') {
      final nextUp = _nextUp;
      if (nextUp != null) {
        _playEpisode(nextUp, fromBeginning: fromBeginning);
        return;
      }
      final firstEpisode = _seasonEpisodes.whereType<Map<String, dynamic>>().firstOrNull;
      if (firstEpisode != null) _playEpisode(firstEpisode, fromBeginning: fromBeginning);
      return;
    }
    if (item['IsFolder'] == true) {
      final track = _firstPlayableTrack;
      if (track != null) _playTrack(track, fromBeginning: fromBeginning);
      return;
    }
    final ticks = (item['UserData'] as Map<String, dynamic>?)?['PlaybackPositionTicks'];
    final isAudioOnly = item['Type'] == 'Audio' || item['Type'] == 'AudioBook';
    _play(widget.itemId, name, startPosition: fromBeginning ? Duration.zero : ticksToDuration(ticks), isAudioOnly: isAudioOnly);
  }

  bool get _hasResumablePlay {
    final item = _item;
    if (item == null) return false;
    if (item['Type'] == 'Series') return _nextUp != null && ((_nextUp!['UserData'] as Map<String, dynamic>?)?['PlaybackPositionTicks'] ?? 0) > 0;
    if (item['IsFolder'] == true) return ((_firstPlayableTrack?['UserData'] as Map<String, dynamic>?)?['PlaybackPositionTicks'] ?? 0) > 0;
    return ((item['UserData'] as Map<String, dynamic>?)?['PlaybackPositionTicks'] ?? 0) > 0;
  }

  Map<String, dynamic>? get _resumeItem => _item?['Type'] == 'Series' ? _nextUp : (_item?['IsFolder'] == true ? _firstPlayableTrack : _item);

  String? get _remainingTimeLabel {
    final resumeItem = _resumeItem;
    if (resumeItem == null) return null;
    final total = ticksToDuration(resumeItem['RunTimeTicks']);
    final position = ticksToDuration((resumeItem['UserData'] as Map<String, dynamic>?)?['PlaybackPositionTicks']);
    final remaining = total > position ? total - position : Duration.zero;
    if (remaining <= Duration.zero) return null;
    final minutes = remaining.inMinutes;
    return minutes >= 60 ? '${minutes ~/ 60}h ${minutes.remainder(60)}m left' : '${minutes}m left';
  }

  Future<void> _openSeasonPicker() async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF141518),
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(padding: EdgeInsets.fromLTRB(20, 16, 20, 8), child: Text('Seasons', style: TextStyle(fontWeight: FontWeight.w700))),
            for (final season in _seasons.whereType<Map<String, dynamic>>())
              ListTile(
                title: Text((season['Name'] as String?) ?? 'Season'),
                trailing: season['Id'] == _selectedSeasonId ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary) : null,
                onTap: () => Navigator.of(context).pop(season['Id'] as String?),
              ),
          ],
        ),
      ),
    );
    if (selected != null && selected != _selectedSeasonId) _selectSeason(selected);
  }

  Future<void> _openEpisodeListSheet() async {
    final seriesName = _asString(_item?['Name']) ?? '';
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0A0B0D),
      builder: (context) => _EpisodeListSheet(
        serverUrl: widget.serverUrl,
        userId: widget.userId,
        token: widget.token,
        seriesId: widget.itemId,
        seriesName: seriesName,
        seasons: _seasons,
        initialSeasonId: _selectedSeasonId,
        initialEpisodes: _seasonEpisodes,
        onSelectEpisode: (episode) {
          Navigator.of(context).pop();
          _playEpisode(episode);
        },
      ),
    );
  }

  List<String> get _remoteTrailerUrls => ((_item?['RemoteTrailers'] as List<dynamic>?) ?? const [])
      .whereType<Map<String, dynamic>>()
      .map((t) => _asString(t['Url']))
      .whereType<String>()
      .where((url) => url.startsWith('http'))
      .toList();

  bool get _hasTrailer => (_asInt(_item?['LocalTrailerCount']) ?? 0) > 0 || _remoteTrailerUrls.isNotEmpty;

  // Prefers a trailer file sitting next to the movie on the server (plays in
  // Sinema's own player); otherwise hands the metadata's YouTube trailer to
  // the YouTube app or browser.
  Future<void> _playTrailer() async {
    final name = _asString(_item?['Name']) ?? 'Trailer';
    if ((_asInt(_item?['LocalTrailerCount']) ?? 0) > 0) {
      final trailers = await _api.getLocalTrailers(widget.serverUrl, widget.userId, widget.token, widget.itemId);
      final trailerId = _asString(trailers.whereType<Map<String, dynamic>>().firstOrNull?['Id']);
      if (trailerId != null) {
        await _play(trailerId, name, subtitle: 'Trailer');
        return;
      }
    }
    final urls = _remoteTrailerUrls;
    if (urls.isEmpty) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No trailer found for this title.')));
      return;
    }
    await ThemeMusicPlayer.instance.stopFor(widget.itemId);
    if (!mounted) return;
    final videoId = urls.map(TrailerScreen.videoIdFrom).whereType<String>().firstOrNull;
    if (videoId == null) {
      // Not a YouTube link (rare) — let the system handle it.
      await launchUrl(Uri.parse(urls.first), mode: LaunchMode.externalApplication);
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => TrailerScreen(videoId: videoId, title: name)));
    if (mounted) _startThemeMusic();
  }

  void _showUnavailable(String feature) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$feature is coming soon.')),
    );
  }

  Future<void> _openManage() async {
    final item = _item;
    final name = _asString(item?['Name']) ?? 'Item';
    final deleted = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => ManageScreen(serverUrl: widget.serverUrl, userId: widget.userId, token: widget.token, itemId: widget.itemId, itemName: name),
    ));
    if (!mounted) return;
    if (deleted == true) {
      Navigator.of(context).pop();
    } else {
      _load();
    }
  }

  Future<void> _showFileInfo() async {
    Map<String, dynamic>? source;
    try {
      source = await _api.getFileInfo(widget.serverUrl, widget.userId, widget.token, widget.itemId);
    } catch (_) {}
    if (!mounted) return;
    final path = _asString(source?['Path']);
    final container = _asString(source?['Container'])?.toUpperCase();
    final sizeBytes = _asNum(source?['Size']);
    final bitrate = _asNum(source?['Bitrate']);
    final sizeLabel = sizeBytes == null ? null : '${(sizeBytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    final bitrateLabel = bitrate == null ? null : '${(bitrate / 1000000).toStringAsFixed(1)} Mbps';
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('File Info'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (container != null) _InfoLine('Container', container),
            if (sizeLabel != null) _InfoLine('Size', sizeLabel),
            if (bitrateLabel != null) _InfoLine('Bitrate', bitrateLabel),
            if (path != null) _InfoLine('Path', path),
            if (container == null && sizeLabel == null && path == null) const Text('File info is unavailable for this item.'),
          ],
        ),
        actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close'))],
      ),
    );
  }

  Future<void> _showHistory() async {
    final item = _item;
    final userData = item?['UserData'] as Map<String, dynamic>?;
    final dateCreated = _asString(item?['DateCreated']);
    final lastPlayed = _asString(userData?['LastPlayedDate']);
    final playCount = _asInt(userData?['PlayCount']);
    String formatDate(String? iso) {
      if (iso == null) return 'Unknown';
      final parsed = DateTime.tryParse(iso);
      if (parsed == null) return iso;
      final local = parsed.toLocal();
      return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('History'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _InfoLine('Added to library', formatDate(dateCreated)),
            if (lastPlayed == null && (playCount ?? 0) == 0)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('You haven\'t watched this yet. Once you do, when and how often will show up here.', style: TextStyle(color: Color(0xFFA5A7AC))),
              )
            else ...[
              _InfoLine('Last played', lastPlayed == null ? 'Never' : formatDate(lastPlayed)),
              _InfoLine('Play count', '${playCount ?? 0}'),
            ],
          ],
        ),
        actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close'))],
      ),
    );
  }

  Future<void> _openMoreActions() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.black,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 38, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(4))),
              const SizedBox(height: 16),
              const Text('More Actions', style: TextStyle(fontSize: 25, fontWeight: FontWeight.w700)),
              const Divider(height: 30, color: Color(0xFF252525)),
              _MoreAction(icon: _isFavorite ? Icons.bookmark_remove_outlined : Icons.bookmark_add_outlined, label: _isFavorite ? 'Remove from List' : 'Add to List', onTap: () { Navigator.pop(context); _toggleFavorite(); }),
              _MoreAction(icon: Icons.playlist_add, label: 'Add To Playlist / Collection', onTap: () { Navigator.pop(context); _showUnavailable('Playlists'); }),
              if (_item?['Type'] == 'Episode') _MoreAction(icon: Icons.tv_outlined, label: 'Go to Show', onTap: () => Navigator.pop(context)),
              _MoreAction(icon: _isWatched ? Icons.remove_done_outlined : Icons.done_all, label: _isWatched ? 'Mark as Unwatched' : 'Mark as Watched', onTap: () { Navigator.pop(context); _setWatched(!_isWatched); }),
              _MoreAction(icon: Icons.history, label: 'History', onTap: () { Navigator.pop(context); _showHistory(); }),
              _MoreAction(icon: Icons.info_outline, label: 'File Info', onTap: () { Navigator.pop(context); _showFileInfo(); }),
              _MoreAction(icon: Icons.format_list_bulleted, label: 'More Ways to Watch', onTap: () { Navigator.pop(context); _showUnavailable('More ways to watch'); }),
              _MoreAction(icon: Icons.share_outlined, label: 'Share', onTap: () { Navigator.pop(context); _showUnavailable('Sharing'); }),
              if (_isAdmin) ...[
                const Divider(height: 30, color: Color(0xFF252525)),
                _MoreAction(icon: Icons.build_outlined, label: 'Manage', onTap: () { Navigator.pop(context); _openManage(); }),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final item = _item;
    if (item == null) return Scaffold(body: Center(child: Text(_error ?? 'Not found', style: const TextStyle(color: Color(0xFFA5A7AC)))));

    final name = _asString(item['Name']) ?? 'Untitled';
    final year = item['ProductionYear']?.toString();
    final officialRating = _asString(item['OfficialRating']);
    final communityRating = _asNum(item['CommunityRating']);
    final criticRating = _asNum(item['CriticRating']);
    final overview = _asString(item['Overview']);
    final genres = (item['Genres'] as List<dynamic>?)?.whereType<String>().join(', ');
    final studios = (item['Studios'] as List<dynamic>?)?.whereType<Map<String, dynamic>>().map((s) => _asString(s['Name'])).whereType<String>().join(', ');
    final people = (item['People'] as List<dynamic>?)?.whereType<Map<String, dynamic>>() ?? const [];
    final cast = people.where((p) => p['Type'] == 'Actor').toList();
    final directors = people.where((p) => p['Type'] == 'Director').map((p) => _asString(p['Name'])).whereType<String>().join(', ');
    final backdropTag = (item['BackdropImageTags'] as List<dynamic>?)?.whereType<String>().firstOrNull;
    final backdropUrl = backdropTag != null ? JellyfinApiService.getBackdropUrl(widget.serverUrl, widget.itemId, imageTag: backdropTag, maxWidth: 1200) : null;
    final imageTags = item['ImageTags'];
    final logoTag = imageTags is Map ? _asString(imageTags['Logo']) : null;
    final logoUrl = logoTag != null ? JellyfinApiService.getLogoUrl(widget.serverUrl, widget.itemId, imageTag: logoTag, maxWidth: 800) : null;
    final isSeries = item['Type'] == 'Series';
    final isContainer = !isSeries && item['IsFolder'] == true;
    final canPlay = isSeries ? (_nextUp != null || _seasonEpisodes.isNotEmpty) : (isContainer ? _tracks.isNotEmpty : true);
    final selectedSeasonName = _asString(_seasons.whereType<Map<String, dynamic>>().firstWhere((s) => s['Id'] == _selectedSeasonId, orElse: () => const {})['Name']);

    return Scaffold(
      backgroundColor: const Color(0xFF090A0C),
      body: Stack(
        children: [
          // A softly blurred, dimmed backdrop behind the whole page so the
          // content feels like an extension of the artwork rather than
          // ending abruptly at the hero image, Apple TV-style. Blurred pixels
          // hide detail anyway, so this can stay at a much lower resolution
          // than the sharp hero image above it.
          if (backdropUrl != null)
            Positioned.fill(
              child: ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 40, sigmaY: 40, tileMode: TileMode.decal),
                child: SinemaImage(
                  imageUrl: backdropUrl,
                  httpHeaders: JellyfinApiService.authHeaders(widget.token),
                  fit: BoxFit.cover,
                  memCacheWidth: 240,
                ),
              ),
            ),
          if (backdropUrl != null) const Positioned.fill(child: ColoredBox(color: Color(0xCC090A0C))),
          CustomScrollView(
            slivers: [
              SliverAppBar(
                expandedHeight: 460,
                pinned: true,
                automaticallyImplyLeading: false,
                backgroundColor: const Color(0xFF090A0C).withValues(alpha: .85),
                leading: Padding(
                  padding: const EdgeInsets.all(8),
                  child: IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.black54,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
                actions: [
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: IconButton(
                      onPressed: () => _showUnavailable('Cast'),
                      icon: const Icon(Icons.cast_outlined),
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.black54,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ),
                ],
                flexibleSpace: FlexibleSpaceBar(
                  background: backdropUrl == null
                      ? const ColoredBox(color: Color(0xFF181A1E))
                      : Stack(
                          fit: StackFit.expand,
                          children: [
                            SinemaImage(imageUrl: backdropUrl, httpHeaders: JellyfinApiService.authHeaders(widget.token), fit: BoxFit.cover, memCacheWidth: 1200),
                            const DecoratedBox(
                              decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Color(0xFF090A0C)])),
                            ),
                            Positioned(
                              left: 24,
                              right: 24,
                              bottom: 26,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (logoUrl != null)
                                    SinemaImage(
                                      imageUrl: logoUrl,
                                      httpHeaders: JellyfinApiService.authHeaders(widget.token),
                                      memCacheWidth: 800,
                                      fit: BoxFit.contain,
                                      height: 94,
                                      errorWidget: (_, _, _) => const SizedBox.shrink(),
                                    )
                                  else
                                    Text(
                                      name,
                                      maxLines: 2,
                                      textAlign: TextAlign.center,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 30,
                                        fontWeight: FontWeight.w800,
                                        shadows: [Shadow(blurRadius: 12)],
                                      ),
                                    ),
                                  if (isSeries && _nextUp != null) ...[
                                    const SizedBox(height: 10),
                                    GestureDetector(
                                      onTap: _seasons.isNotEmpty ? _openEpisodeListSheet : null,
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Flexible(
                                            child: Text(
                                              _asString(_nextUp!['Name']) ?? 'Next episode',
                                              textAlign: TextAlign.center,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontSize: 18,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                          ),
                                          if (_seasons.isNotEmpty) const Icon(Icons.expand_more, size: 20),
                                        ],
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),
                ),
              ),
              SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (backdropUrl == null && logoUrl == null) ...[
                    Text(name, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                  ],
                  if (isSeries && _nextUp != null)
                    _EpisodeMetaRow(episode: _nextUp!, fallbackRating: officialRating, communityRating: communityRating, imdbRating: _imdbRating, rottenTomatoesRating: _rottenTomatoesRating)
                  else
                    Wrap(spacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
                      if (year != null) Text(year, style: const TextStyle(color: Color(0xFFA5A7AC))),
                      if (officialRating != null) _RatingPill(text: officialRating),
                      if (_imdbRating != null) _SourceBadge(label: 'IMDb', value: _imdbRating!, labelColor: const Color(0xFFF5C518), labelTextColor: Colors.black),
                      if (_rottenTomatoesRating != null) _SourceBadge(label: 'RT', value: _rottenTomatoesRating!, labelColor: const Color(0xFFFA320A), labelTextColor: Colors.white),
                      if (communityRating != null) _SourceBadge(label: 'TVDB', value: communityRating.toStringAsFixed(1), labelColor: const Color(0xFF6CD591), labelTextColor: Colors.black),
                      if (criticRating != null) _RatingBadge(icon: Icons.local_movies, color: const Color(0xFFFF5252), value: '${criticRating.round()}%'),
                    ]),
                  const SizedBox(height: 20),
                  if (canPlay) ...[
                    Row(children: [
                      Expanded(child: SizedBox(height: 52, child: FilledButton.icon(style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black), onPressed: _playMain, icon: const Icon(Icons.play_arrow), label: Text(_hasResumablePlay && _remainingTimeLabel != null ? 'Resume • $_remainingTimeLabel' : (_hasResumablePlay ? 'Resume' : 'Watch'))))),
                      if (_hasResumablePlay) ...[
                        const SizedBox(width: 12),
                        IconButton.filled(onPressed: () => _playMain(fromBeginning: true), icon: const Icon(Icons.replay), style: IconButton.styleFrom(backgroundColor: Colors.white24, foregroundColor: Colors.white, fixedSize: const Size(52, 52)), tooltip: 'Play from beginning'),
                      ],
                      if (_hasTrailer) ...[
                        const SizedBox(width: 12),
                        IconButton.filled(onPressed: _playTrailer, icon: const Icon(Icons.theaters_outlined), style: IconButton.styleFrom(backgroundColor: Colors.white24, foregroundColor: Colors.white, fixedSize: const Size(52, 52)), tooltip: 'Play trailer'),
                      ],
                    ]),
                    const SizedBox(height: 16),
                  ],
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _ActionButton(icon: _isFavorite ? Icons.bookmark : Icons.bookmark_border, label: 'Watchlist', active: _isFavorite, onTap: _toggleFavorite),
                      _ActionButton(icon: Icons.star_border_rounded, label: 'Rate', active: false, onTap: _openRateDialog),
                      _ActionButton(icon: _isWatched ? Icons.check_circle : Icons.check_circle_outline, label: 'Watched', active: _isWatched, onTap: _toggleWatched),
                      _downloadProgress != null
                          ? _ActionButtonProgress(progress: _downloadProgress == -1 ? null : _downloadProgress, onTap: _toggleDownload)
                          : _ActionButton(icon: _isDownloaded ? Icons.download_done : Icons.download_outlined, label: _isDownloaded ? 'Downloaded' : 'Download', active: _isDownloaded, onTap: _toggleDownload),
                      _ActionButton(icon: Icons.more_vert, label: 'More', active: false, onTap: _openMoreActions),
                    ],
                  ),
                  if (overview != null) ...[const SizedBox(height: 20), Text(overview, style: const TextStyle(height: 1.4))],
                  if (directors.isNotEmpty) ...[const SizedBox(height: 12), Text('Directed by $directors', style: const TextStyle(color: Color(0xFFA5A7AC)))],
                  if (genres != null && genres.isNotEmpty) ...[const SizedBox(height: 16), _LabelValue(label: 'Genres', value: genres)],
                  if (studios != null && studios.isNotEmpty) ...[const SizedBox(height: 8), _LabelValue(label: 'Studios', value: studios)],
                  if (_techStreams.isNotEmpty) ...[const SizedBox(height: 20), _TechInfo(streams: _techStreams)],
                ],
              ),
            ),
          ),
          if (_seasons.isNotEmpty) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                child: GestureDetector(
                  onTap: _openSeasonPicker,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(14, 6, 8, 6),
                    decoration: BoxDecoration(color: const Color(0xFF1B1D22), borderRadius: BorderRadius.circular(20)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(selectedSeasonName ?? 'Season', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                      const Icon(Icons.expand_more, size: 20),
                    ]),
                  ),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: SizedBox(
                height: 190,
                child: _isLoadingEpisodes
                    ? const Center(child: CircularProgressIndicator())
                    : ListView.builder(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemCount: _seasonEpisodes.length,
                        itemBuilder: (context, index) => _EpisodeCard(episode: _seasonEpisodes[index], serverUrl: widget.serverUrl, token: widget.token, onPlay: _playEpisode),
                      ),
              ),
            ),
          ],
          if (isContainer && _tracks.isNotEmpty) ...[
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(20, 8, 20, 8),
                child: Text('Tracks', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              ),
            ),
            SliverList.builder(
              itemCount: _tracks.length,
              itemBuilder: (context, index) => _TrackRow(track: _tracks[index], onPlay: _playTrack),
            ),
          ],
          if (cast.isNotEmpty) ...[
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(20, 24, 20, 12),
                child: Text('Cast & Crew', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              ),
            ),
            SliverToBoxAdapter(
              child: SizedBox(
                height: 128,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: cast.length,
                  itemBuilder: (context, index) => _CastMember(person: cast[index], serverUrl: widget.serverUrl, token: widget.token),
                ),
              ),
            ),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 32)),
            ],
          ),
        ],
      ),
    );
  }
}

class _EpisodeMetaRow extends StatelessWidget {
  const _EpisodeMetaRow({required this.episode, this.fallbackRating, this.communityRating, this.imdbRating, this.rottenTomatoesRating});
  final Map<String, dynamic> episode;
  final String? fallbackRating;
  final num? communityRating;
  final String? imdbRating;
  final String? rottenTomatoesRating;

  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  String? _formatDate(String? iso) {
    final date = iso == null ? null : DateTime.tryParse(iso);
    if (date == null) return null;
    return '${_months[date.month - 1]} ${date.day}, ${date.year}';
  }

  @override
  Widget build(BuildContext context) {
    final season = episode['ParentIndexNumber'];
    final indexNumber = episode['IndexNumber'];
    final date = _formatDate(_asString(episode['PremiereDate']));
    final runtimeTicks = episode['RunTimeTicks'];
    final runtimeMinutes = runtimeTicks != null ? ticksToDuration(runtimeTicks).inMinutes : null;
    final rating = _asString(episode['OfficialRating']) ?? fallbackRating;

    return Wrap(spacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
      if (season != null && indexNumber != null) Text('S$season • E$indexNumber', style: const TextStyle(color: Color(0xFFA5A7AC), fontWeight: FontWeight.w600)),
      if (date != null) Text(date, style: const TextStyle(color: Color(0xFFA5A7AC))),
      if (runtimeMinutes != null && runtimeMinutes > 0) Text('${runtimeMinutes}m', style: const TextStyle(color: Color(0xFFA5A7AC))),
      if (rating != null) _RatingPill(text: rating),
      if (imdbRating != null) _SourceBadge(label: 'IMDb', value: imdbRating!, labelColor: const Color(0xFFF5C518), labelTextColor: Colors.black),
      if (rottenTomatoesRating != null) _SourceBadge(label: 'RT', value: rottenTomatoesRating!, labelColor: const Color(0xFFFA320A), labelTextColor: Colors.white),
      if (communityRating != null) _SourceBadge(label: 'TVDB', value: communityRating!.toStringAsFixed(1), labelColor: const Color(0xFF6CD591), labelTextColor: Colors.black),
    ]);
  }
}

class _RatingPill extends StatelessWidget {
  const _RatingPill({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(4)),
        child: Text(text, style: const TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.w600)),
      );
}

class _SourceBadge extends StatelessWidget {
  const _SourceBadge({required this.label, required this.value, required this.labelColor, required this.labelTextColor});
  final String label;
  final String value;
  final Color labelColor;
  final Color labelTextColor;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(color: Colors.black.withValues(alpha: .6), borderRadius: BorderRadius.circular(4)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(color: labelColor, borderRadius: BorderRadius.circular(3)),
            child: Text(label, style: TextStyle(color: labelTextColor, fontSize: 10, fontWeight: FontWeight.w800)),
          ),
          const SizedBox(width: 5),
          Text(value, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700)),
        ]),
      );
}

class _RatingBadge extends StatelessWidget {
  const _RatingBadge({required this.icon, required this.color, required this.value});
  final IconData icon;
  final Color color;
  final String value;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 4),
        Text(value, style: const TextStyle(color: Color(0xFFA5A7AC))),
      ]);
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({required this.icon, required this.label, required this.active, required this.onTap});
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 44,
            height: 44,
            decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFF1B1D22)),
            child: Icon(icon, color: active ? Theme.of(context).colorScheme.primary : Colors.white70),
          ),
          const SizedBox(height: 6),
          Text(label, style: const TextStyle(fontSize: 12, color: Color(0xFFA5A7AC))),
        ]),
      );
}

class _ActionButtonProgress extends StatelessWidget {
  const _ActionButtonProgress({required this.progress, required this.onTap});
  final double? progress;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(
            width: 44,
            height: 44,
            child: Stack(alignment: Alignment.center, children: [
              CircularProgressIndicator(value: progress, strokeWidth: 2.5, color: Colors.white70),
              const Icon(Icons.close, size: 16, color: Colors.white70),
            ]),
          ),
          const SizedBox(height: 6),
          Text(progress == null ? 'Downloading' : '${(progress! * 100).round()}%', style: const TextStyle(fontSize: 12, color: Color(0xFFA5A7AC))),
        ]),
      );
}

class _RatingDialog extends StatefulWidget {
  const _RatingDialog({required this.initialValue});
  final double initialValue;

  @override
  State<_RatingDialog> createState() => _RatingDialogState();
}

class _RatingDialogState extends State<_RatingDialog> {
  late double _value = widget.initialValue;

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Rate'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_value.toStringAsFixed(1), style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w700)),
            Slider(value: _value, min: 0, max: 10, divisions: 20, onChanged: (v) => setState(() => _value = v)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(context).pop(_value), child: const Text('Save')),
        ],
      );
}

class _InfoLine extends StatelessWidget {
  const _InfoLine(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(fontSize: 12, color: Color(0xFFA5A7AC))),
            Text(value, style: const TextStyle(fontSize: 14)),
          ],
        ),
      );
}

class _MoreAction extends StatelessWidget {
  const _MoreAction({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon, color: Colors.white),
        title: Text(label, style: const TextStyle(fontSize: 16)),
        onTap: onTap,
      );
}

class _TechInfo extends StatelessWidget {
  const _TechInfo({required this.streams});
  final List<dynamic> streams;

  static const _codecLabels = {
    'h264': 'H.264', 'hevc': 'HEVC', 'av1': 'AV1', 'vp9': 'VP9', 'vp8': 'VP8',
    'mpeg2video': 'MPEG-2', 'mpeg4': 'MPEG-4', 'vc1': 'VC-1',
    'aac': 'AAC', 'ac3': 'AC3', 'eac3': 'E-AC3', 'dts': 'DTS', 'truehd': 'TrueHD',
    'flac': 'FLAC', 'mp3': 'MP3', 'opus': 'Opus', 'pcm_s16le': 'PCM',
    'subrip': 'SRT', 'srt': 'SRT', 'ass': 'ASS', 'ssa': 'SSA', 'pgssub': 'PGS',
    'dvdsub': 'VOBSUB', 'dvbsub': 'DVBSUB', 'mov_text': 'MOV Text', 'vtt': 'VTT', 'webvtt': 'VTT',
  };

  String _codecLabel(String? codec) {
    if (codec == null) return '';
    return _codecLabels[codec.toLowerCase()] ?? codec.toUpperCase();
  }

  String _resolutionLabel(int? height) {
    if (height == null) return '';
    if (height >= 2000) return '4K';
    if (height >= 1300) return '1440p';
    if (height >= 900) return '1080p';
    if (height >= 600) return '720p';
    return '${height}p';
  }

  @override
  Widget build(BuildContext context) {
    final all = streams.whereType<Map<String, dynamic>>().toList();
    final video = all.firstWhereOrNull((s) => s['Type'] == 'Video');
    final audio = all.firstWhereOrNull((s) => s['Type'] == 'Audio' && s['IsDefault'] == true) ?? all.firstWhereOrNull((s) => s['Type'] == 'Audio');
    final subtitle = all.firstWhereOrNull((s) => s['Type'] == 'Subtitle' && s['IsDefault'] == true) ?? all.firstWhereOrNull((s) => s['Type'] == 'Subtitle');

    String? videoLine;
    if (video != null) {
      final res = _resolutionLabel(_asInt(video['Height']));
      final isDovi = _asString(video['VideoRangeType'])?.toUpperCase().contains('DOVI') == true;
      final profile = _asString(video['Profile']);
      final codec = _codecLabel(_asString(video['Codec']));
      videoLine = '$res${isDovi ? ' DoVi' : ''} ($codec${profile != null ? ' $profile' : ''})';
    }

    final audioLine = audio == null ? null : (_asString(audio['DisplayTitle']) ?? '${_asString(audio['Language'])?.toUpperCase() ?? 'Unknown'} (${_codecLabel(_asString(audio['Codec']))})');
    final subtitleLine = subtitle == null ? null : (_asString(subtitle['DisplayTitle']) ?? '${_asString(subtitle['Language'])?.toUpperCase() ?? 'Unknown'} (${_codecLabel(_asString(subtitle['Codec']))})');

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (videoLine != null) _InfoRow(label: 'Video', value: videoLine),
      if (audioLine != null) _InfoRow(label: 'Audio', value: audioLine),
      if (subtitleLine != null) _InfoRow(label: 'Subtitles', value: subtitleLine),
    ]);
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 90, child: Text(label, style: const TextStyle(color: Color(0xFFA5A7AC)))),
          Expanded(child: Text(value)),
        ]),
      );
}

class _LabelValue extends StatelessWidget {
  const _LabelValue({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
          const SizedBox(height: 2),
          Text(value, style: const TextStyle(color: Color(0xFFA5A7AC))),
        ],
      );
}

class _CastMember extends StatelessWidget {
  const _CastMember({required this.person, required this.serverUrl, required this.token});
  final dynamic person;
  final String serverUrl;
  final String token;

  @override
  Widget build(BuildContext context) {
    if (person is! Map<String, dynamic>) return const SizedBox.shrink();
    final item = person as Map<String, dynamic>;
    final personId = item['Id'] as String?;
    final tag = item['PrimaryImageTag'] as String?;
    final imageUrl = personId != null && tag != null ? JellyfinApiService.getImageUrl(serverUrl, personId, imageTag: tag, maxWidth: 220) : null;
    final name = item['Name'] as String? ?? '';
    final role = item['Role'] as String?;

    return Padding(
      padding: const EdgeInsets.only(right: 16),
      child: SizedBox(
        width: 84,
        child: Column(
          children: [
            ClipOval(
              child: SizedBox(
                width: 72,
                height: 72,
                child: imageUrl == null
                    ? const ColoredBox(color: Color(0xFF17191D), child: Icon(Icons.person_outline, color: Colors.white24))
                    : SinemaImage(imageUrl: imageUrl, httpHeaders: JellyfinApiService.authHeaders(token), fit: BoxFit.cover, memCacheWidth: 220, errorWidget: (_, _, _) => const ColoredBox(color: Color(0xFF17191D), child: Icon(Icons.person_outline, color: Colors.white24))),
              ),
            ),
            const SizedBox(height: 6),
            Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            if (role != null && role.isNotEmpty) Text(role, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: const TextStyle(fontSize: 11, color: Color(0xFFA5A7AC))),
          ],
        ),
      ),
    );
  }
}

class _TrackRow extends StatelessWidget {
  const _TrackRow({required this.track, required this.onPlay});
  final dynamic track;
  final void Function(Map<String, dynamic> track) onPlay;

  String _formatDuration(dynamic ticks) {
    final duration = ticksToDuration(ticks);
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final hours = duration.inHours;
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '${duration.inMinutes}:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    if (track is! Map<String, dynamic>) return const SizedBox.shrink();
    final item = track as Map<String, dynamic>;
    final name = item['Name'] as String? ?? 'Track';
    final index = item['IndexNumber'];
    final runTimeTicks = item['RunTimeTicks'];
    final isPlayed = (item['UserData'] as Map<String, dynamic>?)?['Played'] == true;

    return ListTile(
      onTap: () => onPlay(item),
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
      leading: SizedBox(
        width: 28,
        child: Text(index != null ? '$index' : '', textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFFA5A7AC))),
      ),
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15)),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (isPlayed) Padding(padding: const EdgeInsets.only(right: 8), child: Icon(Icons.check, size: 16, color: Theme.of(context).colorScheme.primary)),
        if (runTimeTicks != null) Text(_formatDuration(runTimeTicks), style: const TextStyle(color: Color(0xFFA5A7AC), fontSize: 13)),
      ]),
    );
  }
}

class _EpisodeCard extends StatelessWidget {
  const _EpisodeCard({required this.episode, required this.serverUrl, required this.token, required this.onPlay});
  final dynamic episode;
  final String serverUrl;
  final String token;
  final void Function(Map<String, dynamic> episode) onPlay;

  @override
  Widget build(BuildContext context) {
    if (episode is! Map<String, dynamic>) return const SizedBox.shrink();
    final item = episode as Map<String, dynamic>;
    final itemId = item['Id'] as String?;
    final name = item['Name'] as String? ?? 'Episode';
    final indexNumber = item['IndexNumber'];
    final isWatched = (item['UserData'] as Map<String, dynamic>?)?['Played'] == true;
    final tag = item['PrimaryImageTag'] as String? ?? (item['ImageTags'] is Map ? (item['ImageTags'] as Map)['Primary'] as String? : null);
    final imageUrl = itemId != null && tag != null ? JellyfinApiService.getImageUrl(serverUrl, itemId, imageTag: tag, maxWidth: 500) : null;

    return GestureDetector(
      onTap: () => onPlay(item),
      child: Padding(
        padding: const EdgeInsets.only(right: 12),
        child: SizedBox(
          width: 168,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: SizedBox(
                      width: 168,
                      height: 96,
                      child: imageUrl == null
                          ? const ColoredBox(color: Color(0xFF17191D), child: Icon(Icons.movie_outlined, color: Colors.white24))
                          : SinemaImage(imageUrl: imageUrl, httpHeaders: JellyfinApiService.authHeaders(token), fit: BoxFit.cover, memCacheWidth: 500, errorWidget: (_, _, _) => const ColoredBox(color: Color(0xFF17191D))),
                    ),
                  ),
                  if (isWatched)
                    Positioned(
                      top: 4,
                      right: 4,
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                        child: Icon(Icons.check, size: 14, color: Theme.of(context).colorScheme.primary),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Text('E${indexNumber ?? '?'} • $name', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
            ],
          ),
        ),
      ),
    );
  }
}

class _EpisodeListSheet extends StatefulWidget {
  const _EpisodeListSheet({
    required this.serverUrl,
    required this.userId,
    required this.token,
    required this.seriesId,
    required this.seriesName,
    required this.seasons,
    required this.initialSeasonId,
    required this.initialEpisodes,
    required this.onSelectEpisode,
  });
  final String serverUrl;
  final String userId;
  final String token;
  final String seriesId;
  final String seriesName;
  final List<dynamic> seasons;
  final String? initialSeasonId;
  final List<dynamic> initialEpisodes;
  final void Function(Map<String, dynamic> episode) onSelectEpisode;

  @override
  State<_EpisodeListSheet> createState() => _EpisodeListSheetState();
}

class _EpisodeListSheetState extends State<_EpisodeListSheet> {
  final _api = JellyfinApiService();
  late String? _seasonId = widget.initialSeasonId;
  late List<dynamic> _episodes = widget.initialEpisodes;
  bool _loading = false;

  List<Map<String, dynamic>> get _seasonList => widget.seasons.whereType<Map<String, dynamic>>().toList();

  String? get _nextSeasonId {
    final seasons = _seasonList;
    final index = seasons.indexWhere((s) => s['Id'] == _seasonId);
    return index >= 0 && index + 1 < seasons.length ? _asString(seasons[index + 1]['Id']) : null;
  }

  String? get _nextSeasonName {
    final seasons = _seasonList;
    final index = seasons.indexWhere((s) => s['Id'] == _seasonId);
    return index >= 0 && index + 1 < seasons.length ? _asString(seasons[index + 1]['Name']) : null;
  }

  Future<void> _goToSeason(String seasonId) async {
    setState(() => _loading = true);
    try {
      final episodes = await _api.getEpisodes(widget.serverUrl, widget.userId, widget.token, widget.seriesId, seasonId: seasonId);
      if (mounted) setState(() { _seasonId = seasonId; _episodes = episodes; _loading = false; });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        height: MediaQuery.of(context).size.height * .85,
        child: SafeArea(
          child: Column(
            children: [
              const SizedBox(height: 10),
              Container(width: 38, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(4))),
              const SizedBox(height: 16),
              Text('${_episodes.length} Episodes', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
              const Divider(height: 24, color: Color(0xFF252525)),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : ListView.separated(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        itemCount: _episodes.length,
                        separatorBuilder: (_, _) => const Divider(height: 24, color: Color(0xFF1B1D22)),
                        itemBuilder: (context, index) {
                          final episode = _episodes[index];
                          if (episode is! Map<String, dynamic>) return const SizedBox.shrink();
                          return _EpisodeListRow(episode: episode, serverUrl: widget.serverUrl, token: widget.token, onTap: () => widget.onSelectEpisode(episode));
                        },
                      ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                child: Row(children: [
                  if (_nextSeasonId != null) ...[
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => _goToSeason(_nextSeasonId!),
                        child: Text('Go to ${_nextSeasonName ?? 'Next Season'}', overflow: TextOverflow.ellipsis),
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],
                  Expanded(child: OutlinedButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Go to Show'))),
                ]),
              ),
            ],
          ),
        ),
      );
}

class _EpisodeListRow extends StatelessWidget {
  const _EpisodeListRow({required this.episode, required this.serverUrl, required this.token, required this.onTap});
  final Map<String, dynamic> episode;
  final String serverUrl;
  final String token;
  final VoidCallback onTap;

  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  String? _formatDate(String? iso) {
    final date = iso == null ? null : DateTime.tryParse(iso);
    if (date == null) return null;
    return '${_months[date.month - 1]} ${date.day}, ${date.year}';
  }

  @override
  Widget build(BuildContext context) {
    final itemId = _asString(episode['Id']);
    final name = _asString(episode['Name']) ?? 'Episode';
    final indexNumber = episode['IndexNumber'];
    final date = _formatDate(_asString(episode['PremiereDate']));
    final overview = _asString(episode['Overview']);
    final tag = _asString(episode['PrimaryImageTag']) ?? (episode['ImageTags'] is Map ? _asString((episode['ImageTags'] as Map)['Primary']) : null);
    final imageUrl = itemId != null && tag != null ? JellyfinApiService.getImageUrl(serverUrl, itemId, imageTag: tag, maxWidth: 400) : null;

    return InkWell(
      onTap: onTap,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Stack(children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 110,
                height: 70,
                child: imageUrl == null
                    ? const ColoredBox(color: Color(0xFF17191D), child: Icon(Icons.movie_outlined, color: Colors.white24))
                    : SinemaImage(imageUrl: imageUrl, httpHeaders: JellyfinApiService.authHeaders(token), fit: BoxFit.cover, memCacheWidth: 400, errorWidget: (_, _, _) => const ColoredBox(color: Color(0xFF17191D))),
              ),
            ),
            if (indexNumber != null)
              Positioned(
                top: 4,
                right: 4,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(3)),
                  child: Text('E$indexNumber', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
                ),
              ),
          ]),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                if (date != null) Padding(padding: const EdgeInsets.only(top: 2), child: Text(date, style: const TextStyle(fontWeight: FontWeight.w700, color: Color(0xFFA5A7AC)))),
                if (overview != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(overview, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Color(0xFFA5A7AC)))),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
