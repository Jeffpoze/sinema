// ignore_for_file: avoid_print

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../settings_controller.dart';

/// Converts Jellyfin's tick-based playback position (100ns units) to a [Duration].
Duration ticksToDuration(dynamic ticks) =>
    Duration(microseconds: ((ticks as num?) ?? 0).toInt() ~/ 10);

class JellyfinSession {
  const JellyfinSession({
    required this.serverUrl,
    required this.userId,
    required this.token,
    required this.username,
    this.isAdministrator = false,
  });

  final String serverUrl;
  final String userId;
  final String token;
  final String username;
  final bool isAdministrator;
}

// A slow or overloaded Jellyfin server can otherwise leave a request pending
// forever, which stalls the whole homepage (it awaits every section before
// showing anything). Bound every request so a stuck one fails fast instead.
class _TimeoutHttpClient extends http.BaseClient {
  _TimeoutHttpClient(this._inner, this._timeout);
  final http.Client _inner;
  final Duration _timeout;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _inner.send(request).timeout(_timeout);

  @override
  void close() => _inner.close();
}

class JellyfinApiService {
  JellyfinApiService({http.Client? client})
    : _client = _TimeoutHttpClient(
        client ?? http.Client(),
        const Duration(seconds: 30),
      );

  final http.Client _client;

  static const _deviceId = 'c78432a9-816f-45b6-b510-123456789abc';
  static const _clientIdentity =
      'Client="Sinema", Device="iOS", DeviceId="$_deviceId", Version="1.0.0"';

  // Requesting a size matching where the image is actually displayed (rather
  // than whatever resolution the source art happens to be) is the single
  // biggest lever for scroll smoothness and load time on a modest home
  // server: fewer bytes over the wire and far cheaper decodes.
  static String getImageUrl(
    String serverUrl,
    String itemId, {
    String? imageTag,
    int? maxWidth,
  }) {
    final cleanUrl = serverUrl.trim().replaceAll(RegExp(r'/*$'), '');
    final tagParam = imageTag != null ? '&tag=$imageTag' : '';
    final widthParam = maxWidth != null ? '&maxWidth=$maxWidth' : '';
    return '$cleanUrl/Items/$itemId/Images/Primary?quality=90$tagParam$widthParam';
  }

  static String authorizationHeader(String token) =>
      'MediaBrowser $_clientIdentity, Token="$token"';

  static String getBackdropUrl(
    String serverUrl,
    String itemId, {
    String? imageTag,
    int? maxWidth,
  }) {
    final cleanUrl = serverUrl.trim().replaceAll(RegExp(r'/*$'), '');
    final tagParam = imageTag != null ? '&tag=$imageTag' : '';
    final widthParam = maxWidth != null ? '&maxWidth=$maxWidth' : '';
    return '$cleanUrl/Items/$itemId/Images/Backdrop?quality=90$tagParam$widthParam';
  }

  // A transparent title-treatment image, when the metadata provider has one.
  static String getLogoUrl(
    String serverUrl,
    String itemId, {
    String? imageTag,
    int? maxWidth,
  }) {
    final cleanUrl = serverUrl.trim().replaceAll(RegExp(r'/*$'), '');
    final tagParam = imageTag != null ? '&tag=$imageTag' : '';
    final widthParam = maxWidth != null ? '&maxWidth=$maxWidth' : '';
    return '$cleanUrl/Items/$itemId/Images/Logo?quality=90$tagParam$widthParam';
  }

  /// Text-based subtitle codecs Jellyfin can embed as a WebVTT HLS rendition
  /// without re-encoding video. Anything else (e.g. PGS/VOBSUB image subs)
  /// needs to be burned into the video instead.
  static const _textSubtitleCodecs = {
    'subrip',
    'srt',
    'ass',
    'ssa',
    'vtt',
    'webvtt',
    'mov_text',
  };

  static String subtitleMethodFor(String? codec) =>
      codec != null && _textSubtitleCodecs.contains(codec.toLowerCase())
      ? 'Hls'
      : 'Encode';

  static String getStreamUrl(
    String serverUrl,
    String itemId,
    String token, {
    int? maxBitrateBps,
    int? subtitleStreamIndex,
    String? subtitleMethod,
    String? playSessionId,
  }) {
    final cleanUrl = serverUrl.trim().replaceAll(RegExp(r'/*$'), '');
    final params = <String, String>{
      'api_key': token,
      'MediaSourceId': itemId,
      'PlaySessionId': ?playSessionId,
      // This always transcodes, which is the fallback path used when
      // PlaybackInfo negotiation (below) isn't in play or fails. Query
      // params on this endpoint aren't how direct-play negotiation works —
      // see getPlaybackInfo for the real mechanism.
      'VideoCodec': 'h264',
      'AudioCodec': 'aac',
      if (maxBitrateBps != null) 'VideoBitrate': '$maxBitrateBps',
      if (subtitleStreamIndex != null) ...{
        'SubtitleStreamIndex': '$subtitleStreamIndex',
        'SubtitleMethod': subtitleMethod ?? 'Hls',
      },
    };
    final query = params.entries
        .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    return '$cleanUrl/Videos/$itemId/master.m3u8?$query';
  }

  // Offline download only ever does a single plain HTTP GET to one URL (no
  // HLS/segment support), so it needs a single complete file:
  // - Already-compatible container (mp4/m4v/mov, matching the
  //   DirectPlayProfile restriction): the static original file, no server
  //   work needed.
  // - Anything else (mkv, avi, etc.): a forced progressive single-file
  //   transcode to mp4 — Jellyfin streams the encode as it happens rather
  //   than pre-generating segments, which is exactly what a plain GET can
  //   save straight to disk. Slower and loads the server, but works for
  //   everything.
  static String getDownloadUrl(String serverUrl, String itemId, String token, {required bool needsTranscode}) {
    final cleanUrl = serverUrl.trim().replaceAll(RegExp(r'/*$'), '');
    if (!needsTranscode) {
      return '$cleanUrl/Videos/$itemId/stream?Static=true&api_key=${Uri.encodeQueryComponent(token)}';
    }
    return '$cleanUrl/Videos/$itemId/stream.mp4?Static=false&VideoCodec=h264&AudioCodec=aac&api_key=${Uri.encodeQueryComponent(token)}';
  }

  // The real mechanism Jellyfin clients use to avoid an unnecessary
  // transcode: post a DeviceProfile describing what the player can decode
  // (modeled on Jellyfin's own official Swiftfin client's VLC/ffmpeg-backed
  // profile, since media_kit is also ffmpeg-based) and let the server decide
  // direct play vs. direct stream vs. transcode. The response hands back
  // either a ready-made TranscodingUrl or the info needed to build a direct
  // stream URL — never build codec query params by hand for this endpoint.
  Future<Map<String, dynamic>> getPlaybackInfo(
    String serverUrl,
    String userId,
    String token,
    String itemId, {
    int? maxBitrateBps,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
  }) async {
    final cleanUrl = _normalizeUrl(serverUrl);
    final uri = Uri.parse(
      '$cleanUrl/Items/$itemId/PlaybackInfo',
    ).replace(queryParameters: {'UserId': userId});
    const audioCodecs =
        'aac,ac3,alac,amr_nb,amr_wb,dts,eac3,flac,mp1,mp2,mp3,nellymoser,opus,'
        'pcm_alaw,pcm_bluray,pcm_dvd,pcm_mulaw,pcm_s16be,pcm_s16le,pcm_s24be,'
        'pcm_s24le,pcm_u8,speex,vorbis,wavpack,wmalossless,wmapro,wmav1,wmav2';
    final deviceProfile = {
      if (maxBitrateBps != null) ...{
        'MaxStreamingBitrate': maxBitrateBps,
        'MaxStaticBitrate': maxBitrateBps,
      },
      'DirectPlayProfiles': [
        {
          'Type': 'Video',
          // This profile was originally modeled on Swiftfin's VLC/ffmpeg
          // backend (media_kit's mpv is also ffmpeg-based), which reads
          // essentially any container directly — so it never restricted
          // Container here. Now that playback goes through a real native
          // AVPlayer, that's actively wrong: AVPlayer cannot open Matroska
          // at all. Without this restriction, Jellyfin offered Direct Play
          // for an .mkv source with compatible codecs, we built a plain
          // static-file URL for it (content-type video/x-matroska,
          // confirmed via direct HTTP fetch), and handed that straight to
          // AVPlayer — which fails immediately with a generic "Cannot Open"
          // (AVFoundation error -11829). Restricting Container to what
          // AVPlayer/ExoPlayer actually support makes Jellyfin correctly
          // fall back to a Direct Stream (cheap container remux into HLS,
          // no re-encode) for anything else.
          'Container': 'mp4,m4v,mov',
          'AudioCodec': audioCodecs,
          'VideoCodec':
              'av1,dirac,dv,ffv1,flv1,h261,h263,h264,hevc,mjpeg,mpeg1video,'
              'mpeg2video,mpeg4,msmpeg4v1,msmpeg4v2,msmpeg4v3,prores,theora,'
              'vc1,vp8,vp9,wmv1,wmv2,wmv3',
        },
        {'Type': 'Audio', 'AudioCodec': audioCodecs},
      ],
      'TranscodingProfiles': [
        {
          'Type': 'Video',
          'Container': 'ts',
          'Protocol': 'hls',
          'AudioCodec': 'aac,ac3,alac,dts,eac3,flac,mp1,mp2,mp3,opus,vorbis',
          'VideoCodec': 'h263,h264,hevc,mjpeg,mpeg1video,mpeg2video,mpeg4,vp9',
          'Context': 'Streaming',
          'MaxAudioChannels': '8',
          'MinSegments': 2,
          'BreakOnNonKeyFrames': true,
        },
      ],
      'SubtitleProfiles': [
        for (final format in ['ass', 'mov_text', 'srt', 'ssa', 'subrip', 'vtt'])
          {'Format': format, 'Method': 'Embed'},
        for (final format in ['dvbsub', 'dvdsub', 'pgssub'])
          {'Format': format, 'Method': 'Encode'},
      ],
      // Direct-playing a Dolby Vision stream's base layer without applying
      // its RPU dynamic metadata produces exactly the washed-out/green look
      // reported — media_kit's bundled decoder can read the bitstream, but
      // doesn't apply DoVi's dynamic tone curve. Deliberately leave DOVI*
      // out of the accepted ranges below so Jellyfin transcodes those
      // instead: its own server-side ffmpeg does proper DoVi->HDR10/SDR
      // conversion, and we just play the corrected result. Plain HDR10/HLG
      // (no DoVi layer) still direct-plays fine with the tone-mapping set
      // above.
      'CodecProfiles': [
        for (final codec in ['hevc', 'av1', 'vp9'])
          {
            'Codec': codec,
            'Type': 'Video',
            'Conditions': [
              {'Condition': 'NotEquals', 'IsRequired': false, 'Property': 'IsAnamorphic', 'Value': 'true'},
              {'Condition': 'NotEquals', 'IsRequired': false, 'Property': 'IsInterlaced', 'Value': 'true'},
              {
                'Condition': 'EqualsAny',
                'IsRequired': true,
                'Property': 'VideoRangeType',
                'Value': 'SDR|HDR10|HDR10Plus|HLG',
              },
            ],
          },
      ],
    };
    final body = {
      'UserId': userId,
      'DeviceProfile': deviceProfile,
      'AutoOpenLiveStream': true,
      if (maxBitrateBps != null) 'MaxStreamingBitrate': maxBitrateBps,
      if (audioStreamIndex != null) 'AudioStreamIndex': audioStreamIndex,
      if (subtitleStreamIndex != null)
        'SubtitleStreamIndex': subtitleStreamIndex,
    };
    final response = await _client.post(
      uri,
      headers: {...authHeaders(token), 'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      print(
        'getPlaybackInfo failed for $itemId: ${response.statusCode} ${response.body}',
      );
      throw Exception('Unable to get playback info.');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  // Turns a PlaybackInfo response into a playable URL: use the server's own
  // TranscodingUrl when it decided to transcode, otherwise build the direct
  // (or direct-stream/remux) file URL ourselves.
  static (String url, String playSessionId)? buildUrlFromPlaybackInfo(
    String serverUrl,
    String itemId,
    String token,
    Map<String, dynamic> playbackInfo,
  ) {
    final cleanUrl = serverUrl.trim().replaceAll(RegExp(r'/*$'), '');
    final playSessionId = playbackInfo['PlaySessionId'] as String?;
    final sources = playbackInfo['MediaSources'] as List<dynamic>?;
    if (playSessionId == null || sources == null || sources.isEmpty) {
      return null;
    }
    final source = sources.first as Map<String, dynamic>;
    final transcodingUrl = source['TranscodingUrl'] as String?;
    if (transcodingUrl != null) {
      final separator = transcodingUrl.contains('?') ? '&' : '?';
      return ('$cleanUrl$transcodingUrl${separator}api_key=$token', playSessionId);
    }
    final mediaSourceId = source['Id'] as String? ?? itemId;
    final tag = source['ETag'] as String?;
    final params = <String, String>{
      'api_key': token,
      'Static': 'true',
      'PlaySessionId': playSessionId,
      'MediaSourceId': mediaSourceId,
      'Tag': ?tag,
    };
    final query = params.entries
        .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    return ('$cleanUrl/Videos/$itemId/stream?$query', playSessionId);
  }

  // We were only ever reporting Stopped, never Playing or Playing/Progress.
  // No real Jellyfin client does that — the session/transcode job has no
  // signal that a client is still actively watching, which server logs
  // showed leading to its own idle "kill timer" tearing down the transcode
  // mid-playback (surfacing to us as a fatal read timeout).
  Future<void> reportPlaybackStart(
    String serverUrl,
    String token,
    String itemId,
    String playSessionId,
  ) async {
    final cleanUrl = _normalizeUrl(serverUrl);
    final uri = Uri.parse('$cleanUrl/Sessions/Playing');
    try {
      await _client.post(
        uri,
        headers: {...authHeaders(token), 'Content-Type': 'application/json'},
        body: jsonEncode({
          'ItemId': itemId,
          'PlaySessionId': playSessionId,
          'CanSeek': true,
        }),
      );
    } catch (e) {
      print('reportPlaybackStart failed for $itemId: $e');
    }
  }

  Future<void> reportPlaybackProgress(
    String serverUrl,
    String token,
    String itemId,
    String playSessionId,
    Duration position, {
    required bool isPaused,
  }) async {
    final cleanUrl = _normalizeUrl(serverUrl);
    final uri = Uri.parse('$cleanUrl/Sessions/Playing/Progress');
    try {
      await _client.post(
        uri,
        headers: {...authHeaders(token), 'Content-Type': 'application/json'},
        body: jsonEncode({
          'ItemId': itemId,
          'PlaySessionId': playSessionId,
          'PositionTicks': position.inMicroseconds * 10,
          'IsPaused': isPaused,
          'CanSeek': true,
          'EventName': 'timeupdate',
        }),
      );
    } catch (e) {
      print('reportPlaybackProgress failed for $itemId: $e');
    }
  }

  // Jellyfin only tears down a transcode session's ffmpeg process once it's
  // told playback stopped (or the session times out on its own, which can
  // take minutes and pile up under repeated testing). Report it explicitly
  // whenever the player closes so the server isn't left transcoding for
  // nothing.
  Future<void> reportPlaybackStopped(
    String serverUrl,
    String token,
    String itemId,
    String playSessionId,
    Duration position,
  ) async {
    final cleanUrl = _normalizeUrl(serverUrl);
    final uri = Uri.parse('$cleanUrl/Sessions/Playing/Stopped');
    try {
      await _client.post(
        uri,
        headers: {...authHeaders(token), 'Content-Type': 'application/json'},
        body: jsonEncode({
          'ItemId': itemId,
          'PlaySessionId': playSessionId,
          'PositionTicks': position.inMicroseconds * 10,
        }),
      );
    } catch (e) {
      print('reportPlaybackStopped failed for $itemId: $e');
    }
  }

  // Audio-only items (audiobooks, music) don't have a video stream, so the
  // /Videos master.m3u8 endpoint isn't reliable for them; Jellyfin's audio
  // endpoint is built for exactly this.
  static String getAudioStreamUrl(
    String serverUrl,
    String itemId,
    String userId,
    String token, {
    int? maxBitrateBps,
  }) {
    final cleanUrl = serverUrl.trim().replaceAll(RegExp(r'/*$'), '');
    final params = <String, String>{
      'api_key': token,
      'UserId': userId,
      'DeviceId': _deviceId,
      'Container': 'opus,mp3,aac,m4a,m4b,flac,wav,ogg,wma',
      'AudioCodec': 'aac',
      'TranscodingContainer': 'ts',
      if (maxBitrateBps != null) 'MaxStreamingBitrate': '$maxBitrateBps',
    };
    final query = params.entries
        .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    return '$cleanUrl/Audio/$itemId/universal?$query';
  }

  static Map<String, String> authHeaders(String token) {
    final value = authorizationHeader(token);
    return {'Authorization': value, 'X-Emby-Authorization': value};
  }

  Future<JellyfinSession> login({
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    try {
      final cleanServerUrl = _normalizeUrl(serverUrl);
      // The explicit interpolation keeps the endpoint construction readable.
      // ignore: unnecessary_brace_in_string_interps
      final requestUri = Uri.parse(
        '${cleanServerUrl}/Users/AuthenticateByName',
      );
      const authorization = 'MediaBrowser $_clientIdentity';
      final headers = {
        'Content-Type': 'application/json',
        'Authorization': authorization,
        'X-Emby-Authorization': authorization,
      };
      final body = jsonEncode({'Username': username.trim(), 'Pw': password});
      final request = http.Request('POST', requestUri)
        ..headers.addAll(headers)
        ..bodyBytes = utf8.encode(body);
      final response = await http.Response.fromStream(
        await _client.send(request),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        print('login failed: ${response.statusCode}');
        throw Exception('Unable to sign in.');
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final user = data['User'] as Map<String, dynamic>;
      final policy = user['Policy'] as Map<String, dynamic>?;
      return JellyfinSession(
        serverUrl: cleanServerUrl,
        userId: user['Id'] as String,
        token: data['AccessToken'] as String,
        username: user['Name'] as String,
        isAdministrator: policy?['IsAdministrator'] == true,
      );
    } catch (e) {
      print('login error: $e');
      rethrow;
    }
  }

  Future<List<dynamic>> getFeaturedItems(
    String serverUrl,
    String userId,
    String token,
  ) async {
    final cleanUrl = _normalizeUrl(serverUrl);
    final uri = Uri.parse('$cleanUrl/Users/$userId/Items').replace(
      queryParameters: {
        'SortBy': 'DateCreated',
        'SortOrder': 'Descending',
        'IncludeItemTypes': 'Movie,Series',
        'Recursive': 'true',
        'Limit': '10',
        'Fields': 'Overview,BackdropImageTags,PrimaryImageTag,ProductionYear',
      },
    );
    final response = await _client.get(uri, headers: authHeaders(token));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      print('getFeaturedItems failed: ${response.statusCode} ${response.body}');
      throw Exception('Unable to load featured items.');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final items = (data['Items'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>();
    return items
        .where(
          (item) =>
              (item['BackdropImageTags'] as List<dynamic>?)?.isNotEmpty == true,
        )
        .toList();
  }

  // Powers the homepage banner's network rotation — a "Top 10 on Netflix"
  // style list, rather than the same overall latest-additions every time.
  Future<List<dynamic>> getTopItemsForStudio(
    String serverUrl,
    String userId,
    String token,
    String studioId, {
    int limit = 10,
  }) async {
    final cleanUrl = _normalizeUrl(serverUrl);
    final uri = Uri.parse('$cleanUrl/Users/$userId/Items').replace(
      queryParameters: {
        'StudioIds': studioId,
        'SortBy': 'CommunityRating,DateCreated',
        'SortOrder': 'Descending',
        'IncludeItemTypes': 'Movie,Series',
        'Recursive': 'true',
        'Limit': '$limit',
        'Fields': 'Overview,BackdropImageTags,PrimaryImageTag,ProductionYear',
      },
    );
    final response = await _client.get(uri, headers: authHeaders(token));
    if (response.statusCode < 200 || response.statusCode >= 300) return const [];
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final items = (data['Items'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>();
    return items
        .where(
          (item) =>
              (item['BackdropImageTags'] as List<dynamic>?)?.isNotEmpty == true,
        )
        .toList();
  }

  Future<List<dynamic>> getContinueWatching(
    String serverUrl,
    String userId,
    String token,
  ) {
    final cleanUrl = _normalizeUrl(serverUrl);
    return _getItemList(
      '$cleanUrl/Users/$userId/Items/Resume?Limit=12&Fields=PrimaryImageTag,ImageTags,SeriesPrimaryImageTag',
      token,
    );
  }

  Future<List<dynamic>> getRecentItemsForView(
    String serverUrl,
    String userId,
    String token,
    String viewId,
  ) async {
    final cleanUrl = _normalizeUrl(serverUrl);
    final uri = Uri.parse('$cleanUrl/Users/$userId/Items').replace(
      queryParameters: {
        'ParentId': viewId,
        'SortBy': 'PremiereDate,ProductionYear,SortName',
        'SortOrder': 'Descending',
        'Recursive': 'true',
        'Filters': 'IsNotFolder',
        'Limit': '20',
        'Fields': 'PrimaryImageTag,ImageTags,SeriesPrimaryImageTag,AlbumPrimaryImageTag,AlbumId,PremiereDate,ProductionYear,EndDate,Status',
      },
    );
    final response = await _client.get(uri, headers: authHeaders(token));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      print(
        'getRecentItemsForView failed for $viewId: ${response.statusCode} ${response.body}',
      );
      throw Exception('Unable to load recent items.');
    }
    final data = jsonDecode(response.body);
    final items = data is Map<String, dynamic> && data['Items'] is List<dynamic>
        ? data['Items'] as List<dynamic>
        : const [];
    return _collapseToParentItems(items, serverUrl, userId, token);
  }

  // "Recently added" for a show/music library returns newly added episodes or
  // tracks, not the shows/albums themselves. Collapse those down to one entry
  // per series/album (using the parent's own poster/metadata) so the homepage
  // rows read like a show/album list instead of a flat file list.
  Future<List<dynamic>> _collapseToParentItems(
    List<dynamic> rawItems,
    String serverUrl,
    String userId,
    String token,
  ) async {
    final ordered = <dynamic>[];
    final seenParentIds = <String>{};
    final parentIdsNeeded = <String>[];
    final latestYearByParentId = <String, int>{};
    for (final raw in rawItems) {
      if (raw is! Map<String, dynamic>) continue;
      final parentId = switch (raw['Type']) {
        'Episode' => raw['SeriesId'] as String?,
        'Audio' => raw['AlbumId'] as String?,
        _ => null,
      };
      if (parentId == null) {
        ordered.add(raw);
        continue;
      }
      final rawYear =
          raw['ProductionYear'] as int? ??
          DateTime.tryParse(raw['PremiereDate'] as String? ?? '')?.year;
      if (rawYear != null) {
        final current = latestYearByParentId[parentId];
        if (current == null || rawYear > current)
          latestYearByParentId[parentId] = rawYear;
      }
      if (seenParentIds.contains(parentId)) continue;
      seenParentIds.add(parentId);
      parentIdsNeeded.add(parentId);
      ordered.add(parentId);
    }
    if (parentIdsNeeded.isEmpty) return ordered;
    // One batched request for all parents in this row, instead of one request per item.
    final parentsById = await _getItemsByIds(
      serverUrl,
      userId,
      token,
      parentIdsNeeded,
    );
    // A show's recorded end date can lag behind reality (e.g. a metadata
    // provider marking an anime "Ended" between seasons). If we just saw a
    // newer episode than that recorded end date, treat the show as ongoing.
    for (final id in parentIdsNeeded) {
      final parent = parentsById[id];
      final latestYear = latestYearByParentId[id];
      if (parent == null || latestYear == null) continue;
      final endYear = DateTime.tryParse(parent['EndDate'] as String? ?? '')
          ?.year;
      if (endYear != null && endYear < latestYear) {
        parent.remove('EndDate');
        parent['Status'] = 'Continuing';
      }
    }
    return ordered
        .map((entry) {
          if (entry is String) {
            final parent = parentsById[entry];
            return parent != null && parent.isNotEmpty ? parent : null;
          }
          return entry;
        })
        .whereType<Map<String, dynamic>>()
        .toList();
  }

  Future<Map<String, Map<String, dynamic>>> _getItemsByIds(
    String serverUrl,
    String userId,
    String token,
    List<String> ids,
  ) async {
    final cleanUrl = _normalizeUrl(serverUrl);
    final uri = Uri.parse('$cleanUrl/Users/$userId/Items').replace(
      queryParameters: {
        'Ids': ids.join(','),
        'Fields': 'PrimaryImageTag,ImageTags,ProductionYear,EndDate,Status',
      },
    );
    final response = await _client.get(uri, headers: authHeaders(token));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      print('_getItemsByIds failed: ${response.statusCode} ${response.body}');
      return {};
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final items = (data['Items'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>();
    return {
      for (final item in items)
        if (item['Id'] is String) item['Id'] as String: item,
    };
  }

  Future<List<dynamic>> searchItems(
    String serverUrl,
    String userId,
    String token,
    String query,
  ) async {
    final cleanUrl = _normalizeUrl(serverUrl);
    final uri = Uri.parse('$cleanUrl/Users/$userId/Items').replace(
      queryParameters: {
        'SearchTerm': query,
        'Recursive': 'true',
        'IncludeItemTypes': 'Movie,Series,Episode,Audio,MusicAlbum,BoxSet',
        'Limit': '60',
        'Fields': 'PrimaryImageTag,ImageTags,SeriesPrimaryImageTag,AlbumPrimaryImageTag,AlbumId,ProductionYear,EndDate,Status',
      },
    );
    final response = await _client.get(uri, headers: authHeaders(token));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      print('searchItems failed for "$query": ${response.statusCode} ${response.body}');
      throw Exception('Search failed.');
    }
    final data = jsonDecode(response.body);
    if (data is Map<String, dynamic> && data['Items'] is List<dynamic>) return data['Items'] as List<dynamic>;
    return const [];
  }

  Future<List<dynamic>> getLibraryItems(
    String serverUrl,
    String userId,
    String token,
    String viewId, {
    required SortOption sort,
    LibraryFilter? filter,
    String? collectionType,
  }) async {
    final cleanUrl = _normalizeUrl(serverUrl);
    // A Series (and Season) is itself a folder, so recursive + IsNotFolder
    // walked straight past it down to individual episodes — that's why a
    // TV library showed repeated episode posters instead of one tile per
    // show. The right browsable unit depends on what kind of library this
    // is; only fall back to IsNotFolder (leaf items only, recursed all the
    // way down) for a library type that doesn't have one obvious unit.
    final includeTypes = switch (collectionType) {
      'tvshows' => 'Series',
      'movies' => 'Movie',
      'music' => 'MusicAlbum',
      'books' => 'Book',
      _ => null,
    };
    final itemFilters = [if (includeTypes == null) 'IsNotFolder', if (filter?.unwatchedOnly == true) 'IsUnplayed'];
    final yearParam = filter?.year == null ? null : '${filter!.year}';
    final uri = Uri.parse('$cleanUrl/Users/$userId/Items').replace(
      queryParameters: {
        'ParentId': viewId,
        'SortBy': sort.jellyfinSortBy,
        'SortOrder': sort.jellyfinSortOrder,
        'Recursive': 'true',
        if (itemFilters.isNotEmpty) 'Filters': itemFilters.join(','),
        'IncludeItemTypes': ?includeTypes,
        'Limit': '200',
        'Fields': 'PrimaryImageTag,ImageTags,SeriesPrimaryImageTag,AlbumPrimaryImageTag,AlbumId,PremiereDate,ProductionYear,EndDate,Status,CommunityRating',
        'Genres': ?filter?.genre,
        'Years': ?yearParam,
        'OfficialRatings': ?filter?.officialRating,
        'StudioIds': ?filter?.studioId,
        'PersonIds': ?filter?.personId,
      },
    );
    final response = await _client.get(uri, headers: authHeaders(token));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      print(
        'getLibraryItems failed for $viewId: ${response.statusCode} ${response.body}',
      );
      throw Exception('Unable to load library items.');
    }
    final data = jsonDecode(response.body);
    if (data is Map<String, dynamic> && data['Items'] is List<dynamic>)
      return data['Items'] as List<dynamic>;
    return const [];
  }

  // The legacy endpoint (not /Items/Filters2, which has known bugs — it
  // drops Years/OfficialRatings and always returns empty Tags) returns the
  // Genres/Years/OfficialRatings actually present in this library, for
  // building filter pickers.
  Future<Map<String, dynamic>> getLibraryFilterOptions(
    String serverUrl,
    String userId,
    String token,
    String viewId,
  ) async {
    final cleanUrl = _normalizeUrl(serverUrl);
    final uri = Uri.parse('$cleanUrl/Items/Filters').replace(queryParameters: {'userId': userId, 'parentId': viewId});
    final response = await _client.get(uri, headers: authHeaders(token));
    if (response.statusCode < 200 || response.statusCode >= 300) return const {};
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<List<dynamic>> getStudios(
    String serverUrl,
    String userId,
    String token, [
    String? viewId,
  ]) async {
    final cleanUrl = _normalizeUrl(serverUrl);
    final uri = Uri.parse('$cleanUrl/Studios').replace(queryParameters: {'userId': userId, 'parentId': ?viewId, 'Fields': 'ImageTags'});
    final response = await _client.get(uri, headers: authHeaders(token));
    if (response.statusCode < 200 || response.statusCode >= 300) return const [];
    final data = jsonDecode(response.body);
    if (data is Map<String, dynamic> && data['Items'] is List<dynamic>) return data['Items'] as List<dynamic>;
    return const [];
  }

  // "Network" browsing (Apple TV, Netflix, Prime, …) — Jellyfin doesn't have
  // a distinct Network field, but its metadata providers commonly store the
  // distributing network in the same Studios list movies/shows already
  // carry, and Studio items can have their own logo image when a provider
  // supplied one.
  Future<List<dynamic>> getItemsByStudio(
    String serverUrl,
    String userId,
    String token,
    String studioId,
  ) async {
    final cleanUrl = _normalizeUrl(serverUrl);
    final uri = Uri.parse('$cleanUrl/Users/$userId/Items').replace(
      queryParameters: {
        'StudioIds': studioId,
        'Recursive': 'true',
        'IncludeItemTypes': 'Movie,Series',
        'SortBy': 'SortName',
        'SortOrder': 'Ascending',
        'Limit': '200',
        'Fields': 'PrimaryImageTag,ImageTags,PremiereDate,ProductionYear,EndDate,Status,CommunityRating',
      },
    );
    final response = await _client.get(uri, headers: authHeaders(token));
    if (response.statusCode < 200 || response.statusCode >= 300) return const [];
    final data = jsonDecode(response.body);
    if (data is Map<String, dynamic> && data['Items'] is List<dynamic>) return data['Items'] as List<dynamic>;
    return const [];
  }

  Future<List<dynamic>> getPersons(
    String serverUrl,
    String userId,
    String token,
    String viewId,
    String personType,
  ) async {
    final cleanUrl = _normalizeUrl(serverUrl);
    final uri = Uri.parse('$cleanUrl/Persons').replace(queryParameters: {'userId': userId, 'parentId': viewId, 'personTypes': personType});
    final response = await _client.get(uri, headers: authHeaders(token));
    if (response.statusCode < 200 || response.statusCode >= 300) return const [];
    final data = jsonDecode(response.body);
    if (data is Map<String, dynamic> && data['Items'] is List<dynamic>) return data['Items'] as List<dynamic>;
    return const [];
  }

  Future<List<dynamic>> getUpcomingItems(
    String serverUrl,
    String userId,
    String token,
  ) async {
    final cleanUrl = _normalizeUrl(serverUrl);
    final todayUtc = DateTime.now().toUtc();
    final minPremiereDate = DateTime.utc(
      todayUtc.year,
      todayUtc.month,
      todayUtc.day,
    ).toIso8601String();
    // Fetch an extra day of buffer beyond the nominal 7-day window: provider
    // PremiereDate values are compared in UTC, so an item airing late in the
    // local day 7 can otherwise fall just past the UTC cutoff and get
    // dropped for users west of UTC. The 7-local-day cutoff itself is
    // enforced client-side when grouping (see CalendarScreen).
    final maxPremiereDate = DateTime.utc(
      todayUtc.year,
      todayUtc.month,
      todayUtc.day,
    ).add(const Duration(days: 8)).toIso8601String();
    final uri = Uri.parse('$cleanUrl/Users/$userId/Items').replace(
      queryParameters: {
        'Recursive': 'true',
        'IncludeItemTypes': 'Movie,Episode',
        // Jellyfin's IsUnaired filter depends on the item having been flagged
        // that way at scan time, which misses plenty of genuinely upcoming
        // items; MinPremiereDate alone is a more reliable "is this in the
        // future" check.
        'MinPremiereDate': minPremiereDate,
        'MaxPremiereDate': maxPremiereDate,
        'SortBy': 'PremiereDate',
        'SortOrder': 'Ascending',
        'Limit': '100',
        'Fields': 'PrimaryImageTag,ImageTags,SeriesPrimaryImageTag,SeriesName,PremiereDate,IndexNumber,ParentIndexNumber',
      },
    );
    final response = await _client.get(uri, headers: authHeaders(token));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      print('getUpcomingItems failed: ${response.statusCode} ${response.body}');
      throw Exception('Unable to load upcoming releases.');
    }
    final data = jsonDecode(response.body);
    final items = data is Map<String, dynamic> && data['Items'] is List<dynamic>
        ? data['Items'] as List<dynamic>
        : const [];
    // MinPremiereDate should already exclude these, but guard against items with no known air date at all.
    return items
        .where(
          (item) =>
              item is Map<String, dynamic> && item['PremiereDate'] is String,
        )
        .toList();
  }

  Future<Map<String, dynamic>> getItemDetail(
    String serverUrl,
    String userId,
    String token,
    String itemId,
  ) async {
    final cleanUrl = _normalizeUrl(serverUrl);
    final uri = Uri.parse('$cleanUrl/Users/$userId/Items/$itemId').replace(
      queryParameters: {
        'Fields': 'Overview,Genres,Studios,People,PrimaryImageTag,ImageTags,BackdropImageTags,CommunityRating,CriticRating,OfficialRating,PremiereDate,ProductionYear,EndDate,Status,RunTimeTicks,ProviderIds',
      },
    );
    final response = await _client.get(uri, headers: authHeaders(token));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      print(
        'getItemDetail failed for $itemId: ${response.statusCode} ${response.body}',
      );
      throw Exception('Unable to load details.');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<List<dynamic>> getSeasons(
    String serverUrl,
    String userId,
    String token,
    String seriesId,
  ) async {
    final cleanUrl = _normalizeUrl(serverUrl);
    final uri = Uri.parse('$cleanUrl/Shows/$seriesId/Seasons').replace(
      queryParameters: {
        'userId': userId,
        'Fields': 'PrimaryImageTag,ImageTags',
      },
    );
    final response = await _client.get(uri, headers: authHeaders(token));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      print(
        'getSeasons failed for $seriesId: ${response.statusCode} ${response.body}',
      );
      throw Exception('Unable to load seasons.');
    }
    final data = jsonDecode(response.body);
    if (data is Map<String, dynamic> && data['Items'] is List<dynamic>)
      return data['Items'] as List<dynamic>;
    return const [];
  }

  Future<List<dynamic>> getEpisodes(
    String serverUrl,
    String userId,
    String token,
    String seriesId, {
    String? seasonId,
  }) async {
    final cleanUrl = _normalizeUrl(serverUrl);
    final uri = Uri.parse('$cleanUrl/Shows/$seriesId/Episodes').replace(
      queryParameters: {
        'userId': userId,
        'Fields': 'PrimaryImageTag,ImageTags,Overview,PremiereDate,RunTimeTicks,OfficialRating',
        'SeasonId': ?seasonId,
      },
    );
    final response = await _client.get(uri, headers: authHeaders(token));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      print(
        'getEpisodes failed for $seriesId: ${response.statusCode} ${response.body}',
      );
      throw Exception('Unable to load episodes.');
    }
    final data = jsonDecode(response.body);
    if (data is Map<String, dynamic> && data['Items'] is List<dynamic>)
      return data['Items'] as List<dynamic>;
    return const [];
  }

  // For any playable folder that isn't a Series (music albums, audiobook
  // folders, playlists): its direct children are the actually-playable items.
  Future<List<dynamic>> getChildItems(
    String serverUrl,
    String userId,
    String token,
    String parentId,
  ) async {
    final cleanUrl = _normalizeUrl(serverUrl);
    final uri = Uri.parse('$cleanUrl/Users/$userId/Items').replace(
      queryParameters: {
        'ParentId': parentId,
        'SortBy': 'IndexNumber,SortName',
        'SortOrder': 'Ascending',
        'Fields': 'PrimaryImageTag,ImageTags,RunTimeTicks,IndexNumber',
      },
    );
    final response = await _client.get(uri, headers: authHeaders(token));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      print(
        'getChildItems failed for $parentId: ${response.statusCode} ${response.body}',
      );
      throw Exception('Unable to load items.');
    }
    final data = jsonDecode(response.body);
    if (data is Map<String, dynamic> && data['Items'] is List<dynamic>)
      return data['Items'] as List<dynamic>;
    return const [];
  }

  Future<Map<String, dynamic>?> getNextUp(
    String serverUrl,
    String userId,
    String token,
    String seriesId,
  ) async {
    final cleanUrl = _normalizeUrl(serverUrl);
    final uri = Uri.parse('$cleanUrl/Shows/NextUp').replace(
      queryParameters: {
        'userId': userId,
        'SeriesId': seriesId,
        'Limit': '1',
        'Fields': 'PrimaryImageTag,ImageTags,Overview,PremiereDate,RunTimeTicks,OfficialRating',
      },
    );
    final response = await _client.get(uri, headers: authHeaders(token));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      print(
        'getNextUp failed for $seriesId: ${response.statusCode} ${response.body}',
      );
      return null;
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final items = (data['Items'] as List<dynamic>?)
        ?.whereType<Map<String, dynamic>>();
    return items == null || items.isEmpty ? null : items.first;
  }

  Future<List<dynamic>> getMediaStreams(
    String serverUrl,
    String userId,
    String token,
    String itemId,
  ) async {
    final cleanUrl = _normalizeUrl(serverUrl);
    final uri = Uri.parse('$cleanUrl/Items/$itemId')
        .replace(queryParameters: {'userId': userId, 'Fields': 'MediaStreams'});
    final response = await _client.get(uri, headers: authHeaders(token));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      print(
        'getMediaStreams failed for $itemId: ${response.statusCode} ${response.body}',
      );
      return const [];
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final sources = data['MediaSources'] as List<dynamic>?;
    if (sources != null && sources.isNotEmpty) {
      final first = sources.first as Map<String, dynamic>;
      return (first['MediaStreams'] as List<dynamic>?) ?? const [];
    }
    return const [];
  }

  Future<void> setFavorite(
    String serverUrl,
    String userId,
    String token,
    String itemId,
    bool favorite,
  ) async {
    final cleanUrl = _normalizeUrl(serverUrl);
    final uri = Uri.parse('$cleanUrl/Users/$userId/FavoriteItems/$itemId');
    final response = favorite
        ? await _client.post(uri, headers: authHeaders(token))
        : await _client.delete(uri, headers: authHeaders(token));
    if (response.statusCode < 200 || response.statusCode >= 300)
      throw Exception('Unable to update favorite.');
  }

  Future<void> setWatched(
    String serverUrl,
    String userId,
    String token,
    String itemId,
    bool watched,
  ) async {
    final cleanUrl = _normalizeUrl(serverUrl);
    final uri = Uri.parse('$cleanUrl/Users/$userId/PlayedItems/$itemId');
    final response = watched
        ? await _client.post(uri, headers: authHeaders(token))
        : await _client.delete(uri, headers: authHeaders(token));
    if (response.statusCode < 200 || response.statusCode >= 300)
      throw Exception('Unable to update watched status.');
  }

  Future<bool> checkIsAdministrator(
    String serverUrl,
    String userId,
    String token,
  ) async {
    final cleanUrl = _normalizeUrl(serverUrl);
    final response = await _client.get(
      Uri.parse('$cleanUrl/Users/$userId'),
      headers: authHeaders(token),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) return false;
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final policy = data['Policy'] as Map<String, dynamic>?;
    return policy?['IsAdministrator'] == true;
  }

  // Non-destructive default refresh: fills in missing metadata/images without
  // overwriting what's already there. Matches Jellyfin-web's plain "Refresh
  // metadata" button (not the "Replace all metadata" checkbox variant).
  Future<void> refreshMetadata(
    String serverUrl,
    String token,
    String itemId,
  ) async {
    final cleanUrl = _normalizeUrl(serverUrl);
    final uri = Uri.parse('$cleanUrl/Items/$itemId/Refresh').replace(
      queryParameters: {
        'MetadataRefreshMode': 'Default',
        'ImageRefreshMode': 'Default',
        'ReplaceAllMetadata': 'false',
        'ReplaceAllImages': 'false',
      },
    );
    final response = await _client.post(uri, headers: authHeaders(token));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Unable to refresh metadata.');
    }
  }

  Future<void> deleteItem(String serverUrl, String token, String itemId) async {
    final cleanUrl = _normalizeUrl(serverUrl);
    final response = await _client.delete(
      Uri.parse('$cleanUrl/Items/$itemId'),
      headers: authHeaders(token),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Unable to delete item.');
    }
  }

  // A broad field set so the editor round-trips the item's existing metadata
  // instead of silently nulling out fields the detail screen never fetches —
  // Jellyfin's update endpoint replaces the whole editable DTO, not a patch.
  Future<Map<String, dynamic>> getItemForEdit(
    String serverUrl,
    String userId,
    String token,
    String itemId,
  ) async {
    final cleanUrl = _normalizeUrl(serverUrl);
    final uri = Uri.parse('$cleanUrl/Users/$userId/Items/$itemId').replace(
      queryParameters: {
        'Fields': 'Overview,Genres,Studios,People,Tags,ProviderIds,Taglines,'
            'OriginalTitle,SortName,ForcedSortName,PremiereDate,ProductionYear,'
            'EndDate,Status,OfficialRating,CommunityRating,CriticRating,'
            'RunTimeTicks,LockData,LockedFields,PreferredMetadataLanguage,'
            'PreferredMetadataCountryCode,ExternalUrls,RemoteTrailers',
      },
    );
    final response = await _client.get(uri, headers: authHeaders(token));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Unable to load item for editing.');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<void> updateItemMetadata(
    String serverUrl,
    String token,
    String itemId,
    Map<String, dynamic> fullItem,
  ) async {
    final cleanUrl = _normalizeUrl(serverUrl);
    final response = await _client.post(
      Uri.parse('$cleanUrl/Items/$itemId'),
      headers: {...authHeaders(token), 'Content-Type': 'application/json'},
      body: jsonEncode(fullItem),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Unable to update metadata.');
    }
  }

  Future<Map<String, dynamic>?> getFileInfo(
    String serverUrl,
    String userId,
    String token,
    String itemId,
  ) async {
    final cleanUrl = _normalizeUrl(serverUrl);
    final uri = Uri.parse('$cleanUrl/Users/$userId/Items/$itemId')
        .replace(queryParameters: {'Fields': 'MediaSources,Path'});
    final response = await _client.get(uri, headers: authHeaders(token));
    if (response.statusCode < 200 || response.statusCode >= 300) return null;
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final sources = data['MediaSources'] as List<dynamic>?;
    if (sources == null || sources.isEmpty) return null;
    return sources.first as Map<String, dynamic>;
  }

  Future<void> setArtworkFromUrl(
    String serverUrl,
    String token,
    String itemId,
    String imageUrl, {
    String type = 'Primary',
  }) async {
    final imageResponse = await _client.get(Uri.parse(imageUrl));
    if (imageResponse.statusCode < 200 || imageResponse.statusCode >= 300) {
      throw Exception('Could not download that image.');
    }
    final contentType = imageResponse.headers['content-type'] ?? 'image/jpeg';
    if (!contentType.startsWith('image/')) {
      throw Exception('That URL is not an image.');
    }
    final cleanUrl = _normalizeUrl(serverUrl);
    final response = await _client.post(
      Uri.parse('$cleanUrl/Items/$itemId/Images/$type'),
      headers: {...authHeaders(token), 'Content-Type': contentType},
      body: base64Encode(imageResponse.bodyBytes),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Unable to set artwork.');
    }
  }

  // Candidate images from Jellyfin's configured metadata providers (TMDB,
  // Fanart.tv, etc.) — what jellyfin-web's own "Change Image" picker shows.
  // Returns an empty list (not an error) if no providers are configured or
  // none have a match, which is a real, common case on a personal server.
  Future<List<Map<String, dynamic>>> getRemoteImages(
    String serverUrl,
    String token,
    String itemId, {
    required String type,
  }) async {
    final cleanUrl = _normalizeUrl(serverUrl);
    final uri = Uri.parse('$cleanUrl/Items/$itemId/RemoteImages').replace(queryParameters: {'type': type});
    try {
      final response = await _client.get(uri, headers: authHeaders(token));
      if (response.statusCode < 200 || response.statusCode >= 300) return const [];
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return (data['Images'] as List<dynamic>?)?.whereType<Map<String, dynamic>>().toList() ?? const [];
    } catch (_) {
      return const [];
    }
  }

  Future<void> downloadRemoteImage(
    String serverUrl,
    String token,
    String itemId, {
    required String type,
    required String imageUrl,
    String? providerName,
  }) async {
    final cleanUrl = _normalizeUrl(serverUrl);
    final uri = Uri.parse('$cleanUrl/Items/$itemId/RemoteImages/Download').replace(
      queryParameters: {'Type': type, 'ImageUrl': imageUrl, 'ProviderName': ?providerName},
    );
    final response = await _client.post(uri, headers: authHeaders(token));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Unable to apply that image.');
    }
  }

  Future<List<dynamic>> getLibraryViews(
    String serverUrl,
    String userId,
    String token,
  ) async {
    final cleanUrl = _normalizeUrl(serverUrl);
    final response = await _client.get(
      Uri.parse('$cleanUrl/Users/$userId/Views')
          .replace(queryParameters: {'Fields': 'PrimaryImageTag,ImageTags'}),
      headers: authHeaders(token),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      print('getLibraryViews failed: ${response.statusCode} ${response.body}');
      throw Exception('Unable to load library categories.');
    }
    final data = jsonDecode(response.body);
    if (data is List<dynamic>) return data;
    if (data is Map<String, dynamic> && data['Items'] is List<dynamic>)
      return data['Items'] as List<dynamic>;
    return const [];
  }

  Future<List<dynamic>> _getItemList(String url, String token) async {
    final response = await _client.get(
      Uri.parse(url),
      headers: authHeaders(token),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      print(
        '_getItemList failed for $url: ${response.statusCode} ${response.body}',
      );
      throw Exception('Unable to load home media.');
    }
    final data = jsonDecode(response.body);
    if (data is List<dynamic>) return data;
    if (data is Map<String, dynamic> && data['Items'] is List<dynamic>)
      return data['Items'] as List<dynamic>;
    return const [];
  }

  String _normalizeUrl(String value) {
    final trimmed = value.trim();
    return trimmed.replaceFirst(RegExp(r'/+$'), '');
  }
}
